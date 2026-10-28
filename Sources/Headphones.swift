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
    /// Euler angles as CoreMotion reports them: (yaw, pitch, roll), radians.
    struct Sample { var angles: SIMD3<Double>; var time: Double }

    private let manager = CMHeadphoneMotionManager()
    private let queue = OperationQueue()
    private let lock = NSLock()
    private var last: Sample?
    private var previous: Sample?
    private(set) var running = false

    var isAvailable: Bool { manager.isDeviceMotionAvailable }
    var isDenied: Bool { CMHeadphoneMotionManager.authorizationStatus() == .denied }

    func start() {
        guard !running, isAvailable else { return }
        running = true
        manager.delegate = self
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInteractive
        manager.startDeviceMotionUpdates(to: queue) { [weak self] motion, _ in
            guard let self, let a = motion?.attitude else { return }
            self.lock.lock()
            self.previous = self.last
            self.last = Sample(angles: SIMD3(a.yaw, a.pitch, a.roll), time: CACurrentMediaTime())
            self.lock.unlock()
        }
    }

    func stop() {
        guard running else { return }
        manager.stopDeviceMotionUpdates()
        running = false
    }

    /// Latest two samples, or nil when the AirPods aren't worn/connected.
    func latest() -> (last: Sample, previous: Sample?)? {
        lock.lock(); defer { lock.unlock() }
        guard let last, CACurrentMediaTime() - last.time < 0.3 else { return nil }
        return (last, previous)
    }

    func latestYaw() -> Double? { latest()?.last.angles.x }

    func headphoneMotionManagerDidDisconnect(_ manager: CMHeadphoneMotionManager) {
        lock.lock(); last = nil; previous = nil; lock.unlock()
    }
}

func wrapAngle(_ a: Double) -> Double { atan2(sin(a), cos(a)) }

/// Learns how AirPods' (yaw, pitch, roll) map onto the glasses' (yaw, pitch, roll) — which axis,
/// which direction — by correlating real head movements, so no device-specific axis table is needed.
struct AirPodsAlignment {
    private var evidence = simd_double3x3() // rows: glasses axis, columns: AirPods axis
    private var lastA: SIMD3<Double>?
    private var gAtLastA = SIMD3<Double>.zero
    // Before there is evidence: same axes, roll mirrored (CoreMotion rolls about the forward axis).
    private(set) var axis = [0, 1, 2]
    private(set) var sign: SIMD3<Double> = [1, 1, -1]
    private(set) var confident = false

    /// Call every frame; `g` is the glasses' (yaw, pitch, roll) when available.
    mutating func observe(glasses g: SIMD3<Double>?, airpods a: SIMD3<Double>) {
        defer { lastA = a }
        guard let la = lastA, a != la else { if lastA == nil, let g { gAtLastA = g }; return }
        guard let g else { return }
        let dg = SIMD3(wrapAngle(g.x - gAtLastA.x), wrapAngle(g.y - gAtLastA.y), wrapAngle(g.z - gAtLastA.z))
        let da = SIMD3(wrapAngle(a.x - la.x), wrapAngle(a.y - la.y), wrapAngle(a.z - la.z))
        gAtLastA = g
        guard simd_length(dg) > 0.01, simd_length(da) > 0.01 else { return }
        for i in 0..<3 { for j in 0..<3 { evidence[j][i] += dg[i] * da[j] } }
        for i in 0..<3 {
            let row = (0..<3).map { evidence[$0][i] }
            let j = (0..<3).max { abs(row[$0]) < abs(row[$1]) }!
            if abs(row[j]) > 0.02 { axis[i] = j; sign[i] = row[j] > 0 ? 1 : -1 }
        }
        confident = abs(evidence[axis[0]][0]) > 0.05 // enough yaw turning seen
    }

    /// AirPods angles expressed as the glasses' (yaw, pitch, roll).
    func aligned(_ a: SIMD3<Double>) -> SIMD3<Double> {
        SIMD3(sign.x * a[axis[0]], sign.y * a[axis[1]], sign.z * a[axis[2]])
    }

    func pose(_ a: SIMD3<Double>) -> simd_quatd { .ypr(aligned(a)) }
}

/// Keeps the glasses' heading at a constant offset from the AirPods' heading.
struct HeadingReference {
    private(set) var correction = 0.0 // rad, applied about world up
    private var offset: Double?

    /// Forget the glasses↔AirPods relationship (e.g. after the glasses reconnect).
    mutating func reset() { offset = nil }

    /// `g` is the glasses' uncorrected heading, `a` the aligned AirPods heading.
    mutating func update(glasses g: Double, airpods a: Double, dt: Double, speed: Double) {
        let o = wrapAngle(g + correction - a)
        guard let ref = offset else { offset = o; return }
        guard speed < 0.5 else { return } // AirPods data lags during fast turns
        correction -= wrapAngle(o - ref) * min(dt / 4, 1)
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

    /// Connects (if needed) and makes `device` the sound output, which is what CoreMotion follows.
    static func use(_ device: HeadphoneDevice) -> Bool {
        if outputDevice(for: device.address) == nil {
            guard let bt = IOBluetoothDevice(addressString: device.address) else { return false }
            if !bt.isConnected() { _ = bt.openConnection() }
        }
        for _ in 0..<40 { // the audio device shows up a moment after the Bluetooth link
            if let id = outputDevice(for: device.address) { return setDefaultOutput(id) }
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
