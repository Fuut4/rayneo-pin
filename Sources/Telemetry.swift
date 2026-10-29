// Telemetry recorder: every session is a folder in ~/Library/Logs/RayNeoPin with one CSV per
// stream, so what the glasses, the AirPods and the renderer did (values, delays, decisions) can be
// replayed and charted afterwards (tools/analyze_telemetry.py).
//
//   session.json  version, macOS, every setting, displays
//   imu.csv       every glasses IMU sample (~500/s): raw sensors, fusion, bias
//   airpods.csv   every AirPods sample (~25/s), next to the glasses at the same instant, with the
//                 calibration's full state
//   frames.csv    every rendered frame (~120/s): pose pipeline, prediction, why it was drawn
//   state.csv     20/s overview (connection, temperatures, modes, fps)
//   events.csv    recenters, calibration steps, glitches, re-references, mode changes…
//
// Angles in degrees, rates in °/s, times in seconds on the host clock (CACurrentMediaTime),
// accelerations in m/s². Writes are buffered on a background queue.

import Foundation

final class Telemetry {
    static let shared = Telemetry()
    static let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/RayNeoPin")

    static let headers: [String: [String]] = [
        "imu": ["t", "tick", "dt_ms", "acc_x", "acc_y", "acc_z", "gyro_x", "gyro_y", "gyro_z", "temp_c", "proximity",
                "q_w", "q_x", "q_y", "q_z", "yaw", "pitch", "roll", "bias_x", "bias_y", "bias_z",
                "omega_x", "omega_y", "omega_z", "still_s", "gravity_rejected", "state", "temp_shift_y", "scale_y"],
        "airpods": ["t", "sensor_t", "arrival", "delay_ms", "bud", "q_w", "q_x", "q_y", "q_z", "yaw", "pitch", "roll",
                    "rate_x", "rate_y", "rate_z", "speed", "glasses_t", "glasses_yaw", "glasses_pitch", "glasses_roll",
                    "glasses_x", "glasses_y", "glasses_z", "glasses_speed", "speed_mismatch", "rotated_x", "rotated_y", "rotated_z",
                    "vector_mismatch", "as_glasses_yaw", "as_glasses_pitch", "as_glasses_roll", "yaw_vs_glasses",
                    "phase", "left", "right", "up", "down", "progress", "ready", "fit", "pairs", "lag_ms", "glitches", "jumps",
                    "gaps", "bud_switches", "reseats", "restarts", "ignored", "heading_correction"],
        "frames": ["t", "dt_ms", "present_in_ms", "prediction_ms", "source", "pose_yaw", "pose_pitch", "pose_roll",
                   "omega_x", "omega_y", "omega_z", "speed", "motion", "euro_cutoff_hz", "steady_yaw", "steady_pitch", "steady_roll",
                   "steady_delta", "anchor_yaw", "anchor_pitch", "head_yaw", "head_pitch", "head_roll", "bottom_delta",
                   "heading_correction", "camera_correction", "zoom", "zoom_fix", "lock_blend", "following",
                   "drawn", "draw_reason", "capture_serial", "cursor_version", "work_ms"],
        "state": ["t", "glasses_connected", "glasses_state", "imu_hz", "asleep", "temp_c", "tracking", "airpods_receiving",
                  "airpods_hz", "airpods_delay_ms", "cal_phase", "cal_progress", "cal_ready", "airpods_active", "airpods_ignored",
                  "bias_learned_x", "bias_learned_y", "bias_learned_z", "fps", "drawn_fps", "pixel_lock"],
        "events": ["t", "event", "details"],
    ]

    private let queue = DispatchQueue(label: "telemetry", qos: .utility)
    private var handles: [String: FileHandle] = [:]
    private var buffers: [String: Data] = [:]
    private var written = 0
    private var flushTimer: DispatchSourceTimer?
    private(set) var session: URL?
    /// Read from the sensor and render threads; a stale read only drops or adds a row.
    private(set) var enabled = false
    private let limit = 1_500_000_000 // per session; the rest is dropped

    func start(info: [String: Any]) {
        queue.async { [self] in
            guard handles.isEmpty else { return }
            try? FileManager.default.createDirectory(at: Telemetry.folder, withIntermediateDirectories: true)
            prune()
            let f = DateFormatter()
            f.dateFormat = "yyyyMMdd-HHmmss"
            let dir = Telemetry.folder.appendingPathComponent("session-\(f.string(from: Date()))")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            session = dir
            written = 0
            var meta = info
            meta["started"] = ISO8601DateFormatter().string(from: Date())
            meta["host_time_at_start"] = ProcessInfo.processInfo.systemUptime
            if let data = try? JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: dir.appendingPathComponent("session.json"))
            }
            for (name, header) in Telemetry.headers {
                let url = dir.appendingPathComponent("\(name).csv")
                FileManager.default.createFile(atPath: url.path, contents: nil)
                handles[name] = try? FileHandle(forWritingTo: url)
                buffers[name] = Data((header.joined(separator: ",") + "\n").utf8)
            }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
            timer.setEventHandler { [weak self] in self?.flush() }
            timer.resume()
            flushTimer = timer
            enabled = true
        }
    }

    func stop() {
        enabled = false
        queue.async { [self] in
            flush()
            flushTimer?.cancel()
            flushTimer = nil
            for h in handles.values { try? h.close() }
            handles.removeAll()
            buffers.removeAll()
        }
    }

    /// One row; `fields` in the stream's header order.
    func row(_ stream: String, _ fields: [String]) {
        guard enabled else { return }
        let line = fields.joined(separator: ",") + "\n"
        queue.async { [self] in
            guard buffers[stream] != nil, written < limit else { return }
            buffers[stream]!.append(contentsOf: line.utf8)
            written += line.utf8.count
            if buffers[stream]!.count > 256_000 { flush(stream) }
        }
    }

    func event(_ message: String, details: String = "", time: Double) {
        row("events", [f3(time), quoted(message), quoted(details)])
    }

    /// Zips the current (or newest) session onto the Desktop and returns the file.
    func export(completion: @escaping (URL?) -> Void) {
        queue.async { [self] in
            flush()
            let dir = session ?? (try? FileManager.default.contentsOfDirectory(at: Telemetry.folder, includingPropertiesForKeys: nil))?
                .filter { $0.lastPathComponent.hasPrefix("session-") }.max { $0.lastPathComponent < $1.lastPathComponent }
            guard let dir else { DispatchQueue.main.async { completion(nil) }; return }
            let dest = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop/RayNeoPin-\(dir.lastPathComponent).zip")
            try? FileManager.default.removeItem(at: dest)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            p.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", dir.path, dest.path]
            try? p.run()
            p.waitUntilExit()
            let ok = p.terminationStatus == 0
            DispatchQueue.main.async { completion(ok ? dest : nil) }
        }
    }

    private func flush(_ only: String? = nil) {
        for (name, data) in buffers where only == nil || only == name {
            guard !data.isEmpty, let h = handles[name] else { continue }
            h.write(data)
            buffers[name] = Data()
        }
    }

    private func quoted(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "'") + "\"" }

    /// Keeps the 8 most recent sessions (and removes the old single-file format).
    private func prune() {
        let items = (try? FileManager.default.contentsOfDirectory(at: Telemetry.folder, includingPropertiesForKeys: nil)) ?? []
        for old in items where old.lastPathComponent.hasPrefix("telemetry-") { try? FileManager.default.removeItem(at: old) }
        let sessions = items.filter { $0.lastPathComponent.hasPrefix("session-") }.sorted { $0.lastPathComponent > $1.lastPathComponent }
        for old in sessions.dropFirst(7) { try? FileManager.default.removeItem(at: old) }
    }
}

/// Number formatting for telemetry fields.
func f3(_ x: Double) -> String { x.isFinite ? String(format: "%.3f", x) : "" }
func f4(_ x: Double) -> String { x.isFinite ? String(format: "%.4f", x) : "" }
func deg3(_ r: Double) -> String { f3(r * 180 / .pi) }
func deg4(_ r: Double) -> String { f4(r * 180 / .pi) }
