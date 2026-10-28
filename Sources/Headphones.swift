// AirPods (Pro, Max, 3rd gen, Beats with head tracking) as a second heading reference.
//
// Both devices sit rigidly on the head, so their headings should differ by a constant. When the
// glasses' gyro drifts, that difference changes; we slowly rotate the glasses' pose to keep it
// constant. Apple's headphone attitude has its own well-tuned bias estimation, so the combination
// drifts much less than the glasses alone.

import CoreMotion
import QuartzCore

final class Headphones {
    private let manager = CMHeadphoneMotionManager()
    private let queue = OperationQueue()
    private let lock = NSLock()
    private var yaw: Double?
    private var stamp = 0.0
    private(set) var running = false

    var isAvailable: Bool { manager.isDeviceMotionAvailable }
    var isDenied: Bool { CMHeadphoneMotionManager.authorizationStatus() == .denied }

    func start() {
        guard !running, isAvailable else { return }
        running = true
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInteractive
        manager.startDeviceMotionUpdates(to: queue) { [weak self] motion, _ in
            guard let self, let motion else { return }
            self.lock.lock()
            self.yaw = motion.attitude.yaw
            self.stamp = CACurrentMediaTime()
            self.lock.unlock()
        }
    }

    func stop() {
        guard running else { return }
        manager.stopDeviceMotionUpdates()
        running = false
    }

    /// Latest heading in radians, or nil when the AirPods aren't worn/connected.
    func latestYaw() -> Double? {
        lock.lock(); defer { lock.unlock() }
        return CACurrentMediaTime() - stamp < 0.3 ? yaw : nil
    }
}

func wrapAngle(_ a: Double) -> Double { atan2(sin(a), cos(a)) }

/// Render-thread state that turns AirPods headings into a yaw correction for the glasses.
struct HeadingReference {
    private(set) var correction = 0.0 // rad, applied about world up
    private(set) var locked = false // true once the axis direction is known
    private var sign = 0.0
    private var evidence = 0.0
    private var offset: Double?
    private var lastA: Double?
    private var gAtLastA = 0.0

    /// Forget the glasses↔AirPods relationship (e.g. after the glasses reconnect).
    mutating func reset() {
        offset = nil
        lastA = nil
    }

    /// `g` is the glasses' uncorrected heading, `a` the AirPods heading, `speed` head angular speed.
    mutating func update(glasses g: Double, airpods a: Double?, dt: Double, speed: Double) {
        guard let a else { lastA = nil; return }
        if let la = lastA, a != la {
            // Learn whether AirPods yaw turns the same way as ours from real head turns.
            let dg = wrapAngle(g - gAtLastA), da = wrapAngle(a - la)
            if abs(dg) > 0.01, abs(da) > 0.01 { evidence += dg * da }
            if abs(evidence) > 0.05 { sign = evidence > 0 ? 1 : -1; locked = true }
            gAtLastA = g
        } else if lastA == nil {
            gAtLastA = g
        }
        lastA = a
        guard locked else { return }

        let o = wrapAngle(g + correction - sign * a)
        guard let ref = offset else { offset = o; return }
        guard speed < 0.5 else { return } // AirPods data lags during fast turns
        correction -= wrapAngle(o - ref) * min(dt / 4, 1)
    }
}
