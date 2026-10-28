// Metal renderer on the glasses display: draws the captured frame as a screen fixed in space.
//
// Runs on its own thread, driven by the glasses' vsync (120 Hz). Ideas taken from AirAnchor
// (jief123/AirAnchor): mipmapped sRGB sampling against moiré, motion-adaptive pose smoothing,
// and slow gaze-based recentering to absorb residual yaw drift. From rokid-spatial
// (angkaworn-dotcom/rokid-spatial): halo-clamped, motion-gated sharpening, Catmull-Rom/RGSS
// sampling, prediction from the filtered pose. From Breezy Desktop (wheaney/breezy-desktop):
// curved ultrawide screens and smooth follow.

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

enum SmoothingMode: String, CaseIterable {
    case oneEuro, classic

    var title: String {
        switch self {
        case .oneEuro: return "1€ Filter (adaptive, less lag)"
        case .classic: return "Classic"
        }
    }
}

enum SharpenStyle: String, CaseIterable {
    case rcas, unsharp

    var title: String {
        switch self {
        case .rcas: return "Adaptive (AMD RCAS)"
        case .unsharp: return "Unsharp Mask, halo-clamped (best in tests)"
        }
    }
}

enum FramePacing: String, CaseIterable {
    case metalLink, classic

    var title: String {
        switch self {
        case .metalLink: return "Metal Display Link (predicts to the real photon time)"
        case .classic: return "Classic Display Link"
        }
    }
}

/// 1€ filter (Casiez et al.) on a rotation: heavy smoothing when still, almost none when moving.
/// The cutoff frequency rises with angular speed. Monado uses it for head poses.
struct OneEuroQuat {
    var minCutoff = 0.4 // Hz, at rest
    var beta = 20.0 // Hz per rad/s: a 0.3 rad/s (17 °/s) turn opens the filter to ~6 Hz
    var dCutoff = 2.0 // Hz, for the speed estimate
    private var value: simd_quatd?
    private var lastInput: simd_quatd?
    private var speed = 0.0
    private(set) var cutoff = 0.0

    mutating func reset(_ q: simd_quatd) { value = q; lastInput = q; speed = 0 }

    mutating func filter(_ input: simd_quatd, dt: Double) -> simd_quatd {
        guard let prev = value, let last = lastInput, dt > 0 else { reset(input); return input }
        var q = input
        if simd_dot(prev.vector, q.vector) < 0 { q = simd_quatd(vector: -q.vector) }
        lastInput = q
        let raw = shortestAngle(last, q) / dt
        speed += (raw - speed) * OneEuroQuat.alpha(dCutoff, dt)
        cutoff = minCutoff + beta * speed
        let out = simd_slerp(prev, q, OneEuroQuat.alpha(cutoff, dt))
        value = out
        return out
    }

    private static func alpha(_ cutoff: Double, _ dt: Double) -> Double {
        let tau = 1 / (2 * .pi * cutoff)
        return 1 / (1 + tau / dt)
    }
}

/// Angle of the rotation between two orientations, 0…π.
func shortestAngle(_ a: simd_quatd, _ b: simd_quatd) -> Double {
    let d = (a.inverse * b).angle
    return min(d, 2 * .pi - d)
}

/// Where the text caret is on a pinned screen (fractions of it), from the Accessibility API.
struct CaretPoint { var x: Double; var y: Double; var panel: Int; var time: Double }

final class Renderer: NSObject, CAMetalDisplayLinkDelegate {
    struct Params: Equatable {
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
        // Readability
        var sharpenStyle = SharpenStyle.unsharp
        var motionSharpen = true // full sharpening when still, none while turning (no crawling)
        var smartFilter = true // Catmull-Rom near 1:1 and when magnified, RGSS when shrunk further
        var pixelLock = true // still + ~1:1 scale: draw exactly on the pixel grid
        var curved = true // ultrawide screens bend around you
        var warmth = 0.0 // 0…1, less blue light
        var brightness = 1.0
        // Anchoring
        var follow = false // Smooth Follow: the screen glides back in front of you
        var followDeadzone = 20.0 * .pi / 180
        var lookAwayRecenter = false
        var screenPitch = 0.0 // rad, raises/lowers the screen
        var yawGain = 1.0 // "neck saver": >1 turns the view more than your head
        // Latency
        var smoothing = SmoothingMode.oneEuro
        var predictFiltered = true
        var predictionTrim = 0.0 // s, added to the look-ahead
        // CPU
        var skipIdle = true
        // Drift
        var airPodsBias = true // learn the glasses' gyro bias from the AirPods while moving
        var airPodsScale = false // learn the glasses' gyro sensitivity from the AirPods
        var cameraDrift = false // the Mac's camera sees which way your face points
        var typingDrift = false // while typing you look at the caret
        var metalHUD = false
        var telemetry = true // record sensors and decisions to ~/Library/Logs/RayNeoPin
    }

    /// Fraction of the view width the screen covers at zoom 1.
    static let baseWidth = 0.83

    let window: NSWindow
    let displayID: CGDirectDisplayID
    /// The glasses are in side-by-side 3D mode (3840×1080): draw once per eye.
    let stereo: Bool
    let pacing: FramePacing
    private let metalLayer = CAMetalLayer()
    private let hud = CATextLayer()
    private let devLayer = CATextLayer()
    // Right-eye copies of the text layers in stereo mode.
    private let hudRight = CATextLayer()
    private let devRight = CATextLayer()
    /// Developer overlay text, delivered on the main thread (~10 Hz) for the Mac-side panel.
    var onDeveloperText: ((String) -> Void)?
    private let imu: IMU
    private let headphones: Headphones

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let sampler: MTLSamplerState
    private var textureCache: CVMetalTextureCache?
    private let eyeSize: (w: Double, h: Double)

    /// A captured display drawn in space: the main screen (side 0) or one beside it (−1 left, +1 right).
    private final class Panel {
        let capture: Capture
        let side: Int
        var texture: MTLTexture?
        var serial = -1
        var aspect = 16.0 / 9.0
        /// Mipmaps only help when the screen is shrunk well below 1:1; otherwise the captured frame
        /// is drawn straight from ScreenCaptureKit's buffer (zero copy).
        var wantsMips = true
        var hasMips = false
        var source: (CVMetalTexture, CVPixelBuffer)? // keeps a zero-copy frame alive while drawn
        var copies = 0, zeroCopies = 0, partialCopies = 0
        init(_ capture: Capture, side: Int) { self.capture = capture; self.side = side }
    }
    private var panels: [Panel]
    private var pendingSides: [(Capture, Int)]?

    private let lock = NSLock()
    // RAYNEOPIN_STILL=1 (testing): keep the screen centered, ignoring head tracking.
    private var params = Params(paused: ProcessInfo.processInfo.environment["RAYNEOPIN_STILL"] != nil)
    private var recenterRequested = true
    private var airPodsResetRequested = false
    private var developerDisplayInfo = "" // built on the main thread (NSScreen isn't thread-safe)
    private var notice: String?
    private var toast: (text: String, until: Date)?
    private var shownHUD = ""
    private var airPodsActive = false
    private var caret: CaretPoint?
    private var face: FaceTracker?

    // Render-thread state
    private var link: CADisplayLink?
    private var metalLink: CAMetalDisplayLink?
    private var thread: Thread?
    private var anchor = simd_quatd.identity
    private var smoothed = simd_quatd.identity
    private var euro = OneEuroQuat()
    private var omegaLP = SIMD3<Double>.zero
    private var steadyPose = simd_quatd.identity
    private var steadyMoved = 0.0 // when steadyPose last changed
    private var heading = HeadingReference()
    private var calibration = AirPodsCalibration()
    private var airPodsNote = "" // why AirPods aren't used right now, for the HUD
    private var airPodsCalibrating = false // for start/finish sounds
    private var airPodsAnnounced = false // sounds/toast only for the first calibration, never for refinements
    private var lastWVersion = 0
    // Cross-check of each AirPods sample against the glasses' gyro at the same instant.
    private var airPodsDisturbedUntil = 0.0
    private var airPodsWasDisturbed = false
    private var devAirPodsMismatch = 0.0
    private var devAirPodsGlitches = 0
    private var devAirPodsDelay = 0.0
    private var devYawGap: Double?
    // Glasses gyro bias/scale learned from the AirPods (whose own gyro Apple keeps calibrated).
    private var biasResidual = SIMD3<Double>.zero
    private var biasLearnTime = 0.0
    private var lastBiasApply = 0.0
    private var devBiasApplied = SIMD3<Double>.zero
    private var devBiasRejected = 0
    private var scaleAG = SIMD3<Double>.zero
    private var scaleGG = SIMD3<Double>.zero
    private var devScaleUpdates = 0
    // Mac camera as an absolute heading reference.
    private var cameraHeading = HeadingReference()
    private var faceSign = 0.0 // +1/−1 once the face yaw's direction is known
    private var faceCorr = (xy: 0.0, xx: 0.0, yy: 0.0, n: 0)
    private var lastFacePair: (face: Double, glasses: Double)?
    private var devFace: FaceTracker.Sample?
    private var devFaceGap: Double?
    // Typing prior
    private var devTyping = false
    // Anchoring
    private var following = false
    private var awayTime = 0.0
    private var stillAway = 0.0
    private var hasPose = false
    private var zoom = 1.0
    private var zoomFix = 1.0 // pixel lock: scale nudged to exactly 1:1
    private var lockBlend = 0.0
    private var gazeYawAvg = 0.0
    private var lastTime: CFTimeInterval = 0
    private var frameTime = 1.0 / 120
    private var prediction = 0.014
    private var drewLastFrame = true
    private var lastSignature: Signature?
    private var shownHUDProperties = false

    // Developer overlay state (render thread)
    private var devFrames = 0
    private var devDrawn = 0
    private var devCaptureFrames = 0
    private var devWindowStart: CFTimeInterval = 0
    private var devFPS = 0.0
    private var devDrawFPS = 0.0
    private var devCaptureFPS = 0.0
    private var devCPU = 0.0
    private var devLastUpdate: CFTimeInterval = 0
    private var devHead = simd_quatd.identity
    private var devSteadyDelta = 0.0
    private var devCaptureSize = CGSize.zero
    private var devPresentIn: Double?
    private var devTexelsPerPixel = 1.0
    private var devShown = false

    static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    struct VOut { float4 position [[position]]; float2 uv; };
    // size: the screen in world units; radius > 0 bends it into a cylinder around you.
    // rect places a sub-quad on the screen (center xy, size zw); (0,0,1,1) is the whole screen.
    struct Screen { float2 size; float distance; float radius; float4 rect; float lockBlend; uint columns; };
    struct Look { float sharpness; float texelsPerPixel; uint sharpen; uint sampling; float4 tint; float exact; };

    // mvp[0] is predicted for when the top row lights up, mvp[1] for the bottom row (the panel
    // scans out top to bottom); each vertex blends by where it lands on screen. mvp[2] is the
    // pixel-locked placement, faded in by lockBlend.
    vertex VOut vs(uint vid [[vertex_id]], constant float4x4 *mvp [[buffer(0)]], constant Screen &sc [[buffer(1)]]) {
        float2 c = float2(float(vid / 2) / float(sc.columns) - 0.5, (vid % 2) == 0 ? -0.5 : 0.5);
        float2 p = c * sc.rect.zw + sc.rect.xy;
        float3 l = float3(p.x * sc.size.x, p.y * sc.size.y, -sc.distance);
        if (sc.radius > 0.0) {
            float th = l.x / sc.radius;
            l.x = sc.radius * sin(th);
            l.z = -sc.distance + sc.radius * (1.0 - cos(th));
        }
        float4 top = mvp[0] * float4(l, 1);
        float4 bottom = mvp[1] * float4(l, 1);
        float row = top.w > 0.0001 ? clamp(0.5 - 0.5 * top.y / top.w, 0.0, 1.0) : 0.0;
        float4 pos = mix(top, bottom, row);
        if (sc.lockBlend > 0.0) {
            float4 locked = mvp[2] * float4(l, 1);
            pos = sc.lockBlend >= 1.0 ? locked : mix(pos, locked * pos.w, sc.lockBlend);
        }
        VOut o;
        o.position = pos;
        o.uv = float2(c.x + 0.5, 0.5 - c.y);
        return o;
    }

    // Bicubic Catmull-Rom in 9 bilinear taps (TheRealMJP): sharper than bilinear.
    float4 catmullRom(texture2d<float> tex, sampler s, float2 uv) {
        float2 size = float2(tex.get_width(), tex.get_height());
        float2 pos = uv * size;
        float2 p1 = floor(pos - 0.5) + 0.5;
        float2 f = pos - p1;
        float2 w0 = f * (-0.5 + f * (1.0 - 0.5 * f));
        float2 w1 = 1.0 + f * f * (-2.5 + 1.5 * f);
        float2 w2 = f * (0.5 + f * (2.0 - 1.5 * f));
        float2 w3 = f * f * (-0.5 + 0.5 * f);
        float2 w12 = w1 + w2;
        float2 t0 = (p1 - 1.0) / size, t3 = (p1 + 2.0) / size, t12 = (p1 + w2 / w12) / size;
        float4 r = 0.0;
        r += tex.sample(s, float2(t0.x, t0.y), level(0)) * w0.x * w0.y;
        r += tex.sample(s, float2(t12.x, t0.y), level(0)) * w12.x * w0.y;
        r += tex.sample(s, float2(t3.x, t0.y), level(0)) * w3.x * w0.y;
        r += tex.sample(s, float2(t0.x, t12.y), level(0)) * w0.x * w12.y;
        r += tex.sample(s, float2(t12.x, t12.y), level(0)) * w12.x * w12.y;
        r += tex.sample(s, float2(t3.x, t12.y), level(0)) * w3.x * w12.y;
        r += tex.sample(s, float2(t0.x, t3.y), level(0)) * w0.x * w3.y;
        r += tex.sample(s, float2(t12.x, t3.y), level(0)) * w12.x * w3.y;
        r += tex.sample(s, float2(t3.x, t3.y), level(0)) * w3.x * w3.y;
        // Anti-ringing: Catmull-Rom overshoots at sharp edges, which draws a bright/dark halo
        // around text. Keep the result within the 4 texels it sits between.
        float4 a = tex.sample(s, p1 / size, level(0)), b = tex.sample(s, (p1 + float2(1, 0)) / size, level(0));
        float4 c = tex.sample(s, (p1 + float2(0, 1)) / size, level(0)), d = tex.sample(s, (p1 + 1.0) / size, level(0));
        return clamp(r, min(min(a, b), min(c, d)), max(max(a, b), max(c, d)));
    }

    float4 base(texture2d<float> tex, sampler s, float2 uv, float2 dx, float2 dy, constant Look &lk) {
        if (lk.exact > 0.5) return tex.sample(s, uv, level(0));
        // Up to 1.6 texels per pixel, bicubic keeps strokes crisp where bilinear smears them across
        // two pixels (any sub-pixel placement, i.e. whenever the head moves); beyond that it would
        // alias, so the rotated grid takes over.
        if (lk.sampling == 1 && lk.texelsPerPixel <= 1.6) return catmullRom(tex, s, uv);
        if (lk.sampling == 1) {
            // Rotated-grid 4× supersampling over the pixel footprint: less moiré when shrinking.
            gradient2d g(dx * 0.5, dy * 0.5);
            return 0.25 * (tex.sample(s, uv + 0.125 * dx + 0.375 * dy, g) + tex.sample(s, uv + 0.375 * dx - 0.125 * dy, g)
                         + tex.sample(s, uv - 0.125 * dx - 0.375 * dy, g) + tex.sample(s, uv - 0.375 * dx + 0.125 * dy, g));
        }
        return tex.sample(s, uv, gradient2d(dx, dy));
    }

    // Sharpening in output-pixel units restores edge contrast lost when the desktop is resampled.
    fragment float4 fs(VOut in [[stage_in]], texture2d<float> tex [[texture(0)]], sampler s [[sampler(0)]],
                       constant Look &lk [[buffer(0)]]) {
        float2 dx = dfdx(in.uv), dy = dfdy(in.uv);
        float4 c = base(tex, s, in.uv, dx, dy, lk);
        if (lk.sharpness > 0.0 && lk.exact < 0.5) {
            gradient2d g(dx, dy);
            float3 n = tex.sample(s, in.uv - dy, g).rgb, w = tex.sample(s, in.uv - dx, g).rgb;
            float3 e = tex.sample(s, in.uv + dx, g).rgb, so = tex.sample(s, in.uv + dy, g).rgb;
            float3 mn = min(min(n, w), min(e, so)), mx = max(max(n, w), max(e, so));
            if (lk.sharpen == 0) {
                // AMD FidelityFX RCAS: the strongest sharpening that can't clip, per pixel.
                float3 hitMin = min(mn, c.rgb) / (4.0 * mx + 1e-5);
                float3 hitMax = (1.0 - max(mx, c.rgb)) / (4.0 * mn - 4.0 - 1e-5);
                float3 l = max(-hitMin, hitMax);
                float lobe = max(-0.1875, min(max(l.r, max(l.g, l.b)), 0.0)) * lk.sharpness;
                c.rgb = (lobe * (n + w + e + so) + c.rgb) / (4.0 * lobe + 1.0);
            } else {
                // Unsharp mask, clamped to the neighbours' range so it never draws halos.
                float3 sharp = c.rgb + lk.sharpness * (c.rgb - 0.25 * (n + w + e + so));
                c.rgb = clamp(sharp, min(mn, c.rgb), max(mx, c.rgb));
            }
        }
        c.rgb *= lk.tint.rgb;
        return c;
    }
    """

    struct ScreenUniform {
        var size: SIMD2<Float>
        var distance: Float
        var radius: Float
        var rect: SIMD4<Float>
        var lockBlend: Float
        var columns: UInt32
    }

    struct Look {
        var sharpness: Float
        var texelsPerPixel: Float
        var sharpen: UInt32
        var sampling: UInt32
        var tint: SIMD4<Float>
        var exact: Float
    }

    /// Screen size and projection for one panel.
    private struct Geometry {
        var halfW: Double
        var halfH: Double
        var width: Double
        var height: Double
        var distance: Double
        var radius: Double
        /// Half the horizontal angle the screen covers.
        var halfAngle: Double { radius > 0 ? width / 2 / radius : atan(width / 2 / distance) }
    }

    /// Everything a frame shows; when it equals the last one drawn, the frame is skipped.
    private struct Signature: Equatable {
        var head: SIMD4<Double>
        var headBottom: SIMD4<Double>
        var zoom: Double
        var lockBlend: Double
        var motion: Double
        var serials: [Int]
        var cursor: Int
        var params: Params
    }

    private struct Frame {
        var head = simd_quatd.identity
        var headBottom = simd_quatd.identity
        var params = Params()
        var motion = 0.0 // 0 still … 1 turning
        var zoom = 1.0
        var lockBlend = 0.0
        var lockMatrix = matrix_identity_float4x4
        var needsDraw = true
    }

    /// Resample in gamma space (sRGB values as stored) instead of linear light. Font renderers,
    /// macOS included, blend text in gamma space; resampling it in linear light makes light text
    /// on dark backgrounds glow (a halo) and dark text on light backgrounds thin.
    let gammaSpace: Bool
    private let pixelFormat: MTLPixelFormat

    init(screen: NSScreen, displayID: CGDirectDisplayID, imu: IMU, capture: Capture, headphones: Headphones,
         pacing: FramePacing, gammaSpace: Bool) throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw NSError(domain: "RayNeoPin", code: 1, userInfo: [NSLocalizedDescriptionKey: "Metal unavailable"])
        }
        self.device = device
        self.queue = queue
        self.imu = imu
        self.headphones = headphones
        self.displayID = displayID
        self.pacing = pacing
        self.gammaSpace = gammaSpace
        pixelFormat = gammaSpace ? .bgra8Unorm : .bgra8Unorm_srgb
        panels = [Panel(capture, side: 0)]
        stereo = screen.frame.width / screen.frame.height > 3

        let library = try device.makeLibrary(source: Renderer.shader, options: nil)
        let pd = MTLRenderPipelineDescriptor()
        pd.vertexFunction = library.makeFunction(name: "vs")
        pd.fragmentFunction = library.makeFunction(name: "fs")
        pd.colorAttachments[0].pixelFormat = pixelFormat
        // Premultiplied alpha, for the cursor; the opaque screen is unaffected.
        pd.colorAttachments[0].isBlendingEnabled = true
        pd.colorAttachments[0].sourceRGBBlendFactor = .one
        pd.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        pd.colorAttachments[0].sourceAlphaBlendFactor = .one
        pd.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
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
        let scale = screen.backingScaleFactor
        let pixelW = Double(screen.frame.width * scale), pixelH = Double(screen.frame.height * scale)
        eyeSize = (stereo ? pixelW / 2 : pixelW, pixelH)
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

        metalLayer.device = device
        metalLayer.pixelFormat = pixelFormat
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
        let eyeWidth = stereo ? view.bounds.width / 2 : view.bounds.width
        hud.frame = CGRect(x: 60, y: 40, width: eyeWidth - 120, height: 70)
        view.layer!.addSublayer(hud)

        devLayer.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .medium)
        devLayer.fontSize = 13
        devLayer.foregroundColor = NSColor(white: 0.95, alpha: 1).cgColor
        devLayer.backgroundColor = NSColor(white: 0.12, alpha: 0.9).cgColor
        devLayer.cornerRadius = 8
        devLayer.contentsScale = scale
        devLayer.isWrapped = false
        devLayer.frame = CGRect(x: 110, y: view.bounds.height - 60 - 720, width: 1240, height: 720)
        devLayer.isHidden = true
        if stereo { devLayer.frame = CGRect(x: 40, y: devLayer.frame.minY, width: eyeWidth - 80, height: 720) }
        view.layer!.addSublayer(devLayer)
        if stereo {
            for (copy, original) in [(hudRight, hud), (devRight, devLayer)] {
                copy.font = original.font
                copy.fontSize = original.fontSize
                copy.alignmentMode = original.alignmentMode
                copy.foregroundColor = original.foregroundColor
                copy.backgroundColor = original.backgroundColor
                copy.cornerRadius = original.cornerRadius
                copy.contentsScale = scale
                copy.isWrapped = original.isWrapped
                copy.isHidden = original.isHidden
                copy.frame = original.frame.offsetBy(dx: eyeWidth, dy: 0)
                view.layer!.addSublayer(copy)
            }
        }

        window.orderFrontRegardless()

        if pacing == .metalLink {
            // Hands us the drawable and the time it will reach the panel, so prediction targets
            // the real photon time instead of a guess, and we never stall in nextDrawable.
            let link = CAMetalDisplayLink(metalLayer: metalLayer)
            link.delegate = self
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
            link.preferredFrameLatency = 1
            metalLink = link
        } else {
            let link = view.displayLink(target: self, selector: #selector(frame(_:)))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
            self.link = link
        }
        let thread = Thread { [weak self] in
            if let link = self?.link { link.add(to: .current, forMode: .default) }
            if let link = self?.metalLink { link.add(to: .current, forMode: .default) }
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
        metalLink?.invalidate()
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

    /// Extra screens beside the main one (Virtual Display setup), side −1 left / +1 right.
    func setSideScreens(_ sides: [(Capture, Int)]) {
        lock.lock(); pendingSides = sides; lock.unlock()
    }

    func setCaret(_ c: CaretPoint?) {
        lock.lock(); caret = c; lock.unlock()
    }

    func setFaceTracker(_ f: FaceTracker?) {
        lock.lock(); face = f; lock.unlock()
    }

    /// Cursor drawn by us on the pinned screen: top-left corner and size, as fractions of the screen.
    /// (The hardware cursor is hidden over the glasses, and a hidden cursor isn't captured.)
    struct CursorPlacement: Equatable { var x: Double; var y: Double; var w: Double; var h: Double; var panel = 0 }
    private var cursor: CursorPlacement?
    private var cursorTexture: MTLTexture?
    private var cursorShape: Int?
    private var cursorVersion = 0

    /// Main thread, every display refresh. `shape` identifies the cursor image (arrow, I-beam…), so
    /// its texture is only rebuilt when the shape changes; `image` is only asked for then.
    func setCursor(_ placement: CursorPlacement?, shape: Int?, image: () -> NSImage?) {
        lock.lock()
        let shapeChanged = shape != nil && shape != cursorShape
        let changed = placement != cursor || shapeChanged
        lock.unlock()
        guard changed else { return }
        let texture = shapeChanged ? image().flatMap(makeTexture) : nil
        lock.lock()
        cursor = placement
        if let texture, let shape { cursorTexture = texture; cursorShape = shape }
        cursorVersion &+= 1
        lock.unlock()
    }

    /// Renders an NSImage at 2× into a premultiplied BGRA texture.
    private func makeTexture(_ image: NSImage) -> MTLTexture? {
        let w = max(Int(image.size.width * 2), 1), h = max(Int(image.size.height * 2), 1)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
              let data = ctx.data else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        image.draw(in: NSRect(x: 0, y: 0, width: w, height: h))
        NSGraphicsContext.restoreGraphicsState()
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: pixelFormat, width: w, height: h, mipmapped: false)
        d.usage = [.shaderRead]
        let t = device.makeTexture(descriptor: d)
        t?.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: data, bytesPerRow: ctx.bytesPerRow)
        return t
    }

    /// Live AirPods calibration state, for the Settings window.
    struct AirPodsStatus {
        var receiving = false, ready = false, active = false
        var progress = 0.0, turned = 0.0, nodded = 0.0, lag = 0.0, fitError = 1.0
        var glitches = 0
        var hint = ""
    }
    private var airPodsStatusValue = AirPodsStatus()
    var airPodsStatus: AirPodsStatus {
        lock.lock(); defer { lock.unlock() }
        return airPodsStatusValue
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
        if imu.isAsleep { return } // the display is off: draw nothing, save the GPU
        if drewLastFrame {
            // Wait for a free buffer *before* reading any pose (late latching): otherwise the pose
            // is a whole frame old by the time it is drawn.
            guard let drawable = metalLayer.nextDrawable() else { return }
            let f = step(now: CACurrentMediaTime(), presentIn: nil)
            if f.needsDraw { draw(drawable, f) }
            drewLastFrame = f.needsDraw
        } else {
            // Idle: buffers are free, so checking first and acquiring after costs no latency.
            let f = step(now: CACurrentMediaTime(), presentIn: nil)
            guard f.needsDraw, let drawable = metalLayer.nextDrawable() else { return }
            draw(drawable, f)
            drewLastFrame = true
        }
    }

    func metalDisplayLink(_ link: CAMetalDisplayLink, needsUpdate update: CAMetalDisplayLink.Update) {
        if imu.isAsleep { return }
        let now = CACurrentMediaTime()
        let f = step(now: now, presentIn: update.targetPresentationTimestamp - now)
        if f.needsDraw { draw(update.drawable, f) }
    }

    /// Reads every sensor and works out where the screen goes this frame.
    private func step(now frameStart: CFTimeInterval, presentIn: Double?) -> Frame {
        let dt = lastTime > 0 ? min(frameStart - lastTime, 0.1) : 1 / 120
        lastTime = frameStart
        frameTime += (dt - frameTime) * 0.05

        lock.lock()
        let p = params
        let recenterNow = recenterRequested
        recenterRequested = false
        if airPodsResetRequested || (p.tracking == .glasses && devBiasApplied != .zero) {
            // Whatever was learned from the AirPods goes with them.
            imu.adjustBias(-devBiasApplied)
            devBiasApplied = .zero
            biasResidual = .zero
            biasLearnTime = 0
        }
        if airPodsResetRequested {
            airPodsResetRequested = false
            airPodsSeed = nil
            airPodsSaved = nil
            calibration.reset()
            heading = HeadingReference()
            devYawGap = nil
            airPodsAnnounced = false
        }
        if let seed = airPodsSeed {
            airPodsSeed = nil
            calibration.reset()
            calibration.seed(seed)
            airPodsAnnounced = true // known AirPods: calibrate silently
        }
        airPodsSaved = calibration.saved ?? airPodsSaved
        let notice = notice
        if let t = toast, t.until < Date() { toast = nil }
        let toastText = toast?.text
        let caret = caret
        let face = face
        let cursorVersion = cursorVersion
        if let sides = pendingSides {
            pendingSides = nil
            panels = [panels[0]] + sides.map { s in panels.first { $0.capture === s.0 && $0.side == s.1 } ?? Panel(s.0, side: s.1) }
        }
        lock.unlock()

        if p.metalHUD != shownHUDProperties {
            shownHUDProperties = p.metalHUD
            let on = p.metalHUD
            DispatchQueue.main.async { self.metalLayer.developerHUDProperties = on ? ["mode": "default"] : nil }
        }

        // Look-ahead: with the Metal display link, to when the frame actually reaches the panel
        // (+5 ms panel processing); otherwise as tuned in XRLinuxDriver for RayNeo: 10 ms + 0.45 ×
        // frame time.
        if let presentIn {
            devPresentIn = presentIn
            prediction = min(max(presentIn + 0.005 + p.predictionTrim, 0), 0.05)
        } else {
            devPresentIn = nil
            prediction = min(max(0.010 + 0.45 * frameTime + p.predictionTrim, 0), 0.040)
        }

        let s = imu.snapshot()
        updateHUD(notice ?? toastText ?? status(s, p))

        // Pose source: the glasses' IMU, the AirPods, or the glasses corrected by the AirPods' heading.
        var airpods: Headphones.Sample?
        if p.tracking != .glasses {
            let fresh = headphones.drain()
            calibration.ingest(fresh, glasses: imu.pose(at:))
            if p.telemetry {
                for f in fresh {
                    guard let g = imu.pose(at: calibration.glassesTime(f)) else { continue }
                    // In the glasses' frame once calibrated; before that only the speeds compare.
                    let a = calibration.X == nil ? f.rate : calibration.rate(f)
                    let mismatch = calibration.X == nil ? abs(simd_length(f.rate) - simd_length(g.omega)) : simd_length(a - g.omega)
                    Telemetry.shared.sample([f3(frameStart), f3(f.time), f3(f.arrival), deg3(a.x), deg3(a.y), deg3(a.z),
                                             deg3(g.omega.x), deg3(g.omega.y), deg3(g.omega.z),
                                             deg3(simd_length(f.rate)), deg3(simd_length(g.omega)), deg3(mismatch)])
                }
            }
            airpods = headphones.latest()
            // Both devices sit on the same head, so they must rotate alike. AirPods turning while the
            // glasses don't (being adjusted in the ear, reconnecting, a bud swap) is not head motion:
            // ignore them until they agree again, then take that as the new reference.
            if calibration.ready {
                for f in fresh {
                    guard let g = imu.pose(at: calibration.glassesTime(f)) else { continue }
                    let mismatch = simd_length(calibration.rate(f) - g.omega)
                    devAirPodsMismatch = mismatch
                    if mismatch > max(0.35, 0.5 * simd_length(g.omega)) {
                        if CACurrentMediaTime() >= airPodsDisturbedUntil { devAirPodsGlitches += 1 }
                        airPodsDisturbedUntil = CACurrentMediaTime() + 1.5
                    }
                }
            }
            let disturbed = CACurrentMediaTime() < airPodsDisturbedUntil
            if airPodsWasDisturbed, !disturbed {
                heading.reset()
                calibration.realign()
            }
            airPodsWasDisturbed = disturbed
            if disturbed { airpods = nil } // fall back to the glasses meanwhile
            if p.tracking == .both, calibration.ready, !disturbed {
                // Compare headings at the instant each AirPods sample was measured, so Bluetooth
                // latency doesn't show up as a heading difference.
                for f in fresh {
                    guard let ap = calibration.pose(f), let g = imu.pose(at: calibration.glassesTime(f)) else { continue }
                    heading.update(glasses: g.q.yawPitch.yaw, airpods: ap.yawPitch.yaw, dt: 1 / max(headphones.stats.rate, 10))
                    devYawGap = wrapAngle(g.q.yawPitch.yaw - ap.yawPitch.yaw)
                }
            }
            if (p.airPodsBias || p.airPodsScale), calibration.ready, calibration.fitError < 0.3, !disturbed {
                learnGyro(from: fresh, p)
            }
            if let airpods { devAirPodsDelay = CACurrentMediaTime() - airpods.time }
        }
        // A refined calibration means a new AirPods heading reference: re-take the offset so the
        // correction doesn't drift toward the old one.
        if calibration.wVersion != lastWVersion {
            lastWVersion = calibration.wVersion
            heading.reset()
        }
        let calibrating = p.tracking != .glasses && airpods != nil && !calibration.ready
        if calibrating != airPodsCalibrating, !airPodsAnnounced {
            // Audible start/finish of the first calibration only: nobody can read a progress bar
            // while turning their head, and refinements later on happen silently.
            if calibrating {
                DispatchQueue.main.async { NSSound(named: "Tink")?.play() }
            } else if calibration.ready {
                airPodsAnnounced = true
                DispatchQueue.main.async { NSSound(named: "Glass")?.play() }
                show("AirPods calibrated", seconds: 2)
            }
        }
        airPodsCalibrating = calibrating
        // A sound per finished step of the guided calibration: nobody reads while turning their head.
        if calibration.phase != lastPhase {
            if calibrating, calibration.phase == .nod || calibration.phase == .finishing { DispatchQueue.main.async { NSSound(named: "Pop")?.play() } }
            lastPhase = calibration.phase
        }
        if calibrating {
            let filled = Int((calibration.progress * 20).rounded())
            let bar = String(repeating: "▰", count: filled) + String(repeating: "▱", count: 20 - filled)
            let hint = CACurrentMediaTime() - calibration.lastPairTime > 1.5 && !calibration.fitting
                ? calibration.hint + " — a bit faster" : calibration.hint
            airPodsNote = "Calibrating AirPods  \(bar)  \(Int(calibration.progress * 100))%  — \(hint)"
        } else {
            airPodsNote = p.tracking == .glasses || airpods != nil || airPodsWasDisturbed ? "" : "AirPods: no data — using glasses"
        }

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
        if p.tracking != .glasses {
            let st = AirPodsStatus(receiving: airpods != nil, ready: calibration.ready, active: usingAirPods, progress: calibration.progress,
                                   turned: calibration.turned, nodded: calibration.nodded, lag: calibration.lag,
                                   fitError: calibration.fitError, glitches: calibration.glitches, hint: calibration.hint)
            lock.lock(); airPodsStatusValue = st; lock.unlock()
        }

        // The Mac's camera: an absolute heading, so it can undo drift for good.
        if p.cameraDrift, let face {
            learnFromCamera(face.drain(), airPodsCorrection: usingAirPods && p.tracking == .both ? heading.correction : 0)
            if faceSign != 0, let q = pose { pose = simd_quatd(angle: cameraHeading.correction, axis: SIMD3(0, 1, 0)) * q }
        }

        var f = Frame()
        f.params = p
        let panel = panels[0]
        var head = simd_quatd.identity
        var headBottom = simd_quatd.identity
        if let pose, !p.paused {
            let speed = simd_length(omega)
            omegaLP += (omega - omegaLP) * min(dt / 0.03, 1)
            // While a fast turn stops, the smoothed rate lags behind and would keep "turning" past the
            // stop (the screen overshoots, then snaps back): predict with whichever rate is slower.
            let predictRate = simd_length(omega) < simd_length(omegaLP) ? omega : omegaLP
            if recenterNow, p.telemetry { Telemetry.shared.event("recenter", time: frameStart) }
            if recenterNow || !hasPose {
                let yp = pose.yawPitch
                anchor = .yawPitch(yp.yaw, p.lockPitch ? 0 : yp.pitch)
                smoothed = pose
                euro.reset(pose)
                steadyPose = pose
                gazeYawAvg = 0
                following = false
                if !hasPose { heading.reset(); cameraHeading.reset() }
                hasPose = true
            }
            let t = min(max((speed - 0.02) / 0.3, 0), 1)
            f.motion = t
            var filtered: simd_quatd
            switch p.smoothing {
            case .classic:
                // Heavy damping when still (no shimmering text), none while turning (no lag).
                let still = min(dt / 0.25, 1)
                if p.predictFiltered {
                    smoothed = simd_slerp(smoothed, pose, still + (1 - still) * t)
                    filtered = smoothed.predicted(predictRate, prediction)
                } else {
                    // Late-latched pose: sampled right before drawing, extrapolated over the display latency.
                    smoothed = simd_slerp(smoothed, pose.predicted(omega, prediction), still + (1 - still) * t)
                    filtered = smoothed
                }
            case .oneEuro:
                // Predicting from the filtered pose: extrapolating raw gyro noise amplifies jitter.
                filtered = p.predictFiltered ? euro.filter(pose, dt: dt).predicted(predictRate, prediction)
                    : euro.filter(pose.predicted(omega, prediction), dt: dt)
            }

            // Steady image: ignore movements under 0.1° (heartbeat, breathing) without ever jumping,
            // by only following once the pose leaves that radius.
            if p.steady {
                let delta = shortestAngle(steadyPose, filtered)
                let radius = 0.1 * .pi / 180
                if delta > radius {
                    steadyPose = simd_slerp(steadyPose, filtered, (delta - radius) / delta)
                    steadyMoved = frameStart
                }
            } else {
                if steadyPose.vector != filtered.vector { steadyMoved = frameStart }
                steadyPose = filtered
            }

            if p.autoRecenter { absorbDrift(anchor.inverse * steadyPose, dt) }
            if p.follow { smoothFollow(p, dt) }
            if p.lookAwayRecenter { lookAway(speed, dt) }
            devTyping = false
            if p.typingDrift, let caret, frameStart - caret.time < 1, caret.panel == 0 {
                typingPrior(caret, p, dt, aspect: panel.aspect)
            }
            head = viewRotation(anchor.inverse * steadyPose, p)
            // The bottom row lights up ~7 ms after the top one (XRLinuxDriver's RayNeo scanline value);
            // only while moving, so still images stay perfectly still.
            headBottom = viewRotation(anchor.inverse * steadyPose.extrapolated(omega, 0.007 * t), p)
            devSteadyDelta = shortestAngle(steadyPose, filtered)
        } else if pose == nil {
            hasPose = false
        }

        zoom += (p.zoom - zoom) * min(dt / 0.08, 1)
        if abs(zoom - p.zoom) < 1e-5 { zoom = p.zoom }

        // Pixel lock: at ~1:1 scale, nudge the zoom to exactly 1:1; when still, snap the screen
        // onto the pixel grid so text is as sharp as on a real monitor (no resampling at all).
        var fixTarget = 1.0
        var lockMatrix: simd_float4x4?
        if p.pixelLock, let tex = panel.texture {
            let g0 = geometry(p, aspect: panel.aspect, zoom: zoom)
            if g0.radius == 0 {
                let drawn = g0.width / (2 * g0.halfW) * eyeSize.w
                let r = Double(tex.width) / drawn
                if abs(r - 1) < 0.12 { fixTarget = r }
            }
        }
        zoomFix += (fixTarget - zoomFix) * min(dt / 0.3, 1)
        if abs(zoomFix - fixTarget) < 1e-5 { zoomFix = fixTarget }
        f.zoom = zoom * zoomFix
        if p.pixelLock, fixTarget != 1, zoomFix == fixTarget, zoom == p.zoom, frameStart - steadyMoved > 0.25, f.motion == 0,
           let tex = panel.texture {
            let g = geometry(p, aspect: panel.aspect, zoom: f.zoom)
            lockMatrix = pixelLock(vp: viewProjection(head, g, yaw: 0, p), g, texture: (Double(tex.width), Double(tex.height)))
        }
        if let lockMatrix {
            f.lockMatrix = lockMatrix
            lockBlend = min(lockBlend + dt / 0.25, 1)
        } else {
            lockBlend = f.motion > 0 ? 0 : max(lockBlend - dt / 0.15, 0)
        }
        if lockBlend > 0, lockMatrix == nil {
            // Fading out without a fresh lock: keep the last one.
            f.lockMatrix = lastLockMatrix
        }
        if let lockMatrix { lastLockMatrix = lockMatrix }
        f.lockBlend = lockBlend
        f.head = head
        f.headBottom = headBottom
        devHead = head

        let signature = Signature(head: head.vector, headBottom: headBottom.vector, zoom: f.zoom, lockBlend: lockBlend,
                                  motion: f.motion, serials: panels.map { $0.capture.latestSerial() },
                                  cursor: cursorVersion, params: p)
        f.needsDraw = !p.skipIdle || signature != lastSignature
        if f.needsDraw { lastSignature = signature }

        if p.telemetry { recordTelemetry(s, airpods: airpods, pose: pose, omega: omega, usingAirPods: usingAirPods, p: p, f: f, now: frameStart) }
        devFrames += 1
        if f.needsDraw { devDrawn += 1 }
        if p.developer { developerOverlay(s, airpods: airpods, pose: pose, usingAirPods: usingAirPods, p: p,
                                          cpu: CACurrentMediaTime() - frameStart, now: frameStart) }
        else if devShown { devShown = false; DispatchQueue.main.async { self.devLayer.isHidden = true; self.devRight.isHidden = true } }
        return f
    }

    private var lastLockMatrix = matrix_identity_float4x4

    // MARK: Telemetry

    private var lastTelemetry = 0.0
    private var lastPhase = AirPodsCalibration.Phase.turn
    private var tLastBud = (switches: 0, gaps: 0, phase: AirPodsCalibration.Phase.turn)
    private var tFrames = 0, tDrawn = 0, tWindow = 0.0, tFPS = 0.0, tDrawnFPS = 0.0
    private var tLast = (ready: false, reseats: 0, restarts: 0, ignored: false, tracking: TrackingMode.both, connected: false, asleep: false, jumps: 0)

    private func recordTelemetry(_ s: IMU.Snapshot, airpods: Headphones.Sample?, pose: simd_quatd?, omega: SIMD3<Double>,
                                 usingAirPods: Bool, p: Params, f: Frame, now: Double) {
        tFrames += 1
        if f.needsDraw { tDrawn += 1 }
        if tWindow == 0 { tWindow = now }
        if now - tWindow >= 1 {
            tFPS = Double(tFrames) / (now - tWindow)
            tDrawnFPS = Double(tDrawn) / (now - tWindow)
            tFrames = 0; tDrawn = 0; tWindow = now
        }
        let ignored = now < airPodsDisturbedUntil
        // Events: whatever changed since the last frame.
        let t = Telemetry.shared
        if s.connected != tLast.connected { t.event(s.connected ? "glasses connected" : "glasses disconnected", time: now) }
        let raw = imu.rawSnapshot()
        if raw.asleep != tLast.asleep { t.event(raw.asleep ? "glasses asleep (not worn)" : "glasses awake", time: now) }
        if p.tracking != tLast.tracking { t.event("tracking: \(p.tracking.rawValue)", time: now) }
        if calibration.ready != tLast.ready {
            t.event(calibration.ready ? String(format: "airpods calibrated (lag %.0f ms, fit %.1f%%)", calibration.lag * 1000, calibration.fitError * 100)
                    : "airpods calibration lost", time: now)
        }
        if calibration.budSwitches != tLastBud.switches { t.event("airpods: other earbud took over", time: now) }
        if calibration.gaps != tLastBud.gaps { t.event("airpods: data gap, re-referenced", time: now) }
        if calibration.phase != tLastBud.phase { t.event("airpods calibration step: \(calibration.phase.rawValue)", time: now) }
        tLastBud = (calibration.budSwitches, calibration.gaps, calibration.phase)
        if calibration.reseats != tLast.reseats { t.event("airpods reseated in the ears: relearning", time: now) }
        if calibration.restarts != tLast.restarts { t.event("airpods calibration: poor fit, dropped older movement", time: now) }
        if calibration.jumps != tLast.jumps { t.event("airpods reference jumped (Spatial Audio re-center, bud swap): re-referenced", time: now) }
        if ignored != tLast.ignored { t.event(ignored ? "airpods ignored (disagree with the glasses)" : "airpods trusted again", time: now) }
        tLast = (calibration.ready, calibration.reseats, calibration.restarts, ignored, p.tracking, s.connected, raw.asleep, calibration.jumps)

        guard now - lastTelemetry >= 0.05 else { return }
        lastTelemetry = now
        let state: String
        switch s.state {
        case .ready: state = "ready"
        case .calibrating(let x): state = "calibrating:" + f3(x)
        case .calibratingOnTable(let x): state = "table:" + f3(x)
        }
        let fused = s.q.ypr, a = airpods?.angles ?? SIMD3(repeating: .nan)
        let poseYPR = pose?.ypr ?? SIMD3(repeating: .nan), anc = anchor.ypr, head = f.head.ypr
        func b(_ x: Bool) -> String { x ? "1" : "0" }
        t.state([
            f3(now),
            b(s.connected), state, f3(raw.rate), b(raw.asleep), f3(raw.temperature), f3(raw.stillTime), b(raw.accelRejected),
            deg3(raw.gyro.x), deg3(raw.gyro.y), deg3(raw.gyro.z), f3(raw.acc.x), f3(raw.acc.y), f3(raw.acc.z),
            deg3(raw.bias.x), deg3(raw.bias.y), deg3(raw.bias.z),
            deg3(fused.x), deg3(fused.y), deg3(fused.z),
            p.tracking.rawValue, b(airpods != nil), f3(headphones.stats.rate), f3(devAirPodsDelay * 1000), deg3(a.x), deg3(a.y), deg3(a.z),
            b(calibration.ready), f3(calibration.progress), f3(calibration.turned), f3(calibration.nodded), f3(calibration.lag * 1000),
            f3(calibration.fitError), String(calibration.glitches), String(calibration.restarts), String(calibration.reseats),
            b(usingAirPods), b(ignored), deg3(heading.correction), devYawGap.map(deg3) ?? "",
            deg3(devBiasApplied.x), deg3(devBiasApplied.y), deg3(devBiasApplied.z),
            deg3(poseYPR.x), deg3(poseYPR.y), deg3(poseYPR.z), deg3(anc.x), deg3(anc.y), deg3(head.x), deg3(head.y), deg3(head.z),
            deg3(simd_length(omega)), f3(prediction * 1000), f3(f.zoom), f3(f.lockBlend), f3(tFPS), f3(tDrawnFPS), b(following),
        ])
    }

    // MARK: Drift references

    /// The AirPods' rotation rate is bias-corrected by Apple. Seen in the glasses' frame, any
    /// steady difference from the glasses' gyro is the glasses' remaining bias, on all three axes,
    /// even while the head moves. (Sensitivity errors show up as a difference proportional to speed.)
    private func learnGyro(from fresh: [Headphones.Sample], _ p: Params) {
        let rate = max(headphones.stats.rate, 10)
        for f in fresh {
            guard let g = imu.pose(at: calibration.glassesTime(f)) else { continue }
            let a = calibration.rate(f)
            if p.airPodsBias, simd_length(a) < 1.0 {
                biasResidual += (g.omega - a - biasResidual) * (1 / rate / 20)
                biasLearnTime += 1 / rate
            }
            if p.airPodsScale, simd_length(g.omega) > 0.3, simd_length(g.omega) < 3 {
                scaleAG += a * g.omega
                scaleGG += g.omega * g.omega
            }
        }
        let now = CACurrentMediaTime()
        // Only trust a precise calibration, and only believe a plausible bias: a real gyro bias left
        // after calibration is a few hundredths of a °/s. A big, steady difference means the AirPods
        // calibration is off, and learning from it would make the screen slide sideways by itself.
        let deg = Double.pi / 180
        let trusted = calibration.fitError < 0.15 && calibration.lagCorrelation > 0.8
        if p.airPodsBias, biasLearnTime > 10, now - lastBiasApply > 2 {
            lastBiasApply = now
            if !trusted || simd_length(biasResidual) > 0.3 * deg {
                biasResidual = .zero
                biasLearnTime = 0
                devBiasRejected += 1
            } else {
                let step = 0.01 * deg, total = 0.15 * deg
                var delta = (biasResidual * 0.3).clamped(lowerBound: SIMD3(repeating: -step), upperBound: SIMD3(repeating: step))
                // Never move the bias more than 0.15 °/s in total from what the glasses calibrated.
                delta = (devBiasApplied + delta).clamped(lowerBound: SIMD3(repeating: -total), upperBound: SIMD3(repeating: total)) - devBiasApplied
                imu.adjustBias(delta)
                biasResidual -= delta
                devBiasApplied += delta
            }
        }
        if p.airPodsScale, trusted, scaleGG.max() > 300 {
            var c = SIMD3<Double>(repeating: 1)
            for i in 0..<3 where scaleGG[i] > 100 { c[i] = min(max(scaleAG[i] / scaleGG[i], 0.98), 1.02) }
            imu.scale = imu.scale * (1 + (c - 1) * 0.5)
            scaleAG = .zero
            scaleGG = .zero
            devScaleUpdates += 1
        }
    }

    /// Face yaw from the Mac's camera vs. the glasses' heading at the same instant. The camera
    /// never moves, so their difference must stay constant: any change is glasses drift.
    private func learnFromCamera(_ samples: [FaceTracker.Sample], airPodsCorrection: Double) {
        for s in samples {
            devFace = s
            guard let g = imu.pose(at: s.time) else { continue }
            let gy = wrapAngle(g.q.yawPitch.yaw + airPodsCorrection)
            // Which way Vision's yaw turns relative to ours, learned from moving together.
            if let last = lastFacePair {
                let df = s.yaw - last.face, dg = wrapAngle(gy - last.glasses)
                if abs(df) > 0.01, abs(dg) > 0.01, abs(df) < 0.3, abs(dg) < 0.3 {
                    faceCorr.xy += df * dg; faceCorr.xx += df * df; faceCorr.yy += dg * dg; faceCorr.n += 1
                    let r = faceCorr.xy / sqrt(max(faceCorr.xx * faceCorr.yy, 1e-12))
                    if faceSign == 0, faceCorr.n > 20, abs(r) > 0.6 {
                        faceSign = r > 0 ? 1 : -1
                        cameraHeading.reset()
                        show("Mac camera locked on as a drift reference", seconds: 3)
                    }
                }
            }
            lastFacePair = (s.yaw, gy)
            guard faceSign != 0, abs(s.yaw) < 0.5 else { continue }
            cameraHeading.update(glasses: gy, airpods: faceSign * s.yaw, dt: 1 / 15)
            devFaceGap = wrapAngle(gy + cameraHeading.correction - faceSign * s.yaw)
        }
    }

    // MARK: Anchoring

    /// Locked axes follow the head: drop them from the head rotation (yaw, then pitch, then roll).
    /// Yaw gain > 1 turns the view further than the head ("neck saver").
    private func viewRotation(_ rel: simd_quatd, _ p: Params) -> simd_quatd {
        guard p.lockYaw || p.lockPitch || p.lockRoll || p.yawGain != 1 else { return rel }
        let a = rel.ypr
        return .ypr(SIMD3(p.lockYaw ? 0 : a.x * p.yawGain, p.lockPitch ? 0 : a.y, p.lockRoll ? 0 : a.z))
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

    /// Smooth Follow (VITURE SpaceWalker, Breezy): inside a dead zone the screen stays put; look
    /// past it and the screen glides back in front of you, then stays again. Hides drift on a sofa.
    private func smoothFollow(_ p: Params, _ dt: Double) {
        let rel = (anchor.inverse * steadyPose).yawPitch
        if !following, abs(rel.yaw) > p.followDeadzone || (!p.lockPitch && abs(rel.pitch) > p.followDeadzone * 0.75) {
            following = true
        }
        guard following else { return }
        let yp = steadyPose.yawPitch
        let goal = simd_quatd.yawPitch(yp.yaw, p.lockPitch ? 0 : yp.pitch)
        anchor = simd_normalize(simd_slerp(anchor, goal, min(dt / 0.35, 1)))
        if shortestAngle(anchor, goal) < 0.5 * .pi / 180 { following = false }
    }

    /// Looked away (> ~35°) for 10 s and now holding still: you've probably moved; recenter there.
    private func lookAway(_ speed: Double, _ dt: Double) {
        let rel = (anchor.inverse * steadyPose).yawPitch
        awayTime = abs(rel.yaw) > 0.6 || abs(rel.pitch) > 0.5 ? awayTime + dt : 0
        stillAway = awayTime > 10 && speed < 0.1 ? stillAway + dt : 0
        guard stillAway > 1.5 else { return }
        let yp = steadyPose.yawPitch
        anchor = .yawPitch(yp.yaw, yp.pitch)
        awayTime = 0
        stillAway = 0
        show("Recentered — you were looking elsewhere for a while", seconds: 3)
    }

    /// While you type you look at the caret: very slowly turn the screen so the caret sits where
    /// your head points (≤ 0.15 °/s, only within 12°). Eyes move more than heads, so it's a weak hint.
    private func typingPrior(_ c: CaretPoint, _ p: Params, _ dt: Double, aspect: Double) {
        guard p.yawGain == 1, !p.lockYaw else { return }
        let g = geometry(p, aspect: aspect, zoom: zoom * zoomFix)
        let x = (c.x - 0.5) * g.width
        let target = g.radius > 0 ? -x / g.radius : atan2(-x, g.distance)
        let rel = (anchor.inverse * steadyPose).yawPitch
        let error = wrapAngle(rel.yaw - target)
        guard abs(error) < 12 * .pi / 180 else { return }
        let maxStep = 0.15 * .pi / 180 * dt
        let step = min(max(error * dt / 15, -maxStep), maxStep)
        anchor = simd_normalize(simd_quatd(angle: step, axis: SIMD3(0, 1, 0)) * anchor)
        devTyping = true
    }

    // MARK: Developer overlay

    private func developerOverlay(_ s: IMU.Snapshot, airpods: Headphones.Sample?,
                                  pose: simd_quatd?, usingAirPods: Bool, p: Params, cpu: Double, now: CFTimeInterval) {
        devCPU = max(devCPU * 0.95, cpu)
        if devWindowStart == 0 { devWindowStart = now }
        if now - devWindowStart >= 1 {
            devFPS = Double(devFrames) / (now - devWindowStart)
            devDrawFPS = Double(devDrawn) / (now - devWindowStart)
            devCaptureFPS = Double(devCaptureFrames) / (now - devWindowStart)
            devFrames = 0
            devDrawn = 0
            devCaptureFrames = 0
            devWindowStart = now
        }
        guard now - devLastUpdate >= 0.1 else { return }
        devLastUpdate = now

        func d(_ r: Double) -> String { String(format: "%+7.2f", r * 180 / .pi) }
        func v(_ x: SIMD3<Double>, _ k: Double = 180 / .pi) -> String { String(format: "x %+7.3f  y %+7.3f  z %+7.3f", x.x * k, x.y * k, x.z * k) }
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
        lines.append(String(format: "RAYNEOPIN DEVELOPER   ticks %5.1f/s  drawn %5.1f/s (idle skipped)   work %.2f ms   %@   tracking: %@",
                            devFPS, devDrawFPS, devCPU * 1000, pacing == .metalLink ? "metal link" : "classic link", p.tracking.title))
        lines.append("")
        lines.append("GLASSES IMU   " + (s.connected ? String(format: "%3.0f Hz · %@ · %.1f °C · proximity %.0f · light? %.1f%@", raw.rate, state, raw.temperature,
                                                                  raw.proximity, raw.light, raw.asleep ? " · ASLEEP (not worn)" : "") : "not connected"))
        lines.append("  gyro °/s    " + v(raw.gyro) + "   |ω| " + String(format: "%.2f", simd_length(s.omega) * 180 / .pi))
        lines.append("  bias °/s    " + v(raw.bias) + "   still " + String(format: "%.1f s", raw.stillTime))
        lines.append("  accel m/s²  " + v(raw.acc, 1) + "   |a| " + String(format: "%.2f", simd_length(raw.acc))
                     + (raw.accelRejected ? "   GRAVITY REJECTED (accelerating)" : ""))
        lines.append("  fused °     " + ypr(s.q.ypr))
        lines.append("  temp model  " + (raw.temperatureSlope.map { "slope " + v($0) + " °/s per °C" } ?? "learning")
                     + String(format: "   span %.1f °C   shift %@", raw.temperatureSpan, v(raw.temperatureShift)))
        lines.append(String(format: "  gyro scale  x %.4f  y %.4f  z %.4f   (AirPods updates %d)   taps %d  peak jerk %.0f °/s²  peak Δa %.1f m/s²",
                            raw.scale.x, raw.scale.y, raw.scale.z, devScaleUpdates, raw.taps, raw.tapJerk * 180 / .pi, raw.tapAcc))
        if !raw.lastAck.isEmpty { lines.append("  last ack    " + raw.lastAck) }
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
            lines.append(String(format: "  calibration lag %+.0f ms (agreement %.2f) · turned %.0f%% nodded %.0f%% · quaternion %@ · pairs %d · fit error %.0f%% · jumps %d · restarts %d · glitches skipped %d%@",
                                calibration.lag * 1000, calibration.lagCorrelation, calibration.turned * 100, calibration.nodded * 100, calibration.inverted ? "world→body" : "body→world",
                                calibration.pairCount, calibration.fitError * 100, calibration.jumps, calibration.restarts, calibration.glitches,
                                calibration.seeded ? " · from last session" : ""))
            lines.append("  ears→glasses " + (calibration.X.map { ypr($0.ypr) } ?? "unknown")
                         + "   world " + (calibration.W.map { ypr($0.ypr) } ?? "unknown"))
        }
        if p.tracking == .both {
            lines.append("  heading     correction " + d(heading.correction) + "°   glasses−AirPods yaw " + (devYawGap.map { d($0) + "°" } ?? "—"))
        }
        if p.tracking != .glasses {
            lines.append(String(format: "  cross-check rate mismatch %.1f °/s · glitches ignored %d · reseats relearned %d%@", devAirPodsMismatch * 180 / .pi,
                                devAirPodsGlitches, calibration.reseats, CACurrentMediaTime() < airPodsDisturbedUntil ? " · IGNORING AIRPODS NOW" : ""))
            lines.append("  bias learn  residual " + v(biasResidual) + String(format: "   (%.0f s, rejected %d)   applied ", biasLearnTime, devBiasRejected) + v(devBiasApplied))
        }
        if p.cameraDrift {
            lines.append("CAMERA        " + (devFace.map { String(format: "face yaw %+.1f° pitch %+.1f° · %@", $0.yaw * 180 / .pi, $0.pitch * 180 / .pi,
                                                              faceSign == 0 ? "learning direction (turn your head)" : "locked") } ?? "no face")
                         + "   correction " + d(cameraHeading.correction) + "°   gap " + (devFaceGap.map { d($0) + "°" } ?? "—"))
        }
        lines.append("")
        lines.append("PIPELINE      pose " + (pose.map { ypr($0.ypr) } ?? "none"))
        lines.append("  anchor      " + ypr(anchor.ypr) + (following ? "   FOLLOWING" : "") + (devTyping ? "   typing prior" : ""))
        lines.append("  head→view   " + ypr(devHead.ypr) + "   (after locks)")
        lines.append("  locks       yaw \(onOff(p.lockYaw))  pitch \(onOff(p.lockPitch))  roll \(onOff(p.lockRoll))"
                     + "   steady \(onOff(p.steady)) (" + String(format: "%.3f°", devSteadyDelta * 180 / .pi) + ")"
                     + "   auto drift \(onOff(p.autoRecenter))   follow \(onOff(p.follow))" + (p.paused ? "   PAUSED" : ""))
        lines.append(String(format: "  filter      %@   cutoff %.1f Hz   predict %.1f ms%@ (+7 ms bottom row)   trim %+.0f ms",
                            p.smoothing.title, euro.cutoff, prediction * 1000,
                            devPresentIn.map { String(format: " (present in %.1f ms)", $0 * 1000) } ?? "", p.predictionTrim * 1000))
        lines.append(String(format: "  view        zoom %.0f%% (target %.0f%%, 1:1 fix ×%.3f)   FOV %.0f°   texels/pixel %.2f   pixel lock %.0f%%   sharpness %.1f %@",
                            zoom * 100, p.zoom * 100, zoomFix, p.fovDiagonal, devTexelsPerPixel, lockBlend * 100, p.sharpness, p.sharpenStyle.rawValue))
        lines.append("")
        lock.lock()
        let displayInfo = developerDisplayInfo
        lock.unlock()
        lines.append("DISPLAY       " + displayInfo)
        lines.append(String(format: "  capture     %.0f fps (only when the screen changes)   buffer %.0f×%.0f   screens %d   zero-copy %d · partial %d · full %d",
                            devCaptureFPS, devCaptureSize.width, devCaptureSize.height, panels.count,
                            panels[0].zeroCopies, panels[0].partialCopies, panels[0].copies))
        let text = lines.joined(separator: "\n")
        devShown = true
        DispatchQueue.main.async {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.devLayer.string = text
            self.devLayer.isHidden = false
            self.devRight.string = text
            self.devRight.isHidden = !self.stereo
            CATransaction.commit()
            self.onDeveloperText?(text)
        }
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
            self.hudRight.string = text
            CATransaction.commit()
        }
    }

    // MARK: Drawing

    /// New capture frame -> texture, only when it changed. Zero copy when mipmaps aren't needed;
    /// otherwise only the changed areas are copied into the mipmapped texture.
    private func upload(_ panel: Panel, _ cb: MTLCommandBuffer) {
        let switching = panel.wantsMips != panel.hasMips
        guard let cache = textureCache, panel.capture.latestSerial() != panel.serial || switching,
              let frame = panel.capture.takeFrame() else { return }
        panel.serial = frame.serial
        let pb = frame.buffer
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        if panel.side == 0 {
            devCaptureFrames += 1
            devCaptureSize = CGSize(width: w, height: h)
        }
        var cvTex: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(nil, cache, pb, nil, pixelFormat, w, h, 0, &cvTex)
        guard let cvTex, let src = CVMetalTextureGetTexture(cvTex) else { return }
        panel.aspect = Double(w) / Double(h)

        // A frame still being drawn by the GPU must not go back to ScreenCaptureKit for reuse yet.
        if let old = panel.source { cb.addCompletedHandler { _ in _ = old } }
        guard panel.wantsMips else {
            panel.texture = src
            panel.source = (cvTex, pb)
            panel.hasMips = false
            panel.zeroCopies += 1
            return
        }
        var region = MTLRegionMake2D(0, 0, w, h)
        if panel.texture?.width != w || panel.texture?.height != h || !panel.hasMips {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: pixelFormat, width: w, height: h, mipmapped: true)
            d.usage = [.shaderRead]
            d.storageMode = .private
            panel.texture = device.makeTexture(descriptor: d)
            panel.copies += 1
        } else if let dirty = frame.dirty {
            let r = dirty.intersection(CGRect(x: 0, y: 0, width: w, height: h))
            if r.isEmpty { return } // nothing changed after all
            region = MTLRegionMake2D(Int(r.minX), Int(r.minY), Int(r.width.rounded(.up)), Int(r.height.rounded(.up)))
            region.size.width = min(region.size.width, w - region.origin.x)
            region.size.height = min(region.size.height, h - region.origin.y)
            panel.partialCopies += 1
        } else {
            panel.copies += 1
        }
        guard let dst = panel.texture, let blit = cb.makeBlitCommandEncoder() else { return }
        blit.copy(from: src, sourceSlice: 0, sourceLevel: 0, sourceOrigin: region.origin, sourceSize: region.size,
                  to: dst, destinationSlice: 0, destinationLevel: 0, destinationOrigin: region.origin)
        blit.generateMipmaps(for: dst)
        blit.endEncoding()
        panel.hasMips = true
        panel.source = nil
        cb.addCompletedHandler { _ in _ = (cvTex, pb) } // keep the source alive until the GPU is done
    }

    private func draw(_ drawable: CAMetalDrawable, _ f: Frame) {
        guard let cb = queue.makeCommandBuffer() else { return }
        for panel in panels { upload(panel, cb) }
        let p = f.params

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        guard let enc = cb.makeRenderCommandEncoder(descriptor: pass) else { return }
        let w = Double(drawable.texture.width), h = Double(drawable.texture.height)
        // Side-by-side: each eye gets half the panel with the same view (flat screen, no parallax).
        let eyes = stereo ? [0.0, w / 2] : [0.0]
        let eyeW = stereo ? w / 2 : w
        lock.lock()
        let cursor = cursor, cursorTexture = cursorTexture
        lock.unlock()
        enc.setRenderPipelineState(pipeline)
        enc.setFragmentSamplerState(sampler, index: 0)
        // Warmth: toward ~3400 K at full strength (less blue, easier on the eyes at night).
        let tint = SIMD4<Float>(Float(p.brightness), Float(p.brightness * (1 - 0.18 * p.warmth)),
                                Float(p.brightness * (1 - 0.5 * p.warmth)), 1)
        let exact = f.lockBlend >= 1
        let main = geometry(p, aspect: panels[0].aspect, zoom: f.zoom)
        for x in eyes {
            enc.setViewport(MTLViewport(originX: x, originY: 0, width: eyeW, height: h, znear: 0, zfar: 1))
            for panel in panels {
                guard let tex = panel.texture else { continue }
                let g = geometry(p, aspect: panel.aspect, zoom: f.zoom)
                // Side screens sit edge to edge with the main one, 2° apart; left is +yaw.
                let yaw = panel.side == 0 ? 0 : -Double(panel.side) * (main.halfAngle + g.halfAngle + 2 * .pi / 180)
                let locked = panel.side == 0 ? f.lockBlend : 0
                var m = [floatMatrix(viewProjection(f.head, g, yaw: yaw, p)), floatMatrix(viewProjection(f.headBottom, g, yaw: yaw, p)),
                         f.lockMatrix]
                enc.setVertexBytes(&m, length: MemoryLayout<simd_float4x4>.stride * 3, index: 0)
                let columns: UInt32 = g.radius > 0 ? 96 : 1
                var screen = ScreenUniform(size: SIMD2(Float(g.width), Float(g.height)), distance: Float(g.distance), radius: Float(g.radius),
                                           rect: SIMD4(0, 0, 1, 1), lockBlend: Float(locked), columns: columns)
                let texelsPerPixel = Double(tex.width) / (g.width / (2 * g.halfW) * eyeW)
                if panel.side == 0 { devTexelsPerPixel = texelsPerPixel }
                // Bicubic covers up to 1.6 texels per pixel, plain bilinear about 1; beyond, mipmaps.
                panel.wantsMips = texelsPerPixel > (p.smartFilter ? 1.6 : 1.05)
                let panelExact = panel.side == 0 && exact
                var look = Look(sharpness: panelExact ? 0 : Float(p.sharpness * (p.motionSharpen ? 1 - f.motion : 1)),
                                texelsPerPixel: Float(texelsPerPixel), sharpen: p.sharpenStyle == .rcas ? 0 : 1,
                                sampling: p.smartFilter ? 1 : 0, tint: tint, exact: panelExact ? 1 : 0)
                enc.setVertexBytes(&screen, length: MemoryLayout<ScreenUniform>.stride, index: 1)
                enc.setFragmentBytes(&look, length: MemoryLayout<Look>.stride, index: 0)
                enc.setFragmentTexture(tex, index: 0)
                enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: Int(2 * (columns + 1)))
                if let c = cursor, c.panel == panel.side, let cursorTexture {
                    // Screen-plane coordinates run −0.5…0.5, y up; the placement is top-left based.
                    screen.rect = SIMD4(Float(c.x + c.w / 2 - 0.5), Float(0.5 - c.y - c.h / 2), Float(c.w), Float(c.h))
                    screen.columns = 1
                    look = Look(sharpness: 0, texelsPerPixel: 1, sharpen: 0, sampling: 0, tint: tint, exact: 0)
                    enc.setVertexBytes(&screen, length: MemoryLayout<ScreenUniform>.stride, index: 1)
                    enc.setFragmentBytes(&look, length: MemoryLayout<Look>.stride, index: 0)
                    enc.setFragmentTexture(cursorTexture, index: 0)
                    enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
                }
            }
        }
        enc.endEncoding()
        cb.present(drawable)
        cb.commit()
    }

    private func geometry(_ p: Params, aspect: Double, zoom: Double) -> Geometry {
        let (w, h) = eyeSize
        let halfDiag = tan(p.fovDiagonal * .pi / 360)
        let halfW = halfDiag * w / sqrt(w * w + h * h)
        let halfH = halfDiag * h / sqrt(w * w + h * h)
        let distance = 1.0
        // Same pixel density whatever the shape: a 32:9 desktop is twice as wide as a 16:9 one.
        let width = 2 * distance * halfW * Renderer.baseWidth * zoom * max(aspect / (16.0 / 9.0), 1)
        // Ultrawide (21:9 and wider) bends around you, centered on your head, so its edges are as
        // far away — and as sharp — as its middle.
        let radius = p.curved && aspect > 2.2 ? distance : 0
        return Geometry(halfW: halfW, halfH: halfH, width: width, height: width / aspect, distance: distance, radius: radius)
    }

    /// Projection * camera (inverse head rotation) * where the screen sits (yaw for side screens,
    /// pitch for the height setting).
    private func viewProjection(_ head: simd_quatd, _ g: Geometry, yaw: Double, _ p: Params) -> simd_double4x4 {
        let near = 0.05, far = 100.0
        let proj = simd_double4x4(columns: (
            SIMD4(1 / g.halfW, 0, 0, 0),
            SIMD4(0, 1 / g.halfH, 0, 0),
            SIMD4(0, 0, far / (near - far), -1),
            SIMD4(0, 0, near * far / (near - far), 0)))
        let place = simd_quatd(angle: yaw, axis: SIMD3(0, 1, 0)) * simd_quatd(angle: p.screenPitch, axis: SIMD3(1, 0, 0))
        return proj * simd_double4x4(head.inverse * place)
    }

    /// The flat main screen drawn exactly 1:1 at whole-pixel offsets, facing you, centered where the
    /// perspective screen is. Only when that's close (within ~4% of its height at the corners, i.e.
    /// looking at it within a few degrees of straight on), since the corners shift by that much.
    private func pixelLock(vp: simd_double4x4, _ g: Geometry, texture: (w: Double, h: Double)) -> simd_float4x4? {
        let (ew, eh) = eyeSize
        func pixel(_ x: Double, _ y: Double) -> SIMD2<Double>? {
            let c = vp * SIMD4(x, y, -g.distance, 1)
            guard c.w > 0.01 else { return nil }
            return SIMD2((c.x / c.w + 1) / 2 * ew, (1 - c.y / c.w) / 2 * eh)
        }
        let W = g.width, H = g.height
        guard let tl = pixel(-W / 2, H / 2), let tr = pixel(W / 2, H / 2),
              let bl = pixel(-W / 2, -H / 2), let br = pixel(W / 2, -H / 2) else { return nil }
        let center = (tl + tr + bl + br) / 4
        let left = (center.x - texture.w / 2).rounded(), top = (center.y - texture.h / 2).rounded()
        let target = [SIMD2(left, top), SIMD2(left + texture.w, top), SIMD2(left, top + texture.h), SIMD2(left + texture.w, top + texture.h)]
        let deviation = zip([tl, tr, bl, br], target).map { simd_length($0 - $1) }.max() ?? .infinity
        guard deviation < max(6, 0.04 * texture.h) else { return nil }
        let a = 2 * texture.w / (W * ew), b = 2 * (left + texture.w / 2) / ew - 1
        let c = 2 * texture.h / (H * eh), e = 1 - 2 * (top + texture.h / 2) / eh
        return simd_float4x4(columns: (SIMD4(Float(a), 0, 0, 0), SIMD4(0, Float(c), 0, 0), SIMD4(0, 0, 0, 0),
                                       SIMD4(Float(b), Float(e), 0.5, 1)))
    }
}

func floatMatrix(_ m: simd_double4x4) -> simd_float4x4 {
    simd_float4x4(SIMD4<Float>(m.columns.0), SIMD4<Float>(m.columns.1), SIMD4<Float>(m.columns.2), SIMD4<Float>(m.columns.3))
}
