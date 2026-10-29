// Telemetry consent. Nothing is recorded or sent until the person chooses to; the first launch
// asks once, Settings › Privacy changes it at any time, and both show exactly what is recorded.
// Telemetry only exists to find and fix drift: it holds head-motion numbers, never anything from
// the screen, the keyboard or the person.

import AppKit
import SwiftUI

enum TelemetryChoice: String, CaseIterable {
    case off, local, share

    var title: String {
        switch self {
        case .off: return "Off"
        case .local: return "Keep on this Mac only"
        case .share: return "Keep on this Mac and share with the developer"
        }
    }

    var detail: String {
        switch self {
        case .off: return "Nothing is recorded or sent."
        case .local: return "Recorded to ~/Library/Logs/RayNeoPin. Nothing leaves your Mac unless you export a session and send it yourself."
        case .share: return "Also sends a thinned copy (about 5 MB per 15 minutes) to the project's database so drift problems can be analyzed."
        }
    }
}

extension AppDelegate {
    static let consentKey = "telemetryChoice"

    /// nil until the person has answered.
    var telemetryChoice: TelemetryChoice? {
        UserDefaults.standard.string(forKey: AppDelegate.consentKey).flatMap(TelemetryChoice.init)
    }

    func setTelemetryChoice(_ choice: TelemetryChoice) {
        UserDefaults.standard.set(choice.rawValue, forKey: AppDelegate.consentKey)
        settings.setFlag("telemetry", choice != .off)
        settings.setFlag("uploadTelemetry", choice == .share)
        applyExtras()
    }

    /// Off until answered, whatever an earlier version stored; then asks once.
    func askTelemetryConsentIfNeeded() {
        guard telemetryChoice == nil else { return }
        settings.setFlag("telemetry", false)
        settings.setFlag("uploadTelemetry", false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, self.telemetryChoice == nil else { return }
            ConsentWindow.show { [weak self] choice in self?.setTelemetryChoice(choice) }
        }
    }

    /// Deletes every session on this Mac (the current one too; recording restarts if it's on).
    func deleteTelemetry() {
        Telemetry.shared.deleteAll { [weak self] in self?.applyExtras() }
    }
}

/// The one-time question, on the Mac's own screen.
enum ConsentWindow {
    private static var window: NSWindow?

    static func show(_ choose: @escaping (TelemetryChoice) -> Void) {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 600),
                         styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isReleasedWhenClosed = false
        w.contentViewController = NSHostingController(rootView: ConsentView { choice in
            choose(choice)
            window?.close()
            window = nil
        })
        if let screen = Displays.builtin().flatMap(Displays.screen) ?? NSScreen.main {
            let f = screen.visibleFrame, size = w.frame.size
            w.setFrameOrigin(NSPoint(x: f.midX - size.width / 2, y: f.midY - size.height / 2))
        }
        window = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }
}

struct ConsentView: View {
    let choose: (TelemetryChoice) -> Void
    @State private var showDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(Color.blue.gradient, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Help fix drift?").font(.title2.weight(.semibold))
                    Text("Telemetry is off. You choose.").foregroundStyle(.secondary)
                }
            }
            Text("RayNeoPin can record how the glasses and AirPods sensors move while you use it, so drift and tracking glitches can be found and fixed. It is only motion numbers and timings: never what's on your screen, what you type, window or app names, or who you are.")
                .fixedSize(horizontal: false, vertical: true)
            DisclosureGroup("What exactly is recorded", isExpanded: $showDetails) {
                ScrollView { TelemetryDisclosure().padding(.vertical, 6) }.frame(height: 220)
            }
            Text("You can change this or delete every recording at any time in Settings › Privacy.")
                .font(.callout).foregroundStyle(.secondary)
            VStack(spacing: 8) {
                Button { choose(.share) } label: {
                    Text("Record and share to help fix drift").frame(maxWidth: .infinity)
                }
                .keyboardShortcut(.defaultAction)
                Button { choose(.local) } label: { Text("Record on this Mac only").frame(maxWidth: .infinity) }
                Button { choose(.off) } label: { Text("Don't record").frame(maxWidth: .infinity) }
            }
            .controlSize(.large)
        }
        .padding(24)
        .padding(.top, 8)
        .frame(width: 560)
    }
}

/// Every stream and every column, in plain words. Shared with the consent window and Settings.
struct TelemetryDisclosure: View {
    private static let streams: [(name: String, what: String, shared: String)] = [
        ("imu", "Glasses motion sensor, every sample (~500/s): acceleration, rotation, temperature, the worn sensor, and the head angle and drift estimate computed from them.",
         "1 in 25 samples, plus any sample that arrived late."),
        ("airpods", "AirPods head motion (~25/s) next to the glasses at the same instant, which earbud sent it, and the AirPods calibration's progress and fit.",
         "Every sample."),
        ("frames", "Every frame drawn in the glasses: head angle, prediction, smoothing, zoom, timing and why it was drawn. No image.",
         "1 in 4 frames, plus every frame that stalled or jumped."),
        ("state", "A 20/s overview: connected or not, sensor rates and delays, tracking mode, calibration progress, frame rate.",
         "1 in 10 rows."),
        ("events", "Recenters, double taps, calibration steps, connections, AirPods glitches and re-references.",
         "Every event."),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Self.streams, id: \.name) { s in
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(s.name).csv").font(.system(.body, design: .monospaced).weight(.semibold))
                    Text(s.what).fixedSize(horizontal: false, vertical: true)
                    Text("Shared: \(s.shared)").font(.callout).foregroundStyle(.secondary)
                    Text((Telemetry.headers[s.name] ?? []).joined(separator: ", "))
                        .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("session.json").font(.system(.body, design: .monospaced).weight(.semibold))
                Text("App version, macOS version, Mac model (like Mac15,6), each display's resolution, scale and refresh rate, and this app's own settings.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Never recorded").font(.headline)
                Text("Screen contents or screenshots, window titles, app names, anything you type or the text under the cursor, file names, your name, account or email, AirPods names or Bluetooth addresses, display names, location.")
                    .fixedSize(horizontal: false, vertical: true)
                Text("Shared sessions are labeled with a random ID made for each session, so they can't be linked to you or to each other. As with any web request, the database's servers see your IP address; it isn't stored with the data. The upload key can only add rows: it can't read anything back.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
