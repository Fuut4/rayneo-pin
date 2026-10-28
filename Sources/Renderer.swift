// Metal renderer on the glasses display: draws the captured frame as a quad fixed in space.
//
// Runs on its own thread, driven by the glasses' vsync (120 Hz). Ideas taken from AirAnchor
// (jief123/AirAnchor): mipmapped sRGB sampling against moiré, motion-adaptive pose smoothing,
// and slow gaze-based recentering to absorb residual yaw drift.

import AppKit
import CoreVideo
import Metal
import QuartzCore
import simd

enum TrackingMode: String, CaseIterable {
    case glasses, airpods, both

    var title: String {
        switch self {
        case .glasses: return "Glasses Only"
        case .airpods: return "AirPods Only"
        case .both: return "Glasses + AirPods (recommended)"
        }
    }
}

final class Renderer: NSObject {
    struct Params {
        var zoom = 1.0
        var fovDiagonal = 46.0
        var lockYaw = false // a locked axis follows the head instead of staying fixed in space
        var lockPitch = false
        var lockRoll = false
        var autoRecenter = false
        var steady = true
        var sharpness = 0.5
        var tracking = TrackingMode.both
        var paused = false
        var developer = false
    }

    /// Fraction of the view width the screen covers at zoom 1.
    static let baseWidth = 0.83

    let window: NSWindow
    let displayID: CGDirectDisplayID
    private let metalLayer = CAMetalLayer()
    private let hud = CATextLayer()
    private let devLayer = CATextLayer()
    /// Developer overlay text, delivered on the main thread (~10 Hz) for the Mac-side panel.
    var onDeveloperText: ((String) -> Void)?
    private let imu: IMU
    private let capture: Capture
    private let headphones: Headphones

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let sampler: MTLSamplerState
    private var textureCache: CVMetalTextureCache?
    private var mipTexture: MTLTexture?
    private var lastSerial = -1
    private var aspect = 16.0 / 9.0

    private let lock = NSLock()
    private var params = Params()
    private var recenterRequested = true
    private var airPodsResetRequested = false
    private var developerDisplayInfo = "" // built on the main thread (NSScreen isn't thread-safe)
    private var notice: String?
    private var toast: (text: String, until: Date)?
    private var shownHUD = ""
    private var airPodsActive = false

    // Render-thread state
    private var link: CADisplayLink?
    private var thread: Thread?
    private var anchor = simd_quatd.identity
    private var smoothed = simd_quatd.identity
    private var steadyPose = simd_quatd.identity
    private var heading = HeadingReference()
    private var calibration = AirPodsCalibration()
    private var airPodsNote = "" // why AirPods aren't used right now, for the HUD
    private var devAirPodsDelay = 0.0
    private var devYawGap: Double?
    private var hasPose = false
    private var zoom = 1.0
    private var gazeYawAvg = 0.0
    private var lastTime: CFTimeInterval = 0
    private var frameTime = 1.0 / 120
    private var prediction = 0.014

    // Developer overlay state (render thread)
    private var devFrames = 0
    private var devCaptureFrames = 0
    private var devWindowStart: CFTimeInterval = 0
    private var devFPS = 0.0
    private var devCaptureFPS = 0.0
    private var devCPU = 0.0
    private var devLastUpdate: CFTimeInterval = 0
    private var devHead = simd_quatd.identity
    private var devSteadyDelta = 0.0
    private var devCaptureSize = CGSize.zero
    private var devShown = false

    private static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    struct VOut { float4 position [[position]]; float2 uv; };
    // mvp[0] is predicted for when the top row lights up, mvp[1] for the bottom row (the panel
    // scans out top to bottom); each vertex blends by where it lands on screen.
    vertex VOut vs(uint vid [[vertex_id]], constant float4x4 *mvp [[buffer(0)]]) {
        float2 c[4] = { float2(-0.5, -0.5), float2(0.5, -0.5), float2(-0.5, 0.5), float2(0.5, 0.5) };
        VOut o;
        float4 top = mvp[0] * float4(c[vid], 0, 1);
        float4 bottom = mvp[1] * float4(c[vid], 0, 1);
        float row = top.w > 0.0001 ? clamp(0.5 - 0.5 * top.y / top.w, 0.0, 1.0) : 0.0;
        o.position = mix(top, bottom, row);
        o.uv = float2(c[vid].x + 0.5, 0.5 - c[vid].y);
        return o;
    }
    // Unsharp mask in output-pixel units: restores edge contrast lost when the desktop is scaled down.
    fragment float4 fs(VOut in [[stage_in]], texture2d<float> tex [[texture(0)]], sampler s [[sampler(0)]],
                       constant float &sharpness [[buffer(0)]]) {
        float2 dx = dfdx(in.uv), dy = dfdy(in.uv);
        gradient2d g(dx, dy);
        float4 c = tex.sample(s, in.uv, g);
        if (sharpness <= 0.0) return c;
        float4 n = tex.sample(s, in.uv + dx, g) + tex.sample(s, in.uv - dx, g)
                 + tex.sample(s, in.uv + dy, g) + tex.sample(s, in.uv - dy, g);
        return clamp(c + sharpness * (c - 0.25 * n), 0.0, 1.0);
    }
    """

    init(screen: NSScreen, displayID: CGDirectDisplayID, imu: IMU, capture: Capture, headphones: Headphones) throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw NSError(domain: "RayNeoPin", code: 1, userInfo: [NSLocalizedDescriptionKey: "Metal unavailable"])
        }
        self.device = device
        self.queue = queue
        self.imu = imu
        self.capture = capture
        self.headphones = headphones
        self.displayID = displayID

        let library = try device.makeLibrary(source: Renderer.shader, options: nil)
        let pd = MTLRenderPipelineDescriptor()
        pd.vertexFunction = library.makeFunction(name: "vs")
        pd.fragmentFunction = library.makeFunction(name: "fs")
        pd.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb
        pipeline = try device.makeRenderPipelineState(descriptor: pd)

        let sd = MTLSamplerDescriptor()
        sd.minFilter = .linear
        sd.magFilter = .linear
        sd.mipFilter = .linear
        sd.maxAnisotropy = 8
        sd.sAddressMode = .clampToEdge
        sd.tAddressMode = .clampToEdge
        sampler = device.makeSamplerState(descriptor: sd)!
        CVMetalTextureCacheCreate(nil, nil, device, nil, &textureCache)

        // With `screen:` the rect is relative to that screen; the global frame is set right after.
        window = NSWindow(contentRect: NSRect(origin: .zero, size: screen.frame.size), styleMask: .borderless,
                          backing: .buffered, defer: false, screen: screen)
        super.init()
        window.setFrame(screen.frame, display: true)
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        window.ignoresMouseEvents = true
        window.backgroundColor = .black // black is transparent on the optics
        window.isOpaque = true
        window.hasShadow = false
        // RAYNEOPIN_DEBUG=1 lets screenshots see the glasses window.
        window.sharingType = ProcessInfo.processInfo.environment["RAYNEOPIN_DEBUG"] == nil ? .none : .readOnly

        let view = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.wantsLayer = true
        view.layer!.backgroundColor = NSColor.black.cgColor
        window.contentView = view

        let scale = screen.backingScaleFactor
        metalLayer.device = device
        metalLayer.pixelFormat = .bgra8Unorm_srgb
        metalLayer.framebufferOnly = true
        metalLayer.displaySyncEnabled = true // no tearing
        metalLayer.maximumDrawableCount = 2 // one frame less queued latency than the default 3
        metalLayer.isOpaque = true
        metalLayer.contentsScale = scale
        metalLayer.frame = view.bounds
        metalLayer.drawableSize = CGSize(width: view.bounds.width * scale, height: view.bounds.height * scale)
        view.layer!.addSublayer(metalLayer)

        hud.fontSize = 24
        hud.alignmentMode = .center
        hud.foregroundColor = NSColor(white: 0.9, alpha: 1).cgColor
        hud.contentsScale = scale
        hud.isWrapped = true
        hud.frame = CGRect(x: 60, y: 40, width: view.bounds.width - 120, height: 70)
        view.layer!.addSublayer(hud)

        devLayer.font = NSFont.monospacedSystemFont(ofSize: 14, weight: .medium)
        devLayer.fontSize = 14
        devLayer.foregroundColor = NSColor(white: 0.95, alpha: 1).cgColor
        devLayer.backgroundColor = NSColor(white: 0.12, alpha: 0.9).cgColor
        devLayer.cornerRadius = 8
        devLayer.contentsScale = scale
        devLayer.isWrapped = false
        devLayer.frame = CGRect(x: 130, y: view.bounds.height - 110 - 560, width: 1180, height: 560)
        devLayer.isHidden = true
        view.layer!.addSublayer(devLayer)

        window.orderFrontRegardless()

        let link = view.displayLink(target: self, selector: #selector(frame(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        self.link = link
        let thread = Thread { [weak self] in
            guard let link = self?.link else { return }
            link.add(to: .current, forMode: .default)
            while !Thread.current.isCancelled { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5)) }
        }
        thread.qualityOfService = .userInteractive
        thread.name = "RayNeoPin render"
        thread.start()
        self.thread = thread
    }

    /// macOS moves windows to the main display when the glasses reconfigure (e.g. the 120 Hz switch);
    /// put ours back.
    func keepOn(_ screen: NSScreen) {
        guard window.frame != screen.frame || !window.isVisible else { return }
        window.setFrame(screen.frame, display: true)
        window.orderFrontRegardless()
    }

    func shutdown() {
        link?.invalidate()
        thread?.cancel()
        window.orderOut(nil)
    }

    // MARK: Main-thread API

    func update(_ change: (inout Params) -> Void) {
        lock.lock(); change(&params); lock.unlock()
    }

    var currentParams: Params {
        lock.lock(); defer { lock.unlock() }
        return params
    }

    /// True once AirPods headings are actually correcting the glasses.
    var isUsingAirPods: Bool {
        lock.lock(); defer { lock.unlock() }
        return airPodsActive
    }

    func recenter() {
        lock.lock(); recenterRequested = true; lock.unlock()
    }

    func setDeveloperDisplayInfo(_ text: String) {
        lock.lock(); developerDisplayInfo = text; lock.unlock()
    }

    private var airPodsSeed: AirPodsCalibration.Saved?
    private var airPodsSaved: AirPodsCalibration.Saved?

    /// A previous session's calibration for the current AirPods.
    func seedAirPods(_ s: AirPodsCalibration.Saved) {
        lock.lock(); airPodsSeed = s; lock.unlock()
    }

    /// The calibration worth saving, once good enough.
    var airPodsCalibration: AirPodsCalibration.Saved? {
        lock.lock(); defer { lock.unlock() }
        return airPodsSaved
    }

    /// Start learning the AirPods ↔ glasses relationship from scratch (e.g. other AirPods).
    func recalibrateAirPods() {
        lock.lock(); airPodsResetRequested = true; lock.unlock()
    }

    /// Persistent message (nil clears it), e.g. a missing permission.
    func setNotice(_ text: String?) {
        lock.lock(); notice = text; lock.unlock()
    }

    func show(_ text: String, seconds: Double = 2) {
        lock.lock(); toast = (text, Date().addingTimeInterval(seconds)); lock.unlock()
    }

    // MARK: Render thread

    @objc private func frame(_ link: CADisplayLink) {
        // Never touch `link` in here: during a display reconfiguration AppKit holds the link's lock
        // on the main thread while it waits for this callback to return (deadlock).
        // Wait for a free buffer *before* reading any pose (late latching): otherwise the pose is
        // a whole frame old by the time it is drawn.
        guard let drawable = metalLayer.nextDrawable() else { return }
        let frameStart = CACurrentMediaTime()
        let dt = lastTime > 0 ? min(frameStart - lastTime, 0.1) : 1 / 120
        lastTime = frameStart
        // Look-ahead as tuned in XRLinuxDriver for RayNeo: 10 ms + 0.45 × frame time, capped at 40 ms.
        frameTime += (dt - frameTime) * 0.05
        prediction = min(0.010 + 0.45 * frameTime, 0.040)

        lock.lock()
        let p = params
        let recenterNow = recenterRequested
        recenterRequested = false
        if airPodsResetRequested {
            airPodsResetRequested = false
            airPodsSeed = nil
            airPodsSaved = nil
            calibration.reset()
            heading = HeadingReference()
            devYawGap = nil
        }
        if let seed = airPodsSeed {
            airPodsSeed = nil
            calibration.reset()
            calibration.seed(seed)
        }
        airPodsSaved = calibration.saved ?? airPodsSaved
        let notice = notice
        if let t = toast, t.until < Date() { toast = nil }
        let toastText = toast?.text
        lock.unlock()

        let s = imu.snapshot()
        updateHUD(notice ?? toastText ?? status(s, p))

        // Pose source: the glasses' IMU, the AirPods, or the glasses corrected by the AirPods' heading.
        var airpods: Headphones.Sample?
        if p.tracking != .glasses {
            let fresh = headphones.drain()
            calibration.ingest(fresh, glasses: imu.pose(at:))
            airpods = headphones.latest()
            if p.tracking == .both, calibration.ready {
                // Compare headings at the instant each AirPods sample was measured, so Bluetooth
                // latency doesn't show up as a heading difference.
                for f in fresh {
                    guard let ap = calibration.pose(f), let g = imu.pose(at: calibration.glassesTime(f)) else { continue }
                    heading.update(glasses: g.q.yawPitch.yaw, airpods: ap.yawPitch.yaw, dt: 1 / max(headphones.stats.rate, 10))
                    devYawGap = wrapAngle(g.q.yawPitch.yaw - ap.yawPitch.yaw)
                }
            }
            if let airpods { devAirPodsDelay = CACurrentMediaTime() - airpods.time }
        }
        airPodsNote = p.tracking == .glasses ? ""
            : airpods == nil ? "AirPods: no data — using glasses"
            : !calibration.ready ? "AirPods: calibrating — turn your head left/right and nod (using glasses meanwhile)"
            : ""

        var pose: simd_quatd?
        var omega = SIMD3<Double>.zero
        var usingAirPods = false
        if p.tracking == .airpods, let airpods, let q = calibration.pose(airpods) {
            omega = calibration.rate(airpods)
            // Bring the (late) Bluetooth sample up to now with the AirPods' own gyro.
            pose = q.extrapolated(omega, min(max(CACurrentMediaTime() - airpods.time, 0), 0.2))
            usingAirPods = true
        } else if s.ready {
            pose = s.q
            omega = s.omega
            if p.tracking == .both, calibration.ready, airpods != nil {
                pose = simd_quatd(angle: heading.correction, axis: SIMD3(0, 1, 0)) * s.q
                usingAirPods = true
            }
        }
        if usingAirPods != airPodsActive { lock.lock(); airPodsActive = usingAirPods; lock.unlock() }

        var head = simd_quatd.identity
        var headBottom = simd_quatd.identity
        if let pose, !p.paused {
            let speed = simd_length(omega)
            // Late-latched pose: sampled right before drawing, extrapolated over the display latency.
            let predicted = pose.extrapolated(omega, prediction)
            if recenterNow || !hasPose {
                let yp = predicted.yawPitch
                anchor = .yawPitch(yp.yaw, p.lockPitch ? 0 : yp.pitch)
                smoothed = predicted
                steadyPose = predicted
                gazeYawAvg = 0
                if !hasPose { heading.reset() }
                hasPose = true
            }
            // Heavy damping when still (no shimmering text), none while turning (no lag).
            let t = min(max((speed - 0.02) / 0.3, 0), 1)
            let still = min(dt / 0.25, 1)
            smoothed = simd_slerp(smoothed, predicted, still + (1 - still) * t)

            // Steady image: ignore movements under 0.1° (heartbeat, breathing) without ever jumping,
            // by only following once the pose leaves that radius.
            if p.steady {
                let d = (steadyPose.inverse * smoothed).angle
                let radius = 0.1 * .pi / 180
                let delta = min(d, 2 * .pi - d)
                if delta > radius { steadyPose = simd_slerp(steadyPose, smoothed, (delta - radius) / delta) }
            } else {
                steadyPose = smoothed
            }

            if p.autoRecenter { absorbDrift(anchor.inverse * steadyPose, dt) }
            head = applyLocks(anchor.inverse * steadyPose, p)
            // The bottom row lights up ~7 ms after the top one (XRLinuxDriver's RayNeo scanline value);
            // only while moving, so still images stay perfectly still.
            headBottom = applyLocks(anchor.inverse * steadyPose.extrapolated(omega, 0.007 * t), p)
            devSteadyDelta = (steadyPose.inverse * smoothed).angle
        } else if pose == nil {
            hasPose = false
        }

        zoom += (p.zoom - zoom) * min(dt / 0.08, 1)
        draw(drawable, head: head, headBottom: headBottom, params: p)
        devHead = head
        if p.developer { developerOverlay(s, airpods: airpods, pose: pose, usingAirPods: usingAirPods, p: p,
                                          cpu: CACurrentMediaTime() - frameStart, now: frameStart) }
        else if devShown { devShown = false; DispatchQueue.main.async { self.devLayer.isHidden = true } }
    }

    // MARK: Developer overlay

    private func developerOverlay(_ s: IMU.Snapshot, airpods: Headphones.Sample?,
                                  pose: simd_quatd?, usingAirPods: Bool, p: Params, cpu: Double, now: CFTimeInterval) {
        devFrames += 1
        devCPU = max(devCPU * 0.95, cpu)
        if devWindowStart == 0 { devWindowStart = now }
        if now - devWindowStart >= 1 {
            devFPS = Double(devFrames) / (now - devWindowStart)
            devCaptureFPS = Double(devCaptureFrames) / (now - devWindowStart)
            devFrames = 0
            devCaptureFrames = 0
            devWindowStart = now
        }
        guard now - devLastUpdate >= 0.1 else { return }
        devLastUpdate = now

        func d(_ r: Double) -> String { String(format: "%+7.2f", r * 180 / .pi) }
        func v(_ x: SIMD3<Double>, _ k: Double = 180 / .pi) -> String { String(format: "x %+7.2f  y %+7.2f  z %+7.2f", x.x * k, x.y * k, x.z * k) }
        func ypr(_ a: SIMD3<Double>) -> String { "yaw \(d(a.x))  pitch \(d(a.y))  roll \(d(a.z))" }
        func onOff(_ b: Bool) -> String { b ? "on" : "off" }

        let raw = imu.rawSnapshot()
        let state: String
        switch s.state {
        case .ready: state = "ready"
        case .calibrating(let x): state = "calibrating \(Int(x * 100))%"
        case .calibratingOnTable(let x): state = "table calibration \(Int(x * 100))%"
        }
        var lines: [String] = []
        lines.append(String(format: "RAYNEOPIN DEVELOPER   render %5.1f fps   frame work %.2f ms   tracking: %@",
                            devFPS, devCPU * 1000, p.tracking.title))
        lines.append("")
        lines.append("GLASSES IMU   " + (s.connected ? String(format: "%3.0f Hz · %@ · %.1f °C", raw.rate, state, raw.temperature) : "not connected"))
        lines.append("  gyro °/s    " + v(raw.gyro) + "   |ω| " + String(format: "%.2f", simd_length(s.omega) * 180 / .pi))
        lines.append("  bias °/s    " + v(raw.bias) + "   still " + String(format: "%.1f s", raw.stillTime))
        lines.append("  accel m/s²  " + v(raw.acc, 1) + "   |a| " + String(format: "%.2f", simd_length(raw.acc)))
        lines.append("  fused °     " + ypr(s.q.ypr))
        lines.append("")
        let stats = headphones.stats
        let apState = p.tracking == .glasses ? "off (Glasses Only)"
            : !headphones.isAvailable ? "motion not available"
            : airpods == nil ? "no data (\(headphones.authorization))"
            : usingAirPods ? "active" : calibration.ready ? "ready" : "calibrating — turn your head and nod"
        lines.append("AIRPODS       " + apState + (airpods != nil
            ? String(format: " · %.0f Hz · burst ≤%d · delay %.0f ms · clock %@", stats.rate, stats.maxBurst,
                     devAirPodsDelay * 1000, headphones.usesSensorClock ? "sensor" : "arrival") : ""))
        if let a = airpods {
            lines.append("  raw °       " + ypr(a.angles) + "   rate " + v(a.rate))
            lines.append(String(format: "  calibration lag %+.0f ms (r %.2f) · quaternion %@ · pairs %d · fit error %.0f%% · jumps %d%@",
                                calibration.lag * 1000, calibration.lagCorrelation, calibration.inverted ? "world→body" : "body→world",
                                calibration.pairCount, calibration.fitError * 100, calibration.jumps,
                                calibration.seeded ? " · from last session" : ""))
            lines.append("  ears→glasses " + (calibration.X.map { ypr($0.ypr) } ?? "unknown")
                         + "   world " + (calibration.W.map { ypr($0.ypr) } ?? "unknown"))
            if let q = calibration.pose(a) { lines.append("  as glasses  " + ypr(q.ypr)) }
        }
        if p.tracking == .both {
            lines.append("  heading     correction " + d(heading.correction) + "°   glasses−AirPods yaw " + (devYawGap.map { d($0) + "°" } ?? "—"))
        }
        lines.append("")
        lines.append("PIPELINE      pose " + (pose.map { ypr($0.ypr) } ?? "none"))
        lines.append("  anchor      " + ypr(anchor.ypr))
        lines.append("  head→view   " + ypr(devHead.ypr) + "   (after locks)")
        lines.append("  locks       yaw \(onOff(p.lockYaw))  pitch \(onOff(p.lockPitch))  roll \(onOff(p.lockRoll))"
                     + "   steady \(onOff(p.steady)) (" + String(format: "%.3f°", devSteadyDelta * 180 / .pi) + ")"
                     + "   auto drift \(onOff(p.autoRecenter))" + (p.paused ? "   PAUSED" : ""))
        lines.append(String(format: "  view        zoom %.0f%% (target %.0f%%)   FOV %.0f°   predict %.1f ms (+7 ms bottom row)   sharpness %.1f",
                            zoom * 100, p.zoom * 100, p.fovDiagonal, prediction * 1000, p.sharpness))
        lines.append("")
        lock.lock()
        let displayInfo = developerDisplayInfo
        lock.unlock()
        lines.append("DISPLAY       " + displayInfo)
        lines.append(String(format: "  capture     %.0f fps (only when the screen changes)   buffer %.0f×%.0f", devCaptureFPS, devCaptureSize.width, devCaptureSize.height))
        let text = lines.joined(separator: "\n")
        devShown = true
        DispatchQueue.main.async {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.devLayer.string = text
            self.devLayer.isHidden = false
            CATransaction.commit()
            self.onDeveloperText?(text)
        }
    }

    /// Locked axes follow the head: drop them from the head rotation (yaw, then pitch, then roll).
    private func applyLocks(_ rel: simd_quatd, _ p: Params) -> simd_quatd {
        guard p.lockYaw || p.lockPitch || p.lockRoll else { return rel }
        let a = rel.ypr
        return .ypr(SIMD3(p.lockYaw ? 0 : a.x, p.lockPitch ? 0 : a.y, p.lockRoll ? 0 : a.z))
    }

    /// Residual gyro drift slowly rotates the world. Most of the time you look at the screen, so
    /// nudge the anchor toward the long-term average gaze (at most 0.3 °/s, only near the screen).
    private func absorbDrift(_ rel: simd_quatd, _ dt: Double) {
        let yp = rel.yawPitch
        guard abs(yp.yaw) < 0.35, abs(yp.pitch) < 0.35 else { return } // ~20°: looking elsewhere
        gazeYawAvg += (yp.yaw - gazeYawAvg) * min(dt / 8, 1)
        guard abs(gazeYawAvg) > 0.005 else { return }
        let maxStep = 0.3 * .pi / 180 * dt
        let step = min(max(gazeYawAvg * min(dt / 3, 1), -maxStep), maxStep)
        anchor = simd_normalize(simd_quatd(angle: step, axis: SIMD3(0, 1, 0)) * anchor)
        gazeYawAvg -= step
    }

    private func status(_ s: IMU.Snapshot, _ p: Params) -> String {
        guard s.connected else { return "Glasses not detected (USB)" }
        if !airPodsNote.isEmpty, s.state == .ready { return airPodsNote }
        switch s.state {
        case .calibrating(let p): return "Calibrating… keep your head still (\(Int(p * 100))%)"
        case .calibratingOnTable(let p): return "Calibrating… leave the glasses still on a table (\(Int(p * 100))%)"
        case .ready: return ""
        }
    }

    private func updateHUD(_ text: String) {
        guard text != shownHUD else { return }
        shownHUD = text
        DispatchQueue.main.async {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.hud.string = text
            CATransaction.commit()
        }
    }

    private func draw(_ drawable: CAMetalDrawable, head: simd_quatd, headBottom: simd_quatd, params p: Params) {
        guard let cb = queue.makeCommandBuffer() else { return }

        // New capture frame -> mipmapped texture (only when it changed).
        if let (pb, serial) = capture.latestFrame(), serial != lastSerial, let cache = textureCache {
            lastSerial = serial
            devCaptureFrames += 1
            let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
            devCaptureSize = CGSize(width: w, height: h)
            var cvTex: CVMetalTexture?
            CVMetalTextureCacheCreateTextureFromImage(nil, cache, pb, nil, .bgra8Unorm_srgb, w, h, 0, &cvTex)
            if let cvTex, let src = CVMetalTextureGetTexture(cvTex), let dst = mipTarget(w, h), let blit = cb.makeBlitCommandEncoder() {
                blit.copy(from: src, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(),
                          sourceSize: MTLSize(width: w, height: h, depth: 1),
                          to: dst, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin())
                blit.generateMipmaps(for: dst)
                blit.endEncoding()
                aspect = Double(w) / Double(h)
                cb.addCompletedHandler { _ in _ = (cvTex, pb) } // keep the source alive until the GPU is done
            }
        }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        guard let enc = cb.makeRenderCommandEncoder(descriptor: pass) else { return }
        if let tex = mipTexture {
            var mvp = [matrix(head: head, params: p, drawable: drawable.texture),
                       matrix(head: headBottom, params: p, drawable: drawable.texture)]
            var sharpness = Float(p.sharpness)
            enc.setRenderPipelineState(pipeline)
            enc.setVertexBytes(&mvp, length: MemoryLayout<simd_float4x4>.stride * 2, index: 0)
            enc.setFragmentBytes(&sharpness, length: MemoryLayout<Float>.stride, index: 0)
            enc.setFragmentTexture(tex, index: 0)
            enc.setFragmentSamplerState(sampler, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        enc.endEncoding()
        cb.present(drawable)
        cb.commit()
    }

    private func mipTarget(_ w: Int, _ h: Int) -> MTLTexture? {
        if let t = mipTexture, t.width == w, t.height == h { return t }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb, width: w, height: h, mipmapped: true)
        d.usage = [.shaderRead]
        d.storageMode = .private
        mipTexture = device.makeTexture(descriptor: d)
        return mipTexture
    }

    /// Projection * camera (inverse head rotation) * screen placed 1 m in front of the anchor.
    private func matrix(head: simd_quatd, params p: Params, drawable: MTLTexture) -> simd_float4x4 {
        let w = Double(drawable.width), h = Double(drawable.height)
        let halfDiag = tan(p.fovDiagonal * .pi / 360)
        let halfW = halfDiag * w / sqrt(w * w + h * h)
        let halfH = halfDiag * h / sqrt(w * w + h * h)

        let distance = 1.0
        let width = 2 * distance * halfW * Renderer.baseWidth * zoom
        let height = width / aspect

        let near = 0.05, far = 100.0
        let proj = simd_double4x4(columns: (
            SIMD4(1 / halfW, 0, 0, 0),
            SIMD4(0, 1 / halfH, 0, 0),
            SIMD4(0, 0, far / (near - far), -1),
            SIMD4(0, 0, near * far / (near - far), 0)))
        let view = simd_double4x4(head.inverse)
        let model = simd_double4x4(columns: (
            SIMD4(width, 0, 0, 0),
            SIMD4(0, height, 0, 0),
            SIMD4(0, 0, 1, 0),
            SIMD4(0, 0, -distance, 1)))
        let m = proj * view * model
        return simd_float4x4(SIMD4<Float>(m.columns.0), SIMD4<Float>(m.columns.1),
                             SIMD4<Float>(m.columns.2), SIMD4<Float>(m.columns.3))
    }
}
