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

final class Renderer: NSObject {
    struct Params {
        var zoom = 1.0
        var fovDiagonal = 46.0
        var yawOnly = false
        var prediction = 0.012
        var autoRecenter = true
        var paused = false
    }

    let window: NSWindow
    let displayID: CGDirectDisplayID
    private let metalLayer = CAMetalLayer()
    private let hud = CATextLayer()
    private let imu: IMU
    private let capture: Capture

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
    private var notice: String?
    private var toast: (text: String, until: Date)?
    private var shownHUD = ""

    // Render-thread state
    private var link: CADisplayLink?
    private var thread: Thread?
    private var anchor = simd_quatd.identity
    private var smoothed = simd_quatd.identity
    private var hasPose = false
    private var zoom = 1.0
    private var gazeYawAvg = 0.0
    private var lastTime: CFTimeInterval = 0

    private static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    struct VOut { float4 position [[position]]; float2 uv; };
    vertex VOut vs(uint vid [[vertex_id]], constant float4x4 &mvp [[buffer(0)]]) {
        float2 c[4] = { float2(-0.5, -0.5), float2(0.5, -0.5), float2(-0.5, 0.5), float2(0.5, 0.5) };
        VOut o;
        o.position = mvp * float4(c[vid], 0, 1);
        o.uv = float2(c[vid].x + 0.5, 0.5 - c[vid].y);
        return o;
    }
    fragment float4 fs(VOut in [[stage_in]], texture2d<float> tex [[texture(0)]], sampler s [[sampler(0)]]) {
        return tex.sample(s, in.uv);
    }
    """

    init(screen: NSScreen, displayID: CGDirectDisplayID, imu: IMU, capture: Capture) throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw NSError(domain: "RayNeoPin", code: 1, userInfo: [NSLocalizedDescriptionKey: "Metal unavailable"])
        }
        self.device = device
        self.queue = queue
        self.imu = imu
        self.capture = capture
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

        window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false, screen: screen)
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

    func recenter() {
        lock.lock(); recenterRequested = true; lock.unlock()
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
        let dt = lastTime > 0 ? min(link.timestamp - lastTime, 0.1) : 1 / 120
        lastTime = link.timestamp

        lock.lock()
        let p = params
        let recenterNow = recenterRequested
        recenterRequested = false
        let notice = notice
        if let t = toast, t.until < Date() { toast = nil }
        let toastText = toast?.text
        lock.unlock()

        let s = imu.snapshot()
        updateHUD(notice ?? toastText ?? status(s))

        // Late-latched pose: sampled right before drawing, extrapolated over the display latency.
        var head = simd_quatd.identity
        if s.ready, !p.paused {
            let predicted = s.q.extrapolated(s.omega, p.prediction)
            if recenterNow || !hasPose {
                let yp = predicted.yawPitch
                anchor = .yawPitch(yp.yaw, p.yawOnly ? 0 : yp.pitch)
                smoothed = predicted
                gazeYawAvg = 0
                hasPose = true
            }
            // Heavy damping when still (no shimmering text), none while turning (no lag).
            let speed = simd_length(s.omega)
            let t = min(max((speed - 0.02) / 0.3, 0), 1)
            let still = min(dt / 0.25, 1)
            smoothed = simd_slerp(smoothed, predicted, still + (1 - still) * t)

            var rel = anchor.inverse * smoothed
            if p.autoRecenter { absorbDrift(rel, dt) ; rel = anchor.inverse * smoothed }
            if p.yawOnly { rel = .yawPitch(rel.yawPitch.yaw, 0) }
            head = rel
        } else if !s.ready {
            hasPose = false
        }

        zoom += (p.zoom - zoom) * min(dt / 0.08, 1)
        draw(head: head, params: p)
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

    private func status(_ s: IMU.Snapshot) -> String {
        guard s.connected else { return "Glasses not detected (USB)" }
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

    private func draw(head: simd_quatd, params p: Params) {
        guard let drawable = metalLayer.nextDrawable(), let cb = queue.makeCommandBuffer() else { return }

        // New capture frame -> mipmapped texture (only when it changed).
        if let (pb, serial) = capture.latestFrame(), serial != lastSerial, let cache = textureCache {
            lastSerial = serial
            let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
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
            var mvp = matrix(head: head, params: p, drawable: drawable.texture)
            enc.setRenderPipelineState(pipeline)
            enc.setVertexBytes(&mvp, length: MemoryLayout<simd_float4x4>.stride, index: 0)
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
        let width = 2 * distance * halfW * 0.83 * zoom // zoom 1 ≈ 83% of the view width
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
