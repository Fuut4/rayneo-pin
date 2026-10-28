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
    var fovDiagonal: Double { get { double("fov", 46) } set { d.set(newValue, forKey: "fov") } }
    // Old "yaw only" mode meant pitch and roll locked.
    var lockYaw: Bool { get { bool("lockYaw", false) } set { d.set(newValue, forKey: "lockYaw") } }
    var lockPitch: Bool { get { bool("lockPitch", d.bool(forKey: "yawOnly")) } set { d.set(newValue, forKey: "lockPitch") } }
    var lockRoll: Bool { get { bool("lockRoll", d.bool(forKey: "yawOnly")) } set { d.set(newValue, forKey: "lockRoll") } }
    var autoRecenter: Bool { get { bool("autoDriftCorrection", false) } set { d.set(newValue, forKey: "autoDriftCorrection") } }
    var steady: Bool { get { bool("steady", true) } set { d.set(newValue, forKey: "steady") } }
    var useAirPods: Bool { get { bool("useAirPods", true) } set { d.set(newValue, forKey: "useAirPods") } }
    var sharpness: Double { get { double("sharpness", 0.5) } set { d.set(newValue, forKey: "sharpness") } }
    var highRefresh: Bool { get { bool("highRefresh", true) } set { d.set(newValue, forKey: "highRefresh") } }
    var resolution: VirtualMonitor.Resolution {
        get { VirtualMonitor.Resolution.allCases.first { "\($0)" == d.string(forKey: "resolutionMode") } ?? .crisp }
        set { d.set("\(newValue)", forKey: "resolutionMode") }
    }
    /// "virtual", or "display"/"window" for mirroring something that already exists.
    var sourceKind: String { get { d.string(forKey: "sourceKind") ?? "virtual" } set { d.set(newValue, forKey: "sourceKind") } }
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
        p.useAirPods = useAirPods
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
    var airPodsItem: NSMenuItem!
    var toggles: [(NSMenuItem, () -> Bool)] = []
    var retryTimer: Timer?
    var openedSettings = false
    var resolutionWork: DispatchWorkItem?

    func applicationDidFinishLaunching(_ note: Notification) {
        imu.onConnect = { [weak self] in
            guard let self, self.settings.highRefresh else { return }
            self.imu.send(.panel120Hz)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.applyRefreshRate() }
        }
        imu.start()
        if settings.useAirPods { headphones.start() }
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
            (kVK_ANSI_Q, { NSApp.terminate(nil) }),
        ])
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in self?.screensChanged() }
        capture.onError = { [weak self] msg in
            NSLog("%@", msg)
            if CGPreflightScreenCaptureAccess() { self?.renderer?.show(msg, seconds: 8) } else { self?.permissionMissing() }
        }
        capture.onStarted = { [weak self] in
            self?.renderer?.setNotice(nil)
            self?.retryTimer?.invalidate()
            self?.retryTimer = nil
        }
        // Persist the gyro bias so the next launch starts calibrated.
        Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.saveBias() }

        if !CGPreflightScreenCaptureAccess() { CGRequestScreenCaptureAccess() }
        fence.start()
        if settings.sourceKind == "virtual" { createMonitor() }
        screensChanged()
    }

    func applicationWillTerminate(_ note: Notification) {
        saveBias()
        imu.stop()
        headphones.stop()
    }

    func saveBias() {
        if imu.snapshot().state == .ready { settings.gyroBias = imu.bias }
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            Displays.arrange(virtual: monitor.displayID, glasses: Displays.glasses().map(Displays.id))
            self?.screensChanged()
        }
    }

    /// Picks the virtual display mode; in crisp mode one desktop pixel maps to one glasses pixel.
    func applyResolution() {
        guard let monitor else { return }
        let glassesWidth = Double(Displays.glasses()?.frame.width ?? 1920)
        let covered = glassesWidth * Renderer.baseWidth * settings.zoom
        let mode = VirtualMonitor.logicalWidth(for: settings.resolution, coveredPixels: covered)
        monitor.setMode(width: mode.width, hiDPI: mode.hiDPI)
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
        fence.blocked = gid
        if let r = renderer, r.displayID != gid || r.window.frame != glasses?.frame {
            r.shutdown()
            renderer = nil
        }
        if renderer == nil, let glasses, let gid {
            do {
                let r = try Renderer(screen: glasses, displayID: gid, imu: imu, capture: capture, headphones: headphones)
                r.update { settings.apply(to: &$0) }
                r.show("RayNeoPin — ⌃⌥R recenter · ⌃⌥I / ⌃⌥O zoom · ⌃⌥Q quit", seconds: 5)
                renderer = r
            } catch {
                NSLog("RayNeoPin: renderer failed: %@", error.localizedDescription)
            }
        }
        if source == nil || source == .display(gid ?? 0) {
            source = Displays.builtin().map { .display($0) } ?? .display(CGMainDisplayID())
        }
        if let source, source != capture.source || needsRestart(source) {
            Task { await capture.start(source) }
        }
    }

    private var capturedSize: CGSize?
    /// Restart when the captured display changed resolution (e.g. virtual display mode switch).
    private func needsRestart(_ source: Source) -> Bool {
        guard case .display(let id) = source, let mode = CGDisplayCopyDisplayMode(id) else { return false }
        let size = CGSize(width: mode.pixelWidth, height: mode.pixelHeight)
        defer { capturedSize = size }
        return capturedSize != nil && capturedSize != size
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
        airPodsItem = toggle("Use AirPods Head Tracking", #selector(toggleAirPods)) { [weak self] in self?.settings.useAirPods == true }
        menu.addItem(airPodsItem)
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
        airPodsItem.title = "Use AirPods Head Tracking" + (
            !settings.useAirPods ? ""
                : headphones.isDenied ? " (no permission)"
                : renderer?.isUsingAirPods == true ? " (active)"
                : headphones.latestYaw() != nil ? " (learning — turn your head)"
                : " (put your AirPods on)")

        resolutionMenu.removeAllItems()
        for r in VirtualMonitor.Resolution.allCases {
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

    @MainActor func refreshSources() async {
        sourceMenu.removeAllItems()
        let virtual = item("Virtual Display (extra monitor)", #selector(pickSource(_:)))
        virtual.representedObject = ["virtual", UInt32(0)]
        virtual.state = settings.sourceKind == "virtual" ? .on : .off
        sourceMenu.addItem(virtual)
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
        case "virtual":
            if monitor == nil { createMonitor() } else { source = .display(monitor!.displayID) }
        case "display":
            monitor = nil
            source = .display(id)
        default:
            monitor = nil
            source = .window(id)
        }
        if let source { Task { await capture.start(source) } }
        renderer?.recenter()
    }

    @objc func pickResolution(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let r = VirtualMonitor.Resolution.allCases.first(where: { "\($0)" == raw }) else { return }
        settings.resolution = r
        applyResolution()
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

    @objc func calibrate() {
        imu.calibrateOnTable()
        renderer?.show("Put the glasses on a flat surface and don't touch them", seconds: 4)
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

    @objc func toggleAirPods() {
        setting({ settings.useAirPods.toggle() }, settings.useAirPods ? "AirPods head tracking off" : "AirPods head tracking on — turn your head a bit")
        if settings.useAirPods { headphones.start() } else { headphones.stop() }
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
