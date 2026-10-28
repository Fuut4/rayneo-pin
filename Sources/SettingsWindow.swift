// The Settings window: every option, grouped in tabs, so the menu bar menu only keeps everyday
// actions. Each control goes through the same AppDelegate code as the menus and hotkeys.

import AppKit
import ServiceManagement
import SwiftUI

final class SettingsModel: ObservableObject {
    unowned let app: AppDelegate

    init(_ app: AppDelegate) { self.app = app }

    private func changed() { objectWillChange.send() }

    /// A Settings property; `then` runs after it is stored and applied.
    func value<T>(_ kp: ReferenceWritableKeyPath<Settings, T>, then: ((T) -> Void)? = nil) -> Binding<T> {
        Binding(get: { self.app.settings[keyPath: kp] },
                set: { v in
                    self.app.settings[keyPath: kp] = v
                    self.app.applyExtras()
                    then?(v)
                    self.changed()
                })
    }

    func flag(_ key: String) -> Binding<Bool> {
        Binding(get: { self.app.settings.flag(key) }, set: { self.app.setFlag(key, $0); self.changed() })
    }

    func choice(_ key: String) -> Binding<String> {
        Binding(get: { self.app.settings.choice(key) }, set: { self.app.setChoice(key, $0); self.changed() })
    }

    var setup: Binding<String> {
        Binding(get: { ["display", "window"].contains(self.app.settings.sourceKind) ? "mirror" : self.app.settings.sourceKind },
                set: { if $0 != "mirror" { self.app.chooseSetup($0); self.changed() } })
    }

    var tracking: Binding<TrackingMode> {
        Binding(get: { self.app.settings.tracking }, set: { self.app.chooseTracking($0); self.changed() })
    }

    var resolution: Binding<VirtualMonitor.Resolution> {
        Binding(get: { self.app.settings.resolution }, set: { self.app.chooseResolution($0); self.changed() })
    }

    var zoom: Binding<Double> {
        Binding(get: { self.app.settings.zoom }, set: { self.app.setZoom($0); self.changed() })
    }

    var refresh: Binding<Bool> {
        Binding(get: { self.app.settings.highRefresh }, set: { self.app.setHighRefresh($0); self.changed() })
    }

    var developer: Binding<Bool> {
        Binding(get: { self.app.settings.developer }, set: { self.app.setDeveloper($0); self.changed() })
    }

    var developerOnMac: Binding<Bool> {
        Binding(get: { self.app.settings.developerOnMac }, set: { self.app.setDeveloperOnMac($0); self.changed() })
    }

    var login: Binding<Bool> {
        Binding(get: { SMAppService.mainApp.status == .enabled },
                set: { if $0 != (SMAppService.mainApp.status == .enabled) { self.app.toggleLogin() }; self.changed() })
    }

    func run(_ action: @escaping () -> Void) -> () -> Void { { action(); self.changed() } }
}

/// A settings row in the Magnet / System Settings style: title, an explanation under it, the
/// control on the right.
struct Row<Control: View>: View {
    let title: String
    var detail: String?
    @ViewBuilder var control: () -> Control

    var body: some View {
        LabeledContent {
            control()
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                if let detail { Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
        }
        .padding(.vertical, 3)
    }
}

/// A keyboard shortcut drawn like a key, as in System Settings.
struct KeyCap: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(.body, design: .rounded).weight(.medium))
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}

/// A toggle row with an explanation.
struct ToggleRow: View {
    let title: String
    var detail: String?
    let isOn: Binding<Bool>

    var body: some View {
        Row(title: title, detail: detail) { Toggle("", isOn: isOn).labelsHidden().toggleStyle(.switch) }
    }
}

enum SettingsPage: String, CaseIterable, Identifiable {
    case general, display, text, tracking, anchoring, accuracy, performance, shortcuts, about
    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .display: return "Display"
        case .text: return "Text Clarity"
        case .tracking: return "Head Tracking"
        case .anchoring: return "Anchoring"
        case .accuracy: return "Accuracy"
        case .performance: return "Performance"
        case .shortcuts: return "Shortcuts"
        case .about: return "About"
        }
    }

    var icon: (name: String, color: Color) {
        switch self {
        case .general: return ("gearshape.fill", .gray)
        case .display: return ("display", .blue)
        case .text: return ("textformat.size", .indigo)
        case .tracking: return ("move.3d", .green)
        case .anchoring: return ("pin.fill", .orange)
        case .accuracy: return ("scope", .red)
        case .performance: return ("speedometer", .teal)
        case .shortcuts: return ("command", .purple)
        case .about: return ("info.circle.fill", .secondary)
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    @State private var page: SettingsPage?

    init(model: SettingsModel, page: SettingsPage = .general) {
        self.model = model
        _page = State(initialValue: page)
    }

    var body: some View {
        NavigationSplitView {
            List(SettingsPage.allCases, selection: $page) { p in
                Label {
                    Text(p.title)
                } icon: {
                    Image(systemName: p.icon.name)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 24, height: 24)
                        .background(p.icon.color.gradient, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .padding(.vertical, 3)
                .tag(p)
            }
            .navigationSplitViewColumnWidth(200)
        } detail: {
            Group {
                switch page ?? .general {
                case .general: general
                case .display: display
                case .text: text
                case .tracking: tracking
                case .anchoring: anchoring
                case .accuracy: accuracy
                case .performance: performance
                case .shortcuts: shortcuts
                case .about: about
                }
            }
            .formStyle(.grouped)
            .navigationTitle((page ?? .general).title)
        }
        .frame(minWidth: 780, minHeight: 600)
    }

    private var m: SettingsModel { model }

    // MARK: Pages

    private var general: some View {
        Form {
            Section("Status") {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    let s = m.app.imu.snapshot()
                    VStack(alignment: .leading, spacing: 6) {
                        status(s.connected ? "Glasses connected" : "Glasses not connected", s.connected ? .green : .red)
                        status(s.ready ? "Tracking ready" : "Tracking calibrating…", s.ready ? .green : .orange)
                        status(m.app.settings.tracking == .glasses ? "AirPods not used"
                               : m.app.renderer?.isUsingAirPods == true ? "AirPods correcting drift"
                               : m.app.headphones.latest() != nil ? "AirPods calibrating" : "AirPods: no data",
                               m.app.renderer?.isUsingAirPods == true ? .green : .secondary)
                    }
                    .padding(.vertical, 4)
                }
            }
            Section("Quick actions") {
                Row(title: "Recenter the screen", detail: "Or press ⌃⌥R, or double-tap the glasses.") {
                    Button("Recenter", action: m.run { m.app.recenter() })
                }
                Row(title: "Preset", detail: "Desk keeps the screen fixed. Sofa and Lying Down let it follow you.") {
                    HStack {
                        Button("Desk", action: m.run { m.app.applyPreset("desk") })
                        Button("Sofa", action: m.run { m.app.applyPreset("sofa") })
                        Button("Lying Down", action: m.run { m.app.applyPreset("lying") })
                    }
                }
            }
            Section("App") {
                ToggleRow(title: "Open at login", isOn: m.login)
                ToggleRow(title: "Developer mode", detail: "Live sensor and pipeline data in the glasses. ⌃⌥D", isOn: m.developer)
                ToggleRow(title: "Also show developer data on the Mac", detail: "In a window you can screenshot.", isOn: m.developerOnMac)
            }
        }
    }

    private func status(_ text: String, _ color: Color) -> some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(text)
        }
    }

    private var display: some View {
        Form {
            Section("Setup") {
                Row(title: "Setup", detail: "Glasses Screen adds no display. Virtual Display allows any resolution and side screens.") {
                    Picker("", selection: m.setup) {
                        Text("Glasses Screen").tag("glasses")
                        Text("Glasses Ultrawide 32:9").tag("ultrawide")
                        Text("Virtual Display").tag("virtual")
                        Text("Mirroring").tag("mirror")
                    }
                    .labelsHidden().fixedSize()
                }
                Row(title: "Resolution", detail: "Virtual Display only; picking one switches to it. Crisp Retina gives the cleanest text.") {
                    Picker("", selection: m.resolution) {
                        ForEach(VirtualMonitor.Resolution.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden().frame(maxWidth: 260)
                }
                Row(title: "Side screens", detail: "Extra displays left and right of the pinned one (Virtual Display).") {
                    Picker("", selection: m.choice("sideScreens")) {
                        Text("Off").tag("off"); Text("Left").tag("left"); Text("Right").tag("right"); Text("Both").tag("both")
                    }
                    .labelsHidden().fixedSize()
                }
                ToggleRow(title: "Glasses at 120 Hz", detail: "Smoother motion. Ultrawide always runs at 60 Hz.", isOn: m.refresh)
            }
            Section("Screen") {
                Row(title: "Zoom", detail: "⌃⌥I / ⌃⌥O. Around 120% in Glasses Screen, text is pixel-exact.") {
                    HStack {
                        Slider(value: m.zoom, in: 0.6...2.4).frame(width: 200)
                        Text("\(Int((m.app.settings.zoom * 100).rounded()))%").monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                }
                Row(title: "Height", detail: "Raise or lower the screen. ⌃⌥↑ / ⌃⌥↓") {
                    HStack {
                        Slider(value: m.value(\.screenPitch), in: -30...30).frame(width: 200)
                        Text("\(Int(m.app.settings.screenPitch.rounded()))°").monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                }
                Row(title: "Field of view", detail: "If the screen slides when you turn, adjust this. ⌃⌥L / ⌃⌥K") {
                    Stepper("\(Int(m.app.settings.fovDiagonal))°", value: m.value(\.fovDiagonal), in: 25...70, step: 1).fixedSize()
                }
                ToggleRow(title: "Curve ultrawide screens", detail: "21:9 and wider wrap around you, so the edges stay sharp.", isOn: m.flag("curved"))
            }
            Section("Eye comfort") {
                Row(title: "Warmth", detail: "Less blue light, for the evening.") {
                    Picker("", selection: m.choice("warmth")) {
                        Text("Off").tag("0"); Text("Low").tag("0.3"); Text("Medium").tag("0.6"); Text("High").tag("1")
                    }
                    .labelsHidden().fixedSize()
                }
                Row(title: "Brightness") {
                    Picker("", selection: m.choice("brightness")) {
                        ForEach(["1", "0.85", "0.7", "0.5", "0.35"], id: \.self) { Text("\(Int((Double($0) ?? 1) * 100))%").tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
            }
        }
    }

    private var text: some View {
        Form {
            Section {
                Row(title: "Sharpness", detail: "Restores edge contrast lost when the desktop is resized.") {
                    Picker("", selection: m.value(\.sharpness)) {
                        Text("Off").tag(0.0); Text("Low").tag(0.3); Text("Medium").tag(0.5); Text("High").tag(0.8)
                    }
                    .labelsHidden().fixedSize()
                }
                Row(title: "Sharpening style", detail: "Unsharp Mask scored best in the render lab.") {
                    Picker("", selection: m.choice("sharpenStyle2")) {
                        ForEach(SharpenStyle.allCases, id: \.self) { Text($0.title).tag($0.rawValue) }
                    }
                    .labelsHidden().fixedSize()
                }
                ToggleRow(title: "Resize text like macOS", detail: "Removes the glow around light text and the thinning of dark text.", isOn: m.flag("gammaResample"))
                ToggleRow(title: "Sharper sampling", detail: "Bicubic instead of bilinear: crisp strokes even while the screen moves.", isOn: m.flag("smartFilter"))
                ToggleRow(title: "Sharpen only when still", detail: "No crawling text while you turn your head.", isOn: m.flag("motionSharpen"))
                ToggleRow(title: "Pixel lock when still", detail: "Near 100% scale, the screen settles onto exact pixels, like a real monitor.", isOn: m.flag("pixelLock"))
            } header: {
                Text("Text clarity")
            } footer: {
                Text("The defaults are the best of 108 combinations scored against native text by the render lab.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private var tracking: some View {
        Form {
            Section("Source") {
                Row(title: "Head tracking", detail: "The AirPods' heading cancels the glasses' slow sideways drift.") {
                    Picker("", selection: m.tracking) {
                        ForEach(TrackingMode.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
                Row(title: "AirPods", detail: "Learns how your AirPods sit in your ears. Turn and nod for a few seconds.") {
                    Button("Recalibrate", action: m.run { m.app.recalibrateAirPods() })
                }
                Row(title: "Gyro", detail: "Put the glasses on a table for 3 s. Fixes most drift.") {
                    Button("Calibrate…", action: m.run { m.app.calibrate() })
                }
                ToggleRow(title: "Steady image", detail: "Ignores heartbeat and micro-movements under 0.1°.", isOn: m.value(\.steady))
            }
            if m.app.settings.tracking != .glasses {
                Section("AirPods calibration") {
                    TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                        let st = m.app.renderer?.airPodsStatus ?? Renderer.AirPodsStatus()
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Circle().fill(st.active ? .green : st.receiving ? .orange : .red).frame(width: 8, height: 8)
                                Text(st.active ? "Correcting drift" : st.ready ? "Calibrated" : st.receiving ? "Calibrating — \(st.hint)" : "No data — put the AirPods on")
                                    .font(.headline)
                            }
                            ProgressView(value: st.progress) { Text("Overall") }
                            HStack(spacing: 16) {
                                ProgressView(value: st.turned) { Text("Turn left and right").font(.caption) }
                                ProgressView(value: st.nodded) { Text("Nod up and down").font(.caption) }
                            }
                            Text(String(format: "Bluetooth delay %.0f ms · fit error %.0f%% · glitches skipped %d", st.lag * 1000, st.fitError * 100, st.glitches))
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            Section("Follow your head on these axes") {
                ToggleRow(title: "Yaw — left/right", detail: "⌃⌥Y", isOn: m.value(\.lockYaw) { _ in m.app.renderer?.recenter() })
                ToggleRow(title: "Pitch — up/down", detail: "⌃⌥P", isOn: m.value(\.lockPitch) { _ in m.app.renderer?.recenter() })
                ToggleRow(title: "Roll — tilt", detail: "⌃⌥E", isOn: m.value(\.lockRoll))
            }
        }
    }

    private var anchoring: some View {
        Form {
            Section("Following") {
                ToggleRow(title: "Smooth follow", detail: "The screen stays put until you look past the dead zone, then glides back in front of you. ⌃⌥F", isOn: m.flag("follow"))
                Row(title: "Dead zone") {
                    Picker("", selection: m.choice("followDeadzone")) {
                        ForEach(["10", "20", "30", "45"], id: \.self) { Text("\($0)°").tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
                ToggleRow(title: "Recenter after looking away", detail: "Look elsewhere for 10 s and hold still: the screen moves there.", isOn: m.flag("lookAwayRecenter"))
            }
            Section("Recentering") {
                ToggleRow(title: "Double-tap the glasses to recenter", isOn: m.flag("doubleTap"))
                ToggleRow(title: "Auto drift correction", detail: "Slowly turns the screen toward where you look on average.", isOn: m.value(\.autoRecenter))
            }
            Section("Comfort") {
                Row(title: "Neck saver", detail: "Turn less, see more: 1.5× means turning 30° shows 45°.") {
                    Picker("", selection: m.choice("yawGain")) {
                        Text("Off").tag("1"); Text("1.25×").tag("1.25"); Text("1.5×").tag("1.5"); Text("2×").tag("2")
                    }
                    .labelsHidden().fixedSize()
                }
            }
        }
    }

    private var accuracy: some View {
        Form {
            Section("Sensor fusion") {
                Row(title: "Filter", detail: "Kalman learns gyro bias while you move. Try it and compare drift.") {
                    Picker("", selection: m.choice("fusion")) {
                        Text("Complementary").tag(Fusion.Mode.complementary.rawValue)
                        Text("Kalman").tag(Fusion.Mode.kalman.rawValue)
                    }
                    .labelsHidden().fixedSize()
                }
                ToggleRow(title: "Ignore gravity while accelerating", detail: "Keeps the horizon level when walking or nodding fast.", isOn: m.flag("strictAccel"))
                ToggleRow(title: "Temperature compensation", detail: "Learns how the gyro drifts as the glasses warm up.", isOn: m.flag("temperatureComp"))
                ToggleRow(title: "Learn gyro bias from the AirPods", detail: "Uses the AirPods' calibrated gyro as a reference while you move.", isOn: m.flag("airPodsBias"))
                ToggleRow(title: "Learn gyro sensitivity from the AirPods", detail: "Fixes swimming when turning. Slow and capped.", isOn: m.flag("airPodsScale"))
            }
            Section("Calibration") {
                Row(title: "Turn sensitivity", detail: "Face something, start, turn around once, face it again, finish. ⌃⌥G") {
                    Button(m.app.yawScaleStart == nil ? "Start…" : "Finish", action: m.run { m.app.calibrateYawScale() })
                }
                Row(title: "Reset learned corrections") {
                    HStack {
                        Button("Sensitivity", action: m.run { m.app.resetScale() })
                        Button("Temperature", action: m.run { m.app.resetTemperature() })
                    }
                }
            }
            Section("Experimental") {
                ToggleRow(title: "Mac camera as drift reference", detail: "Sees which way your face points. Never drifts while you face the Mac.", isOn: m.flag("cameraDrift"))
                ToggleRow(title: "Typing hint", detail: "While typing, the screen very slowly turns so the caret is where your head points.", isOn: m.flag("typingDrift"))
                Row(title: "Probe glasses calibration", detail: "Read-only query; the reply shows in developer mode.") {
                    Button("Probe", action: m.run { m.app.probeCalibration() })
                }
            }
        }
    }

    private var performance: some View {
        Form {
            Section("Motion") {
                Row(title: "Smoothing", detail: "1€ adapts to speed: steady when still, no lag when turning.") {
                    Picker("", selection: m.choice("smoothing")) {
                        Text("1€ Filter").tag(SmoothingMode.oneEuro.rawValue); Text("Classic").tag(SmoothingMode.classic.rawValue)
                    }
                    .labelsHidden().fixedSize()
                }
                ToggleRow(title: "Predict from the filtered pose", detail: "Less jitter than extrapolating raw gyro noise.", isOn: m.flag("predictFiltered"))
                Row(title: "Frame pacing", detail: "Metal Display Link predicts to when the frame really reaches the panel.") {
                    Picker("", selection: m.choice("pacing")) {
                        Text("Metal Display Link").tag(FramePacing.metalLink.rawValue); Text("Classic").tag(FramePacing.classic.rawValue)
                    }
                    .labelsHidden().fixedSize()
                }
                Row(title: "Prediction trim", detail: "Screen lags when you turn: add. Overshoots when you stop: subtract.") {
                    Picker("", selection: m.choice("predictionTrim")) {
                        ForEach(["-8", "-4", "0", "4", "8", "12"], id: \.self) { Text($0 == "0" ? "0 ms" : "\($0.hasPrefix("-") ? "" : "+")\($0) ms").tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
            }
            Section("CPU and GPU") {
                ToggleRow(title: "Skip frames when nothing changes", detail: "Saves power while you and the screen are still.", isOn: m.flag("skipIdle"))
                ToggleRow(title: "Metal performance HUD", detail: "Apple's frame rate and GPU time overlay, in the glasses.", isOn: m.flag("metalHUD"))
            }
        }
    }

    private var shortcuts: some View {
        Form {
            Section {
                ForEach(SettingsView.hotkeys, id: \.0) { key, action in
                    Row(title: action) { KeyCap(text: key) }
                }
            } header: {
                Text("Global shortcuts")
            } footer: {
                Text("They work from any app. You can also double-tap the glasses to recenter.").font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    static let hotkeys: [(String, String)] = [
        ("⌃⌥R", "Recenter"), ("⌃⌥T", "Pause tracking"), ("⌃⌥1", "Desk preset"), ("⌃⌥2", "Sofa preset"),
        ("⌃⌥3", "Lying-down preset"), ("⌃⌥F", "Smooth follow on/off"), ("⌃⌥I", "Zoom in"), ("⌃⌥O", "Zoom out"),
        ("⌃⌥0", "Actual size"), ("⌃⌥↑", "Raise the screen"), ("⌃⌥↓", "Lower the screen"),
        ("⌃⌥Y", "Lock yaw (follow left/right)"), ("⌃⌥P", "Lock pitch (follow up/down)"), ("⌃⌥E", "Lock roll (follow tilt)"),
        ("⌃⌥L", "Field of view +1°"), ("⌃⌥K", "Field of view −1°"), ("⌃⌥G", "Turn-sensitivity calibration"),
        ("⌃⌥D", "Developer mode"), ("⌃⌥Q", "Quit"),
    ]

    private var about: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("RayNeoPin").font(.title2.bold())
                    Text("Head-tracked screen pinning for RayNeo glasses on macOS.").foregroundStyle(.secondary)
                    Text("Version \(SettingsView.revision)").font(.callout.monospaced()).foregroundStyle(.secondary)
                }
                .padding(.vertical, 6)
            }
            Section {
                Row(title: "Updates", detail: "Rebuilds from the latest source on your branch.") {
                    Button("Check for Updates…", action: m.run { m.app.update() })
                }
                Row(title: "Source code") {
                    Link("GitHub", destination: URL(string: "https://github.com/Fuut4/rayneo-pin")!)
                }
                Row(title: "Support", detail: "Help pay Claude's bill.") {
                    Link("☕ Buy Me a Coffee", destination: AppDelegate.coffeeURL)
                }
            }
        }
    }

    static let revision: String = Bundle.main.url(forResource: "revision", withExtension: nil)
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) }?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? "dev"
}

/// `RayNeoPin --settings-snapshot <folder>`: renders every Settings page to a PNG (used by CI, so the
/// layout can be checked without a Mac at hand).
enum SettingsSnapshot {
    static func run(_ folder: URL) {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.appearance = NSAppearance(named: .darkAqua)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let delegate = AppDelegate()
        for page in SettingsPage.allCases {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 640),
                             styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            w.titlebarAppearsTransparent = true
            w.contentViewController = NSHostingController(rootView: SettingsView(model: SettingsModel(delegate), page: page))
            w.setContentSize(NSSize(width: 820, height: 640))
            w.orderFront(nil)
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 1))
            guard let view = w.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent("settings-\(page.rawValue).png"))
            w.orderOut(nil)
        }
        exit(0)
    }
}
