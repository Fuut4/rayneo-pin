// The Settings window: every option, grouped in tabs, so the menu bar menu only keeps everyday
// actions. Each control goes through the same AppDelegate code as the menus and hotkeys.

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

struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        TabView {
            general.tabItem { Label("General", systemImage: "gearshape") }
            text.tabItem { Label("Text & Screen", systemImage: "textformat.size") }
            tracking.tabItem { Label("Tracking", systemImage: "move.3d") }
            accuracy.tabItem { Label("Accuracy", systemImage: "scope") }
            performance.tabItem { Label("Performance", systemImage: "speedometer") }
        }
        .frame(width: 600, height: 560)
    }

    private var m: SettingsModel { model }

    // MARK: Tabs

    private var general: some View {
        Form {
            Section {
                Picker("Setup", selection: m.setup) {
                    Text("Glasses Screen — one display").tag("glasses")
                    Text("Glasses Screen Ultrawide 32:9 — 3D mode, 60 Hz").tag("ultrawide")
                    Text("Virtual Display — any resolution, 120 Hz").tag("virtual")
                    Text("Mirroring (pick it in the menu bar › Source)").tag("mirror")
                }
                Picker("Resolution", selection: m.resolution) {
                    ForEach(VirtualMonitor.Resolution.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                Toggle("Glasses at 120 Hz", isOn: m.refresh)
            } header: {
                Text("Display")
            } footer: {
                Text("Resolutions apply to the Virtual Display; picking one switches to it. Crisp Retina gives the cleanest text.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("App") {
                Toggle("Open at Login", isOn: m.login)
                Toggle("Developer Mode (live data in the glasses)  ⌃⌥D", isOn: m.developer)
                Toggle("Also show developer data on the Mac", isOn: m.developerOnMac)
            }
        }
        .formStyle(.grouped)
    }

    private var text: some View {
        Form {
            Section {
                Picker("Sharpness", selection: m.value(\.sharpness)) {
                    Text("Off").tag(0.0); Text("Low").tag(0.3); Text("Medium").tag(0.5); Text("High").tag(0.8)
                }
                Picker("Sharpening style", selection: m.choice("sharpenStyle2")) {
                    ForEach(SharpenStyle.allCases, id: \.self) { Text($0.title).tag($0.rawValue) }
                }
                Toggle("Resize text like macOS (no glow or halo)", isOn: m.flag("gammaResample"))
                Toggle("Sharper sampling (bicubic)", isOn: m.flag("smartFilter"))
                Toggle("Sharpen only when still (no crawling text while turning)", isOn: m.flag("motionSharpen"))
                Toggle("Pixel lock when still (exact pixels near 100% zoom)", isOn: m.flag("pixelLock"))
            } header: {
                Text("Text clarity")
            } footer: {
                Text("Defaults are the best scores from the render lab (see TESTING.md).").font(.caption).foregroundStyle(.secondary)
            }
            Section("Screen") {
                LabeledContent("Zoom") {
                    HStack {
                        Slider(value: m.zoom, in: 0.6...2.4)
                        Text("\(Int((m.app.settings.zoom * 100).rounded()))%").monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                }
                LabeledContent("Height") {
                    HStack {
                        Slider(value: m.value(\.screenPitch), in: -30...30, step: 1)
                        Text("\(Int(m.app.settings.screenPitch))°").monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                }
                Stepper("Field of view: \(Int(m.app.settings.fovDiagonal))° (if the screen swims when turning)",
                        value: m.value(\.fovDiagonal), in: 25...70, step: 1)
                Toggle("Curve ultrawide screens", isOn: m.flag("curved"))
                Picker("Side screens (Virtual Display)", selection: m.choice("sideScreens")) {
                    Text("Off").tag("off"); Text("Left").tag("left"); Text("Right").tag("right"); Text("Both").tag("both")
                }
            }
            Section("Eye comfort") {
                Picker("Warmth", selection: m.choice("warmth")) {
                    Text("Off").tag("0"); Text("Low").tag("0.3"); Text("Medium").tag("0.6"); Text("High").tag("1")
                }
                Picker("Brightness", selection: m.choice("brightness")) {
                    ForEach(["1", "0.85", "0.7", "0.5", "0.35"], id: \.self) { Text("\(Int((Double($0) ?? 1) * 100))%").tag($0) }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var tracking: some View {
        Form {
            Section("Head tracking") {
                Picker("Source", selection: m.tracking) {
                    ForEach(TrackingMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                HStack {
                    Button("Recalibrate AirPods", action: m.run { m.app.recalibrateAirPods() })
                    Button("Calibrate Gyro (glasses on a table)…", action: m.run { m.app.calibrate() })
                }
                Toggle("Steady image (ignore heartbeat and micro-movements)", isOn: m.value(\.steady))
            }
            Section("Presets") {
                HStack {
                    Button("Desk  ⌃⌥1", action: m.run { m.app.applyPreset("desk") })
                    Button("Sofa  ⌃⌥2", action: m.run { m.app.applyPreset("sofa") })
                    Button("Lying Down  ⌃⌥3", action: m.run { m.app.applyPreset("lying") })
                }
            }
            Section("Follow your head on these axes") {
                Toggle("Yaw (left/right)  ⌃⌥Y", isOn: m.value(\.lockYaw) { _ in m.app.renderer?.recenter() })
                Toggle("Pitch (up/down)  ⌃⌥P", isOn: m.value(\.lockPitch) { _ in m.app.renderer?.recenter() })
                Toggle("Roll (tilt)  ⌃⌥E", isOn: m.value(\.lockRoll))
            }
            Section("Anchoring") {
                Toggle("Smooth Follow: the screen glides back in front of you  ⌃⌥F", isOn: m.flag("follow"))
                Picker("Follow dead zone", selection: m.choice("followDeadzone")) {
                    ForEach(["10", "20", "30", "45"], id: \.self) { Text("\($0)°").tag($0) }
                }
                Toggle("Recenter after looking away for a while", isOn: m.flag("lookAwayRecenter"))
                Toggle("Double-tap the glasses to recenter", isOn: m.flag("doubleTap"))
                Toggle("Auto drift correction (follows your average gaze)", isOn: m.value(\.autoRecenter))
                Picker("Neck saver (turn less, see more)", selection: m.choice("yawGain")) {
                    Text("Off").tag("1"); Text("1.25×").tag("1.25"); Text("1.5×").tag("1.5"); Text("2×").tag("2")
                }
            }
        }
        .formStyle(.grouped)
    }

    private var accuracy: some View {
        Form {
            Section("Sensor fusion") {
                Picker("Filter", selection: m.choice("fusion")) {
                    Text("Complementary").tag(Fusion.Mode.complementary.rawValue)
                    Text("Kalman with bias state (experimental)").tag(Fusion.Mode.kalman.rawValue)
                }
                Toggle("Ignore gravity while accelerating", isOn: m.flag("strictAccel"))
                Toggle("Temperature compensation (learns bias vs. °C)", isOn: m.flag("temperatureComp"))
                Toggle("Learn the glasses' gyro bias from the AirPods", isOn: m.flag("airPodsBias"))
                Toggle("Learn the glasses' gyro sensitivity from the AirPods", isOn: m.flag("airPodsScale"))
            }
            Section("Calibration") {
                Button(m.app.yawScaleStart == nil ? "Calibrate turn sensitivity (turn a full circle)…  ⌃⌥G"
                       : "Finish turn calibration (facing the start again)  ⌃⌥G", action: m.run { m.app.calibrateYawScale() })
                HStack {
                    Button("Reset gyro sensitivity", action: m.run { m.app.resetScale() })
                    Button("Forget temperature model", action: m.run { m.app.resetTemperature() })
                }
            }
            Section("Experimental drift references") {
                Toggle("Mac camera (sees which way your face points)", isOn: m.flag("cameraDrift"))
                Toggle("Typing hint (you look at the caret while typing)", isOn: m.flag("typingDrift"))
                Button("Probe glasses calibration (read-only, shows in Developer Mode)", action: m.run { m.app.probeCalibration() })
            }
        }
        .formStyle(.grouped)
    }

    private var performance: some View {
        Form {
            Section("Motion") {
                Picker("Smoothing", selection: m.choice("smoothing")) {
                    ForEach(SmoothingMode.allCases, id: \.self) { Text($0.title).tag($0.rawValue) }
                }
                Toggle("Predict from the filtered pose (less jitter)", isOn: m.flag("predictFiltered"))
                Picker("Frame pacing", selection: m.choice("pacing")) {
                    ForEach(FramePacing.allCases, id: \.self) { Text($0.title).tag($0.rawValue) }
                }
                Picker("Prediction trim", selection: m.choice("predictionTrim")) {
                    ForEach(["-8", "-4", "0", "4", "8", "12"], id: \.self) { Text($0 == "0" ? "0 ms (default)" : "\($0.hasPrefix("-") ? "" : "+")\($0) ms").tag($0) }
                }
            }
            Section("CPU and GPU") {
                Toggle("Skip frames when nothing changes", isOn: m.flag("skipIdle"))
                Toggle("Metal performance HUD in the glasses", isOn: m.flag("metalHUD"))
            }
        }
        .formStyle(.grouped)
    }
}
