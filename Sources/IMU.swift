// Glasses IMU over USB HID plus orientation fusion.
//
// Protocol (from verncat/RayNeo-Air-3S-Pro-OpenVR, verified on an Air 4 Pro):
// host->glasses frames start with 0x66, glasses->host with 0x99. IMU frames are type 0x65:
// accel float[3] m/s² @4, gyro float[3] deg/s @16, temperature float @28, tick uint32 @40 (100 µs).

import Foundation
import IOKit.hid
import QuartzCore
import simd

enum GlassesCommand: UInt8 {
    case deviceInfo = 0x00
    case imuOn = 0x01
    case imuOff = 0x02
    case display3D = 0x06 // side-by-side: the display becomes 3840×1080 @60
    case display2D = 0x07
    case panel60Hz = 0x20
    case panel120Hz = 0x21
    case proximitySensor = 0x38 // value 0 keeps the glasses awake when not worn, 1 restores
}

/// Mean and standard deviation of a block of gyro samples.
struct GyroStats {
    private(set) var n = 0
    private var sum = SIMD3<Double>.zero
    private var sq = SIMD3<Double>.zero

    mutating func add(_ v: SIMD3<Double>) { n += 1; sum += v; sq += v * v }
    var mean: SIMD3<Double> { sum / Double(max(n, 1)) }
    var maxSD: Double {
        let m = mean
        let v = sq / Double(max(n, 1)) - m * m
        return sqrt(max(v.max(), 0))
    }
}

/// Gyro bias as a function of the IMU's temperature, learned from every rest period and
/// calibration (SlimeVR-style temperature compensation). MEMS gyro bias moves roughly linearly with
/// temperature, and the glasses warm up by a few °C in the first minutes of use.
struct TemperatureModel: Codable {
    struct Bin: Codable { var t: Double; var b: [Double]; var w: Double }
    /// 0.5 °C bins of averaged bias (rad/s).
    private(set) var bins: [Int: Bin] = [:]

    var isEmpty: Bool { bins.isEmpty }

    /// `weight`: 1 per rest sample, more for a deliberate calibration. Old data fades (cap 50).
    mutating func add(temperature t: Double, bias: SIMD3<Double>, weight: Double) {
        guard t > 0, t < 80 else { return }
        let k = Int((t * 2).rounded())
        var bin = bins[k] ?? Bin(t: t, b: [bias.x, bias.y, bias.z], w: 0)
        let a = weight / (min(bin.w, 50 - weight) + weight)
        bin.t += (t - bin.t) * a
        for i in 0..<3 { bin.b[i] += (bias[i] - bin.b[i]) * a }
        bin.w = min(bin.w + weight, 50)
        bins[k] = bin
    }

    /// d(bias)/d(°C), from a weighted line fit over the bins; nil until they span 1.5 °C.
    var slope: SIMD3<Double>? {
        let list = Array(bins.values)
        guard list.count >= 2, let lo = list.map(\.t).min(), let hi = list.map(\.t).max(), hi - lo >= 1.5 else { return nil }
        let tm = list.reduce(0) { $0 + $1.t * $1.w } / list.reduce(0) { $0 + $1.w }
        var s = SIMD3<Double>.zero
        var tt = 0.0
        for b in list {
            let dt = b.t - tm
            tt += b.w * dt * dt
            for i in 0..<3 { s[i] += b.w * dt * b.b[i] }
        }
        guard tt > 0 else { return nil }
        let limit = 0.05 * .pi / 180 // °/s per °C; anything steeper is a bad fit
        return (s / tt).clamped(lowerBound: SIMD3(repeating: -limit), upperBound: SIMD3(repeating: limit))
    }

    var span: Double {
        let ts = bins.values.map(\.t)
        return (ts.max() ?? 0) - (ts.min() ?? 0)
    }
}

/// Small dense matrices for the Kalman filter (row-major).
struct Mat {
    let rows: Int, cols: Int
    var m: [Double]
    init(_ rows: Int, _ cols: Int, diagonal d: Double = 0) {
        self.rows = rows; self.cols = cols
        m = [Double](repeating: 0, count: rows * cols)
        for i in 0..<min(rows, cols) { m[i * cols + i] = d }
    }
    subscript(_ r: Int, _ c: Int) -> Double {
        get { m[r * cols + c] }
        set { m[r * cols + c] = newValue }
    }
    static func * (a: Mat, b: Mat) -> Mat {
        var o = Mat(a.rows, b.cols)
        for i in 0..<a.rows { for k in 0..<a.cols {
            let x = a[i, k]
            if x == 0 { continue }
            for j in 0..<b.cols { o.m[i * b.cols + j] += x * b.m[k * b.cols + j] }
        } }
        return o
    }
    static func + (a: Mat, b: Mat) -> Mat { var o = a; for i in 0..<o.m.count { o.m[i] += b.m[i] }; return o }
    static func - (a: Mat, b: Mat) -> Mat { var o = a; for i in 0..<o.m.count { o.m[i] -= b.m[i] }; return o }
    var t: Mat {
        var o = Mat(cols, rows)
        for i in 0..<rows { for j in 0..<cols { o[j, i] = self[i, j] } }
        return o
    }
}

/// Multiplicative extended Kalman filter: orientation error (3) + gyro bias (3), corrected by
/// gravity. Unlike the complementary filter, the bias is part of the state, so pitch/roll bias is
/// learned while you move (Monado / Oculus "keeping it simple" style). Yaw bias stays unobservable
/// without a heading reference; rest detection and the AirPods take care of that.
struct BiasKalman {
    var P = Mat(6, 6)
    private var initialized = false

    mutating func reset() { initialized = false }

    /// Propagates `q`/`bias` with the gyro and corrects them with the accelerometer.
    /// Returns false when the accelerometer was rejected (not gravity right now).
    mutating func update(q: inout simd_quatd, bias: inout SIMD3<Double>, gyro: SIMD3<Double>, acc: SIMD3<Double>,
                         accJitter: Double, dt: Double) -> Bool {
        let deg = Double.pi / 180
        if !initialized {
            P = Mat(6, 6)
            for i in 0..<3 { P[i, i] = 0.05 * 0.05; P[i + 3, i + 3] = pow(0.5 * deg, 2) }
            initialized = true
        }
        let w = gyro - bias
        let l = simd_length(w) * dt
        if l > 1e-12 { q = simd_normalize(q * simd_quatd(angle: l, axis: w / simd_length(w))) }

        // F = [[I − [w×]dt, −I·dt], [0, I]]
        var F = Mat(6, 6, diagonal: 1)
        let wx = w * dt
        F[0, 1] = wx.z; F[0, 2] = -wx.y
        F[1, 0] = -wx.z; F[1, 2] = wx.x
        F[2, 0] = wx.y; F[2, 1] = -wx.x
        for i in 0..<3 { F[i, i + 3] = -dt }
        var Q = Mat(6, 6)
        let gyroNoise = 0.3 * deg // rad/s/√Hz, generous: head motion isn't white noise
        let biasWalk = 0.002 * deg
        for i in 0..<3 { Q[i, i] = gyroNoise * gyroNoise * dt; Q[i + 3, i + 3] = biasWalk * biasWalk * dt }
        P = F * P * F.t + Q

        let an = simd_length(acc)
        guard an > 1 else { return false }
        let measured = acc / an
        let h = q.inverse.act(SIMD3(0, 1, 0)) // gravity "up" expected in the body frame
        let y = measured - h
        // H = [[h×], 0]: the body-frame error rotation δθ changes the expected up by h × δθ.
        var H = Mat(3, 6)
        H[0, 1] = -h.z; H[0, 2] = h.y
        H[1, 0] = h.z; H[1, 2] = -h.x
        H[2, 0] = -h.y; H[2, 1] = h.x
        // Trust gravity less when the accelerometer says we are accelerating.
        let sigma = 0.03 + 0.5 * abs(an - 9.81) / 9.81 + 0.3 * accJitter
        let S = H * P * H.t + Mat(3, 3, diagonal: sigma * sigma)
        let s3 = simd_double3x3(rows: [SIMD3(S[0, 0], S[0, 1], S[0, 2]), SIMD3(S[1, 0], S[1, 1], S[1, 2]), SIMD3(S[2, 0], S[2, 1], S[2, 2])])
        guard abs(s3.determinant) > 1e-18 else { return false }
        let Si = s3.inverse
        // Mahalanobis gate (χ², 3 dof, 99.9%): a hard shake or a tap is not gravity.
        if simd_dot(y, Si * y) > 16.3 { return false }
        var Sm = Mat(3, 3)
        for i in 0..<3 { for j in 0..<3 { Sm[i, j] = Si[j][i] } }
        let K = P * H.t * Sm
        var yv = Mat(3, 1)
        for i in 0..<3 { yv[i, 0] = y[i] }
        let dx = K * yv
        let dth = SIMD3(dx[0, 0], dx[1, 0], dx[2, 0])
        let a = simd_length(dth)
        if a > 1e-12 { q = simd_normalize(q * simd_quatd(angle: a, axis: dth / a)) }
        bias += SIMD3(dx[3, 0], dx[4, 0], dx[5, 0])
        P = (Mat(6, 6, diagonal: 1) - K * H) * P
        return true
    }
}

/// Mahony-style complementary filter (or the Kalman filter above). Device frame: x right, y up,
/// z back (toward the face).
struct Fusion {
    enum State: Equatable { case calibrating(Double), calibratingOnTable(Double), ready }
    enum Mode: String { case complementary, kalman }

    var q = simd_quatd(ix: 0, iy: 0, iz: 0, r: 1) // device -> world
    var bias: SIMD3<Double>
    var omega = SIMD3<Double>.zero // bias-corrected angular velocity, rad/s
    private(set) var state: State
    var mode = Mode.complementary
    /// x-io Fusion style: ignore the accelerometer while it disagrees with the estimate by >10°
    /// or isn't ~1 g (you're accelerating), recovering after 3 s.
    var strictAccel = true
    /// Per-axis gyro sensitivity correction (1 = as reported).
    var scale = SIMD3<Double>(repeating: 1)
    var temperature = TemperatureModel()
    var useTemperature = true
    private(set) var accelRejected = false
    /// World yaw turned since start (unwrapped, rad), for the full-circle scale calibration.
    private(set) var turned = 0.0
    private(set) var temperatureNow = 0.0
    private(set) var temperatureShift = SIMD3<Double>.zero // bias change applied from temperature since start

    private static let deg = Double.pi / 180
    private var initialized = false
    private var lastTick: UInt32 = 0
    private var block = GyroStats()
    private var blocksOK = 0
    private var tableSum = SIMD3<Double>.zero
    private(set) var stillTime = 0.0
    private var lpGyro = SIMD3<Double>.zero
    private var lpAcc = SIMD3<Double>.zero
    private var lpTemp: Double?
    private var restSampleTime = 0.0
    private var rejectTime = 0.0
    private var slope: SIMD3<Double>?
    private var slopeAge = 0.0
    private var kalman = BiasKalman()
    private let kp = 0.5

    /// `bias` is a previously saved gyro bias; without one the filter calibrates first.
    init(bias: SIMD3<Double>?) {
        self.bias = bias ?? .zero
        state = bias == nil ? .calibrating(0) : .ready
    }

    /// Precise calibration: glasses resting on a table for ~3 s.
    mutating func calibrateOnTable() {
        state = .calibratingOnTable(0)
        block = GyroStats(); blocksOK = 0; tableSum = .zero
    }

    /// Gives up a table calibration, keeping the previous bias.
    mutating func cancelCalibration() {
        if case .calibratingOnTable = state { state = .ready }
    }

    mutating func setMode(_ m: Mode) {
        guard m != mode else { return }
        mode = m
        kalman.reset()
    }

    mutating func update(acc: SIMD3<Double>, gyro rawGyro: SIMD3<Double>, temperature t: Double, tick: UInt32) {
        let gyro = rawGyro * scale
        if !initialized {
            guard simd_length(acc) > 1 else { return }
            q = simd_quatd(from: simd_normalize(acc), to: SIMD3(0, 1, 0))
            initialized = true
            lastTick = tick
            lpAcc = acc
            return
        }
        guard tick != lastTick else { return } // the glasses resend the last sample when idle
        var dt = Double(tick &- lastTick) * 1e-4
        lastTick = tick
        if dt <= 0 || dt > 0.05 { dt = 0.002 }

        // Temperature: low-passed (the reading is coarse), then the learned slope moves the bias
        // as the glasses warm up, between rest periods.
        if t > 0, t < 80 {
            let prev = lpTemp ?? t
            let now = prev + (t - prev) * min(dt / 5, 1)
            lpTemp = now
            temperatureNow = now
            slopeAge += dt
            if slopeAge > 1 { slopeAge = 0; slope = temperature.slope }
            if useTemperature, let slope, state == .ready {
                bias += slope * (now - prev)
                temperatureShift += slope * (now - prev)
            }
        }

        switch state {
        case .calibrating:
            // On the head: accept 1 s that is very still. Refined later by the tracker below.
            if calibrationBlock(gyro, maxSD: 1.0 * Fusion.deg, blocks: 1) { return }
            if state == .ready { temperature.add(temperature: temperatureNow, bias: bias, weight: 3) }
        case .calibratingOnTable:
            if calibrationBlock(gyro, maxSD: 0.5 * Fusion.deg, blocks: 3) { return }
            if state == .ready { temperature.add(temperature: temperatureNow, bias: bias, weight: 10) }
        case .ready:
            break
        }

        // Rest detection and bias estimation after VQF (Laidig & Seel, dlaidig/vqf): at rest the
        // gyro stays within 2 °/s of its own 0.5 s low-pass, that low-pass stays under 2 °/s, and the
        // accelerometer within 0.5 m/s² of its low-pass, for at least 1.5 s. Then the low-passed
        // gyro *is* the bias. Comparing against the low-pass rather than zero works even while the
        // current bias estimate is off.
        let k = min(dt / 0.5, 1)
        lpGyro += (gyro - lpGyro) * k
        lpAcc += (acc - lpAcc) * k
        // Unlike VQF (2 °/s), only small corrections to the current bias count as rest: on a head, a
        // slow 1–2 °/s turn is indistinguishable from bias and must not be absorbed. Large errors are
        // the startup/table calibration's job.
        let correction = lpGyro - bias
        let accJitter = simd_length(acc - lpAcc)
        let resting = simd_length(gyro - lpGyro) < 2 * Fusion.deg
            && max(abs(correction.x), abs(correction.y), abs(correction.z)) < 0.6 * Fusion.deg
            && accJitter < 0.5
        stillTime = resting ? stillTime + dt : 0
        if stillTime > 1.5 {
            bias += (lpGyro - bias) * min(dt / 3, 1)
            restSampleTime += dt
            if restSampleTime > 2 {
                restSampleTime = 0
                temperature.add(temperature: temperatureNow, bias: lpGyro, weight: 1)
            }
        }

        let w = gyro - bias
        omega = w
        turned += q.act(w).y * dt

        if mode == .kalman {
            accelRejected = !kalman.update(q: &q, bias: &bias, gyro: gyro, acc: acc, accJitter: accJitter, dt: dt)
            omega = gyro - bias
            return
        }

        // Pull pitch/roll toward gravity; yaw is gyro-only.
        var wc = w
        let an = simd_length(acc)
        if an > 7, an < 12.5 {
            let measuredUp = acc / an
            let estimatedUp = q.inverse.act(SIMD3(0, 1, 0))
            var gain = kp
            var accept = true
            if strictAccel {
                let error = acos(max(-1, min(1, simd_dot(measuredUp, estimatedUp))))
                accept = (abs(an - 9.81) < 1.5 && error < 10 * Fusion.deg) || rejectTime > 3
                // Recovery: after 3 s of rejection, converge fast once, like x-io Fusion.
                if accept, rejectTime > 3 { gain = 5 * kp }
                // Fast head turns leak centripetal acceleration into the reading.
                gain /= 1 + simd_length(w) / 2
            }
            if accept {
                rejectTime = 0
                wc += gain * simd_cross(measuredUp, estimatedUp)
            } else {
                rejectTime += dt
            }
            accelRejected = !accept
        }
        let angle = simd_length(wc) * dt
        if angle > 1e-12 {
            q = simd_normalize(q * simd_quatd(angle: angle, axis: wc / simd_length(wc)))
        }
    }

    /// Feeds 500-sample blocks; a block that moves too much starts over. Returns true while calibrating.
    private mutating func calibrationBlock(_ gyro: SIMD3<Double>, maxSD: Double, blocks: Int) -> Bool {
        block.add(gyro)
        let progress = (Double(blocksOK) + Double(block.n) / 500) / Double(blocks)
        if case .calibrating = state { state = .calibrating(progress) } else { state = .calibratingOnTable(progress) }
        guard block.n >= 500 else { return true }
        if block.maxSD < maxSD {
            blocksOK += 1
            tableSum += block.mean
        } else {
            blocksOK = 0
            tableSum = .zero
        }
        block = GyroStats()
        if blocksOK >= blocks {
            bias = tableSum / Double(blocks)
            state = .ready
            blocksOK = 0
            tableSum = .zero
            return false
        }
        return true
    }
}

/// Orientation at a host time (CACurrentMediaTime), kept so other sensors can be compared with
/// what the glasses measured at the same instant.
struct PoseSample {
    var time: Double
    var q: simd_quatd
    var omega: SIMD3<Double>
}

/// Fixed-size ring of the last few seconds of poses.
struct PoseHistory {
    private var items: [PoseSample]
    private var next = 0
    private(set) var count = 0

    init(capacity: Int) { items = Array(repeating: PoseSample(time: 0, q: .identity, omega: .zero), count: capacity) }

    mutating func append(_ p: PoseSample) {
        items[next] = p
        next = (next + 1) % items.count
        count = min(count + 1, items.count)
    }

    mutating func removeAll() { count = 0 }

    private func item(_ i: Int) -> PoseSample { items[(next - count + i + items.count) % items.count] }

    /// Interpolated pose at `t`, nil if `t` is outside the stored window.
    func pose(at t: Double) -> PoseSample? {
        guard count > 1, t >= item(0).time, t <= item(count - 1).time else { return nil }
        var lo = 0, hi = count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if item(mid).time <= t { lo = mid } else { hi = mid }
        }
        let a = item(lo), b = item(hi)
        let f = b.time > a.time ? (t - a.time) / (b.time - a.time) : 0
        return PoseSample(time: t, q: simd_slerp(a.q, b.q, f), omega: a.omega + (b.omega - a.omega) * f)
    }
}

/// Double tap on the glasses' frame (XRLinuxDriver / rokid-spatial): a tap is a gyro spike
/// (> 2500 °/s² over ~6 ms) together with an accelerometer jump (> 3 m/s²). Turning your head
/// can't produce both that sharply; two taps 0.12–0.6 s apart recenter.
struct TapDetector {
    var jerkThreshold = 2500 * Double.pi / 180 // rad/s²
    var accThreshold = 3.0 // m/s²
    private var gyro = [SIMD3<Double>](repeating: .zero, count: 4)
    private var acc = [SIMD3<Double>](repeating: .zero, count: 4)
    private var i = 0
    private var filled = 0
    private var lastTap = -1.0
    private var firstTap = -1.0
    /// Strongest recent values, for tuning in the developer overlay.
    private(set) var peakJerk = 0.0
    private(set) var peakAcc = 0.0
    private(set) var taps = 0

    mutating func update(gyro g: SIMD3<Double>, acc a: SIMD3<Double>, time: Double) -> Bool {
        let old = (i + 1) % 4 // three samples back: ~6 ms at 500 Hz
        let jerk = simd_length(g - gyro[old]) / 0.006
        let jump = simd_length(a - acc[old])
        gyro[i] = g
        acc[i] = a
        i = old
        filled = min(filled + 1, 4)
        guard filled == 4 else { return false }
        peakJerk = max(peakJerk * 0.999, jerk)
        peakAcc = max(peakAcc * 0.999, jump)
        guard jerk > jerkThreshold, jump > accThreshold, time - lastTap > 0.08 else { return false }
        lastTap = time
        taps += 1
        if firstTap > 0, time - firstTap > 0.12, time - firstTap < 0.6 {
            firstTap = -1
            return true
        }
        firstTap = time
        return false
    }
}

final class IMU {
    /// Raw sensor values for the developer overlay.
    struct Raw {
        var acc = SIMD3<Double>.zero // m/s²
        var gyro = SIMD3<Double>.zero // rad/s, before bias removal
        var temperature = 0.0 // °C
        var rate = 0.0 // unique samples per second
        var bias = SIMD3<Double>.zero
        var stillTime = 0.0
        var proximity = 0.0 // proximity sensor reading
        var light = 0.0 // float at offset 48: unknown, possibly the ambient light sensor
        var asleep = false // display off because the glasses aren't worn
        var scale = SIMD3<Double>(repeating: 1)
        var accelRejected = false
        var temperatureSlope: SIMD3<Double>?
        var temperatureSpan = 0.0
        var temperatureShift = SIMD3<Double>.zero
        var tapJerk = 0.0
        var tapAcc = 0.0
        var taps = 0
        var lastAck = "" // last 0xC8 frame, hex, for protocol exploration
    }

    struct Snapshot {
        var q: simd_quatd
        var omega: SIMD3<Double>
        var state: Fusion.State
        var connected: Bool
        var ready: Bool { connected && state == .ready }
    }

    /// Called on the IMU thread whenever the glasses (re)connect or wake up.
    var onConnect: (() -> Void)?
    /// Called on the IMU thread on a double tap on the glasses.
    var onDoubleTap: (() -> Void)?

    private var manager: IOHIDManager!
    private var device: IOHIDDevice?
    private var fusion: Fusion
    private var taps = TapDetector()
    private let lock = NSLock()
    private var connected = false
    private var lastSample = Date.distantPast
    private(set) var samples = 0
    private var raw = Raw()
    private var history = PoseHistory(capacity: 15000) // ~30 s at 500 Hz: AirPods calibration re-pairs old motion
    private var rateCount = 0
    private var rateStart = Date()

    init(savedBias: SIMD3<Double>?) {
        fusion = Fusion(bias: savedBias)
    }

    func start() {
        let thread = Thread { [self] in
            manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
            IOHIDManagerSetDeviceMatching(manager, [
                kIOHIDVendorIDKey: 0x1BBB, kIOHIDProductIDKey: 0xAF50, kIOHIDPrimaryUsagePageKey: 0xFF00,
            ] as CFDictionary)
            let ctx = Unmanaged.passUnretained(self).toOpaque()
            IOHIDManagerRegisterDeviceMatchingCallback(manager, { ctx, _, _, dev in
                Unmanaged<IMU>.fromOpaque(ctx!).takeUnretainedValue().attach(dev)
            }, ctx)
            IOHIDManagerRegisterDeviceRemovalCallback(manager, { ctx, _, _, _ in
                Unmanaged<IMU>.fromOpaque(ctx!).takeUnretainedValue().detach()
            }, ctx)
            IOHIDManagerRegisterInputReportCallback(manager, { ctx, _, _, _, _, report, len in
                Unmanaged<IMU>.fromOpaque(ctx!).takeUnretainedValue().handle(report, len)
            }, ctx)
            IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
            IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))

            // Watchdog: the stream stops after the glasses sleep; ask again.
            let timer = Timer(timeInterval: 1, repeats: true) { [self] _ in
                if device != nil, Date().timeIntervalSince(lastSample) > 1.5 { send(.imuOn) }
            }
            RunLoop.current.add(timer, forMode: .default)
            CFRunLoopRun()
        }
        thread.qualityOfService = .userInteractive
        thread.name = "RayNeo IMU"
        thread.start()
    }

    func stop() { send(.imuOff) }

    func snapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        return Snapshot(q: fusion.q, omega: fusion.omega, state: fusion.state, connected: connected)
    }

    /// What the glasses measured at host time `t` (within the last ~30 s).
    func pose(at t: Double) -> PoseSample? {
        lock.lock(); defer { lock.unlock() }
        return history.pose(at: t)
    }

    func rawSnapshot() -> Raw {
        lock.lock(); defer { lock.unlock() }
        var r = raw
        r.bias = fusion.bias
        r.stillTime = fusion.stillTime
        r.scale = fusion.scale
        r.accelRejected = fusion.accelRejected
        r.temperatureSlope = fusion.temperature.slope
        r.temperatureSpan = fusion.temperature.span
        r.temperatureShift = fusion.temperatureShift
        r.tapJerk = taps.peakJerk
        r.tapAcc = taps.peakAcc
        r.taps = taps.taps
        return r
    }

    var isAsleep: Bool {
        lock.lock(); defer { lock.unlock() }
        return raw.asleep
    }

    var bias: SIMD3<Double> {
        lock.lock(); defer { lock.unlock() }
        return fusion.bias
    }

    /// Small correction to the gyro bias from another reference (the AirPods), rad/s.
    func adjustBias(_ delta: SIMD3<Double>) {
        lock.lock(); fusion.bias += delta; lock.unlock()
    }

    var scale: SIMD3<Double> {
        get { lock.lock(); defer { lock.unlock() }; return fusion.scale }
        set {
            let s = newValue.clamped(lowerBound: SIMD3(repeating: 0.9), upperBound: SIMD3(repeating: 1.1))
            lock.lock(); fusion.scale = s; lock.unlock()
        }
    }

    /// World yaw turned so far (unwrapped), for the full-circle scale calibration.
    var turned: Double {
        lock.lock(); defer { lock.unlock() }
        return fusion.turned
    }

    var temperatureModel: TemperatureModel {
        get { lock.lock(); defer { lock.unlock() }; return fusion.temperature }
        set { lock.lock(); fusion.temperature = newValue; lock.unlock() }
    }

    func configure(mode: Fusion.Mode, strictAccel: Bool, temperature: Bool) {
        lock.lock()
        fusion.setMode(mode)
        fusion.strictAccel = strictAccel
        fusion.useTemperature = temperature
        lock.unlock()
    }

    func calibrateOnTable() {
        lock.lock(); fusion.calibrateOnTable(); lock.unlock()
    }

    func cancelCalibration() {
        lock.lock(); fusion.cancelCalibration(); lock.unlock()
    }

    func send(_ command: GlassesCommand, value: UInt8 = 0) { send(raw: command.rawValue, value: value) }

    func send(raw command: UInt8, value: UInt8 = 0) {
        guard let device else { return }
        var frame = [UInt8](repeating: 0, count: 64)
        frame[0] = 0x66
        frame[1] = command
        frame[2] = value
        IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 0, frame, 64)
    }

    private func attach(_ dev: IOHIDDevice) {
        device = dev
        lock.lock(); connected = true; lock.unlock()
        send(.imuOn)
        onConnect?()
    }

    private func detach() {
        device = nil
        lock.lock()
        connected = false
        var f = Fusion(bias: fusion.state == .ready ? fusion.bias : nil)
        f.setMode(fusion.mode)
        f.strictAccel = fusion.strictAccel
        f.useTemperature = fusion.useTemperature
        f.scale = fusion.scale
        f.temperature = fusion.temperature
        fusion = f
        history.removeAll()
        lock.unlock()
    }

    private var lastLoggedTick: UInt32 = 0
    private var lastRestLog = 0.0

    /// One row per IMU report, with the fusion's state right after it (called under `lock`).
    private func logSample(_ t: Double, tick: UInt32, acc: SIMD3<Double>, gyro: SIMD3<Double>, temperature: Double, proximity: Double) {
        let dt = Double(tick &- lastLoggedTick) * 0.1 // ms; 0 = the glasses repeated the last report
        lastLoggedTick = tick
        let q = fusion.q, ypr = q.ypr, b = fusion.bias, w = fusion.omega
        let state: String
        switch fusion.state {
        case .ready: state = "ready"
        case .calibrating(let x): state = "calibrating:" + f3(x)
        case .calibratingOnTable(let x): state = "table:" + f3(x)
        }
        Telemetry.shared.row("imu", [
            f4(t), String(tick), f3(dt), f4(acc.x), f4(acc.y), f4(acc.z), deg4(gyro.x), deg4(gyro.y), deg4(gyro.z), f3(temperature), f3(proximity),
            f4(q.real), f4(q.imag.x), f4(q.imag.y), f4(q.imag.z), deg4(ypr.x), deg4(ypr.y), deg4(ypr.z),
            deg4(b.x), deg4(b.y), deg4(b.z), deg4(w.x), deg4(w.y), deg4(w.z),
            f3(fusion.stillTime), fusion.accelRejected ? "1" : "0", state, deg4(fusion.temperatureShift.y), f4(fusion.scale.y),
        ])
    }

    private func handle(_ r: UnsafeMutablePointer<UInt8>, _ len: CFIndex) {
        guard len >= 64, r[0] == 0x99 else { return }
        switch r[1] {
        case 0x65:
            let raw = UnsafeRawPointer(r)
            func f(_ o: Int) -> Double { Double(raw.loadUnaligned(fromByteOffset: o, as: Float32.self)) }
            let acc = SIMD3(f(4), f(8), f(12))
            let gyro = SIMD3(f(16), f(20), f(24)) * (.pi / 180) // deg/s -> rad/s
            let tick = raw.loadUnaligned(fromByteOffset: 40, as: UInt32.self)
            let now = Date()
            lastSample = now
            samples += 1
            rateCount += 1
            let hostTime = CACurrentMediaTime()
            lock.lock()
            fusion.update(acc: acc, gyro: gyro, temperature: f(28), tick: tick)
            // Resting (not worn): 10 rows a second are enough to follow the bias and cooling.
            if Telemetry.shared.enabled, !self.raw.asleep || hostTime - lastRestLog >= 0.1 {
                if self.raw.asleep { lastRestLog = hostTime }
                logSample(hostTime, tick: tick, acc: acc, gyro: gyro, temperature: f(28), proximity: f(44))
            }
            if fusion.state == .ready { history.append(PoseSample(time: hostTime, q: fusion.q, omega: fusion.omega)) }
            let doubleTap = taps.update(gyro: gyro, acc: acc, time: hostTime)
            self.raw.acc = acc
            self.raw.gyro = gyro
            self.raw.temperature = f(28)
            self.raw.proximity = f(44)
            self.raw.light = f(48)
            if now.timeIntervalSince(rateStart) >= 1 {
                self.raw.rate = Double(rateCount) / now.timeIntervalSince(rateStart)
                rateCount = 0
                rateStart = now
            }
            lock.unlock()
            if doubleTap { onDoubleTap?() }
        case 0xC8: // acknowledgments; byte 8 carries sleep (0x41) / wake (0x42) notifications
            let hex = (0..<32).map { String(format: "%02X", r[$0]) }.joined(separator: " ")
            lock.lock(); raw.lastAck = hex; lock.unlock()
            if r[8] == 0x41 {
                lock.lock(); raw.asleep = true; lock.unlock()
            } else if r[8] == 0x42 {
                lock.lock(); raw.asleep = false; lock.unlock()
                send(.imuOn)
                onConnect?()
            }
        default:
            break
        }
    }
}

// MARK: - Orientation helpers

extension simd_quatd {
    static let identity = simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)

    /// Yaw/pitch of the forward (-z) axis, ignoring roll.
    var yawPitch: (yaw: Double, pitch: Double) {
        let f = act(SIMD3(0, 0, -1))
        return (atan2(-f.x, -f.z), asin(max(-1, min(1, f.y))))
    }

    static func yawPitch(_ yaw: Double, _ pitch: Double) -> simd_quatd {
        simd_quatd(angle: yaw, axis: SIMD3(0, 1, 0)) * simd_quatd(angle: pitch, axis: SIMD3(1, 0, 0))
    }

    /// (yaw, pitch, roll): yaw about world up, then pitch about x, then roll about z.
    var ypr: SIMD3<Double> {
        let yp = yawPitch
        let r = simd_quatd.yawPitch(yp.yaw, yp.pitch).inverse * self // what's left is roll about z
        let roll = 2 * atan2(r.imag.z, r.real)
        return SIMD3(yp.yaw, yp.pitch, atan2(sin(roll), cos(roll)))
    }

    static func ypr(_ a: SIMD3<Double>) -> simd_quatd {
        yawPitch(a.x, a.y) * simd_quatd(angle: a.z, axis: SIMD3(0, 0, 1))
    }

    /// Body-frame angular velocity that turns `from` into `self` in `dt` seconds.
    func angularVelocity(from: simd_quatd, dt: Double) -> SIMD3<Double> {
        var d = from.inverse * self
        if d.real < 0 { d = simd_quatd(vector: -d.vector) } // shortest way round
        let angle = d.angle
        return angle > 1e-9 && dt > 0 ? d.axis * angle / dt : .zero
    }

    /// Look-ahead for display latency: like `extrapolated`, but never more than 3°, so a very fast
    /// flick of the head can't throw the screen far past where it will stop.
    func predicted(_ w: SIMD3<Double>, _ t: Double) -> simd_quatd {
        let angle = simd_length(w) * t, limit = 3 * Double.pi / 180
        return extrapolated(angle > limit ? w * (limit / angle) : w, t)
    }

    /// Rotates further by angular velocity `w` (rad/s, body frame) for `t` seconds.
    func extrapolated(_ w: SIMD3<Double>, _ t: Double) -> simd_quatd {
        let l = simd_length(w)
        return l > 1e-9 ? self * simd_quatd(angle: l * t, axis: w / l) : self
    }
}

func degrees(_ r: Double) -> Double { r * 180 / .pi }
