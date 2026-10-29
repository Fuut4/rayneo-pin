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
    /// Uploads a compact copy for analysis (Settings › General), nil when off.
    private var uploader: TelemetryUploader?
    /// Set before `start`; takes effect for the next session.
    var upload = false
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
            uploader = upload ? TelemetryUploader(info: meta, queue: queue) : nil
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
            var ticks = 0
            timer.setEventHandler { [weak self] in
                self?.flush()
                ticks += 1
                if ticks % 20 == 0 { self?.uploader?.send() } // every 10 s
            }
            timer.resume()
            flushTimer = timer
            enabled = true
        }
    }

    func stop() {
        enabled = false
        let sendRest = upload // sharing just switched off: whatever is pending is dropped, not sent
        queue.async { [self] in
            flush()
            flushTimer?.cancel()
            flushTimer = nil
            if sendRest { uploader?.send() } else { uploader?.cancel() }
            uploader = nil
            for h in handles.values { try? h.close() }
            handles.removeAll()
            buffers.removeAll()
        }
    }

    /// Stops recording and deletes every session on this Mac.
    func deleteAll(then: @escaping () -> Void) {
        stop()
        queue.async { [self] in
            try? FileManager.default.removeItem(at: Telemetry.folder)
            session = nil
            DispatchQueue.main.async(execute: then)
        }
    }

    /// One row; `fields` in the stream's header order.
    func row(_ stream: String, _ fields: [String]) {
        guard enabled else { return }
        let line = fields.joined(separator: ",") + "\n"
        queue.async { [self] in
            guard buffers[stream] != nil, written < limit else { return }
            buffers[stream]!.append(contentsOf: line.utf8)
            uploader?.offer(stream, fields)
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

/// Sends a compact copy of the session to the project's Supabase database while it runs, so it can
/// be analyzed without exporting anything: dense streams thinned (IMU 20/s, frames 30/s, overview
/// 2/s) but every AirPods sample, every event, every IMU gap and every stalled or jumping frame kept.
/// The key below can only insert rows; it can't read, change or delete anything.
final class TelemetryUploader {
    static let endpoint = URL(string: "https://umrcguqdblcwdtccfeit.supabase.co/rest/v1/")!
    static let key = "sb_publishable_YiW9vqbk9IHAoQ5aBQZ6GQ_QSTxvpU9"

    /// Columns of each table (a subset of the CSV columns) and which of them hold text.
    static let tables: [String: (columns: [String], text: Set<String>)] = [
        "frames": (["t", "dt_ms", "present_in_ms", "prediction_ms", "source", "pose_yaw", "pose_pitch", "pose_roll", "speed", "motion",
                    "euro_cutoff_hz", "steady_delta", "anchor_yaw", "anchor_pitch", "head_yaw", "head_pitch", "head_roll", "bottom_delta",
                    "heading_correction", "camera_correction", "zoom", "zoom_fix", "lock_blend", "following", "drawn", "draw_reason", "work_ms"],
                   ["source", "draw_reason"]),
        "imu": (["t", "dt_ms", "acc_x", "acc_y", "acc_z", "gyro_x", "gyro_y", "gyro_z", "temp_c", "proximity", "yaw", "pitch", "roll",
                 "bias_x", "bias_y", "bias_z", "omega_x", "omega_y", "omega_z", "still_s", "gravity_rejected", "state", "temp_shift_y", "scale_y"],
                ["state"]),
        "airpods": (["t", "sensor_t", "arrival", "delay_ms", "bud", "yaw", "pitch", "roll", "rate_x", "rate_y", "rate_z", "speed",
                     "glasses_yaw", "glasses_pitch", "glasses_roll", "glasses_x", "glasses_y", "glasses_z", "glasses_speed", "speed_mismatch",
                     "rotated_x", "rotated_y", "rotated_z", "vector_mismatch", "as_glasses_yaw", "as_glasses_pitch", "as_glasses_roll",
                     "yaw_vs_glasses", "phase", "left", "right", "up", "down", "progress", "ready", "fit", "pairs", "lag_ms", "glitches",
                     "jumps", "gaps", "bud_switches", "reseats", "restarts", "ignored", "heading_correction"],
                    ["phase"]),
        "state": (Telemetry.headers["state"]!, ["glasses_state", "tracking", "cal_phase"]),
        "events": (["t", "event", "details"], ["event", "details"]),
    ]

    let session = UUID()
    private let queue: DispatchQueue
    private var pending: [String: [[String: Any]]] = [:]
    private var counts: [String: Int] = [:]
    private var lastHeadYaw: Double?
    private var sessionSent = false
    private let info: [String: Any]
    private var sending = false
    private var cancelled = false
    private var lastStream = ""

    init(info: [String: Any], queue: DispatchQueue) {
        self.info = info // already free of anything identifying (AppDelegate.sessionInfo)
        self.queue = queue
    }

    /// Called on the telemetry queue with each CSV row (header order).
    func offer(_ stream: String, _ fields: [String]) {
        guard let table = TelemetryUploader.tables[stream], let header = Telemetry.headers[stream] else { return }
        let n = (counts[stream] ?? 0) + 1
        counts[stream] = n
        func value(_ name: String) -> Double? { header.firstIndex(of: name).flatMap { Double(fields[$0]) } }
        switch stream {
        case "imu": guard n % 25 == 0 || (value("dt_ms") ?? 0) > 10 else { return }
        case "state": guard n % 10 == 0 else { return }
        case "frames":
            let yaw = value("head_yaw")
            let jumped = yaw != nil && lastHeadYaw != nil && abs(yaw! - lastHeadYaw!) > 0.5
            lastHeadYaw = yaw ?? lastHeadYaw
            guard n % 4 == 0 || jumped || (value("dt_ms") ?? 0) > 20 else { return }
        default: break
        }
        var row: [String: Any] = ["session_id": session.uuidString]
        for (i, name) in header.enumerated() where i < fields.count && table.columns.contains(name) {
            var f = fields[i]
            if f.hasPrefix("\""), f.hasSuffix("\""), f.count >= 2 { f = String(f.dropFirst().dropLast()) }
            // Every row needs every column: the database refuses a batch whose rows differ, and a
            // refused batch is dropped. Leaving out empty values lost whole batches of events.
            if table.text.contains(name) { row[name] = f.isEmpty ? NSNull() : f }
            else if let d = Double(f), d.isFinite { row[name] = d } else { row[name] = NSNull() }
        }
        pending[stream, default: []].append(row)
        // A long offline stretch must not grow without bound: keep the newest.
        if pending[stream]!.count > 60_000 { pending[stream]!.removeFirst(10_000) }
    }

    /// Nothing more is sent after this (a request already in flight still completes).
    func cancel() { cancelled = true }

    /// Posts what's pending (the session row first). Failed batches stay queued for the next try.
    func send() {
        guard !sending, !cancelled else { return }
        if !sessionSent {
            sending = true
            post("sessions", [["id": session.uuidString, "revision": info["revision"] ?? "", "info": info]]) { [self] status in
                let ok = status / 100 == 2
                sessionSent = ok
                sending = false
                if ok { send() }
            }
            return
        }
        // Tables in turn, so one that keeps failing can't hold up the others.
        let streams = pending.keys.sorted().filter { !pending[$0]!.isEmpty }
        guard !streams.isEmpty else { return }
        let stream = streams.first { $0 > lastStream } ?? streams[0]
        lastStream = stream
        let batch = Array(pending[stream]!.prefix(2000))
        sending = true
        post(stream, batch) { [self] status in
            // 2xx sent; 4xx the database refused it and always will, so drop it; else retry later.
            let done = status / 100 == 2 || status / 100 == 4
            if done { pending[stream]!.removeFirst(min(batch.count, pending[stream]!.count)) }
            sending = false
            if done { send() }
        }
    }

    /// HTTP status, or 0 when the request didn't get an answer.
    private func post(_ table: String, _ rows: [[String: Any]], done: @escaping (Int) -> Void) {
        var request = URLRequest(url: TelemetryUploader.endpoint.appendingPathComponent(table))
        request.httpMethod = "POST"
        request.setValue(TelemetryUploader.key, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(TelemetryUploader.key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("return=minimal", forHTTPHeaderField: "Prefer")
        request.httpBody = try? JSONSerialization.data(withJSONObject: rows)
        request.timeoutInterval = 30
        URLSession.shared.dataTask(with: request) { [queue] _, response, _ in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            queue.async { done(status) }
        }.resume()
    }
}
