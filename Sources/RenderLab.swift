// Render lab: real macOS text pushed through the glasses' pipeline offscreen, in every
// combination of the readability options, and scored against the same text drawn natively at the
// size it appears in the glasses. No glasses or display needed:
//
//   RayNeoPin --render-lab [output folder]
//
// Scores (1.00 = identical to native text):
//   sharp   edge energy vs native (lower = blurrier)
//   weight  how much light the text adds vs native (above 1 = glow/bold, below = thin/faded)
//   blur    share of half-tone pixels vs native (above 1 = soft edges)
//   ring    pixels beyond the text/background colors (halos from overshoot), per mille

import AppKit
import Metal
import simd

enum RenderLab {
    struct Theme { let name: String; let bg: CGFloat; let fg: CGFloat }
    struct Source { let name: String; let scale: Int; let logical: (w: Int, h: Int) }
    struct Variant {
        var gamma: Bool
        var smart: Bool
        var sharpen: Float
        var rcas: Bool
        var lock: Bool // exact 1:1 at whole pixels (only meaningful when the source matches)
        var yaw: Double // degrees: sub-pixel placement when not locked

        var name: String {
            "\(gamma ? "gamma" : "linear") \(smart ? "smart" : "plain") "
                + (sharpen == 0 ? "sharp-off" : "\(rcas ? "rcas" : "unsharp")\(sharpen)") + (lock ? " LOCK" : String(format: " yaw%.2f", yaw))
        }
    }
    struct Score { var sharp: Double; var weight: Double; var blur: Double; var ring: Double
        /// Distance from native: 0 is perfect.
        var error: Double { abs(log(sharp)) + abs(log(weight)) + abs(log(max(blur, 0.01))) + ring / 20 }
    }

    static let eye = (w: 1920, h: 1080)
    static let fov = 43.0

    static func run(output: URL) {
        setvbuf(stdout, nil, _IOLBF, 0)
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            print("Render lab: no Metal device"); exit(1)
        }
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let themes = [Theme(name: "dark", bg: 0.12, fg: 0.88), Theme(name: "light", bg: 1.0, fg: 0.08)]
        // What the glasses show today: their own 1920 desktop shrunk to 83%; Crisp 1600 (~1:1);
        // Crisp Retina (1600 logical drawn at 2×).
        let sources = [Source(name: "glasses-1920", scale: 1, logical: (1920, 1080)),
                       Source(name: "crisp-1600", scale: 1, logical: (1600, 900)),
                       Source(name: "retina-1600@2x", scale: 2, logical: (1600, 900))]
        var variants: [Variant] = []
        for gamma in [false, true] {
            for smart in [false, true] {
                for (sharpen, rcas) in [(Float(0), true), (0.5, true), (0.8, true), (0.5, false)] {
                    variants.append(Variant(gamma: gamma, smart: smart, sharpen: sharpen, rcas: rcas, lock: false, yaw: 0.37))
                }
            }
            variants.append(Variant(gamma: gamma, smart: false, sharpen: 0, rcas: true, lock: true, yaw: 0))
        }

        var rows: [(String, Score)] = []
        for theme in themes {
            for source in sources {
                let native = nativeImage(theme, source)
                let nativeStats = stats(native, theme)
                let at = textPixel(source)
                save(crop(native, at), output.appendingPathComponent("\(theme.name)-\(source.name)-0-native.png"))
                for v in variants {
                    if v.lock, source.logical.w != 1600 || source.scale != 1 { continue }
                    guard let img = render(device, queue, theme, source, v) else { print("render failed"); continue }
                    let s = stats(img, theme)
                    let score = Score(sharp: s.edge / nativeStats.edge, weight: s.light / nativeStats.light,
                                      blur: s.half / max(nativeStats.half, 1e-9), ring: s.ring * 1000)
                    let label = "\(theme.name) \(source.name) \(v.name)"
                    rows.append((label, score))
                    save(crop(img, at), output.appendingPathComponent(label.replacingOccurrences(of: " ", with: "-") + ".png"))
                }
            }
        }
        print(String(format: "%-62@ %6@ %6@ %6@ %6@ %6@", "variant" as NSString, "sharp" as NSString, "weight" as NSString,
                     "blur" as NSString, "ring‰" as NSString, "error" as NSString))
        for (label, s) in rows.sorted(by: { $0.1.error < $1.1.error }) {
            print(String(format: "%-62@ %6.2f %6.2f %6.2f %6.1f %6.2f", label as NSString, s.sharp, s.weight, s.blur, s.ring, s.error))
        }
        print("Crops (3× zoom) in \(output.path)")
        exit(0)
    }

    // MARK: Text

    static let lines: [(String, NSFont)] = [
        ("The quick brown fox jumps over the lazy dog 0123456789", .systemFont(ofSize: 13)),
        ("func render(_ frame: Frame) -> Bool { return lock != nil } // ilI1|", .monospacedSystemFont(ofSize: 12, weight: .regular)),
        ("Small menu text — Settings, Window, Help · minimum readable size", .systemFont(ofSize: 11)),
        ("Bold heading: Pinned screen sharpness test", .boldSystemFont(ofSize: 15)),
        ("Thin strokes: illumination, minimum, ||||||||, ////////, ........", .systemFont(ofSize: 12, weight: .light)),
    ]

    /// Draws the sample text block at logical `origin`, `k` pixels per point.
    static func drawText(_ ctx: CGContext, _ theme: Theme, origin: CGPoint, k: CGFloat) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        ctx.saveGState()
        ctx.translateBy(x: origin.x * k, y: origin.y * k)
        ctx.scaleBy(x: k, y: k)
        var y: CGFloat = 0
        for _ in 0..<4 {
            for (text, font) in lines {
                NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor(white: theme.fg, alpha: 1)])
                    .draw(at: CGPoint(x: 0, y: y))
                y += font.pointSize * 1.6
            }
        }
        ctx.restoreGState()
        NSGraphicsContext.restoreGraphicsState()
    }

    static func context(_ w: Int, _ h: Int) -> CGContext {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        // Flipped (y down), like a screen.
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        return ctx
    }

    /// Text block placement on the source desktop, in points.
    static let textOrigin = CGPoint(x: 220, y: 200)

    /// The desktop as captured: logical size × scale pixels.
    static func sourceImage(_ theme: Theme, _ source: Source) -> CGContext {
        let w = source.logical.w * source.scale, h = source.logical.h * source.scale
        let ctx = context(w, h)
        ctx.setFillColor(gray: theme.bg, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        drawText(ctx, theme, origin: textOrigin, k: CGFloat(source.scale))
        return ctx
    }

    /// Where the screen lands in the eye at zoom 1, looking straight at it.
    static func screenRect(aspect: Double) -> CGRect {
        let w = Renderer.baseWidth * Double(eye.w), h = w / aspect
        return CGRect(x: (Double(eye.w) - w) / 2, y: (Double(eye.h) - h) / 2, width: w, height: h)
    }

    /// The same desktop as a real monitor of that size would draw it: text rendered at the final size.
    static func nativeImage(_ theme: Theme, _ source: Source) -> [UInt8] {
        let ctx = context(eye.w, eye.h)
        let r = screenRect(aspect: Double(source.logical.w) / Double(source.logical.h))
        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: eye.w, height: eye.h))
        ctx.setFillColor(gray: theme.bg, alpha: 1)
        ctx.fill(r)
        let k = r.width / CGFloat(source.logical.w)
        drawText(ctx, theme, origin: CGPoint(x: r.minX / k + textOrigin.x, y: r.minY / k + textOrigin.y), k: k)
        return bytes(ctx)
    }

    static func bytes(_ ctx: CGContext) -> [UInt8] {
        let n = ctx.bytesPerRow * ctx.height
        return Array(UnsafeBufferPointer(start: ctx.data!.assumingMemoryBound(to: UInt8.self), count: n))
    }

    // MARK: Pipeline

    static func render(_ device: MTLDevice, _ queue: MTLCommandQueue, _ theme: Theme, _ source: Source, _ v: Variant) -> [UInt8]? {
        let format: MTLPixelFormat = v.gamma ? .bgra8Unorm : .bgra8Unorm_srgb
        let src = sourceImage(theme, source)
        let tw = src.width, th = src.height
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: tw, height: th, mipmapped: true)
        td.usage = [.shaderRead]
        guard let tex = device.makeTexture(descriptor: td) else { return nil }
        tex.replace(region: MTLRegionMake2D(0, 0, tw, th), mipmapLevel: 0, withBytes: src.data!, bytesPerRow: src.bytesPerRow)

        let od = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: eye.w, height: eye.h, mipmapped: false)
        od.usage = [.renderTarget, .shaderRead]
        od.storageMode = .shared
        guard let out = device.makeTexture(descriptor: od),
              let library = try? device.makeLibrary(source: Renderer.shader, options: nil) else { return nil }
        let pd = MTLRenderPipelineDescriptor()
        pd.vertexFunction = library.makeFunction(name: "vs")
        pd.fragmentFunction = library.makeFunction(name: "fs")
        pd.colorAttachments[0].pixelFormat = format
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: pd) else { return nil }
        let sd = MTLSamplerDescriptor()
        sd.minFilter = .linear; sd.magFilter = .linear; sd.mipFilter = .linear; sd.maxAnisotropy = 8
        sd.sAddressMode = .clampToEdge; sd.tAddressMode = .clampToEdge
        let sampler = device.makeSamplerState(descriptor: sd)!

        guard let cb = queue.makeCommandBuffer(), let blit = cb.makeBlitCommandEncoder() else { return nil }
        blit.generateMipmaps(for: tex)
        blit.endEncoding()
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = out
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        guard let enc = cb.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        enc.setRenderPipelineState(pipeline)
        enc.setFragmentSamplerState(sampler, index: 0)
        enc.setViewport(MTLViewport(originX: 0, originY: 0, width: Double(eye.w), height: Double(eye.h), znear: 0, zfar: 1))

        let aspect = Double(tw) / Double(th)
        let w = Double(eye.w), h = Double(eye.h)
        let halfDiag = tan(fov * .pi / 360)
        let halfW = halfDiag * w / sqrt(w * w + h * h), halfH = halfDiag * h / sqrt(w * w + h * h)
        let width = 2 * halfW * Renderer.baseWidth, height = width / aspect
        var drawnW = width / (2 * halfW) * w
        var vp: simd_float4x4
        if v.lock {
            // 1:1 at whole pixels, as the renderer's pixel lock does.
            drawnW = Double(tw)
            let left = ((w - Double(tw)) / 2).rounded(), top = ((h - Double(th)) / 2).rounded()
            let a = 2 * Double(tw) / (width * w), b = 2 * (left + Double(tw) / 2) / w - 1
            let c = 2 * Double(th) / (height * h), e = 1 - 2 * (top + Double(th) / 2) / h
            vp = simd_float4x4(columns: (SIMD4(Float(a), 0, 0, 0), SIMD4(0, Float(c), 0, 0), SIMD4(0, 0, 0, 0), SIMD4(Float(b), Float(e), 0.5, 1)))
        } else {
            let near = 0.05, far = 100.0
            let proj = simd_double4x4(columns: (SIMD4(1 / halfW, 0, 0, 0), SIMD4(0, 1 / halfH, 0, 0),
                                                SIMD4(0, 0, far / (near - far), -1), SIMD4(0, 0, near * far / (near - far), 0)))
            let head = simd_quatd(angle: v.yaw * .pi / 180, axis: SIMD3(0, 1, 0))
            vp = floatMatrix(proj * simd_double4x4(head.inverse))
        }
        var m = [vp, vp, vp]
        enc.setVertexBytes(&m, length: MemoryLayout<simd_float4x4>.stride * 3, index: 0)
        var screen = Renderer.ScreenUniform(size: SIMD2(Float(width), Float(height)), distance: 1, radius: 0,
                                            rect: SIMD4(0, 0, 1, 1), lockBlend: v.lock ? 1 : 0, columns: 1)
        var look = Renderer.Look(sharpness: v.lock ? 0 : v.sharpen, texelsPerPixel: Float(Double(tw) / drawnW),
                                 sharpen: v.rcas ? 0 : 1, sampling: v.smart ? 1 : 0, tint: SIMD4(1, 1, 1, 1), exact: v.lock ? 1 : 0)
        enc.setVertexBytes(&screen, length: MemoryLayout<Renderer.ScreenUniform>.stride, index: 1)
        enc.setFragmentBytes(&look, length: MemoryLayout<Renderer.Look>.stride, index: 0)
        enc.setFragmentTexture(tex, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        enc.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        var px = [UInt8](repeating: 0, count: eye.w * eye.h * 4)
        out.getBytes(&px, bytesPerRow: eye.w * 4, from: MTLRegionMake2D(0, 0, eye.w, eye.h), mipmapLevel: 0)
        return px
    }

    // MARK: Scoring

    /// The text block in the eye image (rows ≈ the drawn lines, a margin inside the screen).
    static var region: (x0: Int, x1: Int, y0: Int, y1: Int) { (330, 1450, 250, 720) }

    static func luma(_ p: [UInt8], _ x: Int, _ y: Int) -> Double {
        let i = (y * eye.w + x) * 4
        return (Double(p[i]) + Double(p[i + 1]) + Double(p[i + 2])) / (3 * 255)
    }

    static func stats(_ p: [UInt8], _ theme: Theme) -> (edge: Double, light: Double, half: Double, ring: Double) {
        let r = region
        let bg = Double(theme.bg), fg = Double(theme.fg)
        let lo = min(bg, fg) - 0.03, hi = max(bg, fg) + 0.03
        var edge = 0.0, light = 0.0, half = 0.0, ring = 0.0, n = 0.0
        for y in r.y0..<r.y1 {
            for x in r.x0..<r.x1 {
                let l = luma(p, x, y)
                edge += abs(l - luma(p, x + 1, y)) + abs(l - luma(p, x, y + 1))
                let t = (l - bg) / (fg - bg) // 0 background … 1 text
                light += t
                if t > 0.25, t < 0.75 { half += 1 }
                if l < lo || l > hi { ring += 1 }
                n += 1
            }
        }
        return (edge / n, light / n, half / n, ring / n)
    }

    // MARK: Output

    /// Where the text block starts in the eye image.
    static func textPixel(_ source: Source) -> (Int, Int) {
        let r = screenRect(aspect: Double(source.logical.w) / Double(source.logical.h))
        let k = r.width / CGFloat(source.logical.w)
        return (Int(r.minX + textOrigin.x * k) - 6, Int(r.minY + textOrigin.y * k) - 4)
    }

    /// 3× nearest-neighbour zoom of a patch of text, for looking at.
    static func crop(_ p: [UInt8], _ at: (Int, Int)) -> CGImage {
        let (cx, cy, cw, ch, z) = (at.0, at.1, 300, 110, 3)
        let ctx = CGContext(data: nil, width: cw * z, height: ch * z, bitsPerComponent: 8, bytesPerRow: cw * z * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        let dst = ctx.data!.assumingMemoryBound(to: UInt8.self)
        for y in 0..<(ch * z) {
            for x in 0..<(cw * z) {
                let s = ((cy + y / z) * eye.w + cx + x / z) * 4, d = (y * cw * z + x) * 4
                for c in 0..<4 { dst[d + c] = p[s + c] }
            }
        }
        return ctx.makeImage()!
    }

    static func save(_ img: CGImage?, _ url: URL) {
        guard let img, let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, img, nil)
        CGImageDestinationFinalize(dest)
    }
}
