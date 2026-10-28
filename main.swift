// RayNeoPin — 3DoF spatially pinned screen for RayNeo Air 4 Pro on macOS.
//
// Reads the glasses' IMU over USB HID (protocol from verncat/RayNeo-Air-3S-Pro-OpenVR:
// host->glasses frames start with 0x66, glasses->host with 0x99, IMU frames are type 0x65),
// captures a Mac display or window with ScreenCaptureKit and draws it on the glasses
// display as a plane that stays fixed in space while the head turns.
//
//   RayNeoPin.app            menu bar app (eyeglasses icon)
//   RayNeoPin --imu-test     print orientation to the terminal, no rendering

import AppKit
import Carbon.HIToolbox
import CoreMedia
import IOKit.hid
import QuartzCore
import ScreenCaptureKit
import simd

// MARK: - Settings

final class Settings {
    private let d = UserDefaults.standard
    var zoom: Double { get { d.object(forKey: "zoom") as? Double ?? 1.0 } set { d.set(newValue, forKey: "zoom") } }
    /// Diagonal field of view of the glasses. Wrong values make the screen "swim" when turning.
    var fovDiagonal: Double { get { d.object(forKey: "fov") as? Double ?? 46.0 } set { d.set(newValue, forKey: "fov") } }
    var yawOnly: Bool { get { d.bool(forKey: "yawOnly") } set { d.set(newValue, forKey: "yawOnly") } }
    /// Motion-to-photon compensation, seconds.
    var prediction: Double { get { d.object(forKey: "prediction") as? Double ?? 0.015 } set { d.set(newValue, forKey: "prediction") } }
}

// MARK: - Sensor fusion

/// Mahony-style complementary filter. Device frame: x right, y up, z back (toward the face).
struct Fusion {
    var q = simd_quatd(ix: 0, iy: 0, iz: 0, r: 1) // device -> world
    var bias = SIMD3<Double>.zero
    var omega = SIMD3<Double>.zero // bias-corrected angular velocity, rad/s
    var calibrated = false
    var calibrationProgress: Double { Double(calN) / Double(Fusion.calSamples) }

    static let calSamples = 600
    private var initialized = false
    private var calSum = SIMD3<Double>.zero
    private var calN = 0
    private var stillN = 0
    private var lastTick: UInt32 = 0
    private let kp = 0.5

    mutating func update(acc: SIMD3<Double>, gyro: SIMD3<Double>, tick: UInt32) {
        if !initialized {
            guard simd_length(acc) > 1 else { return }
            q = simd_quatd(from: simd_normalize(acc), to: SIMD3(0, 1, 0))
            initialized = true
            lastTick = tick
            return
        }
        guard tick != lastTick else { return } // the glasses resend the last sample when idle
        var dt = Double(tick &- lastTick) * 1e-4 // tick unit is 100 µs
        lastTick = tick
        if dt <= 0 || dt > 0.05 { dt = 0.002 }

        if !calibrated {
            if simd_length(gyro) > 0.15 { calSum = .zero; calN = 0; return } // moving: start over
            calSum += gyro
            calN += 1
            if calN >= Fusion.calSamples {
                bias = calSum / Double(calN)
                calibrated = true
            }
            return
        }

        let w = gyro - bias
        omega = w

        // Slowly track gyro bias drift while the head is really still.
        stillN = simd_length(w) < 0.02 ? stillN + 1 : 0
        if stillN > 500 { bias += (gyro - bias) * 0.0005 }

        // Pull pitch/roll toward gravity; yaw is gyro-only.
        var wc = w
        let an = simd_length(acc)
        if an > 7, an < 12.5 {
            let measuredUp = acc / an
            let estimatedUp = q.inverse.act(SIMD3(0, 1, 0))
            wc += kp * simd_cross(measuredUp, estimatedUp)
        }
        let angle = simd_length(wc) * dt
        if angle > 1e-12 {
            q = simd_normalize(q * simd_quatd(angle: angle, axis: wc / simd_length(wc)))
        }
    }
}

// MARK: - IMU (USB HID)

final class IMU {
    struct Snapshot { var q: simd_quatd; var omega: SIMD3<Double>; var calibrated: Bool; var progress: Double; var connected: Bool }

    private var manager: IOHIDManager!
    private var device: IOHIDDevice?
    private var fusion = Fusion()
    private let lock = NSLock()
    private var connected = false
    private var lastSample = Date.distantPast
    private(set) var samples = 0

    func start() {
        let thread = Thread { [self] in
            manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
            IOHIDManagerSetDeviceMatching(manager, [
                kIOHIDVendorIDKey: 0x1BBB, kIOHIDProductIDKey: 0xAF50, kIOHIDPrimaryUsagePageKey: 0xFF00,
            ] as CFDictionary)
            let ctx = Unmanaged.passUnretained(self).toOpaque()
            IOHIDManagerRegisterDeviceMatchingCallback(manager, { ctx, _, _, dev in
                Unmanaged<IMU>.fromOpaque(ctx!).takeUnretainedValue().attach(dev)
            }, ctx)
            IOHIDManagerRegisterDeviceRemovalCallback(manager, { ctx, _, _, _ in
                Unmanaged<IMU>.fromOpaque(ctx!).takeUnretainedValue().detach()
            }, ctx)
            IOHIDManagerRegisterInputReportCallback(manager, { ctx, _, _, _, _, report, len in
                Unmanaged<IMU>.fromOpaque(ctx!).takeUnretainedValue().handle(report, len)
            }, ctx)
            IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
            IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))

            // Watchdog: the stream stops after the glasses sleep; ask again.
            let timer = Timer(timeInterval: 1, repeats: true) { [self] _ in
                if device != nil, Date().timeIntervalSince(lastSample) > 1.5 { send(command: 0x01) }
            }
            RunLoop.current.add(timer, forMode: .default)
            CFRunLoopRun()
        }
        thread.qualityOfService = .userInteractive
        thread.name = "RayNeo IMU"
        thread.start()
    }

    func stop() {
        send(command: 0x02) // IMU off, as we found it
    }

    func snapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        return Snapshot(q: fusion.q, omega: fusion.omega, calibrated: fusion.calibrated,
                        progress: fusion.calibrationProgress, connected: connected)
    }

    func recalibrate() {
        lock.lock(); fusion = Fusion(); lock.unlock()
    }

    private func attach(_ dev: IOHIDDevice) {
        device = dev
        lock.lock(); connected = true; lock.unlock()
        send(command: 0x01) // IMU on
    }

    private func detach() {
        device = nil
        lock.lock(); connected = false; fusion = Fusion(); lock.unlock()
    }

    private func send(command: UInt8, value: UInt8 = 0) {
        guard let device else { return }
        var frame = [UInt8](repeating: 0, count: 64)
        frame[0] = 0x66
        frame[1] = command
        frame[2] = value
        IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 0, frame, 64)
    }

    private func handle(_ r: UnsafeMutablePointer<UInt8>, _ len: CFIndex) {
        guard len >= 64, r[0] == 0x99 else { return }
        switch r[1] {
        case 0x65:
            let raw = UnsafeRawPointer(r)
            func f(_ o: Int) -> Double { Double(raw.loadUnaligned(fromByteOffset: o, as: Float32.self)) }
            let acc = SIMD3(f(4), f(8), f(12))
            let gyro = SIMD3(f(16), f(20), f(24)) * (.pi / 180) // deg/s -> rad/s
            let tick = raw.loadUnaligned(fromByteOffset: 40, as: UInt32.self)
            lastSample = Date()
            samples += 1
            lock.lock(); fusion.update(acc: acc, gyro: gyro, tick: tick); lock.unlock()
        case 0x42: // wake notify
            send(command: 0x01)
        default:
            break
        }
    }
}

// MARK: - Orientation helpers

extension simd_quatd {
    /// Yaw/pitch of the forward (-z) axis, ignoring roll.
    var yawPitch: (yaw: Double, pitch: Double) {
        let f = act(SIMD3(0, 0, -1))
        return (atan2(-f.x, -f.z), asin(max(-1, min(1, f.y))))
    }

    static func yawPitch(_ yaw: Double, _ pitch: Double) -> simd_quatd {
        simd_quatd(angle: yaw, axis: SIMD3(0, 1, 0)) * simd_quatd(angle: pitch, axis: SIMD3(1, 0, 0))
    }
}

func degrees(_ r: Double) -> Double { r * 180 / .pi }

// MARK: - Capture

enum Source: Equatable {
    case display(CGDirectDisplayID)
    case window(CGWindowID)
}

final class Capture: NSObject, SCStreamOutput, SCStreamDelegate {
    var onFrame: ((IOSurface, CGSize) -> Void)?
    var onError: ((String) -> Void)?
    var onStarted: (() -> Void)?
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "capture", qos: .userInteractive)

    func start(_ source: Source) async {
        await stopStream()
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            let filter: SCContentFilter
            var pixelSize: CGSize
            switch source {
            case .display(let id):
                guard let display = content.displays.first(where: { $0.displayID == id }) ?? content.displays.first
                else { onError?("No hay pantallas para capturar"); return }
                filter = SCContentFilter(display: display, excludingWindows: [])
                let mode = CGDisplayCopyDisplayMode(display.displayID)
                pixelSize = CGSize(width: mode?.pixelWidth ?? display.width, height: mode?.pixelHeight ?? display.height)
            case .window(let id):
                guard let window = content.windows.first(where: { $0.windowID == id })
                else { onError?("La ventana ya no existe"); return }
                filter = SCContentFilter(desktopIndependentWindow: window)
                pixelSize = CGSize(width: window.frame.width * 2, height: window.frame.height * 2)
            }
            let cap = 2560.0 // glasses are 1920 wide; more is wasted bandwidth
            if pixelSize.width > cap { pixelSize = CGSize(width: cap, height: (pixelSize.height * cap / pixelSize.width).rounded()) }

            let config = SCStreamConfiguration()
            config.width = Int(pixelSize.width)
            config.height = Int(pixelSize.height)
            config.pixelFormat = kCVPixelFormatType_32BGRA
            config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
            config.queueDepth = 6
            config.showsCursor = true
            config.scalesToFit = true

            let stream = SCStream(filter: filter, configuration: config, delegate: self)
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            try await stream.startCapture()
            self.stream = stream
            DispatchQueue.main.async { self.onStarted?() }
        } catch {
            onError?("Captura: \(error.localizedDescription)")
        }
    }

    func stopStream() async {
        if let stream { try? await stream.stopCapture() }
        stream = nil
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let status = attachments.first?[.status] as? Int, status == SCFrameStatus.complete.rawValue,
              let pb = CMSampleBufferGetImageBuffer(sb),
              let surface = CVPixelBufferGetIOSurface(pb)?.takeUnretainedValue()
        else { return }
        let size = CGSize(width: CVPixelBufferGetWidth(pb), height: CVPixelBufferGetHeight(pb))
        let s = unsafeBitCast(surface, to: IOSurface.self)
        DispatchQueue.main.async { self.onFrame?(s, size) }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { self.onError?("Captura detenida: \(error.localizedDescription)") }
    }
}

// MARK: - Renderer (window on the glasses display)

final class Renderer: NSObject {
    let window: NSWindow
    private let stage = CALayer()
    private let screenLayer = CALayer()
    private let hud = CATextLayer()
    private let imu: IMU
    private let settings: Settings
    private var anchor = simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)
    private var needsRecenter = true
    private var wasCalibrated = false
    private var aspect = 16.0 / 9.0
    private var hudUntil = Date.distantPast
    /// Shown until cleared, e.g. a missing permission.
    var notice: String?
    var paused = false { didSet { if !paused { needsRecenter = true } } }

    init(screen: NSScreen, imu: IMU, settings: Settings) {
        self.imu = imu
        self.settings = settings
        window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false, screen: screen)
        super.init()
        window.setFrame(screen.frame, display: true)
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        window.ignoresMouseEvents = true
        window.backgroundColor = .black // black is transparent on the optics
        window.isOpaque = true
        // RAYNEOPIN_DEBUG=1 lets screenshots see the glasses window.
        window.sharingType = ProcessInfo.processInfo.environment["RAYNEOPIN_DEBUG"] == nil ? .none : .readOnly
        window.hasShadow = false

        let view = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.wantsLayer = true
        view.layer!.backgroundColor = NSColor.black.cgColor
        window.contentView = view

        stage.frame = view.bounds
        stage.masksToBounds = true
        view.layer!.addSublayer(stage)

        screenLayer.position = CGPoint(x: stage.bounds.midX, y: stage.bounds.midY)
        screenLayer.contentsGravity = .resizeAspect
        screenLayer.minificationFilter = .linear
        screenLayer.magnificationFilter = .linear
        screenLayer.isDoubleSided = false
        screenLayer.edgeAntialiasingMask = [.layerLeftEdge, .layerRightEdge, .layerTopEdge, .layerBottomEdge]
        screenLayer.allowsEdgeAntialiasing = true
        screenLayer.backgroundColor = NSColor(white: 0.08, alpha: 1).cgColor
        stage.addSublayer(screenLayer)

        hud.fontSize = 26
        hud.alignmentMode = .center
        hud.foregroundColor = NSColor(white: 0.9, alpha: 1).cgColor
        hud.contentsScale = screen.backingScaleFactor
        hud.frame = CGRect(x: 0, y: 40, width: view.bounds.width, height: 80)
        hud.isWrapped = true
        view.layer!.addSublayer(hud)

        layoutScreen()
        window.orderFrontRegardless()

        let link = view.displayLink(target: self, selector: #selector(frame(_:)))
        link.add(to: .main, forMode: .common)
    }

    func show(_ message: String, seconds: Double = 3) {
        hud.string = message
        hudUntil = Date().addingTimeInterval(seconds)
    }

    func recenter() { needsRecenter = true }

    func setFrame(_ surface: IOSurface, size: CGSize) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        screenLayer.contents = surface
        let a = size.width / max(size.height, 1)
        if abs(a - aspect) > 0.001 { aspect = a; layoutScreen() }
        CATransaction.commit()
    }

    func layoutScreen() {
        let w = 1600 * settings.zoom
        screenLayer.bounds = CGRect(x: 0, y: 0, width: w, height: w / aspect)
        var p = CATransform3DIdentity
        p.m34 = -1 / focalLength
        stage.sublayerTransform = p
    }

    /// Distance from eye to the stage plane in points, derived from the glasses' FOV.
    private var focalLength: Double {
        let w = stage.bounds.width, h = stage.bounds.height
        let halfDiag = tan(settings.fovDiagonal * .pi / 360)
        let halfW = halfDiag * w / sqrt(w * w + h * h)
        return (w / 2) / halfW
    }

    @objc private func frame(_ link: CADisplayLink) {
        let s = imu.snapshot()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        if Date() > hudUntil {
            hud.string = notice ?? (!s.connected ? "Gafas no detectadas (USB)"
                : !s.calibrated ? "Calibrando… no muevas la cabeza (\(Int(s.progress * 100))%)" : "")
        }
        guard s.connected, s.calibrated, !paused else {
            screenLayer.transform = CATransform3DIdentity
            screenLayer.isHidden = false
            wasCalibrated = s.calibrated
            return
        }
        if !wasCalibrated { needsRecenter = true; wasCalibrated = true }

        var q = s.q
        let wl = simd_length(s.omega)
        if wl > 1e-9 { q = q * simd_quatd(angle: wl * settings.prediction, axis: s.omega / wl) }
        if needsRecenter {
            let yp = q.yawPitch
            anchor = .yawPitch(yp.yaw, settings.yawOnly ? 0 : yp.pitch)
            needsRecenter = false
        }
        var rel = anchor.inverse * q // head orientation in the anchor frame
        if settings.yawOnly { rel = .yawPitch(rel.yawPitch.yaw, 0) }

        let m = simd_double3x3(rel) // column-major: m[col][row]
        let f = focalLength

        // Hide when part of the plane would end up behind the eye.
        let hw = screenLayer.bounds.width / 2, hh = screenLayer.bounds.height / 2
        let corners = [SIMD3(-hw, -hh, -f), SIMD3(hw, -hh, -f), SIMD3(-hw, hh, -f), SIMD3(hw, hh, -f)]
        screenLayer.isHidden = corners.contains { (m.transpose * $0).z > -0.05 * f }

        // Core Animation uses row vectors, so the camera rotation (M^T) appears as M.
        var r = CATransform3DIdentity
        r.m11 = m[0][0]; r.m12 = m[1][0]; r.m13 = m[2][0]
        r.m21 = m[0][1]; r.m22 = m[1][1]; r.m23 = m[2][1]
        r.m31 = m[0][2]; r.m32 = m[1][2]; r.m33 = m[2][2]
        // Rotate about the eye (at z = +f), not about the plane's center.
        screenLayer.transform = CATransform3DConcat(CATransform3DConcat(CATransform3DMakeTranslation(0, 0, -f), r),
                                                    CATransform3DMakeTranslation(0, 0, f))
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
    let imu = IMU()
    let settings = Settings()
    let capture = Capture()
    var renderer: Renderer?
    var statusItem: NSStatusItem!
    var source: Source = .display(CGMainDisplayID())
    let sourceMenu = NSMenu()
    var pauseItem: NSMenuItem!
    var yawItem: NSMenuItem!

    func applicationDidFinishLaunching(_ note: Notification) {
        imu.start()
        buildMenu()
        installHotKeys([
            (kVK_ANSI_R, { [weak self] in self?.recenter() }),
            (kVK_ANSI_T, { [weak self] in self?.togglePause() }),
            (kVK_ANSI_Y, { [weak self] in self?.toggleYawOnly() }),
            (kVK_ANSI_Equal, { [weak self] in self?.zoom(1.1) }),
            (kVK_ANSI_Minus, { [weak self] in self?.zoom(1 / 1.1) }),
            (kVK_ANSI_RightBracket, { [weak self] in self?.fov(1) }),
            (kVK_ANSI_LeftBracket, { [weak self] in self?.fov(-1) }),
            (kVK_ANSI_Q, { NSApp.terminate(nil) }),
        ])
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in self?.setUpRenderer() }
        capture.onFrame = { [weak self] surface, size in self?.renderer?.setFrame(surface, size: size) }
        capture.onError = { [weak self] msg in
            NSLog("%@", msg)
            if CGPreflightScreenCaptureAccess() { self?.renderer?.show(msg, seconds: 8) } else { self?.permissionMissing() }
        }
        capture.onStarted = { [weak self] in
            self?.renderer?.notice = nil
            self?.retryTimer?.invalidate()
            self?.retryTimer = nil
        }

        if !CGPreflightScreenCaptureAccess() { CGRequestScreenCaptureAccess() }
        setUpRenderer()
    }

    func applicationWillTerminate(_ note: Notification) { imu.stop() }

    var retryTimer: Timer?
    var openedSettings = false

    /// Without Screen Recording permission the glasses would stay black; say so on them and keep retrying.
    func permissionMissing() {
        renderer?.notice = "Falta permiso: Ajustes › Privacidad y seguridad › Grabación de pantalla › activá RayNeoPin"
        if !openedSettings {
            openedSettings = true
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        }
        if retryTimer == nil {
            retryTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
                guard let self else { return }
                Task { await self.capture.start(self.source) }
            }
        }
    }

    /// Pulls the latest source, rebuilds, reinstalls and relaunches (see install.sh).
    @objc func update() {
        let script = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/RayNeoPin/src/install.sh").path
        guard FileManager.default.fileExists(atPath: script) else {
            renderer?.show("Instalá con install.sh para poder actualizar desde el menú", seconds: 5)
            return
        }
        renderer?.show("Buscando actualización…", seconds: 60)
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
                self?.renderer?.show(p.terminationStatus == 0 ? "Ya tenés la última versión"
                                     : "Error al actualizar (ver ~/Library/Logs/RayNeoPin-update.log)", seconds: 5)
            }
        }
        try? p.run()
    }

    static func glassesScreen() -> NSScreen? {
        NSScreen.screens.first {
            let n = $0.localizedName.lowercased()
            return n.contains("smartglasses") || n.contains("rayneo")
        }
    }

    func setUpRenderer() {
        guard let screen = AppDelegate.glassesScreen() else {
            renderer?.window.orderOut(nil)
            renderer = nil
            return
        }
        let glassesID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        if renderer?.window.screen != screen {
            renderer?.window.orderOut(nil)
            renderer = Renderer(screen: screen, imu: imu, settings: settings)
            renderer?.show("RayNeoPin — ⌃⌥R recentrar · ⌃⌥ +/- zoom · ⌃⌥Q salir", seconds: 6)
        }
        // Never mirror the glasses into themselves: default to the built-in display.
        if case .display(let id) = source, id == glassesID || renderer != nil && id == CGMainDisplayID() {
            let builtin = NSScreen.screens.compactMap { $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID }
                .first { CGDisplayIsBuiltin($0) != 0 && $0 != glassesID }
            source = .display(builtin ?? CGMainDisplayID())
        }
        Task { await capture.start(source) }
    }

    // MARK: Menu

    func buildMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "eyeglasses", accessibilityDescription: "RayNeoPin")
        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(item("Recentrar  ⌃⌥R", #selector(recenter)))
        menu.addItem(item("Recalibrar giroscopio", #selector(recalibrate)))
        pauseItem = item("Pausar tracking  ⌃⌥T", #selector(togglePause))
        menu.addItem(pauseItem)
        yawItem = item("Solo horizontal (sin pitch/roll)  ⌃⌥Y", #selector(toggleYawOnly))
        menu.addItem(yawItem)
        menu.addItem(.separator())
        menu.addItem(item("Agrandar  ⌃⌥=", #selector(zoomIn)))
        menu.addItem(item("Achicar  ⌃⌥-", #selector(zoomOut)))
        menu.addItem(item("FOV +1°  ⌃⌥]", #selector(fovUp)))
        menu.addItem(item("FOV −1°  ⌃⌥[", #selector(fovDown)))
        menu.addItem(.separator())
        let src = NSMenuItem(title: "Fuente", action: nil, keyEquivalent: "")
        src.submenu = sourceMenu
        menu.addItem(src)
        menu.addItem(.separator())
        menu.addItem(item("Buscar actualización…", #selector(update)))
        menu.addItem(item("Salir  ⌃⌥Q", #selector(NSApp.terminate(_:)), target: NSApp))
        statusItem.menu = menu
    }

    func item(_ title: String, _ action: Selector, target: AnyObject? = nil) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
        i.target = target ?? self
        return i
    }

    func menuWillOpen(_ menu: NSMenu) {
        pauseItem.state = renderer?.paused == true ? .on : .off
        yawItem.state = settings.yawOnly ? .on : .off
        Task { @MainActor in await refreshSources() }
    }

    @MainActor func refreshSources() async {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true) else {
            sourceMenu.removeAllItems()
            sourceMenu.addItem(NSMenuItem(title: "Falta permiso de Grabación de pantalla", action: nil, keyEquivalent: ""))
            return
        }
        let glassesID = AppDelegate.glassesScreen()?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        sourceMenu.removeAllItems()
        for d in content.displays where d.displayID != glassesID {
            let name = NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == d.displayID }?.localizedName ?? "Pantalla \(d.displayID)"
            let i = NSMenuItem(title: "🖥  \(name)", action: #selector(pickSource(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = ["display", d.displayID]
            i.state = source == .display(d.displayID) ? .on : .off
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
            let i = NSMenuItem(title: "▢  \(title.prefix(70))", action: #selector(pickSource(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = ["window", w.windowID]
            i.state = source == .window(w.windowID) ? .on : .off
            sourceMenu.addItem(i)
        }
    }

    @objc func pickSource(_ sender: NSMenuItem) {
        guard let rep = sender.representedObject as? [Any], let kind = rep.first as? String, let id = rep.last as? UInt32 else { return }
        source = kind == "display" ? .display(id) : .window(id)
        Task { await capture.start(source) }
        renderer?.recenter()
    }

    @objc func recenter() { renderer?.recenter(); renderer?.show("Recentrado", seconds: 1) }
    @objc func recalibrate() { imu.recalibrate() }
    @objc func togglePause() {
        guard let r = renderer else { return }
        r.paused.toggle()
        r.show(r.paused ? "Tracking en pausa (pantalla fija a la cabeza)" : "Tracking activo", seconds: 2)
    }
    @objc func toggleYawOnly() {
        settings.yawOnly.toggle()
        renderer?.recenter()
        renderer?.show(settings.yawOnly ? "Solo horizontal" : "3DoF completo", seconds: 2)
    }
    @objc func zoomIn() { zoom(1.1) }
    @objc func zoomOut() { zoom(1 / 1.1) }
    @objc func fovUp() { fov(1) }
    @objc func fovDown() { fov(-1) }

    func zoom(_ k: Double) {
        settings.zoom = min(3, max(0.3, settings.zoom * k))
        renderer?.layoutScreen()
        renderer?.show(String(format: "Zoom %.0f%%", settings.zoom * 100), seconds: 1)
    }

    func fov(_ delta: Double) {
        settings.fovDiagonal = min(70, max(25, settings.fovDiagonal + delta))
        renderer?.layoutScreen()
        renderer?.show(String(format: "FOV %.0f°", settings.fovDiagonal), seconds: 1)
    }
}

// MARK: - Entry point

if CommandLine.arguments.contains("--imu-test") {
    setvbuf(stdout, nil, _IOLBF, 0)
    let imu = IMU()
    imu.start()
    print("Leyendo IMU — quedate quieto ~1 s para calibrar. Ctrl+C para salir.")
    var anchor: simd_quatd?
    Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
        let s = imu.snapshot()
        guard s.connected else { print("sin gafas"); return }
        guard s.calibrated else { print(String(format: "calibrando %3.0f%%", s.progress * 100)); return }
        if anchor == nil { let yp = s.q.yawPitch; anchor = .yawPitch(yp.yaw, yp.pitch) }
        let rel = anchor!.inverse * s.q
        let yp = rel.yawPitch
        let up = rel.inverse.act(SIMD3(0, 1, 0))
        let roll = atan2(up.x, up.y)
        print(String(format: "yaw %+7.1f°  pitch %+6.1f°  roll %+6.1f°   (%d muestras)",
                     degrees(yp.yaw), degrees(yp.pitch), degrees(roll), imu.samples))
    }
    RunLoop.main.run()
} else {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
