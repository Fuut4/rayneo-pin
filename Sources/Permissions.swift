// The permissions RayNeoPin needs, in one window: what each is for, its live status, and a button
// that asks for it or opens the exact System Settings pane, with the app's icon to drag into the
// list (the pattern of PermissionFlow / GrantKit). It opens on its own when a required one is
// missing.
//
// Builds signed ad-hoc (no Apple Development certificate) get a new code identity on every
// update, and macOS ties permissions to that identity: the old toggle stays "on" but no longer
// applies. After such an update the stale entries are reset (`tccutil reset <service> <bundle>`)
// so asking again starts clean.

import AppKit
import AVFoundation
import CoreBluetooth
import CoreMotion
import Security
import SwiftUI

enum Permission: String, CaseIterable, Identifiable {
    case screenRecording, accessibility, motion, bluetooth, camera

    var id: String { rawValue }

    enum Status { case granted, needsRelaunch, notGranted, denied }

    var title: String {
        switch self {
        case .screenRecording: return "Screen & System Audio Recording"
        case .accessibility: return "Accessibility"
        case .motion: return "Motion & Fitness"
        case .bluetooth: return "Bluetooth"
        case .camera: return "Camera"
        }
    }

    var purpose: String {
        switch self {
        case .screenRecording: return "Shows your screen in the glasses. Required."
        case .accessibility: return "Keeps windows off the glasses' own display and puts them back after unplugging (Virtual Display), and the typing hint."
        case .motion: return "Reads the AirPods' head motion, the drift reference."
        case .bluetooth: return "Connects your AirPods when you pick them in the menu."
        case .camera: return "Optional drift reference from the Mac's camera."
        }
    }

    var icon: String {
        switch self {
        case .screenRecording: return "rectangle.dashed.badge.record"
        case .accessibility: return "accessibility"
        case .motion: return "figure.walk.motion"
        case .bluetooth: return "dot.radiowaves.left.and.right"
        case .camera: return "camera"
        }
    }

    var required: Bool { self == .screenRecording }

    /// Panes where the app is added by dragging it into the list (or with +).
    var draggable: Bool { self == .screenRecording || self == .accessibility }

    var pane: URL {
        let anchor: String
        switch self {
        case .screenRecording: anchor = "Privacy_ScreenCapture"
        case .accessibility: anchor = "Privacy_Accessibility"
        case .motion: anchor = "Privacy_Motion"
        case .bluetooth: anchor = "Privacy_Bluetooth"
        case .camera: anchor = "Privacy_Camera"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!
    }

    /// The TCC service name, for `tccutil reset`.
    var service: String {
        switch self {
        case .screenRecording: return "ScreenCapture"
        case .accessibility: return "Accessibility"
        case .motion: return "Motion"
        case .bluetooth: return "BluetoothAlways"
        case .camera: return "Camera"
        }
    }

    /// Only the permissions the current settings use are listed.
    func relevant(_ s: Settings) -> Bool {
        switch self {
        case .screenRecording: return true
        case .accessibility: return !s.singleDisplay || s.flag("typingDrift")
        case .motion, .bluetooth: return s.tracking != .glasses
        case .camera: return s.flag("cameraDrift")
        }
    }

    /// Checked without prompting. Screen Recording is frozen per process: a fresh grant shows up
    /// only in a new process, so `freshScreenGrant` asks one.
    func status(freshScreenGrant: Bool) -> Status {
        switch self {
        case .screenRecording:
            return CGPreflightScreenCaptureAccess() ? .granted : freshScreenGrant ? .needsRelaunch : .notGranted
        case .accessibility:
            return AXIsProcessTrusted() ? .granted : .notGranted
        case .motion:
            switch CMHeadphoneMotionManager.authorizationStatus() {
            case .authorized: return .granted
            case .denied, .restricted: return .denied
            default: return .notGranted
            }
        case .bluetooth:
            // macOS aborts a process that asks without the usage description (a bare binary, CI).
            guard Bundle.main.object(forInfoDictionaryKey: "NSBluetoothAlwaysUsageDescription") != nil else { return .notGranted }
            switch CBManager.authorization {
            case .allowedAlways: return .granted
            case .denied, .restricted: return .denied
            default: return .notGranted
            }
        case .camera:
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized: return .granted
            case .denied, .restricted: return .denied
            default: return .notGranted
            }
        }
    }

    /// Asks with the system prompt where there is one, and opens the pane where the switch lives.
    func request(_ app: AppDelegate) {
        switch self {
        case .screenRecording:
            CGRequestScreenCaptureAccess()
            NSWorkspace.shared.open(pane)
        case .accessibility:
            _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
            NSWorkspace.shared.open(pane)
        case .motion:
            // macOS asks the first time motion is requested (AirPods in the ears).
            if CMHeadphoneMotionManager.authorizationStatus() == .notDetermined { app.headphones.stop(); app.headphones.start() }
            else { NSWorkspace.shared.open(pane) }
        case .bluetooth:
            if CBManager.authorization == .notDetermined { Permission.bluetoothProbe = CBCentralManager() }
            else { NSWorkspace.shared.open(pane) }
        case .camera:
            if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined { AVCaptureDevice.requestAccess(for: .video) { _ in } }
            else { NSWorkspace.shared.open(pane) }
        }
    }

    /// Removes this app's entry for the service, e.g. a stale "on" left by an older build.
    @discardableResult
    func reset() -> Bool {
        guard let id = Bundle.main.bundleIdentifier else { return false }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        p.arguments = ["reset", service, id]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    private static var bluetoothProbe: CBCentralManager? // creating one is what shows the prompt

    /// True when this build is signed ad-hoc: its permissions don't carry over to the next build.
    static var adHocSigned: Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(Bundle.main.bundleURL as CFURL, [], &code) == errSecSuccess, let code else { return false }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, [], &info) == errSecSuccess,
              let flags = (info as? [String: Any])?[kSecCodeInfoFlags as String] as? UInt32 else { return false }
        return flags & SecCodeSignatureFlags.adhoc.rawValue != 0
    }

    /// After an update of an ad-hoc build, the old grants point at the previous build: clear them
    /// so macOS asks cleanly instead of showing a switch that is on but does nothing.
    static func resetStaleAfterUpdate() {
        let key = "permissionsRevision"
        let revision = SettingsView.revision
        defer { UserDefaults.standard.set(revision, forKey: key) }
        guard let last = UserDefaults.standard.string(forKey: key), last != revision, adHocSigned,
              !CGPreflightScreenCaptureAccess() else { return }
        Permission.screenRecording.reset()
        if !AXIsProcessTrusted() { Permission.accessibility.reset() }
        Telemetry.shared.event("stale permissions reset after update", details: "\(last) → \(revision)", time: CACurrentMediaTime())
    }
}

final class PermissionsModel: ObservableObject {
    unowned let app: AppDelegate
    @Published var statuses: [Permission: Permission.Status] = [:]
    private var timer: Timer?

    init(_ app: AppDelegate) {
        self.app = app
        refresh()
    }

    var shown: [Permission] { Permission.allCases.filter { $0.relevant(app.settings) } }

    func refresh() {
        let fresh = !CGPreflightScreenCaptureAccess() && AppDelegate.permissionGrantedInFreshProcess()
        var s: [Permission: Permission.Status] = [:]
        for p in Permission.allCases { s[p] = p.status(freshScreenGrant: fresh) }
        if s != statuses { statuses = s }
    }

    /// While visible: System Settings changes don't notify us, so look again every 1.5 s.
    func watch(_ on: Bool) {
        timer?.invalidate()
        timer = on ? Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in self?.refresh() } : nil
    }
}

struct PermissionsView: View {
    @ObservedObject var model: PermissionsModel
    var standalone = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if standalone {
                HStack(spacing: 12) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 44, height: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("RayNeoPin needs a few permissions").font(.title3.weight(.semibold))
                        Text("Each one is used only for what it says. You can change them any time in System Settings.")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            ForEach(model.shown) { p in row(p) }
            if Permission.adHocSigned {
                Text("This build isn't signed with a developer certificate, so macOS may ask again after updates.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(standalone ? 22 : 0)
        .frame(width: standalone ? 560 : nil)
        .onAppear { model.refresh(); model.watch(true) }
        .onDisappear { model.watch(false) }
    }

    private func row(_ p: Permission) -> some View {
        let status = model.statuses[p] ?? .notGranted
        return HStack(alignment: .center, spacing: 12) {
            Image(systemName: p.icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(Color.accentColor.gradient, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(p.title).font(.body.weight(.medium))
                    if p.required { Text("Required").font(.caption2.weight(.bold)).foregroundStyle(.secondary) }
                }
                Text(p.purpose).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            switch status {
            case .granted:
                Label("Allowed", systemImage: "checkmark.circle.fill").labelStyle(.titleAndIcon).foregroundStyle(.green)
            case .needsRelaunch:
                Button("Relaunch") { model.app.relaunch() }.buttonStyle(.borderedProminent)
            case .notGranted, .denied:
                HStack(spacing: 8) {
                    if p.draggable { AppDragTile() }
                    Menu {
                        Button("Open System Settings") { NSWorkspace.shared.open(p.pane) }
                        Button("Already on but not working? Reset it") { p.reset(); p.request(model.app); model.refresh() }
                    } label: {
                        Text(status == .denied ? "Open Settings…" : "Allow…")
                    } primaryAction: {
                        p.request(model.app)
                        model.refresh()
                    }
                    .fixedSize()
                }
            }
        }
        .padding(.vertical, 4)
    }
}

/// The app's icon, draggable into a System Settings permission list (it carries the app's URL).
struct AppDragTile: View {
    var body: some View {
        Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .frame(width: 26, height: 26)
            .help("Drag into the list in System Settings")
            .onDrag { NSItemProvider(object: Bundle.main.bundleURL as NSURL) }
    }
}

/// The standalone window, on the Mac's own screen.
enum PermissionsWindow {
    private static var window: NSWindow?

    static func show(_ app: AppDelegate) {
        if let window { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
                         styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true
        w.title = "RayNeoPin Permissions"
        w.isReleasedWhenClosed = false
        w.contentViewController = NSHostingController(rootView: PermissionsView(model: PermissionsModel(app), standalone: true)
            .background(Color(nsColor: .windowBackgroundColor)))
        if let screen = Displays.builtin().flatMap(Displays.screen) ?? NSScreen.main {
            let f = screen.visibleFrame, size = w.frame.size
            w.setFrameOrigin(NSPoint(x: f.midX - size.width / 2, y: f.midY - size.height / 2))
        }
        window = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }
}
