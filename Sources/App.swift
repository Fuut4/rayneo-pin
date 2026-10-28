// RayNeoPin — 3DoF spatially pinned screen for RayNeo Air 4 Pro on macOS.
//
// Default setup: a virtual monitor ("RayNeoPin Display") is created and shown in the glasses as
// a screen fixed in space. The glasses' own display is fenced off, so you work with two screens:
// the Mac's and the pinned one.

import AppKit
import Carbon.HIToolbox
import ScreenCaptureKit
import ServiceManagement
import SwiftUI
import simd

// MARK: - Settings

final class Settings {
    private let d = UserDefaults.standard

    private func bool(_ key: String, _ fallback: Bool) -> Bool { d.object(forKey: key) as? Bool ?? fallback }
    private func double(_ key: String, _ fallback: Double) -> Double { d.object(forKey: key) as? Double ?? fallback }

    var zoom: Double { get { double("zoom", 1) } set { d.set(newValue, forKey: "zoom") } }
    /// Diagonal field of view of the glasses. Wrong values make the screen "swim" when turning.
    /// 43° is what XRLinuxDriver uses for RayNeo glasses.
    var fovDiagonal: Double { get { double("fov", 43) } set { d.set(newValue, forKey: "fov") } }
    // Old "yaw only" mode meant pitch and roll locked.
    var lockYaw: Bool { get { bool("lockYaw", false) } set { d.set(newValue, forKey: "lockYaw") } }
    var lockPitch: Bool { get { bool("lockPitch", d.bool(forKey: "yawOnly")) } set { d.set(newValue, forKey: "lockPitch") } }
    var lockRoll: Bool { get { bool("lockRoll", d.bool(forKey: "yawOnly")) } set { d.set(newValue, forKey: "lockRoll") } }
    var autoRecenter: Bool { get { bool("autoDriftCorrection", false) } set { d.set(newValue, forKey: "autoDriftCorrection") } }
    var steady: Bool { get { bool("steady", true) } set { d.set(newValue, forKey: "steady") } }
    var tracking: TrackingMode {
        get { TrackingMode(rawValue: d.string(forKey: "tracking") ?? "") ?? (bool("useAirPods", true) ? .both : .glasses) }
        set { d.set(newValue.rawValue, forKey: "tracking") }
    }
    var sharpness: Double { get { double("sharpness", 0.5) } set { d.set(newValue, forKey: "sharpness") } }
    var highRefresh: Bool { get { bool("highRefresh", true) } set { d.set(newValue, forKey: "highRefresh") } }
    var developer: Bool { get { bool("developer", false) } set { d.set(newValue, forKey: "developer") } }
    /// Developer data also in a window on the Mac (off: only in the glasses).
    var developerOnMac: Bool { get { bool("developerOnMac", false) } set { d.set(newValue, forKey: "developerOnMac") } }
    var resolution: VirtualMonitor.Resolution {
        get { VirtualMonitor.Resolution.allCases.first { "\($0)" == d.string(forKey: "resolutionMode") } ?? .crisp }
        set { d.set("\(newValue)", forKey: "resolutionMode") }
    }
    /// "glasses" (the glasses' own desktop, one display), "ultrawide" (same, in 3D mode: 3840×1080),
    /// "virtual" (an extra virtual monitor), or "display"/"window" to mirror something that exists.
    var sourceKind: String { get { d.string(forKey: "setup") ?? "glasses" } set { d.set(newValue, forKey: "setup") } }
    var singleDisplay: Bool { sourceKind == "glasses" || sourceKind == "ultrawide" }
    /// AirPods calibration per Bluetooth address.
    func airPodsCalibration(for address: String) -> AirPodsCalibration.Saved? {
        (d.data(forKey: "airpods." + address)).flatMap { try? JSONDecoder().decode(AirPodsCalibration.Saved.self, from: $0) }
    }

    func setAirPodsCalibration(_ c: AirPodsCalibration.Saved, for address: String) {
        d.set(try? JSONEncoder().encode(c), forKey: "airpods." + address)
    }

    /// On/off options added on the test branch, with their defaults.
    static let flagDefaults: [String: Bool] = [
        "motionSharpen": true, "smartFilter": true, "pixelLock": true, "curved": true,
        "follow": false, "lookAwayRecenter": false, "doubleTap": true,
        "strictAccel": true, "temperatureComp": true, "airPodsBias": true, "airPodsScale": false,
        "cameraDrift": false, "typingDrift": false,
        "predictFiltered": true, "skipIdle": true, "metalHUD": false, "gammaResample": true, "telemetry": true,
    ]

    func flag(_ key: String) -> Bool { bool(key, Settings.flagDefaults[key] ?? false) }
    func setFlag(_ key: String, _ value: Bool) { d.set(value, forKey: key) }

    /// Multiple-choice options, stored as strings.
    static let choiceDefaults: [String: String] = [
        "sharpenStyle2": SharpenStyle.unsharp.rawValue, // best in the render lab (new key: resets earlier picks) "smoothing": SmoothingMode.oneEuro.rawValue,
        "pacing": FramePacing.metalLink.rawValue, "fusion": Fusion.Mode.complementary.rawValue,
        "warmth": "0", "brightness": "1", "yawGain": "1", "followDeadzone": "20", "predictionTrim": "0",
        "sideScreens": "off",
    ]

    func choice(_ key: String) -> String { d.string(forKey: key) ?? Settings.choiceDefaults[key] ?? "" }
    func setChoice(_ key: String, _ value: String) { d.set(value, forKey: key) }
    private func number(_ key: String) -> Double { Double(choice(key)) ?? Double(Settings.choiceDefaults[key] ?? "") ?? 0 }

    /// Screen height: degrees above (+) or below (−) eye level.
    var screenPitch: Double { get { double("screenPitch", 0) } set { d.set(newValue, forKey: "screenPitch") } }

    var gyroScale: SIMD3<Double> {
        get { (d.array(forKey: "gyroScale") as? [Double]).flatMap { $0.count == 3 ? SIMD3($0[0], $0[1], $0[2]) : nil } ?? SIMD3(repeating: 1) }
        set { d.set([newValue.x, newValue.y, newValue.z], forKey: "gyroScale") }
    }

    var temperatureModel: TemperatureModel? {
        get { d.data(forKey: "temperatureModel").flatMap { try? JSONDecoder().decode(TemperatureModel.self, from: $0) } }
        set { d.set(newValue.flatMap { try? JSONEncoder().encode($0) }, forKey: "temperatureModel") }
    }

    var fusionMode: Fusion.Mode { Fusion.Mode(rawValue: choice("fusion")) ?? .complementary }
    var pacing: FramePacing { FramePacing(rawValue: choice("pacing")) ?? .metalLink }
    var sideScreens: String { choice("sideScreens") }

    var gyroBias: SIMD3<Double>? {
        get { (d.array(forKey: "gyroBias") as? [Double]).flatMap { $0.count == 3 ? SIMD3($0[0], $0[1], $0[2]) : nil } }
        set { d.set(newValue.map { [$0.x, $0.y, $0.z] }, forKey: "gyroBias") }
    }

    func apply(to p: inout Renderer.Params) {
        p.zoom = zoom
        p.fovDiagonal = fovDiagonal
        p.lockYaw = lockYaw
        p.lockPitch = lockPitch
        p.lockRoll = lockRoll
        p.autoRecenter = autoRecenter
        p.steady = steady
        p.tracking = tracking
        p.developer = developer
        p.sharpness = sharpness
        p.sharpenStyle = SharpenStyle(rawValue: choice("sharpenStyle2")) ?? .unsharp
        p.motionSharpen = flag("motionSharpen")
        p.smartFilter = flag("smartFilter")
        p.pixelLock = flag("pixelLock")
        p.curved = flag("curved")
        p.warmth = number("warmth")
        p.brightness = number("brightness")
        p.follow = flag("follow")
        p.followDeadzone = number("followDeadzone") * .pi / 180
        p.lookAwayRecenter = flag("lookAwayRecenter")
        p.screenPitch = screenPitch * .pi / 180
        p.yawGain = number("yawGain")
        p.smoothing = SmoothingMode(rawValue: choice("smoothing")) ?? .oneEuro
        p.predictFiltered = flag("predictFiltered")
        p.predictionTrim = number("predictionTrim") / 1000
        p.skipIdle = flag("skipIdle")
        p.airPodsBias = flag("airPodsBias")
        p.airPodsScale = flag("airPodsScale")
        p.cameraDrift = flag("cameraDrift")
        p.typingDrift = flag("typingDrift")
        p.metalHUD = flag("metalHUD")
        p.telemetry = flag("telemetry")
    }
}

// MARK: - Global hotkeys (Carbon; no Accessibility permission needed)

var hotKeyActions: [UInt32: () -> Void] = [:]
var hotKeyRefs: [EventHotKeyRef?] = []

func installHotKeys(_ keys: [(Int, () -> Void)]) {
    var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
        var id = EventHotKeyID()
        GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                          nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
        hotKeyActions[id.id]?()
        return noErr
    }, 1, &spec, nil, nil)
    for (i, (code, action)) in keys.enumerated() {
        let id = UInt32(i + 1)
        hotKeyActions[id] = action
        var ref: EventHotKeyRef?
        RegisterEventHotKey(UInt32(code), UInt32(controlKey | optionKey),
                            EventHotKeyID(signature: OSType(0x524E_5049), id: id), GetApplicationEventTarget(), 0, &ref)
        hotKeyRefs.append(ref)
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static let coffeeURL = URL(string: "https://buymeacoffee.com/fuut4")!

    let settings = Settings()
    lazy var imu = IMU(savedBias: settings.gyroBias)
    let capture = Capture()
    let headphones = Headphones()
    let fence = CursorFence()
    var renderer: Renderer?
    var monitor: VirtualMonitor?
    var source: Source?
    var statusItem: NSStatusItem!
    let sourceMenu = NSMenu()
    let trackingMenu = NSMenu()
    let airPodsMenu = NSMenu()
    var pairedHeadphones: [HeadphoneDevice] = []
    var toggles: [(NSMenuItem, () -> Bool)] = []
    var retryTimer: Timer?
    var openedSettings = false
    var resolutionWork: DispatchWorkItem?
    var developerPanel: NSPanel?
    var developerLabel: NSTextField?
    // Test branch
    /// Side screens beside the pinned one (Virtual Display setup), by side (−1 left, +1 right).
    var sideMonitors: [Int: VirtualMonitor] = [:]
    var sideCaptures: [Int: Capture] = [:]
    var face: FaceTracker?
    let caretQueue = DispatchQueue(label: "caret", qos: .utility)
    var caretBusy = false
    var lastCaret: CGRect?
    var lastCaretMove = 0.0
    var wasAsleep = false
    var yawScaleStart: Double?
    var cursorSeed: Int?
    var cursorShape: Int?
    var cursorLook: (image: NSImage, hotSpot: NSPoint)?

    /// SIGTERM (installer, `pkill`) skips applicationWillTerminate, which restores the hidden
    /// cursor and puts the glasses back in 2D; route it through a normal quit instead.
    private var termSource: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ note: Notification) {
        signal(SIGTERM, SIG_IGN)
        termSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        termSource?.setEventHandler { AppDelegate.quit() }
        termSource?.resume()

        imu.scale = settings.gyroScale
        if let model = settings.temperatureModel { imu.temperatureModel = model }
        imu.onDoubleTap = { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.settings.flag("doubleTap"), self.calibrationTimer == nil else { return }
                NSSound(named: "Pop")?.play()
                Telemetry.shared.event("double tap", time: CACurrentMediaTime())
                self.renderer?.recenter()
                self.renderer?.show("Recentered (double tap)", seconds: 1)
            }
        }
        imu.onConnect = { [weak self] in
            DispatchQueue.main.async {
                self?.applyPanelMode()
                if self?.calibrationTimer != nil { self?.imu.send(.proximitySensor, value: 0) }
            }
        }
        imu.start()
        if settings.tracking != .glasses { headphones.start() }
        buildMenu()
        installHotKeys([
            (kVK_ANSI_R, { [weak self] in self?.recenter() }),
            (kVK_ANSI_T, { [weak self] in self?.togglePause() }),
            (kVK_ANSI_Y, { [weak self] in self?.toggleLockYaw() }),
            (kVK_ANSI_P, { [weak self] in self?.toggleLockPitch() }),
            (kVK_ANSI_E, { [weak self] in self?.toggleLockRoll() }),
            (kVK_ANSI_I, { [weak self] in self?.zoom(1.1) }),
            (kVK_ANSI_O, { [weak self] in self?.zoom(1 / 1.1) }),
            (kVK_ANSI_0, { [weak self] in self?.zoomReset() }),
            (kVK_ANSI_L, { [weak self] in self?.fov(1) }),
            (kVK_ANSI_K, { [weak self] in self?.fov(-1) }),
            (kVK_ANSI_D, { [weak self] in self?.toggleDeveloper() }),
            (kVK_ANSI_Q, { AppDelegate.quit() }),
            (kVK_ANSI_1, { [weak self] in self?.applyPreset("desk") }),
            (kVK_ANSI_2, { [weak self] in self?.applyPreset("sofa") }),
            (kVK_ANSI_3, { [weak self] in self?.applyPreset("lying") }),
            (kVK_UpArrow, { [weak self] in self?.height(2) }),
            (kVK_DownArrow, { [weak self] in self?.height(-2) }),
            (kVK_ANSI_F, { [weak self] in self?.flip("follow", "Smooth Follow") }),
            (kVK_ANSI_G, { [weak self] in self?.calibrateYawScale() }),
        ])
        // A fullscreen app on another Space can freeze the capture; re-applying its filter fixes it.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            for delay in [0.3, 1.2] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.refreshCaptures() }
            }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in self?.screensChanged() }
        capture.onError = { [weak self] msg in
            NSLog("%@", msg)
            if CGPreflightScreenCaptureAccess() { self?.renderer?.show(msg, seconds: 8) } else { self?.permissionMissing() }
        }
        capture.ownWindowIDs = {
            let ids = { NSApp.windows.map { CGWindowID($0.windowNumber) } }
            return Thread.isMainThread ? ids() : DispatchQueue.main.sync(execute: ids)
        }
        capture.onStarted = { [weak self] in
            self?.renderer?.setNotice(nil)
            self?.retryTimer?.invalidate()
            self?.retryTimer = nil
        }
        // Persist the gyro bias so the next launch starts calibrated.
        Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.saveBias() }
        // One display-rate timer for the cursor fence and our own cursor on the pinned screen.
        let cursorTimer = Timer(timeInterval: 1 / 120, repeats: true) { [weak self] _ in
            guard let self, self.renderer != nil else { return }
            self.fence.check()
            if !self.wasAsleep { self.updateCursor() }
        }
        RunLoop.main.add(cursorTimer, forMode: .common)
        // The caret, for the typing drift hint (10 Hz, off the main thread: AX calls can block).
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.pollCaret() }
        // Windows that end up on the fenced glasses display would be unreachable: move them out.
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.rescueWindows() }
        // Display reconfigurations can move our windows without telling us; check every second.
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, let glasses = Displays.glasses() else { return }
            self.renderer?.keepOn(glasses)
            // Glasses taken off: stop capturing until they're worn again.
            let asleep = self.imu.isAsleep
            if asleep != self.wasAsleep {
                self.wasAsleep = asleep
                let captures = [self.capture] + Array(self.sideCaptures.values)
                Task { for c in captures { if asleep { await c.pause() } else { await c.resume() } } }
            }
            if self.settings.developer { self.renderer?.setDeveloperDisplayInfo(self.developerDisplayInfo()) }
            if self.settings.developer, self.settings.developerOnMac, let panel = self.developerPanel, !NSScreen.screens.contains(where: {
                $0.frame.intersects(panel.frame) && Displays.id(of: $0) != Displays.id(of: glasses)
            }) { self.placeDeveloperPanel() }
        }

        if !CGPreflightScreenCaptureAccess() { CGRequestScreenCaptureAccess() }
        fence.start()
        applySetup()
        applyExtras()
        if settings.developer && settings.developerOnMac { showDeveloperPanel(true) }
    }

    func applicationWillTerminate(_ note: Notification) {
        saveBias()
        if Displays.glasses().map({ $0.frame.width >= 3840 }) == true { imu.send(.display2D) } // leave the glasses in 2D
        if calibrationTimer != nil { imu.send(.proximitySensor, value: 1) }
        imu.stop()
        headphones.stop()
        fence.stop()
    }

    func saveBias() {
        if imu.snapshot().state == .ready { settings.gyroBias = imu.bias }
        settings.gyroScale = imu.scale
        if !imu.temperatureModel.isEmpty { settings.temperatureModel = imu.temperatureModel }
        if let c = renderer?.airPodsCalibration, let address = HeadphoneCatalog.currentOutputAddress() {
            settings.setAirPodsCalibration(c, for: address)
        }
    }

    /// Reuse the last calibration of whichever AirPods are the sound output now.
    func seedAirPodsCalibration() {
        guard let address = HeadphoneCatalog.currentOutputAddress(), let c = settings.airPodsCalibration(for: address) else { return }
        renderer?.seedAirPods(c)
    }

    // MARK: Displays

    func createMonitor() {
        monitor = VirtualMonitor()
        guard let monitor else {
            renderer?.show("Could not create the virtual display", seconds: 6)
            return
        }
        source = .display(monitor.displayID)
        applyResolution()
        // WindowServer needs a moment before the new display can be positioned.
        // WindowServer needs a moment before the new display's modes and position can be set.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.applyResolution()
            Displays.arrange(above: monitor.displayID, right: Displays.glasses().map(Displays.id))
            self?.screensChanged()
            self?.applySideScreens()
        }
    }

    /// Extra virtual displays left/right of the pinned one, each drawn beside it in the glasses.
    func applySideScreens() {
        let wanted: Set<Int> = settings.sourceKind != "virtual" || monitor == nil ? [] : [
            "left": [-1], "right": [1], "both": [-1, 1],
        ][settings.sideScreens] ?? []
        for side in sideMonitors.keys where !wanted.contains(side) {
            sideMonitors[side] = nil // releasing it removes the display
            if let c = sideCaptures.removeValue(forKey: side) { Task { await c.stop() } }
        }
        for side in wanted where sideMonitors[side] == nil {
            guard let m = VirtualMonitor(name: side < 0 ? "RayNeoPin Left" : "RayNeoPin Right", index: side < 0 ? 1 : 2) else { continue }
            sideMonitors[side] = m
            let c = Capture()
            c.ownWindowIDs = capture.ownWindowIDs
            sideCaptures[side] = c
        }
        renderer?.setSideScreens(sideCaptures.map { ($0.value, $0.key) })
        guard !wanted.isEmpty, let main = monitor else { return }
        // Like the main one, new displays need a moment before they can be configured.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self else { return }
            for m in self.sideMonitors.values { m.setMode(width: 1920, height: 1080, hiDPI: false) }
            Displays.arrangeSides(of: main.displayID, left: self.sideMonitors[-1]?.displayID, right: self.sideMonitors[1]?.displayID)
            for (side, c) in self.sideCaptures {
                guard let m = self.sideMonitors[side] else { continue }
                Task { await c.start(.display(m.displayID)) }
            }
        }
    }

    func refreshCaptures() {
        let captures = [capture] + Array(sideCaptures.values)
        Task { for c in captures { await c.refreshFilter() } }
    }

    private var askedAccessibility = false

    /// In setups where the glasses' own display only shows our rendering (virtual display, mirror),
    /// any window macOS puts there is invisible and unreachable; move it to the screen you work on.
    func rescueWindows() {
        guard !settings.singleDisplay, let glasses = Displays.glasses() else { return }
        let target = monitor.map { CGDisplayBounds($0.displayID) } ?? CGDisplayBounds(CGMainDisplayID())
        let result = WindowRescue.move(from: CGDisplayBounds(Displays.id(of: glasses)), to: target,
                                       askPermission: !askedAccessibility)
        if result.needsPermission, !askedAccessibility {
            askedAccessibility = true
            renderer?.show("A window is stuck on the glasses' hidden display. Allow RayNeoPin in System Settings › Privacy & Security › Accessibility to move it out automatically.", seconds: 8)
        }
        if result.moved > 0 { renderer?.show("Moved \(result.moved) window\(result.moved == 1 ? "" : "s") off the glasses' hidden display", seconds: 3) }
    }

    /// WindowServer's cursor seed changes only when the cursor's shape changes. macOS hands out a
    /// new NSCursor object on every query, so without it the cursor texture was rebuilt each frame.
    static let currentCursorSeed: (@convention(c) () -> Int32)? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGSCurrentCursorSeed") else { return nil } // RTLD_DEFAULT
        return unsafeBitCast(sym, to: (@convention(c) () -> Int32).self)
    }()

    /// Where the system cursor is on a captured display, and what it looks like (arrow, I-beam…).
    func updateCursor() {
        guard let renderer else { return }
        var targets: [(Int, CGDirectDisplayID)] = []
        if case .display(let id)? = capture.source { targets.append((0, id)) }
        for (side, m) in sideMonitors { targets.append((side, m.displayID)) }
        let m = NSEvent.mouseLocation
        guard let (side, screen) = targets.lazy.compactMap({ t in Displays.screen(for: t.1).map { (t.0, $0) } })
            .first(where: { $0.1.frame.contains(m) }) else {
            renderer.setCursor(nil, shape: nil) { nil }
            return
        }
        let seed = AppDelegate.currentCursorSeed.map { Int($0()) }
        if seed == nil || seed != cursorSeed || cursorLook == nil {
            let cursor = NSCursor.currentSystem ?? .arrow
            cursorLook = (cursor.image, cursor.hotSpot)
            cursorSeed = seed
            cursorShape = seed ?? AppDelegate.fingerprint(cursor.image, cursor.hotSpot)
        }
        guard let look = cursorLook else { return }
        let f = screen.frame, hot = look.hotSpot, size = look.image.size
        renderer.setCursor(.init(x: (m.x - f.minX - hot.x) / f.width, y: (f.maxY - m.y - hot.y) / f.height,
                                 w: size.width / f.width, h: size.height / f.height, panel: side),
                           shape: cursorShape) { look.image }
    }

    /// Identifies a cursor image without the seed: hot spot, size and an 8×8 thumbnail.
    static func fingerprint(_ image: NSImage, _ hot: NSPoint) -> Int {
        var h = Hasher()
        h.combine(hot.x); h.combine(hot.y); h.combine(image.size.width); h.combine(image.size.height)
        if let ctx = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
                               space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
           let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 8, height: 8))
            if let data = ctx.data { h.combine(bytes: UnsafeRawBufferPointer(start: data, count: 256)) }
        }
        return h.finalize()
    }

    /// The caret's position on the pinned screen, and when it last moved (= you're typing).
    func pollCaret() {
        guard settings.flag("typingDrift"), let renderer, !caretBusy, case .display(let id)? = capture.source else { return }
        caretBusy = true
        caretQueue.async { [weak self] in
            let rect = Caret.rect()
            DispatchQueue.main.async {
                guard let self else { return }
                self.caretBusy = false
                guard let rect else { renderer.setCaret(nil); return }
                let now = CACurrentMediaTime()
                if rect != self.lastCaret { self.lastCaret = rect; self.lastCaretMove = now }
                let b = CGDisplayBounds(id)
                guard b.contains(CGPoint(x: rect.midX, y: rect.midY)) else { renderer.setCaret(nil); return }
                renderer.setCaret(CaretPoint(x: (rect.midX - b.minX) / b.width, y: (rect.midY - b.minY) / b.height,
                                             panel: 0, time: self.lastCaretMove))
            }
        }
    }

    /// Switches between the display setups (see Settings.sourceKind).
    func applySetup() {
        if settings.sourceKind == "virtual" {
            if monitor == nil { createMonitor() }
        } else if monitor != nil {
            monitor = nil // releasing it removes the virtual display
        }
        if settings.singleDisplay { source = nil }
        applyPanelMode()
        screensChanged()
        arrangedFor = nil
        if monitor != nil || !sideMonitors.isEmpty { applySideScreens() }
    }

    /// 3D (3840×1080 @60) for ultrawide, otherwise 2D at the chosen refresh rate.
    func applyPanelMode() {
        let wide = Displays.glasses().map { $0.frame.width >= 3840 } ?? false
        if settings.sourceKind == "ultrawide" {
            if !wide { imu.send(.display3D) }
        } else {
            if wide { imu.send(.display2D) }
            if settings.highRefresh { imu.send(.panel120Hz) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.applyRefreshRate() }
        }
    }

    private var arrangedFor: CGDirectDisplayID?
    /// In single-display setups the glasses' desktop is your second screen: put it above the Mac's.
    func arrangeGlassesAbove(_ gid: CGDirectDisplayID) {
        guard arrangedFor != gid else { return }
        arrangedFor = gid
        let main = CGDisplayBounds(CGMainDisplayID()), g = CGDisplayBounds(gid)
        if abs(g.maxY - main.minY) > 1 { Displays.arrange(above: gid, right: nil) }
    }

    /// Picks the virtual display mode; in crisp mode one desktop pixel maps to one glasses pixel.
    func applyResolution() {
        guard let monitor else { return }
        let glassesWidth = Double(Displays.glasses()?.frame.width ?? 1920)
        let covered = glassesWidth * Renderer.baseWidth * settings.zoom
        guard let mode = settings.resolution.mode(coveredPixels: covered) else { return } // manual: macOS decides
        monitor.setMode(width: mode.w, height: mode.h, hiDPI: mode.hiDPI)
    }

    /// Zooming in steps would otherwise switch resolution on every key press.
    func applyResolutionSoon() {
        resolutionWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.applyResolution() }
        resolutionWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: work)
    }

    func applyRefreshRate() {
        guard let g = Displays.glasses() else { return }
        Displays.setRefresh(settings.highRefresh ? 120 : 60, glasses: Displays.id(of: g))
    }

    /// Creates/moves the glasses window and (re)starts capture when what we show changed.
    func screensChanged() {
        let glasses = Displays.glasses()
        let gid = glasses.map(Displays.id)
        let single = settings.singleDisplay
        fence.blocked = single ? nil : gid
        fence.hideOn = single ? gid : nil
        if single, let gid {
            source = .display(gid) // the glasses' own desktop, under our rendering
            arrangeGlassesAbove(gid)
        }
        if let r = renderer, r.displayID != gid || r.window.frame.size != glasses?.frame.size {
            r.shutdown()
            renderer = nil
        }
        if let r = renderer, let glasses { r.keepOn(glasses) }
        if renderer == nil, let glasses, let gid {
            do {
                let r = try Renderer(screen: glasses, displayID: gid, imu: imu, capture: capture, headphones: headphones,
                                     pacing: settings.pacing, gammaSpace: settings.flag("gammaResample"))
                r.update { settings.apply(to: &$0) }
                r.setFaceTracker(face)
                r.setSideScreens(sideCaptures.map { ($0.value, $0.key) })
                r.onDeveloperText = { [weak self] text in self?.developerLabel?.stringValue = text }
                renderer = r
                seedAirPodsCalibration()
                // A new window only shows up in ScreenCaptureKit's list a moment later; restart the
                // capture then so it is excluded.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
                    if let source = self?.source { Task { await self?.capture.start(source) } }
                }
                r.show("RayNeoPin — ⌃⌥R recenter · ⌃⌥I / ⌃⌥O zoom · ⌃⌥Q quit", seconds: 5)
            } catch {
                NSLog("RayNeoPin: renderer failed: %@", error.localizedDescription)
            }
        }
        // Mirroring: never show the glasses inside the glasses.
        if !single, source == nil || source == .display(gid ?? 0) {
            source = Displays.builtin().map { .display($0) } ?? .display(CGMainDisplayID())
        }
        if let source, needsRestart(source) || source != capture.source { // size check first: it records the size
            Task { await capture.start(source) }
        }
    }

    private var capturedSize: CGSize?
    /// Restart when the captured display changed resolution (e.g. virtual display mode switch).
    private func needsRestart(_ source: Source) -> Bool {
        guard case .display(let id) = source, let mode = CGDisplayCopyDisplayMode(id) else { return false }
        let size = CGSize(width: mode.pixelWidth, height: mode.pixelHeight)
        defer { capturedSize = size }
        return capturedSize != size
    }

    // MARK: Permission

    /// Without Screen Recording permission the glasses would stay black; say so on them and keep checking.
    func permissionMissing() {
        renderer?.setNotice("Screen Recording permission needed: System Settings › Privacy & Security › Screen & System Audio Recording › turn on RayNeoPin")
        if !openedSettings {
            openedSettings = true
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        }
        // A running process never sees the grant, so ask a fresh copy of ourselves and relaunch when it says yes.
        if retryTimer == nil {
            retryTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                guard let self, AppDelegate.permissionGrantedInFreshProcess() else { return }
                self.retryTimer?.invalidate()
                self.relaunch()
            }
        }
    }

    static func permissionGrantedInFreshProcess() -> Bool {
        let p = Process()
        p.executableURL = Bundle.main.executableURL
        p.arguments = ["--check-permission"]
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    /// Starts the installed copy once this process has really exited (an `open` while we still
    /// run would just bring the old version back to the front).
    func relaunch() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "while kill -0 \"$1\" 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\"",
                       Bundle.main.bundlePath, String(getpid())]
        try? p.run()
        AppDelegate.quit()
    }

    /// Normal quit (restores the cursor, puts the glasses back in 2D), but never hangs: if cleanup
    /// takes more than 3 s, exit anyway.
    static func quit() {
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) { exit(0) }
        NSApp.terminate(nil)
    }

    // MARK: Menu

    func buildMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "eyeglasses", accessibilityDescription: "RayNeoPin")
        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(statusLine)
        menu.addItem(.separator())
        menu.addItem(item("Recenter", #selector(recenter), key: "r"))
        menu.addItem(toggle("Pause Tracking", #selector(togglePause), key: "t") { [weak self] in self?.renderer?.currentParams.paused == true })
        let presets = NSMenu()
        presets.addItem(toggle("Desk", #selector(presetDesk), key: "1") { [weak self] in self?.currentPreset == "desk" })
        presets.addItem(toggle("Sofa", #selector(presetSofa), key: "2") { [weak self] in self?.currentPreset == "sofa" })
        presets.addItem(toggle("Lying Down", #selector(presetLying), key: "3") { [weak self] in self?.currentPreset == "lying" })
        menu.addItem(submenu("Preset", presets))
        let zoomMenu = NSMenu()
        zoomMenu.addItem(item("Zoom In", #selector(zoomIn), key: "i"))
        zoomMenu.addItem(item("Zoom Out", #selector(zoomOut), key: "o"))
        zoomMenu.addItem(item("Actual Size", #selector(zoomReset), key: "0"))
        menu.addItem(submenu("Zoom", zoomMenu))
        menu.addItem(.separator())
        menu.addItem(submenu("Display", sourceMenu))
        menu.addItem(submenu("Head Tracking", trackingMenu))
        menu.addItem(.separator())
        menu.addItem(toggle("Developer Mode", #selector(toggleDeveloper), key: "d") { [weak self] in self?.settings.developer == true })
        menu.addItem(item("Settings…", #selector(showSettings), key: ",", modifiers: .command))
        menu.addItem(item("Check for Updates…", #selector(update)))
        menu.addItem(.separator())
        menu.addItem(item("Quit RayNeoPin", #selector(quitApp), key: "q"))
        statusItem.menu = menu
    }

    /// First line of the menu: which build runs, and whether the glasses are there.
    let statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")

    /// Which preset the current settings match, if any.
    var currentPreset: String? {
        let follow = settings.flag("follow")
        if !follow, !settings.lockYaw, !settings.lockPitch, !settings.lockRoll { return "desk" }
        if follow, !settings.lockYaw, !settings.lockPitch, settings.lockRoll { return "sofa" }
        if follow, !settings.lockYaw, settings.lockPitch, settings.lockRoll { return "lying" }
        return nil
    }

    @objc func quitApp() { AppDelegate.quit() }

    /// Menu item; `key` shows on the right, with ⌃⌥ like the global hotkeys (which work everywhere).
    func item(_ title: String, _ action: Selector, key: String = "", modifiers: NSEvent.ModifierFlags = [.control, .option],
              target: AnyObject? = nil) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        if !key.isEmpty { i.keyEquivalentModifierMask = modifiers }
        i.target = target ?? self
        return i
    }

    func header(_ title: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.isEnabled = false
        return i
    }

    func submenu(_ title: String, _ menu: NSMenu) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.submenu = menu
        return i
    }

    func toggle(_ title: String, _ action: Selector, key: String = "", isOn: @escaping () -> Bool) -> NSMenuItem {
        let i = item(title, action, key: key)
        toggles.append((i, isOn))
        return i
    }

    func menuWillOpen(_ menu: NSMenu) {
        for (i, isOn) in toggles { i.state = isOn() ? .on : .off }
        let s = imu.snapshot()
        statusLine.title = "RayNeoPin \(SettingsView.revision) — " + (!s.connected ? "glasses not connected" : s.ready ? "tracking" : "calibrating…")
        statusLine.isEnabled = false
        trackingMenu.removeAllItems()
        for mode in TrackingMode.allCases {
            let i = item(mode.title, #selector(pickTracking(_:)))
            i.representedObject = mode.rawValue
            i.state = settings.tracking == mode ? .on : .off
            trackingMenu.addItem(i)
        }
        trackingMenu.addItem(.separator())
        if settings.tracking != .glasses {
            trackingMenu.addItem(header(
                headphones.isDenied ? "AirPods: motion access denied in System Settings"
                    : renderer?.isUsingAirPods == true ? "AirPods: correcting drift"
                    : headphones.latest() != nil ? "AirPods: calibrating — turn and nod"
                    : "AirPods: no data — put them on"))
        }
        trackingMenu.addItem(submenu("AirPods", airPodsMenu))
        trackingMenu.addItem(item("Recalibrate AirPods", #selector(recalibrateAirPods)))
        trackingMenu.addItem(.separator())
        trackingMenu.addItem(item("Calibrate Gyro (glasses on a table)…", #selector(calibrate)))
        rebuildAirPodsMenu()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let found = HeadphoneCatalog.paired()
            DispatchQueue.main.async {
                self?.pairedHeadphones = found
                self?.rebuildAirPodsMenu()
            }
        }

        Task { @MainActor in await refreshSources() }
    }

    // MARK: Test-branch menus

    func flip(_ key: String, _ title: String) {
        setFlag(key, !settings.flag(key))
        renderer?.show("\(title): \(settings.flag(key) ? "on" : "off")", seconds: 2)
    }

    func setFlag(_ key: String, _ on: Bool) {
        guard on != settings.flag(key) else { return }
        settings.setFlag(key, on)
        if key == "follow" || key == "lookAwayRecenter" { renderer?.recenter() }
        applyExtras()
        if key == "gammaResample" { rebuildRenderer() }
    }

    func setChoice(_ key: String, _ value: String) {
        let old = settings.choice(key)
        settings.setChoice(key, value)
        applyExtras()
        if key == "pacing", old != value { rebuildRenderer() }
        if key == "sideScreens" {
            if value != "off", settings.sourceKind != "virtual" {
                settings.sourceKind = "virtual" // side screens are extra virtual displays
                applySetup()
            } else {
                applySideScreens()
            }
        }
    }

    /// Pushes every setting to the renderer, the sensor fusion and the optional references.
    func applyExtras() {
        renderer?.update { settings.apply(to: &$0) }
        if settings.flag("telemetry") { Telemetry.shared.start() } else { Telemetry.shared.stop() }
        imu.configure(mode: settings.fusionMode, strictAccel: settings.flag("strictAccel"), temperature: settings.flag("temperatureComp"))
        if settings.flag("cameraDrift") {
            if face == nil {
                face = FaceTracker()
                face?.start()
            }
        } else if let f = face {
            f.stop()
            face = nil
        }
        renderer?.setFaceTracker(face)
        if !settings.flag("typingDrift") { renderer?.setCaret(nil) }
        if settings.flag("typingDrift"), !AXIsProcessTrusted() {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }
    }

    func rebuildRenderer() {
        renderer?.shutdown()
        renderer = nil
        screensChanged()
    }

    var settingsWindow: NSWindow?

    @objc func showSettings() {
        if settingsWindow == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(model: SettingsModel(self))))
            w.title = "RayNeoPin Settings"
            // Sidebar up to the top edge, traffic lights over it (Magnet / System Settings style).
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            w.titlebarAppearsTransparent = true
            w.toolbarStyle = .unified
            w.setContentSize(NSSize(width: 820, height: 640))
            w.isReleasedWhenClosed = false
            settingsWindow = w
            // On the Mac's own screen: the glasses may only show a captured image of their desktop.
            if let screen = Displays.builtin().flatMap(Displays.screen) ?? NSScreen.main {
                let f = screen.visibleFrame, size = w.frame.size
                w.setFrameOrigin(NSPoint(x: f.midX - size.width / 2, y: f.midY - size.height / 2))
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func setHighRefresh(_ on: Bool) { if on != settings.highRefresh { toggleRefresh() } }
    func setZoom(_ z: Double) { zoom(z / settings.zoom) }
    func setDeveloper(_ on: Bool) { if on != settings.developer { toggleDeveloper() } }
    func setDeveloperOnMac(_ on: Bool) { if on != settings.developerOnMac { toggleDeveloperOnMac() } }

    @objc func useCrispRetina() {
        settings.resolution = .crispRetina
        if settings.sourceKind != "virtual" {
            settings.sourceKind = "virtual"
            applySetup()
        } else {
            applyResolution()
        }
        renderer?.show("Crisp Retina: macOS draws the desktop at 2×", seconds: 3)
    }

    @objc func presetDesk() { applyPreset("desk") }
    @objc func presetSofa() { applyPreset("sofa") }
    @objc func presetLying() { applyPreset("lying") }

    /// Desk: fixed in space. Sofa: follows you past a dead zone, no tilt. Lying down: also level
    /// (pitch follows your head), so it stays in view whatever angle you lie at.
    func applyPreset(_ name: String) {
        let follow = name != "desk"
        settings.setFlag("follow", follow)
        settings.lockYaw = false
        settings.lockPitch = name == "lying"
        settings.lockRoll = name != "desk"
        applyExtras()
        renderer?.recenter()
        renderer?.show(["desk": "Desk: screen fixed in space", "sofa": "Sofa: screen follows you, no tilt",
                        "lying": "Lying down: screen follows you, level"][name] ?? name, seconds: 2)
    }

    @objc func heightUp() { height(2) }
    @objc func heightDown() { height(-2) }
    @objc func heightReset() { height(-settings.screenPitch) }

    func height(_ delta: Double) {
        settings.screenPitch = min(30, max(-30, settings.screenPitch + delta))
        applyExtras()
        renderer?.show(String(format: "Screen height %+.0f°", settings.screenPitch), seconds: 1)
    }

    /// Full-circle turn: face something, start, turn around once (or more), face it again, finish.
    /// What the gyro says you turned vs. whole turns gives its sensitivity about the vertical axis.
    @objc func calibrateYawScale() {
        guard let start = yawScaleStart else {
            yawScaleStart = imu.turned
            NSSound(named: "Tink")?.play()
            renderer?.show("Look at something you can find again. Turn around once (360°, either way), look at it again, then press ⌃⌥G", seconds: 15)
            return
        }
        yawScaleStart = nil
        let turned = abs(imu.turned - start)
        let turns = (turned / (2 * .pi)).rounded()
        guard turns >= 1, abs(turned - turns * 2 * .pi) < 20 * .pi / 180 else {
            NSSound(named: "Basso")?.play()
            renderer?.show(String(format: "That was %.0f° — not a whole turn. Nothing changed.", degrees(turned)), seconds: 5)
            return
        }
        let factor = turns * 2 * .pi / turned
        var s = imu.scale
        s.y *= factor
        imu.scale = s
        settings.gyroScale = imu.scale
        NSSound(named: "Glass")?.play()
        renderer?.show(String(format: "Measured %.1f° for %.0f×360° — turn sensitivity ×%.4f", degrees(turned), turns, factor), seconds: 6)
    }

    @objc func resetScale() {
        imu.scale = SIMD3(repeating: 1)
        settings.gyroScale = imu.scale
        renderer?.show("Gyro sensitivity reset", seconds: 2)
    }

    @objc func resetTemperature() {
        imu.temperatureModel = TemperatureModel()
        settings.temperatureModel = nil
        renderer?.show("Temperature model cleared", seconds: 2)
    }

    /// Sends 0x3E, which the RayNeo SDK names "read gyro bias", and nothing that writes. The raw
    /// reply shows as "last ack" in the developer overlay.
    @objc func probeCalibration() {
        imu.send(raw: 0x3E)
        if !settings.developer { toggleDeveloper() }
        renderer?.show("Sent read-only query 0x3E — the reply is under GLASSES IMU › last ack", seconds: 5)
    }

    @objc func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() } else { try SMAppService.mainApp.register() }
            renderer?.show(SMAppService.mainApp.status == .enabled ? "RayNeoPin opens at login" : "RayNeoPin won't open at login", seconds: 2)
        } catch {
            renderer?.show("Open at Login failed: \(error.localizedDescription)", seconds: 5)
        }
    }

    /// Lists paired Apple headphones; picking one makes it the sound output, which is what
    /// CoreMotion follows for head tracking.
    func rebuildAirPodsMenu() {
        airPodsMenu.removeAllItems()
        airPodsMenu.addItem(header("Head tracking follows your current sound output"))
        let current = HeadphoneCatalog.currentOutputAddress()
        if pairedHeadphones.isEmpty { airPodsMenu.addItem(header("Looking for paired AirPods…")) }
        for d in pairedHeadphones {
            let support = d.headTracking == false ? " — no head tracking" : d.headTracking == nil ? " — head tracking unknown" : ""
            let state = d.address.uppercased() == current ? "" : d.connected ? " — switch to these" : " — connect & use"
            let i = item("\(d.name) (\(d.model))\(support)\(state)", #selector(pickHeadphones(_:)))
            i.representedObject = d.address
            i.state = d.address.uppercased() == current ? .on : .off
            i.isEnabled = d.headTracking != false
            airPodsMenu.addItem(i)
        }
        airPodsMenu.addItem(.separator())
        airPodsMenu.addItem(header("Works with: \(HeadphoneCatalog.supportedSummary)"))
    }

    @MainActor func refreshSources() async {
        sourceMenu.removeAllItems()
        for (kind, title) in [("glasses", "Glasses Screen"), ("ultrawide", "Glasses Screen Ultrawide (32:9)"),
                              ("virtual", "Virtual Display")] {
            let i = item(title, #selector(pickSource(_:)))
            i.representedObject = [kind, UInt32(0)]
            i.state = settings.sourceKind == kind ? .on : .off
            sourceMenu.addItem(i)
        }
        let displays = NSMenu(), windows = NSMenu()
        sourceMenu.addItem(.separator())
        sourceMenu.addItem(submenu("Mirror Display", displays))
        sourceMenu.addItem(submenu("Mirror Window", windows))
        guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true) else {
            displays.addItem(header("Screen Recording permission needed"))
            return
        }
        let gid = Displays.glasses().map(Displays.id)
        for d in content.displays where d.displayID != gid && d.displayID != monitor?.displayID {
            let i = item(Displays.name(of: d.displayID), #selector(pickSource(_:)))
            i.representedObject = ["display", d.displayID]
            i.state = settings.sourceKind == "display" && source == .display(d.displayID) ? .on : .off
            displays.addItem(i)
        }
        let list = content.windows.filter {
            $0.windowLayer == 0 && $0.frame.width > 200 && $0.frame.height > 150
                && $0.owningApplication?.bundleIdentifier != Bundle.main.bundleIdentifier
        }
        for w in list.prefix(25) {
            let app = w.owningApplication?.applicationName ?? "?"
            let title = (w.title ?? "").isEmpty ? app : "\(app) — \(w.title!)"
            let i = item(String(title.prefix(70)), #selector(pickSource(_:)))
            i.representedObject = ["window", w.windowID]
            i.state = source == .window(w.windowID) ? .on : .off
            windows.addItem(i)
        }
        if list.isEmpty { windows.addItem(header("No windows")) }
    }

    @objc func pickSource(_ sender: NSMenuItem) {
        guard let rep = sender.representedObject as? [Any], let kind = rep.first as? String, let id = rep.last as? UInt32 else { return }
        settings.sourceKind = kind
        switch kind {
        case "display": source = .display(id)
        case "window": source = .window(id)
        default: break
        }
        applySetup()
        if let source { Task { await capture.start(source) } }
        renderer?.recenter()
    }

    /// The display setups the Settings window offers (mirroring stays in the menu).
    func chooseSetup(_ kind: String) {
        guard kind != settings.sourceKind else { return }
        settings.sourceKind = kind
        applySetup()
        if let source { Task { await capture.start(source) } }
        renderer?.recenter()
    }

    func chooseResolution(_ r: VirtualMonitor.Resolution) {
        settings.resolution = r
        if settings.sourceKind != "virtual" {
            settings.sourceKind = "virtual" // these sizes only exist on the virtual display
            applySetup()
        } else {
            applyResolution()
        }
        renderer?.show(r == .manual ? "Resolution: pick it in System Settings › Displays › RayNeoPin Display" : "Resolution: \(r.rawValue)", seconds: 3)
    }

    // MARK: Actions

    func setting(_ change: () -> Void, _ message: String) {
        change()
        applyExtras()
        renderer?.show(message)
    }

    @objc func recenter() { renderer?.recenter(); renderer?.show("Recentered", seconds: 1) }

    var calibrationTimer: Timer?
    var calibrationPanel: NSPanel?

    /// Table calibration. The glasses' proximity sensor turns them off when not worn, so it is
    /// disabled meanwhile; progress is shown on the Mac and signalled with sounds, since nobody is
    /// looking into the glasses.
    @objc func calibrate() {
        guard calibrationTimer == nil else { return }
        Telemetry.shared.event("table calibration started", time: CACurrentMediaTime())
        imu.send(.proximitySensor, value: 0)
        imu.calibrateOnTable()
        NSSound(named: "Tink")?.play()
        showCalibrationStatus("Put the glasses on a flat surface and don't touch them…")
        let started = Date()
        calibrationTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self else { return }
            switch self.imu.snapshot().state {
            case .calibratingOnTable(let progress):
                if Date().timeIntervalSince(started) > 90 {
                    self.imu.cancelCalibration()
                    self.finishCalibration("Calibration failed: the glasses kept moving. The previous calibration is kept.", ok: false)
                } else if progress > 0 {
                    self.showCalibrationStatus(String(format: "Calibrating gyro… %.0f%%", progress * 100))
                }
            default:
                let b = self.imu.bias * 180 / .pi
                self.finishCalibration(String(format: "Calibration done. Gyro bias %+.3f %+.3f %+.3f °/s", b.x, b.y, b.z), ok: true)
            }
        }
    }

    func finishCalibration(_ message: String, ok: Bool) {
        Telemetry.shared.event("table calibration: " + message, time: CACurrentMediaTime())
        calibrationTimer?.invalidate()
        calibrationTimer = nil
        imu.send(.proximitySensor, value: 1)
        if ok { saveBias() }
        NSSound(named: ok ? "Glass" : "Basso")?.play()
        showCalibrationStatus(message)
        renderer?.show(message, seconds: 5)
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            if self?.calibrationTimer == nil { self?.calibrationPanel?.orderOut(nil) }
        }
    }

    /// Small HUD on the Mac's own screen, top center.
    func showCalibrationStatus(_ text: String, title: String = "RayNeoPin Calibration") {
        if calibrationPanel == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 64),
                                styleMask: [.titled, .hudWindow, .utilityWindow, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.title = "RayNeoPin Calibration"
            panel.level = .floating
            panel.isReleasedWhenClosed = false
            let label = NSTextField(labelWithString: "")
            label.font = .systemFont(ofSize: 13, weight: .medium)
            label.alignment = .center
            label.frame = panel.contentView!.bounds.insetBy(dx: 12, dy: 12)
            label.autoresizingMask = [.width, .height]
            panel.contentView!.addSubview(label)
            calibrationPanel = panel
        }
        guard let panel = calibrationPanel, let label = panel.contentView?.subviews.first as? NSTextField else { return }
        panel.title = title
        label.stringValue = text
        if let screen = Displays.builtin().flatMap(Displays.screen) ?? NSScreen.main {
            let f = screen.visibleFrame
            panel.setFrameTopLeftPoint(NSPoint(x: f.midX - 260, y: f.maxY - 10))
        }
        panel.orderFrontRegardless()
    }

    @objc func togglePause() {
        guard let r = renderer else { return }
        r.update { $0.paused.toggle() }
        let paused = r.currentParams.paused
        if !paused { r.recenter() }
        r.show(paused ? "Tracking paused (screen follows your head)" : "Tracking on")
    }

    @objc func toggleLockYaw() {
        setting({ settings.lockYaw.toggle() }, settings.lockYaw ? "Yaw unlocked" : "Yaw locked — follows your head left/right")
        renderer?.recenter()
    }

    @objc func toggleLockPitch() {
        setting({ settings.lockPitch.toggle() }, settings.lockPitch ? "Pitch unlocked" : "Pitch locked — follows your head up/down")
        renderer?.recenter()
    }

    @objc func toggleLockRoll() {
        setting({ settings.lockRoll.toggle() }, settings.lockRoll ? "Roll unlocked" : "Roll locked — follows your head tilt")
    }

    @objc func toggleSteady() {
        setting({ settings.steady.toggle() }, settings.steady ? "Steady image off" : "Steady image on")
    }

    @objc func pickTracking(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let mode = TrackingMode(rawValue: raw) else { return }
        chooseTracking(mode)
    }

    func chooseTracking(_ mode: TrackingMode) {
        guard mode != settings.tracking else { return }
        let hint = mode == .glasses ? "" : " — turn your head left and right a couple of times"
        setting({ settings.tracking = mode }, "Head tracking: \(mode.title)\(hint)")
        if mode == .glasses { headphones.stop() } else { headphones.start() }
        renderer?.recenter()
    }

    @objc func recalibrateAirPods() {
        Telemetry.shared.event("airpods recalibration requested", time: CACurrentMediaTime())
        renderer?.recalibrateAirPods()
        renderer?.show("Recalibrating AirPods — turn your head left/right and nod a few times", seconds: 4)
    }

    @objc func pickHeadphones(_ sender: NSMenuItem) {
        guard let address = sender.representedObject as? String,
              let device = pairedHeadphones.first(where: { $0.address == address }) else { return }
        renderer?.show("Connecting \(device.name)…", seconds: 10)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let ok = HeadphoneCatalog.use(device)
            DispatchQueue.main.async {
                guard let self else { return }
                self.renderer?.show(ok ? "Using \(device.name) for sound and head tracking" : "Couldn't connect \(device.name) — is it nearby and out of its case?", seconds: 4)
                if ok, self.settings.tracking == .glasses {
                    self.settings.tracking = .both
                    self.renderer?.update { self.settings.apply(to: &$0) }
                }
                // CoreMotion picks the new route up on restart; other AirPods sit differently in the ears.
                if ok {
                    self.renderer?.recalibrateAirPods()
                    self.seedAirPodsCalibration()
                }
                self.headphones.stop()
                if self.settings.tracking != .glasses { self.headphones.start() }
            }
        }
    }

    @objc func toggleDeveloper() {
        setting({ settings.developer.toggle() }, settings.developer ? "Developer mode off" : "Developer mode on")
        showDeveloperPanel(settings.developer && settings.developerOnMac)
    }

    @objc func toggleDeveloperOnMac() {
        settings.developerOnMac.toggle()
        showDeveloperPanel(settings.developer && settings.developerOnMac)
    }

    /// Same text as the overlay in the glasses, in a floating panel on the Mac (screenshots can't
    /// see the glasses window).
    func showDeveloperPanel(_ show: Bool) {
        guard show else { developerPanel?.orderOut(nil); return }
        if developerPanel == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 600),
                                styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
                                backing: .buffered, defer: false)
            panel.title = "RayNeoPin Developer"
            panel.level = .floating
            panel.isReleasedWhenClosed = false
            panel.hidesOnDeactivate = false
            let label = NSTextField(labelWithString: "Waiting for data…")
            label.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            label.textColor = .labelColor
            label.isSelectable = true
            label.frame = panel.contentView!.bounds.insetBy(dx: 12, dy: 10)
            label.autoresizingMask = [.width, .height]
            panel.contentView!.addSubview(label)
            developerPanel = panel
            developerLabel = label
            placeDeveloperPanel()
        }
        developerPanel?.orderFrontRegardless()
    }

    func developerDisplayInfo() -> String {
        func mode(_ id: CGDirectDisplayID) -> String {
            guard let m = CGDisplayCopyDisplayMode(id) else { return "?" }
            return "\(m.width)×\(m.height)\(m.pixelWidth != m.width ? " HiDPI" : "") @\(Int(m.refreshRate)) Hz"
        }
        let glasses = Displays.glasses().map { "glasses " + mode(Displays.id(of: $0)) } ?? "glasses not found"
        let src: String
        switch capture.source {
        case .display(let id)?: src = "\(Displays.name(of: id)) " + mode(id)
        case .window(let id)?: src = "window \(id)"
        case nil: src = "none"
        }
        return "\(glasses)   source \(src)   resolution mode \(settings.resolution)"
    }

    /// Top-right of the Mac's own screen (never the glasses or the virtual monitor).
    func placeDeveloperPanel() {
        guard let panel = developerPanel, let screen = Displays.builtin().flatMap(Displays.screen) ?? NSScreen.main else { return }
        let f = screen.visibleFrame
        panel.setFrame(NSRect(x: f.maxX - 1020, y: f.maxY - 620, width: 1000, height: 600), display: true)
    }

    @objc func toggleAutoRecenter() {
        setting({ settings.autoRecenter.toggle() }, settings.autoRecenter ? "Auto drift correction off" : "Auto drift correction on")
    }

    @objc func toggleRefresh() {
        settings.highRefresh.toggle()
        imu.send(settings.highRefresh ? .panel120Hz : .panel60Hz)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.applyRefreshRate() }
        renderer?.show(settings.highRefresh ? "Glasses at 120 Hz" : "Glasses at 60 Hz")
    }

    @objc func zoomIn() { zoom(1.1) }
    @objc func zoomOut() { zoom(1 / 1.1) }
    @objc func fovUp() { fov(1) }
    @objc func fovDown() { fov(-1) }
    @objc func zoomReset() { zoom(1 / settings.zoom) }

    func zoom(_ k: Double) {
        settings.zoom = min(2.4, max(0.6, settings.zoom * k))
        let z = settings.zoom
        renderer?.update { $0.zoom = z }
        renderer?.show(String(format: "Zoom %.0f%%", z * 100), seconds: 1)
        if settings.resolution == .crisp || settings.resolution == .crispRetina { applyResolutionSoon() }
    }

    func fov(_ delta: Double) {
        settings.fovDiagonal = min(70, max(25, settings.fovDiagonal + delta))
        let f = settings.fovDiagonal
        renderer?.update { $0.fovDiagonal = f }
        renderer?.show(String(format: "FOV %.0f°", f), seconds: 1)
    }

    @objc func coffee() { NSWorkspace.shared.open(AppDelegate.coffeeURL) }

    /// Pulls the latest source, rebuilds, reinstalls and relaunches (see install.sh).
    @objc func update() {
        let script = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/RayNeoPin/src/install.sh").path
        guard FileManager.default.fileExists(atPath: script) else {
            renderer?.show("Install with install.sh to update from the menu", seconds: 5)
            return
        }
        guard updateProcess == nil else { updatePanel?.orderFrontRegardless(); return }
        renderer?.show("Checking for updates…", seconds: 3)
        updateProgress(step: 0, of: 4, "Checking for updates…")
        let logURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/RayNeoPin-update.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = [script]
        p.environment = ProcessInfo.processInfo.environment.merging(["RAYNEOPIN_FROM_APP": "1"]) { $1 }
        p.standardOutput = try? FileHandle(forWritingTo: logURL)
        p.standardError = p.standardOutput
        // Follow the script's "==> step/total" lines while it runs.
        let started = Date()
        updateTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self, let log = try? String(contentsOf: logURL, encoding: .utf8),
                  let line = log.split(separator: "\n").last(where: { $0.hasPrefix("==> ") }) else { return }
            let parts = line.dropFirst(4).split(separator: " ", maxSplits: 1)
            let fraction = parts.first?.split(separator: "/").compactMap { Int($0) } ?? []
            guard fraction.count == 2, parts.count == 2 else { return }
            let seconds = Int(Date().timeIntervalSince(started))
            self.updateProgress(step: fraction[0], of: fraction[1], String(parts[1]), detail: "\(seconds) s")
            self.renderer?.show("Updating: " + String(parts[1]), seconds: 2)
        }
        // The script builds and installs a new version, then this app restarts into it.
        p.terminationHandler = { [weak self] p in
            DispatchQueue.main.async {
                guard let self else { return }
                self.updateTimer?.invalidate()
                self.updateTimer = nil
                self.updateProcess = nil
                // The script's last line says what it did, e.g. "up to date (61775b3, test/everything)".
                let last = (try? String(contentsOf: logURL, encoding: .utf8))?
                    .split(separator: "\n").last.map(String.init) ?? ""
                let message = p.terminationStatus != 0 ? "Update failed — see ~/Library/Logs/RayNeoPin-update.log"
                    : last.contains(" installed to ") ? "Updated — restarting…" : (last.isEmpty ? "You have the latest version" : last)
                self.renderer?.show(message, seconds: 6)
                let installed = p.terminationStatus == 0 && last.contains(" installed to ")
                if installed {
                    self.updateProgress(step: 4, of: 4, "Restarting into the new version…")
                } else {
                    self.updateProgress(step: 4, of: 4, message, finished: true, failed: p.terminationStatus != 0)
                }
                if installed {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.relaunch() }
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 6) { self.updatePanel?.orderOut(nil) }
                }
            }
        }
        updateProcess = p
        do { try p.run() } catch {
            updateTimer?.invalidate()
            updateTimer = nil
            updateProcess = nil
            updateProgress(step: 0, of: 4, "Couldn't start the updater: \(error.localizedDescription)", failed: true)
        }
    }

    var updateProcess: Process?
    var updateTimer: Timer?
    var updatePanel: NSPanel?
    private var updateLabel: NSTextField?
    private var updateDetail: NSTextField?
    private var updateBar: NSProgressIndicator?

    private var updateStep = -1
    private var updateStepStart = Date()

    /// A small window at the top of the Mac's screen showing each update step (download, build,
    /// install, restart) with a progress bar, since you might not be wearing the glasses.
    func updateProgress(step: Int, of total: Int, _ text: String, detail: String = "", finished: Bool = false, failed: Bool = false) {
        if updatePanel == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 92),
                                styleMask: [.titled, .closable, .hudWindow, .utilityWindow, .nonactivatingPanel],
                                backing: .buffered, defer: false)
            panel.title = "Updating RayNeoPin"
            panel.level = .floating
            panel.isReleasedWhenClosed = false
            let label = NSTextField(labelWithString: "")
            label.font = .systemFont(ofSize: 13, weight: .semibold)
            label.lineBreakMode = .byTruncatingTail
            label.frame = NSRect(x: 16, y: 54, width: 360, height: 20)
            let detailLabel = NSTextField(labelWithString: "")
            detailLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            detailLabel.textColor = .secondaryLabelColor
            detailLabel.alignment = .right
            detailLabel.frame = NSRect(x: 376, y: 55, width: 48, height: 18)
            let bar = NSProgressIndicator(frame: NSRect(x: 16, y: 22, width: 408, height: 16))
            bar.style = .bar
            bar.isIndeterminate = false
            bar.minValue = 0
            for v in [label, detailLabel, bar] { panel.contentView!.addSubview(v) }
            updatePanel = panel
            updateLabel = label
            updateDetail = detailLabel
            updateBar = bar
        }
        guard let panel = updatePanel else { return }
        if step != updateStep { updateStep = step; updateStepStart = Date() }
        updateLabel?.stringValue = failed ? "⚠️ " + text : finished || step == 0 ? text : "\(step)/\(total)  \(text)"
        updateDetail?.stringValue = detail
        updateBar?.maxValue = Double(total)
        // Each step fills its share over its usual duration, so the bar keeps moving during the build.
        let durations: [Int: Double] = [0: 4, 1: 5, 2: 60, 3: 3, 4: 2]
        let expected = durations[step] ?? 5
        let within = min(Date().timeIntervalSince(updateStepStart) / expected, 0.95)
        updateBar?.doubleValue = finished ? Double(total) : failed ? 0 : Double(max(step - 1, 0)) + (step == 0 ? 0.1 : within)
        if let screen = Displays.builtin().flatMap(Displays.screen) ?? NSScreen.main, !panel.isVisible {
            let f = screen.visibleFrame
            panel.setFrameTopLeftPoint(NSPoint(x: f.midX - 220, y: f.maxY - 10))
        }
        panel.orderFrontRegardless()
    }
}
