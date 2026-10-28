// RayNeoPin — 3DoF spatially pinned screen for RayNeo Air 4 Pro on macOS.
//
// Default setup: a virtual monitor ("RayNeoPin Display") is created and shown in the glasses as
// a screen fixed in space. The glasses' own display is fenced off, so you work with two screens:
// the Mac's and the pinned one.

import AppKit
import Carbon.HIToolbox
import ScreenCaptureKit
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
    let resolutionMenu = NSMenu()
    let sharpnessMenu = NSMenu()
    let trackingMenu = NSMenu()
    let airPodsMenu = NSMenu()
    var pairedHeadphones: [HeadphoneDevice] = []
    var toggles: [(NSMenuItem, () -> Bool)] = []
    var retryTimer: Timer?
    var openedSettings = false
    var resolutionWork: DispatchWorkItem?
    var developerPanel: NSPanel?
    var developerLabel: NSTextField?

    /// SIGTERM (installer, `pkill`) skips applicationWillTerminate, which restores the hidden
    /// cursor and puts the glasses back in 2D; route it through a normal quit instead.
    private var termSource: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ note: Notification) {
        signal(SIGTERM, SIG_IGN)
        termSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        termSource?.setEventHandler { NSApp.terminate(nil) }
        termSource?.resume()

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
            (kVK_ANSI_Q, { NSApp.terminate(nil) }),
        ])
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
        // Our own cursor on the pinned screen, at display rate.
        let cursorTimer = Timer(timeInterval: 1 / 120, repeats: true) { [weak self] _ in self?.updateCursor() }
        RunLoop.main.add(cursorTimer, forMode: .common)
        // Windows that end up on the fenced glasses display would be unreachable: move them out.
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.rescueWindows() }
        // Display reconfigurations can move our windows without telling us; check every second.
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, let glasses = Displays.glasses() else { return }
            self.renderer?.keepOn(glasses)
            if self.settings.developer { self.renderer?.setDeveloperDisplayInfo(self.developerDisplayInfo()) }
            if self.settings.developer, self.settings.developerOnMac, let panel = self.developerPanel, !NSScreen.screens.contains(where: {
                $0.frame.intersects(panel.frame) && Displays.id(of: $0) != Displays.id(of: glasses)
            }) { self.placeDeveloperPanel() }
        }

        if !CGPreflightScreenCaptureAccess() { CGRequestScreenCaptureAccess() }
        fence.start()
        applySetup()
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
        }
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

    /// Where the system cursor is on the captured display, and what it looks like (arrow, I-beam…).
    func updateCursor() {
        guard let renderer else { return }
        guard case .display(let id)? = capture.source, let screen = Displays.screen(for: id) else {
            renderer.setCursor(nil, image: nil)
            return
        }
        let m = NSEvent.mouseLocation, f = screen.frame
        guard f.contains(m) else { renderer.setCursor(nil, image: nil); return }
        let cursor = NSCursor.currentSystem ?? .arrow
        let image = cursor.image, hot = cursor.hotSpot
        renderer.setCursor(.init(x: (m.x - f.minX - hot.x) / f.width, y: (f.maxY - m.y - hot.y) / f.height,
                                 w: image.size.width / f.width, h: image.size.height / f.height), image: image)
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
                let r = try Renderer(screen: glasses, displayID: gid, imu: imu, capture: capture, headphones: headphones)
                r.update { settings.apply(to: &$0) }
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

    func relaunch() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
        try? p.run()
        NSApp.terminate(nil)
    }

    // MARK: Menu

    func buildMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "eyeglasses", accessibilityDescription: "RayNeoPin")
        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(item("Recenter  ⌃⌥R", #selector(recenter)))
        menu.addItem(item("Calibrate Gyro (glasses on a table)…", #selector(calibrate)))
        menu.addItem(toggle("Pause Tracking  ⌃⌥T", #selector(togglePause)) { [weak self] in self?.renderer?.currentParams.paused == true })
        menu.addItem(.separator())
        menu.addItem(header("Lock an axis (it follows your head)"))
        menu.addItem(toggle("Lock Yaw — left/right  ⌃⌥Y", #selector(toggleLockYaw)) { [weak self] in self?.settings.lockYaw == true })
        menu.addItem(toggle("Lock Pitch — up/down  ⌃⌥P", #selector(toggleLockPitch)) { [weak self] in self?.settings.lockPitch == true })
        menu.addItem(toggle("Lock Roll — tilt  ⌃⌥E", #selector(toggleLockRoll)) { [weak self] in self?.settings.lockRoll == true })
        menu.addItem(.separator())
        menu.addItem(header("Stability"))
        menu.addItem(toggle("Steady Image (ignore heartbeat & micro-movements)", #selector(toggleSteady)) { [weak self] in self?.settings.steady == true })
        menu.addItem(submenu("Head Tracking Source", trackingMenu))
        menu.addItem(submenu("AirPods", airPodsMenu))
        menu.addItem(item("Recalibrate AirPods", #selector(recalibrateAirPods)))
        menu.addItem(toggle("Auto Drift Correction (follows your gaze)", #selector(toggleAutoRecenter)) { [weak self] in self?.settings.autoRecenter == true })
        menu.addItem(.separator())
        menu.addItem(header("Display"))
        menu.addItem(item("Zoom In  ⌃⌥I", #selector(zoomIn)))
        menu.addItem(item("Zoom Out  ⌃⌥O", #selector(zoomOut)))
        menu.addItem(item("Reset Zoom  ⌃⌥0", #selector(zoomReset)))
        menu.addItem(submenu("Resolution", resolutionMenu))
        menu.addItem(submenu("Sharpness", sharpnessMenu))
        menu.addItem(submenu("Source", sourceMenu))
        menu.addItem(toggle("Glasses at 120 Hz", #selector(toggleRefresh)) { [weak self] in self?.settings.highRefresh == true })
        menu.addItem(item("FOV +1°  ⌃⌥L", #selector(fovUp)))
        menu.addItem(item("FOV −1°  ⌃⌥K", #selector(fovDown)))
        menu.addItem(.separator())
        menu.addItem(toggle("Developer Mode (data in the glasses)  ⌃⌥D", #selector(toggleDeveloper)) { [weak self] in self?.settings.developer == true })
        menu.addItem(toggle("Also Show Developer Data on the Mac", #selector(toggleDeveloperOnMac)) { [weak self] in self?.settings.developerOnMac == true })
        menu.addItem(item("☕ Buy Me a Coffee — help pay Claude's bill", #selector(coffee)))
        menu.addItem(item("Check for Updates…", #selector(update)))
        menu.addItem(item("Quit  ⌃⌥Q", #selector(NSApp.terminate(_:)), target: NSApp))
        statusItem.menu = menu
    }

    func item(_ title: String, _ action: Selector, target: AnyObject? = nil) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
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

    func toggle(_ title: String, _ action: Selector, isOn: @escaping () -> Bool) -> NSMenuItem {
        let i = item(title, action)
        toggles.append((i, isOn))
        return i
    }

    func menuWillOpen(_ menu: NSMenu) {
        for (i, isOn) in toggles { i.state = isOn() ? .on : .off }
        trackingMenu.removeAllItems()
        for mode in TrackingMode.allCases {
            let i = item(mode.title, #selector(pickTracking(_:)))
            i.representedObject = mode.rawValue
            i.state = settings.tracking == mode ? .on : .off
            trackingMenu.addItem(i)
        }
        if settings.tracking != .glasses {
            trackingMenu.addItem(.separator())
            trackingMenu.addItem(header(
                headphones.isDenied ? "AirPods: motion access denied (System Settings › Privacy & Security › Motion & Fitness)"
                    : renderer?.isUsingAirPods == true ? "AirPods: active"
                    : headphones.latest() != nil ? "AirPods: learning — turn your head left and right"
                    : "AirPods: no head tracking data — put them on"))
        }
        rebuildAirPodsMenu()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let found = HeadphoneCatalog.paired()
            DispatchQueue.main.async {
                self?.pairedHeadphones = found
                self?.rebuildAirPodsMenu()
            }
        }

        resolutionMenu.removeAllItems()
        if settings.sourceKind != "virtual" { resolutionMenu.addItem(header("Picking one switches to the Virtual Display setup")) }
        for r in VirtualMonitor.Resolution.allCases {
            if r == .wuxga || r == .uw2560 || r == .manual { resolutionMenu.addItem(.separator()) }
            let i = item(r.rawValue, #selector(pickResolution(_:)))
            i.representedObject = "\(r)"
            i.state = settings.resolution == r ? .on : .off
            resolutionMenu.addItem(i)
        }
        sharpnessMenu.removeAllItems()
        for (name, value) in [("Off", 0.0), ("Low", 0.3), ("Medium", 0.5), ("High", 0.8)] {
            let i = item(name, #selector(pickSharpness(_:)))
            i.representedObject = value
            i.state = abs(settings.sharpness - value) < 0.01 ? .on : .off
            sharpnessMenu.addItem(i)
        }
        Task { @MainActor in await refreshSources() }
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
        for (kind, title) in [("glasses", "Glasses Screen — one display (recommended)"),
                              ("ultrawide", "Glasses Screen Ultrawide 32:9 — one display, 3D mode, 60 Hz"),
                              ("virtual", "Virtual Display — any resolution incl. ultrawide, 120 Hz (adds a display)")] {
            let i = item(title, #selector(pickSource(_:)))
            i.representedObject = [kind, UInt32(0)]
            i.state = settings.sourceKind == kind ? .on : .off
            sourceMenu.addItem(i)
        }
        sourceMenu.addItem(.separator())
        guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true) else {
            sourceMenu.addItem(NSMenuItem(title: "Screen Recording permission needed", action: nil, keyEquivalent: ""))
            return
        }
        let gid = Displays.glasses().map(Displays.id)
        for d in content.displays where d.displayID != gid && d.displayID != monitor?.displayID {
            let i = item("Mirror \(Displays.name(of: d.displayID))", #selector(pickSource(_:)))
            i.representedObject = ["display", d.displayID]
            i.state = settings.sourceKind == "display" && source == .display(d.displayID) ? .on : .off
            sourceMenu.addItem(i)
        }
        sourceMenu.addItem(.separator())
        let windows = content.windows.filter {
            $0.windowLayer == 0 && $0.frame.width > 200 && $0.frame.height > 150
                && $0.owningApplication?.bundleIdentifier != Bundle.main.bundleIdentifier
        }
        for w in windows.prefix(25) {
            let app = w.owningApplication?.applicationName ?? "?"
            let title = (w.title ?? "").isEmpty ? app : "\(app) — \(w.title!)"
            let i = item("Window: \(title.prefix(70))", #selector(pickSource(_:)))
            i.representedObject = ["window", w.windowID]
            i.state = source == .window(w.windowID) ? .on : .off
            sourceMenu.addItem(i)
        }
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

    @objc func pickResolution(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let r = VirtualMonitor.Resolution.allCases.first(where: { "\($0)" == raw }) else { return }
        settings.resolution = r
        if settings.sourceKind != "virtual" {
            settings.sourceKind = "virtual" // these sizes only exist on the virtual display
            applySetup()
        } else {
            applyResolution()
        }
        renderer?.show(r == .manual ? "Resolution: pick it in System Settings › Displays › RayNeoPin Display" : "Resolution: \(r.rawValue)", seconds: 3)
    }

    @objc func pickSharpness(_ sender: NSMenuItem) {
        guard let v = sender.representedObject as? Double else { return }
        settings.sharpness = v
        renderer?.update { $0.sharpness = v }
    }

    // MARK: Actions

    func setting(_ change: () -> Void, _ message: String) {
        change()
        renderer?.update { settings.apply(to: &$0) }
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
    func showCalibrationStatus(_ text: String) {
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
        let hint = mode == .glasses ? "" : " — turn your head left and right a couple of times"
        setting({ settings.tracking = mode }, "Head tracking: \(mode.title)\(hint)")
        if mode == .glasses { headphones.stop() } else { headphones.start() }
        renderer?.recenter()
    }

    @objc func recalibrateAirPods() {
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
        if settings.resolution == .crisp { applyResolutionSoon() }
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
        renderer?.show("Checking for updates…", seconds: 60)
        let logURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/RayNeoPin-update.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = [script]
        p.standardOutput = try? FileHandle(forWritingTo: logURL)
        p.standardError = p.standardOutput
        // If there is a new version the script quits and relaunches this app; otherwise it just exits.
        p.terminationHandler = { [weak self] p in
            DispatchQueue.main.async {
                self?.renderer?.show(p.terminationStatus == 0 ? "You have the latest version"
                                     : "Update failed (see ~/Library/Logs/RayNeoPin-update.log)", seconds: 5)
            }
        }
        try? p.run()
    }
}
