// Telemetry recorder: one CSV per session in ~/Library/Logs/RayNeoPin, so what the glasses and
// the AirPods actually did (delays, glitches, drift, calibration) can be analyzed afterwards.
//
// Rows, by their first column:
//   s  state snapshot, 20 per second (see `stateHeader`)
//   a  one AirPods sample next to the glasses' rotation at the same instant
//   e  an event (recenter, calibration finished, AirPods ignored, …)
// Angles in degrees, rates in °/s, times in seconds (host clock), accelerations in m/s².

import Foundation

final class Telemetry {
    static let shared = Telemetry()
    static let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/RayNeoPin")

    static let stateHeader = [
        "kind", "t",
        "glasses_connected", "glasses_state", "imu_hz", "asleep", "temp_c", "still_s", "gravity_rejected",
        "gyro_x", "gyro_y", "gyro_z", "acc_x", "acc_y", "acc_z", "bias_x", "bias_y", "bias_z",
        "fused_yaw", "fused_pitch", "fused_roll",
        "tracking", "airpods_receiving", "airpods_hz", "airpods_delay_ms", "airpods_yaw", "airpods_pitch", "airpods_roll",
        "cal_ready", "cal_progress", "cal_turned", "cal_nodded", "cal_lag_ms", "cal_fit", "cal_glitches", "cal_restarts", "cal_reseats",
        "airpods_active", "airpods_ignored", "heading_correction", "yaw_gap", "bias_learned_x", "bias_learned_y", "bias_learned_z",
        "pose_yaw", "pose_pitch", "pose_roll", "anchor_yaw", "anchor_pitch", "head_yaw", "head_pitch", "head_roll",
        "speed", "prediction_ms", "zoom", "pixel_lock", "fps", "drawn_fps", "following",
    ]
    static let sampleHeader = ["kind", "t", "airpods_time", "arrival", "rate_x", "rate_y", "rate_z",
                               "glasses_x", "glasses_y", "glasses_z", "speed_airpods", "speed_glasses", "mismatch"]

    private let queue = DispatchQueue(label: "telemetry", qos: .utility)
    private var handle: FileHandle?
    private var written = 0
    private(set) var file: URL?
    private let limit = 300_000_000 // stop a single session's file at 300 MB

    var isRecording: Bool { queue.sync { handle != nil } }

    func start() {
        queue.async { [self] in
            guard handle == nil else { return }
            try? FileManager.default.createDirectory(at: Telemetry.folder, withIntermediateDirectories: true)
            prune()
            let f = DateFormatter()
            f.dateFormat = "yyyyMMdd-HHmmss"
            let url = Telemetry.folder.appendingPathComponent("telemetry-\(f.string(from: Date())).csv")
            FileManager.default.createFile(atPath: url.path, contents: nil)
            handle = try? FileHandle(forWritingTo: url)
            file = url
            written = 0
            let revision = Bundle.main.url(forResource: "revision", withExtension: nil)
                .flatMap { try? String(contentsOf: $0, encoding: .utf8) }?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "dev"
            write("# RayNeoPin \(revision) telemetry, started \(Date())\n")
            write("# " + Telemetry.stateHeader.joined(separator: ",") + "\n")
            write("# " + Telemetry.sampleHeader.joined(separator: ",") + "\n")
            write("# e,t,message\n")
        }
    }

    func stop() {
        queue.async { [self] in
            try? handle?.close()
            handle = nil
        }
    }

    func state(_ values: [String]) { line(["s"] + values) }
    func sample(_ values: [String]) { line(["a"] + values) }

    func event(_ message: String, time: Double) {
        line(["e", String(format: "%.4f", time), "\"" + message.replacingOccurrences(of: "\"", with: "'") + "\""])
    }

    private func line(_ fields: [String]) {
        queue.async { [self] in
            guard handle != nil else { return }
            write(fields.joined(separator: ",") + "\n")
        }
    }

    private func write(_ s: String) {
        guard let handle, written < limit, let data = s.data(using: .utf8) else { return }
        handle.write(data)
        written += data.count
    }

    /// Keeps the 15 most recent sessions.
    private func prune() {
        let files = (try? FileManager.default.contentsOfDirectory(at: Telemetry.folder, includingPropertiesForKeys: [.creationDateKey]))?
            .filter { $0.lastPathComponent.hasPrefix("telemetry-") }
            .sorted { $0.lastPathComponent > $1.lastPathComponent } ?? []
        for old in files.dropFirst(14) { try? FileManager.default.removeItem(at: old) }
    }
}

/// Number formatting for telemetry fields.
func f3(_ x: Double) -> String { x.isFinite ? String(format: "%.3f", x) : "" }
func deg3(_ r: Double) -> String { f3(r * 180 / .pi) }
