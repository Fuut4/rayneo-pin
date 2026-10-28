// Glasses IMU over USB HID plus orientation fusion.
//
// Protocol (from verncat/RayNeo-Air-3S-Pro-OpenVR, verified on an Air 4 Pro):
// host->glasses frames start with 0x66, glasses->host with 0x99. IMU frames are type 0x65:
// accel float[3] m/s² @4, gyro float[3] deg/s @16, temperature float @28, tick uint32 @40 (100 µs).

import Foundation
import IOKit.hid
import simd

enum GlassesCommand: UInt8 {
    case deviceInfo = 0x00
    case imuOn = 0x01
    case imuOff = 0x02
    case panel60Hz = 0x20
    case panel120Hz = 0x21
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

/// Mahony-style complementary filter. Device frame: x right, y up, z back (toward the face).
struct Fusion {
    enum State: Equatable { case calibrating(Double), calibratingOnTable(Double), ready }

    var q = simd_quatd(ix: 0, iy: 0, iz: 0, r: 1) // device -> world
    var bias: SIMD3<Double>
    var omega = SIMD3<Double>.zero // bias-corrected angular velocity, rad/s
    private(set) var state: State

    private static let deg = Double.pi / 180
    private var initialized = false
    private var lastTick: UInt32 = 0
    private var block = GyroStats()
    private var blocksOK = 0
    private var tableSum = SIMD3<Double>.zero
    private var stillTime = 0.0
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

    mutating func update(acc: SIMD3<Double>, gyro: SIMD3<Double>, tick: UInt32) {
        if !initialized {
            guard simd_length(acc) > 1 else { return }
            q = simd_quatd(from: simd_normalize(acc), to: SIMD3(0, 1, 0))
            initialized = true
            lastTick = tick
            return
        }
        guard tick != lastTick else { return } // the glasses resend the last sample when idle
        var dt = Double(tick &- lastTick) * 1e-4
        lastTick = tick
        if dt <= 0 || dt > 0.05 { dt = 0.002 }

        switch state {
        case .calibrating:
            // On the head: accept 1 s that is very still. Refined later by the tracker below.
            if calibrationBlock(gyro, maxSD: 1.0 * Fusion.deg, blocks: 1) { return }
        case .calibratingOnTable:
            if calibrationBlock(gyro, maxSD: 0.5 * Fusion.deg, blocks: 3) { return }
        case .ready:
            break
        }

        let w = gyro - bias
        omega = w

        // Gyro offset tracking as in x-io Fusion (also used by XRLinuxDriver): after 5 s with
        // every axis under 3 °/s, low-pass the bias toward the raw gyro (0.02 Hz cutoff).
        let threshold = 3 * Fusion.deg
        stillTime = abs(w.x) < threshold && abs(w.y) < threshold && abs(w.z) < threshold ? stillTime + dt : 0
        if stillTime > 5 { bias += (gyro - bias) * (2 * .pi * 0.02 * dt) }

        // Pull pitch/roll toward gravity; yaw is gyro-only.
        var wc = w
        let an = simd_length(acc)
        if an > 7, an < 12.5 {
            let measuredUp = acc / an
            let estimatedUp = q.inverse.act(SIMD3(0, 1, 0))
            wc += kp * simd_cross(measuredUp, estimatedUp)
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

final class IMU {
    struct Snapshot {
        var q: simd_quatd
        var omega: SIMD3<Double>
        var state: Fusion.State
        var connected: Bool
        var ready: Bool { connected && state == .ready }
    }

    /// Called on the IMU thread whenever the glasses (re)connect.
    var onConnect: (() -> Void)?

    private var manager: IOHIDManager!
    private var device: IOHIDDevice?
    private var fusion: Fusion
    private let lock = NSLock()
    private var connected = false
    private var lastSample = Date.distantPast
    private(set) var samples = 0

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

    var bias: SIMD3<Double> {
        lock.lock(); defer { lock.unlock() }
        return fusion.bias
    }

    func calibrateOnTable() {
        lock.lock(); fusion.calibrateOnTable(); lock.unlock()
    }

    func send(_ command: GlassesCommand, value: UInt8 = 0) {
        guard let device else { return }
        var frame = [UInt8](repeating: 0, count: 64)
        frame[0] = 0x66
        frame[1] = command.rawValue
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
        fusion = Fusion(bias: fusion.state == .ready ? fusion.bias : nil)
        lock.unlock()
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
            lastSample = Date()
            samples += 1
            lock.lock(); fusion.update(acc: acc, gyro: gyro, tick: tick); lock.unlock()
        case 0x42: // wake notify
            send(.imuOn)
            onConnect?()
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

    /// Rotates further by angular velocity `w` (rad/s, body frame) for `t` seconds.
    func extrapolated(_ w: SIMD3<Double>, _ t: Double) -> simd_quatd {
        let l = simd_length(w)
        return l > 1e-9 ? self * simd_quatd(angle: l * t, axis: w / l) : self
    }
}

func degrees(_ r: Double) -> Double { r * 180 / .pi }
