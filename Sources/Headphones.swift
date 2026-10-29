// AirPods (Pro, Max, 3rd/4th gen, Beats Fit Pro) head tracking.
//
// CoreMotion always reports the headphones that are the current sound output; the catalog at the
// bottom switches between paired AirPods by connecting them and making them the output.
//
// Uses: as a second heading reference for the glasses (both sit rigidly on the head, so their
// headings should differ by a constant; when the glasses' gyro drifts we slowly undo it), or as
// the only tracker.

import CoreAudio
import CoreMotion
import IOBluetooth
import QuartzCore
import simd

final class Headphones: NSObject, CMHeadphoneMotionManagerDelegate {
    struct Sample {
        var q: simd_quatd // CMAttitude quaternion as reported (convention detected later)
        var rate: SIMD3<Double> // rotationRate, rad/s, AirPods body frame
        var angles: SIMD3<Double> // CMAttitude (yaw, pitch, roll), for display
        var time: Double // when it was measured, host clock (sensor timestamp when usable)
        var arrival: Double // when it reached us
        var bud = 0 // which earbud measured it: 0 unknown, 1 left, 2 right (they sit mirrored)
    }

    private let manager = CMHeadphoneMotionManager()
    private let queue = OperationQueue()
    private let lock = NSLock()
    private var last: Sample?
    private var pending: [Sample] = []
    private(set) var running = false
    private var rateCount = 0
    private var rateStart = CACurrentMediaTime()
    private var measuredRate = 0.0
    private var burst = 0
    private var maxBurst = 0
    private var lastArrival = 0.0
    private(set) var usesSensorClock = true

    var isAvailable: Bool { manager.isDeviceMotionAvailable }
    var isDenied: Bool { CMHeadphoneMotionManager.authorizationStatus() == .denied }

    func start() {
        guard !running, isAvailable else { return }
        running = true
        manager.delegate = self
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInteractive
        manager.startDeviceMotionUpdates(to: queue) { [weak self] motion, _ in
            guard let self, let m = motion else { return }
            let arrival = CACurrentMediaTime()
            // CMLogItem.timestamp is seconds since boot, the same clock as CACurrentMediaTime.
            // If it ever isn't (or is nonsense), fall back to arrival time.
            let sensorOK = abs(arrival - m.timestamp) < 1
            let q = m.attitude.quaternion
            let sample = Sample(q: simd_normalize(simd_quatd(ix: q.x, iy: q.y, iz: q.z, r: q.w)),
                                rate: SIMD3(m.rotationRate.x, m.rotationRate.y, m.rotationRate.z),
                                angles: SIMD3(m.attitude.yaw, m.attitude.pitch, m.attitude.roll),
                                time: sensorOK ? m.timestamp : arrival, arrival: arrival,
                                // Motion comes from one bud at a time; taking it out switches to the other.
                                bud: m.sensorLocation == .headphoneLeft ? 1 : m.sensorLocation == .headphoneRight ? 2 : 0)
            self.lock.lock()
            self.usesSensorClock = sensorOK
            self.last = sample
            self.pending.append(sample)
            if self.pending.count > 400 { self.pending.removeFirst(self.pending.count - 400) }
            // Bluetooth tends to deliver several samples back to back.
            self.burst = arrival - self.lastArrival < 0.003 ? self.burst + 1 : 1
            self.maxBurst = max(self.maxBurst, self.burst)
            self.lastArrival = arrival
            self.rateCount += 1
            if arrival - self.rateStart >= 1 {
                self.measuredRate = Double(self.rateCount) / (arrival - self.rateStart)
                self.rateCount = 0
                self.rateStart = arrival
            }
            self.lock.unlock()
        }
    }

    func stop() {
        guard running else { return }
        manager.stopDeviceMotionUpdates()
        running = false
    }

    /// Latest sample, or nil when the AirPods aren't worn/connected.
    func latest() -> Sample? {
        lock.lock(); defer { lock.unlock() }
        guard let last, CACurrentMediaTime() - last.arrival < 0.3 else { return nil }
        return last
    }

    func latestYaw() -> Double? { latest()?.angles.x }

    /// Every sample since the previous call, in order.
    func drain() -> [Sample] {
        lock.lock(); defer { lock.unlock() }
        let s = pending
        pending.removeAll(keepingCapacity: true)
        return s
    }

    /// Updates per second over the last second (0 when no data), and the largest back-to-back burst.
    var stats: (rate: Double, maxBurst: Int) {
        lock.lock(); defer { lock.unlock() }
        guard let last, CACurrentMediaTime() - last.arrival < 0.3 else { return (0, maxBurst) }
        return (measuredRate, maxBurst)
    }

    var authorization: String {
        switch CMHeadphoneMotionManager.authorizationStatus() {
        case .authorized: return "authorized"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "not asked yet"
        @unknown default: return "unknown"
        }
    }

    func headphoneMotionManagerDidDisconnect(_ manager: CMHeadphoneMotionManager) {
        lock.lock(); last = nil; pending.removeAll(); lock.unlock()
    }

    /// Seconds since the last sample (infinity if none yet).
    var dataAge: Double {
        lock.lock(); defer { lock.unlock() }
        return last.map { CACurrentMediaTime() - $0.arrival } ?? .infinity
    }

    private var lastRestart = 0.0

    /// Keeps asking for motion while it isn't arriving: macOS only delivers it once the AirPods
    /// are connected and the sound output, which can happen long after launch. Called every second.
    func keepAlive() {
        guard dataAge > 3, CACurrentMediaTime() - lastRestart > 5 else { return }
        lastRestart = CACurrentMediaTime()
        stop()
        start()
    }

    /// Why the AirPods aren't being used, in one calm sentence (nil while motion arrives).
    /// `usual` is the pair last used with this Mac.
    func problem(usual: String?) -> String? {
        guard dataAge > 1 else { return nil }
        switch CMHeadphoneMotionManager.authorizationStatus() {
        case .denied, .restricted: return "Motion & Fitness access is off for RayNeoPin in System Settings."
        case .notDetermined: return "Put your AirPods in to allow motion access."
        default: break
        }
        let output = HeadphoneCatalog.currentOutputAddress()
        if let usual, output != usual.uppercased() {
            return HeadphoneCatalog.isConnected(usual) ? "Your AirPods aren't this Mac's sound output."
                                                       : "Your AirPods are in use on another device."
        }
        if output == nil { return "No AirPods are connected to this Mac." }
        if !isAvailable { return "These headphones don't support head tracking." }
        return "Put both AirPods in your ears to use them."
    }
}

func wrapAngle(_ a: Double) -> Double { atan2(sin(a), cos(a)) }

/// Rotation R minimizing Σ|b − R·a|² (Wahba's problem), via Davenport's q-method with power
/// iteration. Both conventions of the resulting quaternion are tried and the better fit is kept.
func solveRotation(_ pairs: [(a: SIMD3<Double>, b: SIMD3<Double>)]) -> simd_quatd? {
    guard pairs.count >= 3 else { return nil }
    var B = simd_double3x3() // Σ b·aᵀ, element (row i, col j) = B[j][i]
    var scale = 0.0
    for (a, b) in pairs {
        for i in 0..<3 { for j in 0..<3 { B[j][i] += b[i] * a[j] } }
        scale += simd_length(a) * simd_length(b)
    }
    func e(_ i: Int, _ j: Int) -> Double { B[j][i] }
    let sigma = e(0, 0) + e(1, 1) + e(2, 2)
    let z = SIMD3(e(1, 2) - e(2, 1), e(2, 0) - e(0, 2), e(0, 1) - e(1, 0))
    var K = simd_double4x4()
    for i in 0..<3 { for j in 0..<3 { K[j][i] = e(i, j) + e(j, i) - (i == j ? sigma : 0) } }
    for i in 0..<3 { K[3][i] = z[i]; K[i][3] = z[i] }
    K[3][3] = sigma
    // Largest eigenvector: power iteration on K shifted to be positive definite.
    let M = K + simd_double4x4(diagonal: SIMD4(repeating: scale))
    var v = SIMD4<Double>(0.5, 0.5, 0.5, 0.5)
    for _ in 0..<200 { v = simd_normalize(M * v) }
    let q = simd_quatd(ix: v.x, iy: v.y, iz: v.z, r: v.w)
    func residual(_ r: simd_quatd) -> Double { pairs.reduce(0) { $0 + simd_length_squared($1.b - r.act($1.a)) } }
    return residual(q) <= residual(q.conjugate) ? q : q.conjugate
}

/// Learns, from your own head movements, everything needed to turn AirPods attitude into the
/// glasses' frame:
///  - `lag`: AirPods sample time → matching glasses time (Bluetooth/clock offset);
///  - `inverted`: whether CMAttitude's quaternion is body→world or world→body, checked against
///    the AirPods' own gyro;
///  - `X`: rotation from the glasses' body frame to the AirPods' (they sit tilted in the ears);
///  - `W`: rotation from the AirPods' world frame to the glasses'.
/// Then glasses orientation = W · Ra · X.
///
/// The raw AirPods motion is kept, not pairs matched at the time: every solve re-pairs it with the
/// glasses' history at the current delay estimate, and the delay itself is chosen as the one at
/// which the two gyros agree best once rotated onto each other. A wrong early delay can't spoil
/// the data, which used to leave the calibration stuck.
struct AirPodsCalibration {
    private(set) var lag = 0.0
    private(set) var lagCorrelation = 0.0 // 1 − fit error at the chosen delay, for the overlay
    private(set) var inverted = false
    private(set) var X: simd_quatd?
    private(set) var W: simd_quatd?
    private(set) var fitError = 1.0 // rms residual / mean rate (0 = perfect)
    private(set) var pairCount = 0
    private(set) var jumps = 0
    /// Guided calibration: one turn left and right, then one nod up and down, measured on the
    /// glasses. Two perpendicular rotations are exactly what pins down how the AirPods sit
    /// (Wahba's problem needs two non-parallel axes); the glasses check every AirPods sample.
    enum Phase: String { case turn, nod, finishing, done }
    private(set) var phase = Phase.turn
    /// How much of the turn (left and right) and the nod (up and down) is done, 0…1 each.
    private(set) var turned = 0.0
    private(set) var nodded = 0.0
    static let sweepYaw = 20 * Double.pi / 180 // each side
    static let sweepPitch = 12 * Double.pi / 180 // up and down
    private var sweepRef: (yaw: Double, pitch: Double)?
    private var yawRange = (lo: 0.0, hi: 0.0)
    private var pitchRange = (lo: 0.0, hi: 0.0)
    private var airPodsRef: simd_quatd?
    /// Each side of the guided movement, 0…1, filled only as far as both the glasses and the
    /// AirPods agree the head turned that way.
    private(set) var left = 0.0, right = 0.0, up = 0.0, down = 0.0
    /// Calibration per earbud, since motion comes from one bud at a time and they sit mirrored.
    private var xByBud: [Int: simd_quatd] = [:]
    private var bud = 0
    private(set) var budSwitches = 0
    private(set) var gaps = 0
    /// Bumped whenever W is recomputed, so users of the AirPods heading can re-reference.
    private(set) var wVersion = 0
    private var wStale = false // recompute W at the next sample, keeping the old one meanwhile
    private var recentAgreement: [Bool] = [] // last 25 moving samples: did they match the glasses?
    private var gate = true // reject disagreeing samples; off while relearning after a reseat
    private(set) var reseats = 0
    private(set) var restarts = 0

    /// AirPods samples taken while turning: when, and their rotation rate.
    private var moving: [(t: Double, rate: SIMD3<Double>)] = []
    private var lastSample: Headphones.Sample?
    private var conventionScore = 0.0
    private var newSamples = 0
    private var poorSolves = 0
    private var xAtW: simd_quatd? // the X that W was computed with
    private var relearning = false // after a reseat: keep the old result until the new one is ready
    private var peak = 0.0 // the progress bar only moves forward
    private(set) var glitches = 0 // samples skipped because their speed didn't match the glasses
    private(set) var seeded = false // X/convention/lag came from a previous session

    /// What's worth keeping between sessions for the same AirPods (W depends on the session).
    struct Saved: Codable {
        var x: [Double]; var inverted: Bool; var lag: Double
        var buds: [String: [Double]]? // per earbud ("1" left, "2" right)
    }

    var saved: Saved? {
        guard let X, fitError < 0.3, pairCount >= AirPodsCalibration.neededPairs else { return nil }
        func v(_ q: simd_quatd) -> [Double] { [q.vector.x, q.vector.y, q.vector.z, q.vector.w] }
        var buds = xByBud.mapValues(v)
        buds[bud] = v(X)
        return Saved(x: v(X), inverted: inverted, lag: lag, buds: Dictionary(uniqueKeysWithValues: buds.map { (String($0.key), $0.value) }))
    }

    /// Start from a previous session's result; it keeps refining from new movement.
    mutating func seed(_ s: Saved) {
        guard s.x.count == 4 else { return }
        X = simd_normalize(simd_quatd(vector: SIMD4(s.x[0], s.x[1], s.x[2], s.x[3])))
        inverted = s.inverted
        conventionScore = s.inverted ? 1 : -1
        lag = s.lag
        fitError = 0.2
        pairCount = AirPodsCalibration.neededPairs
        turned = 1
        nodded = 1
        phase = .done
        seeded = true
        calibrated = true
        for (k, x) in s.buds ?? [:] where x.count == 4 {
            if let b = Int(k) { xByBud[b] = simd_normalize(simd_quatd(vector: SIMD4(x[0], x[1], x[2], x[3]))) }
        }
    }

    /// Moving samples (both devices turning faster than ~14 °/s) needed: about 2–3 s of movement.
    static let neededPairs = 50
    private(set) var lastPairTime = 0.0

    /// Once calibrated it stays calibrated: only a recalibration, an unknown earbud taking over or
    /// a reseat (which keeps the old result until the new one is solved) change that. Re-checking
    /// against the last ~25 s of movement used to "lose" it whenever you sat still for a while.
    var ready: Bool { calibrated && X != nil && W != nil }
    private(set) var calibrated = false

    private var conditionsMet: Bool {
        X != nil && W != nil && fitError < 0.4 && pairCount >= AirPodsCalibration.neededPairs && turned >= 1 && nodded >= 1
            && (phase == .finishing || phase == .done)
    }

    /// 0…1 for the progress bar: collecting movement in both directions, then the fit quality (so it
    /// keeps moving instead of sitting at 95% while the fit is still poor).
    var progress: Double { ready ? 1 : peak }

    private var rawProgress: Double {
        switch phase {
        case .turn: return 0.45 * turned
        case .nod: return 0.45 + 0.45 * nodded
        case .finishing, .done:
            let enough = min(Double(pairCount) / Double(AirPodsCalibration.neededPairs), 1)
            return 0.9 + 0.09 * enough * min(max((0.8 - fitError) / 0.4, 0), 1)
        }
    }

    /// Enough movement collected but the fit isn't good yet (moving too jerkily, or AirPods loose).
    var fitting: Bool { !ready && pairCount >= AirPodsCalibration.neededPairs && turned >= 1 && nodded >= 1 }

    /// What to do next, for the calibration hint.
    var hint: String {
        switch phase {
        // Yaw grows to the left (counterclockwise seen from above), so the left side is the high end.
        case .turn: return left < 1 ? "step 1 of 2: turn your head to the LEFT" : "step 1 of 2: now to the RIGHT"
        case .nod: return up < 1 ? "step 2 of 2: look UP" : "step 2 of 2: now look DOWN"
        case .finishing: return fitError >= 0.4 && pairCount >= AirPodsCalibration.neededPairs
            ? "once more, a bit slower: left, right, up, down" : "checking against the glasses — keep moving gently"
        case .done: return ""
        }
    }

    mutating func reset() { self = AirPodsCalibration() }

    /// Forget only where the AirPods' world is (after a jump, or to re-align).
    mutating func realign() { wStale = true }

    func bodyToWorld(_ s: Headphones.Sample) -> simd_quatd { inverted ? s.q.inverse : s.q }

    /// AirPods sample as the glasses' orientation (nil until calibrated).
    func pose(_ s: Headphones.Sample) -> simd_quatd? {
        guard let X, let W else { return nil }
        return simd_normalize(W * bodyToWorld(s) * X)
    }

    /// AirPods rotation rate expressed in the glasses' body frame.
    func rate(_ s: Headphones.Sample) -> SIMD3<Double> { X.map { $0.inverse.act(s.rate) } ?? .zero }

    /// Glasses time matching an AirPods sample.
    func glassesTime(_ s: Headphones.Sample) -> Double { s.time + lag }

    mutating func ingest(_ samples: [Headphones.Sample], glasses: (Double) -> PoseSample?) {
        for s in samples {
            defer { lastSample = s }
            let speed = simd_length(s.rate)
            if s.bud != bud { switchBud(to: s.bud) }

            if let prev = lastSample, s.time - prev.time >= 0.2 {
                // After a gap (reconnect, updates restarted) the AirPods' reference frame may have reset.
                gaps += 1
                wStale = true
            }
            if let prev = lastSample, s.time > prev.time {
                let dt = s.time - prev.time
                // Between two samples the attitude must turn by what the AirPods' own gyro measured. Any
                // more is a jump of their reference, not motion: macOS re-centers AirPods yaw whenever
                // an app starts Spatial Audio, and buds get swapped or reseated. Re-take the reference
                // at once instead of letting the drift correction slowly drag the screen over.
                let turned = (prev.q.inverse * s.q).angle
                let measured = simd_length((s.rate + prev.rate) / 2) * dt
                if dt < 0.2, abs(min(turned, 2 * .pi - turned) - measured) > max(2 * .pi / 180, 0.3 * measured) {
                    jumps += 1
                    wStale = true
                }
                // Convention: the body rate implied by consecutive quaternions should match rotationRate.
                if speed > 0.3, dt < 0.1 {
                    let asBodyToWorld = s.q.angularVelocity(from: prev.q, dt: dt)
                    let asWorldToBody = s.q.inverse.angularVelocity(from: prev.q.inverse, dt: dt)
                    conventionScore += simd_dot(asWorldToBody, s.rate) - simd_dot(asBodyToWorld, s.rate)
                    inverted = conventionScore > 0
                }
            }

            guard let g = glasses(glassesTime(s)) else { continue }
            trackSweeps(g.q, airPods: s.q)
            // Once X is known both devices must agree. A single disagreement is a glitch; most recent
            // ones disagreeing means the AirPods were reseated in the ears: X changed, learn it again.
            // Only checked against a finished calibration: an early, rough X would make good samples
            // look wrong (that used to throw the progress back to 0 again and again).
            let agrees = !ready || X.map { simd_length(s.rate - $0.act(g.omega)) < max(0.35, 0.5 * simd_length(g.omega)) } ?? true
            if speed > 0.25, simd_length(g.omega) > 0.25, ready, gate {
                recentAgreement.append(agrees)
                if recentAgreement.count > 25 { recentAgreement.removeFirst() }
                if recentAgreement.count == 25, recentAgreement.filter({ !$0 }).count > 15 {
                    // Keep using the old result until the new one is solved from fresh movement.
                    moving.removeAll()
                    recentAgreement.removeAll()
                    newSamples = 0
                    gate = false
                    seeded = false
                    relearning = true
                    reseats += 1
                }
            }
            if speed > 0.25, agrees || !gate {
                moving.append((s.time, s.rate))
                lastPairTime = s.arrival
                // ~25 s of turning, within the glasses' 30 s history: bad early data ages out.
                if moving.count > 600 { moving.removeFirst(moving.count - 600) }
                if let first = moving.first, s.time - first.t > 25 { moving.removeAll { s.time - $0.t > 25 } }
                newSamples += 1
            }
            // Refinements never make the calibration drop out: the old W stays until replaced.
            // Once calibrated, X is trusted: a reference jump is always re-taken, whatever the latest fit.
            if W == nil || wStale, let X, fitError < 0.4 || calibrated {
                W = simd_normalize(g.q * X.inverse * bodyToWorld(s).inverse)
                xAtW = X
                wStale = false
                wVersion += 1
            }
        }
        if newSamples >= 15 {
            newSamples = 0
            solve(glasses)
        }
    }

    /// Glasses/AirPods rate pairs at delay `L`, both turning.
    private func pairs(_ L: Double, _ from: ArraySlice<(t: Double, rate: SIMD3<Double>)>,
                       _ glasses: (Double) -> PoseSample?) -> [(a: SIMD3<Double>, b: SIMD3<Double>)] {
        from.compactMap { m in
            guard let g = glasses(m.t + L) else { return nil }
            let gs = simd_length(g.omega), a = simd_length(m.rate)
            // Rotating a vector never changes its length: the AirPods must turn as fast as the glasses,
            // whatever their tilt in the ears. A sample that doesn't is a glitch (a bud moving, a
            // Bluetooth hiccup) and is skipped, from the very first sample.
            guard gs > 0.25, abs(a - gs) < max(0.3, 0.35 * gs) else { return nil }
            return (g.omega, m.rate)
        }
    }

    /// Rotation from glasses to AirPods rates, refit without the worst 20% (glitches), and its
    /// relative rms error.
    private func fit(_ p: [(a: SIMD3<Double>, b: SIMD3<Double>)]) -> (x: simd_quatd, error: Double)? {
        guard p.count >= 10, let first = solveRotation(p) else { return nil }
        let ranked = p.sorted { simd_length_squared($0.b - first.act($0.a)) < simd_length_squared($1.b - first.act($1.a)) }
        let kept = Array(ranked.prefix(max(10, p.count * 4 / 5)))
        let x = solveRotation(kept) ?? first
        let rms = sqrt(kept.reduce(0) { $0 + simd_length_squared($1.b - x.act($1.a)) } / Double(kept.count))
        let mean = kept.reduce(0) { $0 + simd_length($1.b) } / Double(kept.count)
        return (x, rms / max(mean, 1e-6))
    }

    private mutating func solve(_ glasses: (Double) -> PoseSample?) {
        // Delay: where the two gyros agree best (−50…+300 ms, then refined to 2.5 ms), on recent motion.
        let recent = moving.suffix(250)
        if recent.count >= 30 {
            var best = (lag: lag, error: Double.infinity)
            for step in -5...30 {
                let L = Double(step) * 0.01
                if let f = fit(pairs(L, recent, glasses)), f.error < best.error { best = (L, f.error) }
            }
            let coarse = best.lag
            for step in -4...4 where step != 0 {
                let L = coarse + Double(step) * 0.0025
                if let f = fit(pairs(L, recent, glasses)), f.error < best.error { best = (L, f.error) }
            }
            if best.error.isFinite { lag = best.lag; lagCorrelation = max(0, 1 - best.error) }
        }

        let all = pairs(lag, moving[...], glasses)
        glitches = moving.count - all.count
        // After a reseat the previous result keeps working until there's enough new movement.
        if relearning, all.count < AirPodsCalibration.neededPairs { return }
        // Calibrated and not much recent movement: keep the result, don't re-judge it on scraps.
        if calibrated, !relearning, all.count < AirPodsCalibration.neededPairs { return }
        relearning = false
        pairCount = all.count
        // A seeded X is only replaced once there is as much fresh data as it was built from.
        guard !seeded || all.count >= AirPodsCalibration.neededPairs, let f = fit(all) else { return }
        fitError = f.error
        // Still poor after ~10 s of extra movement: start collecting again rather than stay stuck.
        if all.count >= AirPodsCalibration.neededPairs, fitError >= 0.4, X == nil || W == nil {
            poorSolves += 1
            // Drop the older half, never everything, so the bar doesn't start over.
            if poorSolves >= 15 { moving.removeFirst(moving.count / 2); poorSolves = 0; restarts += 1 }
        } else {
            poorSolves = 0
        }
        if X == nil || fitError < 0.4 { X = f.x }
        if fitError < 0.4 { gate = true }
        // W depends on X: redo it while X is still improving.
        if let X, let old = xAtW, (old.inverse * X).angle.truncatingRemainder(dividingBy: 2 * .pi) > 0.005,
           2 * .pi - (old.inverse * X).angle > 0.005 { wStale = true }
        if conditionsMet { calibrated = true }
        if ready { phase = .done; xByBud[bud] = X }
        peak = max(peak, min(rawProgress, 0.99))
    }

    /// Starts the guided movement over from where the head points now (recenter).
    mutating func restartSweeps() {
        guard phase == .turn || phase == .nod else { return }
        sweepRef = nil
        airPodsRef = nil
        yawRange = (0, 0)
        pitchRange = (0, 0)
        if phase == .turn { left = 0; right = 0; turned = 0 } else { up = 0; down = 0; nodded = 0 }
    }

    /// Follows the glasses through the guided movement: the turn counts once the head has been 20°
    /// to each side of where it started, the nod once it has been 12° up and down.
    private mutating func trackSweeps(_ q: simd_quatd, airPods: simd_quatd) {
        guard phase == .turn || phase == .nod else { return }
        let yp = q.yawPitch
        guard let ref = sweepRef, let apRef = airPodsRef else { sweepRef = (yp.yaw, yp.pitch); airPodsRef = airPods; return }
        // Glasses: signed yaw (left is +) and pitch (up is +) from where it started. AirPods: how far
        // they rotated, whatever their tilt in the ears. A side only fills as far as both agree.
        let dy = wrapAngle(yp.yaw - ref.yaw), dp = yp.pitch - ref.pitch
        let ap = shortestAngle(apRef, airPods)
        yawRange = (min(yawRange.lo, dy), max(yawRange.hi, dy))
        pitchRange = (min(pitchRange.lo, dp), max(pitchRange.hi, dp))
        if phase == .turn {
            let both = min(abs(dy), ap) / AirPodsCalibration.sweepYaw
            if dy > 0 { left = max(left, min(both, 1)) } else { right = max(right, min(both, 1)) }
        } else {
            let both = min(abs(dp), ap) / AirPodsCalibration.sweepPitch
            if dp > 0 { up = max(up, min(both, 1)) } else { down = max(down, min(both, 1)) }
        }
        turned = (left + right) / 2
        nodded = (up + down) / 2
        if phase == .turn, turned >= 1 { phase = .nod }
        if phase == .nod, nodded >= 1 { phase = .finishing }
        peak = max(peak, min(rawProgress, 0.99))
    }

    /// The other earbud took over: use its own calibration if known, otherwise learn it while the
    /// glasses track alone.
    private mutating func switchBud(to new: Int) {
        if let X, ready { xByBud[bud] = X }
        let old = bud
        bud = new
        // First sample of the session: adopt this bud's saved calibration, if any.
        guard old != 0 else { if let known = xByBud[new] { X = known }; return }
        budSwitches += 1
        moving.removeAll()
        newSamples = 0
        recentAgreement.removeAll()
        if let known = xByBud[new] {
            X = known
            wStale = true
        } else {
            X = nil
            W = nil
            calibrated = false
            fitError = 1
            pairCount = 0
            phase = .finishing // the guided movement was already done; just keep moving
            turned = 1
            nodded = 1
        }
    }
}

/// Keeps the glasses' heading at a constant offset from the AirPods' heading.
struct HeadingReference {
    private(set) var correction = 0.0 // rad, applied about world up
    private(set) var offset: Double?

    /// Forget the glasses↔AirPods relationship (e.g. after the glasses reconnect).
    mutating func reset() { offset = nil }

    /// `g` is the glasses' uncorrected heading and `a` the AirPods heading, at the same instant.
    mutating func update(glasses g: Double, airpods a: Double, dt: Double) {
        let o = wrapAngle(g + correction - a)
        guard let ref = offset else { offset = o; return }
        // Real gyro drift is well under 0.1 °/s; capping at 0.5 °/s means nothing can make the screen jump.
        let maxStep = 0.5 * .pi / 180 * dt
        correction -= min(max(wrapAngle(o - ref) * min(dt / 4, 1), -maxStep), maxStep)
    }
}

// MARK: - Choosing which AirPods

struct HeadphoneDevice {
    let name: String
    let address: String // "A4:C6:F0:C5:63:F7"
    let productID: Int
    let connected: Bool

    var model: String { HeadphoneCatalog.models[productID]?.name ?? String(format: "Apple headphones 0x%04X", productID) }
    /// nil when the model is unknown to us (it may still work).
    var headTracking: Bool? { HeadphoneCatalog.models[productID]?.headTracking }
}

enum HeadphoneCatalog {
    /// Apple/Beats Bluetooth product IDs (vendor 0x004C).
    static let models: [Int: (name: String, headTracking: Bool)] = [
        0x2002: ("AirPods (1st gen)", false),
        0x200F: ("AirPods (2nd gen)", false),
        0x2013: ("AirPods (3rd gen)", true),
        0x2019: ("AirPods 4", true),
        0x201B: ("AirPods 4 (ANC)", true),
        0x200E: ("AirPods Pro", true),
        0x2014: ("AirPods Pro 2", true),
        0x2024: ("AirPods Pro 2 (USB-C)", true),
        0x2027: ("AirPods Pro 3", true),
        0x200A: ("AirPods Max", true),
        0x201F: ("AirPods Max (USB-C)", true),
        0x2012: ("Beats Fit Pro", true),
        0x2003: ("Powerbeats3", false),
        0x200B: ("Powerbeats Pro", false),
        0x2011: ("Beats Studio Buds", false),
    ]
    static let supportedSummary = "AirPods Pro (all), AirPods 3 & 4, AirPods Max, Beats Fit Pro"

    /// Paired Apple headphones, from System Information (takes about a second; call off the main thread).
    static func paired() -> [HeadphoneDevice] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        p.arguments = ["SPBluetoothDataType", "-json"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let root = (json["SPBluetoothDataType"] as? [[String: Any]])?.first else { return [] }

        var found: [HeadphoneDevice] = []
        for (key, connected) in [("device_connected", true), ("device_not_connected", false)] {
            for entry in root[key] as? [[String: Any]] ?? [] {
                for (name, value) in entry {
                    guard let info = value as? [String: Any],
                          (info["device_vendorID"] as? String)?.lowercased() == "0x004c",
                          let pid = (info["device_productID"] as? String).flatMap({ Int($0.dropFirst(2), radix: 16) }),
                          let address = info["device_address"] as? String,
                          info["device_minorType"] as? String == "Headphones" || models[pid] != nil
                    else { continue }
                    found.append(HeadphoneDevice(name: name, address: address, productID: pid, connected: connected))
                }
            }
        }
        return found.sorted { ($0.connected ? 0 : 1, $0.name) < ($1.connected ? 0 : 1, $1.name) }
    }

    /// Bluetooth address of the current sound output, if it is Bluetooth.
    static func currentOutputAddress() -> String? {
        guard let id = defaultOutput(), let uid = uid(of: id) else { return nil }
        return address(fromUID: uid)
    }

    /// Connected to this Mac over Bluetooth (not necessarily the sound output).
    static func isConnected(_ address: String) -> Bool {
        IOBluetoothDevice(addressString: address)?.isConnected() == true
    }

    /// Connects (if needed) and makes `device` the sound output, which is what CoreMotion follows.
    /// Connecting takes the AirPods back from another device (an iPhone), like choosing them in
    /// Control Center.
    static func use(_ device: HeadphoneDevice) -> Bool { use(address: device.address) }

    static func use(address: String) -> Bool {
        if outputDevice(for: address) == nil {
            guard let bt = IOBluetoothDevice(addressString: address) else { return false }
            if !bt.isConnected() { _ = bt.openConnection() }
        }
        for _ in 0..<40 { // the audio device shows up a moment after the Bluetooth link
            if let id = outputDevice(for: address) { return setDefaultOutput(id) }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return false
    }

    // MARK: CoreAudio

    private static func address(_ s: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: s, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func defaultOutput() -> AudioObjectID? {
        var a = address(kAudioHardwarePropertyDefaultOutputDevice)
        var id = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &id) == noErr, id != 0 else { return nil }
        return id
    }

    private static func setDefaultOutput(_ id: AudioObjectID) -> Bool {
        var a = address(kAudioHardwarePropertyDefaultOutputDevice)
        var id = id
        return AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, UInt32(MemoryLayout<AudioObjectID>.size), &id) == noErr
    }

    private static func uid(of id: AudioObjectID) -> String? {
        var a = address(kAudioDevicePropertyDeviceUID)
        var v: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, &v) == noErr, let v else { return nil }
        return v.takeRetainedValue() as String
    }

    /// Bluetooth audio UIDs look like "A4-C6-F0-C5-63-F7:output".
    private static func address(fromUID uid: String) -> String? {
        let mac = uid.split(separator: ":").first.map { $0.replacingOccurrences(of: "-", with: ":") }
        return mac?.count == 17 ? mac?.uppercased() : nil
    }

    private static func outputDevice(for btAddress: String) -> AudioObjectID? {
        var a = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &a, 0, nil, &size) == noErr else { return nil }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &a, 0, nil, &size, &ids) == noErr else { return nil }
        return ids.first { id in
            var sa = address(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput)
            var streams: UInt32 = 0
            AudioObjectGetPropertyDataSize(id, &sa, 0, nil, &streams)
            return streams > 0 && uid(of: id).flatMap(address(fromUID:)) == btAddress.uppercased()
        }
    }
}
