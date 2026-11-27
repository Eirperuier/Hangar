import HangarCore
import Metal
import MetalKit
import QuartzCore
import UIKit

/// Where something works on a picture, in its units (0 to 1 each way from its top left), to be shown working there.
public enum HangarArea: Sendable, Equatable {
    /// All of it.
    case whole
    /// Where it's painted: the strokes shown.
    case painted
    /// Boxes over it (text found, a part to bring close).
    case boxes([CGRect])
    /// Round it, out to a frame past its edges (Extend's): what's to be drawn.
    case around(CGRect)
}

/// How the light over a picture looks: where it's painted (Photos' Clean Up brush, a frost of the picture under it,
/// bright where the finger's just been and fading behind it), what stays of the paint until it's worked (kept as a
/// fainter frost), the rainbow round its edge, and the picture lit while something works on it (its lines lit in
/// colours that move through them, over a pink veil). Brighter than white where the screen can show it.
public struct HangarGlow: Sendable, Equatable {
    /// How much of the frost stays where it's painted, once the finger's gone on.
    public var trail: CGFloat = 0.38
    /// How much white is in the frost (the rest the picture under it, blurred).
    public var frost: CGFloat = 0.32
    /// How long the paint stays bright behind the finger, in seconds.
    public var tail: Double = 0.45
    /// How strong the rainbow round the paint's edge is.
    public var rim: CGFloat = 1
    /// How bright the brightest is, in whites: past 1 where the screen shows more than white (no brighter than it can).
    public var brightest: CGFloat = 1.6
    /// The veil over the picture while something works on it, and how much of it shows.
    public var veil: UIColor = UIColor(red: 1, green: 0.62, blue: 0.82, alpha: 1)
    public var veilAmount: CGFloat = 0.22

    public init() {}
}

/// The light over a picture (`HangarGlow`): the strokes painted on it, and where something works on it. Its picture's
/// frame is in its own coordinates, set as the picture moves and zooms; the strokes are `HangarStroke`s, in the
/// picture's units, as a model is given them (`HangarRetouch.mask`) and as Flowith's web canvas keeps them: what's
/// lit is exactly what was painted. Drawn by Metal at the screen's frames while anything moves, not at all while
/// nothing does; each new piece of a stroke is laid once, however long the stroke.
@MainActor
public final class HangarGlowView: UIView {
    override public class var layerClass: AnyClass { CAMetalLayer.self }

    public var look = HangarGlow() { didSet { if look != oldValue { setNeedsDraw() } } }
    /// Where the picture is, in its coordinates.
    public var pictureFrame = CGRect.zero { didSet { if pictureFrame != oldValue { drawNow() } } }
    /// What of it the picture's seen through (a zoomed picture's window), in its coordinates; nil for all of it.
    /// What's drawn round the picture (`HangarArea.around`) isn't held to it.
    public var clipFrame: CGRect? { didSet { if clipFrame != oldValue { drawNow() } } }

    /// The strokes kept (painted, waiting to be worked).
    public var strokes: [HangarStroke] {
        get { kept }
        set {
            guard newValue != kept || live != nil else { return }
            kept = newValue
            live = nil
            restamp = true
            setNeedsDraw()
        }
    }

    private let kit = GlowKit.shared
    private var picture: MTLTexture?
    private var pictureSize = CGSize(width: 1, height: 1)
    private var cover: MTLTexture?
    private var heat: MTLTexture?
    private var kept: [HangarStroke] = []
    private var live: HangarStroke?
    /// Pieces of strokes laid since the last frame, in the cover's pixels; those still bright, with when.
    private var pending: [Segment] = []
    private var recent: [(segment: Segment, at: Double, lifted: Double?)] = []
    private var restamp = false
    private var area: HangarArea?
    private var workStart = 0.0
    private var workEnd: Double?
    private var fadeStart: Double?
    private var fadeFrom = 1.0
    private var clock = 0.0
    private var lastTick: CFTimeInterval?
    private var link: CADisplayLink?
    private var dirty = false

    override public init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isOpaque = false
        backgroundColor = .clear
        let layer = metalLayer
        layer.device = kit.device
        layer.pixelFormat = .rgba16Float
        layer.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
        layer.isOpaque = false
        layer.framebufferOnly = true
        // Drawn with the picture's own move (a pinch), not a frame behind it.
        layer.presentsWithTransaction = true
        accessibilityIgnoresInvertColors = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

    /// The picture under it, its frost and the lines lit as something works on it; its strokes go with it.
    public func show(_ image: CGImage?) {
        guard let image else {
            picture = nil
            return setNeedsDraw()
        }
        picture = try? kit.loader.newTexture(cgImage: image, options: [.SRGB: true, .generateMipmaps: true, .allocateMipmaps: true,
                                                                       .textureStorageMode: MTLStorageMode.private.rawValue])
        let size = CGSize(width: image.width, height: image.height)
        if size != pictureSize {
            pictureSize = size
            makeCover()
        }
        setNeedsDraw()
    }

    /// The stroke under a finger as it is now (more points as it goes on).
    public func paint(_ stroke: HangarStroke) {
        let from = live.map { $0.width == stroke.width && $0.points.count <= stroke.points.count ? $0.points.count : 0 } ?? 0
        if from == 0 { live = HangarStroke(points: [], width: stroke.width, color: stroke.color) }
        let added = Array(stroke.points[from...])
        guard !added.isEmpty else { return }
        let last = live?.points.last
        live?.points.append(contentsOf: added)
        lay(stroke.width, from: last, through: added)
        startTicking()
    }

    /// The stroke under the finger let go: kept, the whole of it flashing as it goes into the trail.
    public func lift() {
        guard let stroke = live else { return }
        live = nil
        kept.append(stroke)
        // The whole of it, however long ago it began.
        recent.removeAll { $0.lifted == nil }
        recent += segments(of: stroke).map { ($0, clock, clock) }
        startTicking()
    }

    /// Shown working over `area` (the picture lit, its lines moving with colour), or not.
    public func work(_ area: HangarArea?) {
        guard let area else {
            // Going, over a moment.
            if self.area != nil, workEnd == nil { workEnd = clock }
            return startTicking()
        }
        guard area != self.area || workEnd != nil else { return }
        if self.area == nil || workEnd == nil { workStart = clock }
        self.area = area
        workEnd = nil
        fadeStart = nil
        startTicking()
    }

    /// The strokes taken off, fading if `fading`; and whatever was working.
    public func clear(fading: Bool) {
        kept = []
        live = nil
        guard fading else {
            area = nil
            recent = []
            restamp = true
            return setNeedsDraw()
        }
        fadeStart = clock
        fadeFrom = 1
        startTicking()
    }

    // MARK: Laying strokes

    struct Segment {
        var a: SIMD2<Float>
        var b: SIMD2<Float>
        var radius: Float
        var strength: Float
    }

    /// The cover: the picture's shape, its longer side at most 1536 pixels.
    private func makeCover() {
        let long = max(pictureSize.width, pictureSize.height)
        let k = min(1, 1536 / max(long, 1))
        let w = max(1, Int((pictureSize.width * k).rounded())), h = max(1, Int((pictureSize.height * k).rounded()))
        func texture() -> MTLTexture? {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: w, height: h, mipmapped: true)
            d.usage = [.renderTarget, .shaderRead]
            d.storageMode = .private
            return kit.device.makeTexture(descriptor: d)
        }
        cover = texture()
        heat = texture()
        restamp = true
    }

    private var coverSize: SIMD2<Float> { SIMD2(Float(cover?.width ?? 1), Float(cover?.height ?? 1)) }

    /// Pieces of a stroke `width` wide (of the shorter side), from `from` through `points` (the picture's units).
    private func lay(_ width: CGFloat, from: CGPoint?, through points: [CGPoint]) {
        let size = coverSize
        let radius = Float(width) * min(size.x, size.y) / 2
        var previous = from.map { SIMD2(Float($0.x), Float($0.y)) * size }
        for point in points {
            let p = SIMD2(Float(point.x), Float(point.y)) * size
            let segment = Segment(a: previous ?? p, b: p, radius: radius, strength: 1)
            pending.append(segment)
            recent.append((segment, clock, nil))
            previous = p
        }
    }

    private func segments(of stroke: HangarStroke) -> [Segment] {
        let size = coverSize
        let radius = Float(stroke.width) * min(size.x, size.y) / 2
        let points = stroke.points.map { SIMD2(Float($0.x), Float($0.y)) * size }
        guard let first = points.first else { return [] }
        guard points.count > 1 else { return [Segment(a: first, b: first, radius: radius, strength: 1)] }
        return zip(points, points.dropFirst()).map { Segment(a: $0, b: $1, radius: radius, strength: 1) }
    }

    // MARK: Drawing

    private func setNeedsDraw() {
        dirty = true
        startTicking()
    }

    private func startTicking() {
        guard link == nil, window != nil else { return }
        let link = CADisplayLink(target: GlowTicker(self), selector: #selector(GlowTicker.tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    private func stopTicking() {
        link?.invalidate()
        link = nil
        lastTick = nil
    }

    override public func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { stopTicking() } else { setNeedsDraw() }
    }

    override public func layoutSubviews() {
        super.layoutSubviews()
        let scale = window?.screen.scale ?? traitCollection.displayScale
        let size = CGSize(width: max(1, bounds.width * scale), height: max(1, bounds.height * scale))
        if metalLayer.drawableSize != size {
            metalLayer.drawableSize = size
            dirty = true
            drawNow()
        }
    }

    fileprivate func tick(_ link: CADisplayLink) {
        let now = link.timestamp
        var dt = lastTick.map { now - $0 } ?? 0
        #if DEBUG
        dt *= HangarEditor.debugSpeed
        #endif
        lastTick = now
        clock += dt
        // What's bright behind the finger, or flashing: until it's faded into the trail.
        let gone = look.tail * 3
        recent.removeAll { item in item.lifted.map { clock - $0 > 0.9 } ?? (clock - item.at > gone) }
        if let workEnd, clock - workEnd > 0.3 {
            self.workEnd = nil
            area = nil
        }
        if let fadeStart, clock - fadeStart > 0.35 {
            self.fadeStart = nil
            area = nil
            recent = []
            restamp = true
        }
        let moving = !recent.isEmpty || area != nil || fadeStart != nil || live != nil
        if moving || dirty {
            draw()
        }
        if !moving { stopTicking() }
    }

    /// Drawn at once (the picture moved under it), if there's anything to draw.
    private func drawNow() {
        dirty = true
        guard window != nil else { return }
        draw()
    }

    private func draw() {
        dirty = false
        guard let cover, let heat, bounds.width > 0, let buffer = kit.queue.makeCommandBuffer() else { return }
        // The cover: laid again whole, or only what's new.
        if restamp {
            restamp = false
            pending = []
            stamp(kept.flatMap(segments) + (live.map(segments) ?? []), into: cover, clearing: true, buffer: buffer)
        } else if !pending.isEmpty {
            stamp(pending, into: cover, clearing: false, buffer: buffer)
            pending = []
        }
        // What's bright: behind the finger, fading over `tail`; a stroke let go flashing, then fading.
        let tail = max(look.tail, 0.01)
        let bright = recent.map { item -> Segment in
            var s = item.segment
            let fresh = exp(-(clock - item.at) / tail)
            let flash = item.lifted.map { lifted -> Double in
                let t = clock - lifted
                return t < 0.12 ? t / 0.12 : exp(-(t - 0.12) / 0.3)
            } ?? 0
            s.strength = Float(max(fresh, flash))
            return s
        }
        stamp(bright, into: heat, clearing: true, buffer: buffer)
        if let blit = buffer.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: cover)
            blit.generateMipmaps(for: heat)
            blit.endEncoding()
        }
        // Past white only while something's bright (fresh paint, a flash, a job): the screen's left as it was otherwise.
        let lit = !recent.isEmpty || area != nil
        if metalLayer.wantsExtendedDynamicRangeContent != lit { metalLayer.wantsExtendedDynamicRangeContent = lit }
        guard let drawable = metalLayer.nextDrawable() else { return buffer.commit() }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        if let encoder = buffer.makeRenderCommandEncoder(descriptor: pass), let uniforms = uniforms(drawable: drawable.texture) {
            var u = uniforms
            encoder.setRenderPipelineState(kit.glow)
            encoder.setFragmentBytes(&u, length: MemoryLayout<GlowUniforms>.stride, index: 0)
            encoder.setFragmentTexture(picture ?? kit.blank, index: 0)
            encoder.setFragmentTexture(cover, index: 1)
            encoder.setFragmentTexture(heat, index: 2)
            encoder.setFragmentSamplerState(kit.sampler, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
        }
        buffer.commit()
        buffer.waitUntilScheduled()
        drawable.present()
    }

    private func stamp(_ segments: [Segment], into texture: MTLTexture, clearing: Bool, buffer: MTLCommandBuffer) {
        guard clearing || !segments.isEmpty else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = clearing ? .clear : .load
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        if !segments.isEmpty {
            encoder.setRenderPipelineState(kit.stamp)
            var size = coverSize
            encoder.setVertexBytes(&size, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
            // In pieces Metal takes as bytes (4 KB at a time); a long stroke's a few.
            let per = 4096 / MemoryLayout<Segment>.stride
            var start = 0
            while start < segments.count {
                let chunk = Array(segments[start..<min(start + per, segments.count)])
                chunk.withUnsafeBytes { encoder.setVertexBytes($0.baseAddress!, length: $0.count, index: 0) }
                encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: chunk.count)
                start += per
            }
        }
        encoder.endEncoding()
    }

    private func uniforms(drawable: MTLTexture) -> GlowUniforms? {
        let scale = Float(drawable.width) / Float(max(bounds.width, 1))
        var u = GlowUniforms()
        u.frame = SIMD4(Float(pictureFrame.minX) * scale, Float(pictureFrame.minY) * scale,
                        Float(pictureFrame.width) * scale, Float(pictureFrame.height) * scale)
        guard u.frame.z > 0, u.frame.w > 0 else { return nil }
        if let clip = clipFrame {
            u.clip = SIMD4(Float(clip.minX) * scale, Float(clip.minY) * scale, Float(clip.maxX) * scale, Float(clip.maxY) * scale)
        }
        let still = UIAccessibility.isReduceMotionEnabled
        u.time = Float(still ? 0 : clock)
        let headroom = Float(window?.screen.currentEDRHeadroom ?? 1)
        u.bright = max(1, min(Float(look.brightest), headroom))
        u.trail = Float(look.trail)
        u.frost = Float(look.frost)
        u.rim = Float(look.rim)
        u.opacity = fadeStart.map { Float(max(0, 1 - (clock - $0) / 0.35)) } ?? 1
        u.hasPicture = picture == nil ? 0 : 1
        u.coverTexel = SIMD2(1, 1) / coverSize
        var veil = (r: CGFloat(0), g: CGFloat(0), b: CGFloat(0), a: CGFloat(0))
        look.veil.getRed(&veil.r, green: &veil.g, blue: &veil.b, alpha: &veil.a)
        // The veil's colour, as light (linear).
        func linear(_ v: CGFloat) -> Float { Float(v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)) }
        u.veil = SIMD4(linear(veil.r), linear(veil.g), linear(veil.b), Float(look.veilAmount))
        if let area {
            u.workAge = Float(clock - workStart)
            u.workLevel = workEnd.map { Float(max(0, 1 - (clock - $0) / 0.3)) } ?? 1
            switch area {
            case .whole: u.area = 1
            case .painted: u.area = 2
            case .boxes(let boxes):
                u.area = 3
                u.boxCount = Int32(min(boxes.count, 8))
                withUnsafeMutableBytes(of: &u.boxes) { raw in
                    let out = raw.bindMemory(to: SIMD4<Float>.self)
                    for (i, box) in boxes.prefix(8).enumerated() {
                        out[i] = SIMD4(Float(box.minX), Float(box.minY), Float(box.maxX), Float(box.maxY))
                    }
                }
            case .around(let frame):
                u.area = 4
                u.around = SIMD4(Float(frame.minX), Float(frame.minY), Float(frame.maxX), Float(frame.maxY))
            }
        }
        return u
    }
}

/// The display link's target: it holds its target, which mustn't be the view.
private final class GlowTicker: NSObject {
    weak var view: HangarGlowView?
    init(_ view: HangarGlowView) { self.view = view }
    @MainActor @objc func tick(_ link: CADisplayLink) {
        guard let view else { return link.invalidate() }
        view.tick(link)
    }
}

/// What `glow.metal` reads: as laid out there.
struct GlowUniforms {
    var frame = SIMD4<Float>(0, 0, 1, 1)
    var veil = SIMD4<Float>(1, 0.6, 0.8, 0.2)
    var around = SIMD4<Float>(0, 0, 1, 1)
    var clip = SIMD4<Float>(-1e6, -1e6, 1e6, 1e6)
    var boxes: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>) =
        (.zero, .zero, .zero, .zero, .zero, .zero, .zero, .zero)
    var coverTexel = SIMD2<Float>(1, 1)
    var time: Float = 0
    var bright: Float = 1
    var trail: Float = 0.5
    var frost: Float = 0.4
    var rim: Float = 1
    var opacity: Float = 1
    var hasPicture: Float = 0
    var workAge: Float = 0
    var workLevel: Float = 1
    var area: Int32 = 0
    var boxCount: Int32 = 0
}

/// The device, its pipelines (made once, from `GlowKit.source`), and a picture for none.
final class GlowKit: @unchecked Sendable {
    static let shared = GlowKit()

    let device: MTLDevice
    let queue: MTLCommandQueue
    let loader: MTKTextureLoader
    let stamp: MTLRenderPipelineState
    let glow: MTLRenderPipelineState
    let sampler: MTLSamplerState
    let blank: MTLTexture

    private init() {
        device = MTLCreateSystemDefaultDevice()!
        queue = device.makeCommandQueue()!
        loader = MTKTextureLoader(device: device)
        let library = try! device.makeLibrary(source: Self.source, options: nil)
        let stamp = MTLRenderPipelineDescriptor()
        stamp.vertexFunction = library.makeFunction(name: "stampVertex")
        stamp.fragmentFunction = library.makeFunction(name: "stampFragment")
        stamp.colorAttachments[0].pixelFormat = .r8Unorm
        // Each piece over what's there, the most of the two: a stroke's overlaps no more than it.
        stamp.colorAttachments[0].isBlendingEnabled = true
        stamp.colorAttachments[0].rgbBlendOperation = .max
        stamp.colorAttachments[0].alphaBlendOperation = .max
        self.stamp = try! device.makeRenderPipelineState(descriptor: stamp)
        let glow = MTLRenderPipelineDescriptor()
        glow.vertexFunction = library.makeFunction(name: "glowVertex")
        glow.fragmentFunction = library.makeFunction(name: "glowFragment")
        glow.colorAttachments[0].pixelFormat = .rgba16Float
        self.glow = try! device.makeRenderPipelineState(descriptor: glow)
        let sampler = MTLSamplerDescriptor()
        sampler.minFilter = .linear
        sampler.magFilter = .linear
        sampler.mipFilter = .linear
        sampler.sAddressMode = .clampToEdge
        sampler.tAddressMode = .clampToEdge
        self.sampler = device.makeSamplerState(descriptor: sampler)!
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
        blank = device.makeTexture(descriptor: d)!
    }

    /// Made ready off the main thread, before it's first needed (making its pipelines takes a moment).
    static func prepare() {
        Task.detached(priority: .utility) { _ = GlowKit.shared }
    }

    static let source = #"""
    #include <metal_stdlib>
    using namespace metal;

    struct Segment { float2 a; float2 b; float radius; float strength; };

    struct StampOut {
        float4 position [[position]];
        float2 p;
        float2 a [[flat]];
        float2 b [[flat]];
        float radius [[flat]];
        float strength [[flat]];
    };

    // A piece of a stroke: a quad round it, in the cover's pixels.
    vertex StampOut stampVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                                constant Segment *segments [[buffer(0)]], constant float2 &size [[buffer(1)]]) {
        Segment s = segments[iid];
        float pad = s.radius + 2.0;
        float2 lo = min(s.a, s.b) - pad, hi = max(s.a, s.b) + pad;
        float2 corner = float2((vid & 1) ? hi.x : lo.x, (vid & 2) ? hi.y : lo.y);
        StampOut out;
        out.position = float4(corner.x / size.x * 2.0 - 1.0, 1.0 - corner.y / size.y * 2.0, 0.0, 1.0);
        out.p = corner;
        out.a = s.a;
        out.b = s.b;
        out.radius = s.radius;
        out.strength = s.strength;
        return out;
    }

    // Round-ended, as the mask is drawn: what's within its radius of the piece.
    fragment half4 stampFragment(StampOut in [[stage_in]]) {
        float2 pa = in.p - in.a, ba = in.b - in.a;
        float h = clamp(dot(pa, ba) / max(dot(ba, ba), 1e-4), 0.0, 1.0);
        float d = length(pa - ba * h);
        float c = clamp(in.radius - d + 0.5, 0.0, 1.0) * in.strength;
        return half4(c, c, c, c);
    }

    struct Uniforms {
        float4 frame;
        float4 veil;
        float4 around;
        float4 clip;
        float4 boxes[8];
        float2 coverTexel;
        float time;
        float bright;
        float trail;
        float frost;
        float rim;
        float opacity;
        float hasPicture;
        float workAge;
        float workLevel;
        int area;
        int boxCount;
    };

    struct GlowOut { float4 position [[position]]; };

    vertex GlowOut glowVertex(uint vid [[vertex_id]]) {
        float2 p = float2(float((vid << 1) & 2), float(vid & 2));
        GlowOut out;
        out.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
        return out;
    }

    // Colours through the spectrum, a little paled: iridescence.
    static float3 spectrum(float h) {
        float3 c = 0.5 + 0.5 * cos(6.2831853 * (h + float3(0.0, 0.33, 0.67)));
        return mix(c, float3(1.0), 0.2);
    }

    // A ring where a soft coverage crosses its middle.
    static float ring(float c) { return saturate(4.0 * c * (1.0 - c)); }

    // A box, its edge `soft` wide (the picture's units), 1 inside.
    static float box(float2 uv, float4 r, float soft) {
        float2 d = max(r.xy - uv, uv - r.zw);
        return 1.0 - smoothstep(-soft, soft, max(d.x, d.y));
    }

    fragment half4 glowFragment(GlowOut in [[stage_in]], constant Uniforms &u [[buffer(0)]],
                                texture2d<float> picture [[texture(0)]], texture2d<float> cover [[texture(1)]],
                                texture2d<float> heat [[texture(2)]], sampler s [[sampler(0)]]) {
        float2 uv = (in.position.xy - u.frame.xy) / u.frame.zw;
        float2 at = in.position.xy;
        float seen = (all(at >= u.clip.xy) && all(at <= u.clip.zw)) ? 1.0 : 0.0;
        float inside = (all(uv >= 0.0) && all(uv <= 1.0)) ? seen : 0.0;
        // Off the picture, nothing; but round it, for what's drawn there (a little past, for the rim's glow).
        float near = (all(uv >= -0.03) && all(uv <= 1.03)) ? seen : 0.0;
        if (near == 0.0 && u.area != 4) return half4(0.0);
        float2 cuv = clamp(uv, 0.0, 1.0);
        float t = u.time;
        float3 rgb = float3(0.0);
        float alpha = 0.0;

        // The picture under it, blurred: the frost's.
        float3 blur = u.hasPicture > 0.5 ? picture.sample(s, cuv, level(4.0)).rgb : float3(0.5);
        float3 frost = mix(blur, float3(1.0), u.frost);

        // While something works, the paint gives way to it.
        float working = u.area > 0 ? smoothstep(0.0, 0.35, u.workAge) * u.workLevel : 0.0;

        // The paint: a fainter frost where it stays, bright (past white) where the finger's just been and where a
        // stroke let go flashes; a rainbow round its edge, brighter where it's bright.
        float c = cover.sample(s, cuv, level(0.0)).r * inside;
        float cb = cover.sample(s, cuv, level(3.0)).r * inside;
        float h = heat.sample(s, cuv, level(0.0)).r * inside;
        float hb = heat.sample(s, cuv, level(2.5)).r * inside;
        float paint = (1.0 - working);
        float a = max(c * u.trail, h * 0.92) * paint;
        float lift = 1.0 + h * (u.bright - 1.0);
        rgb += frost * lift * a;
        alpha = max(alpha, a);
        // The rim: the blurred cover's middle, its red pushed out and its blue in (a prism's fringe), and the
        // spectrum moving along it.
        float2 e = u.coverTexel * 6.0;
        float gx = cover.sample(s, cuv + float2(e.x, 0.0), level(3.0)).r - cover.sample(s, cuv - float2(e.x, 0.0), level(3.0)).r;
        float gy = cover.sample(s, cuv + float2(0.0, e.y), level(3.0)).r - cover.sample(s, cuv - float2(0.0, e.y), level(3.0)).r;
        float2 n = normalize(float2(gx, gy) + 1e-5) * e * 0.5;
        float rr = ring(cover.sample(s, cuv + n, level(3.0)).r);
        float rb = ring(cover.sample(s, cuv - n, level(3.0)).r);
        float r0 = ring(cb);
        float3 fringe = float3(rr, r0, rb);
        float3 hue = spectrum(t * 0.12 + dot(uv, float2(1.4, 0.9)) + cb * 0.5);
        float3 rim = (hue * r0 * 0.9 + fringe * 0.3) * u.rim * (0.5 + 1.3 * hb) * mix(1.0, u.bright, hb) * paint * inside;
        // And its glow, just outside it, in the same colours.
        float halo = saturate(cover.sample(s, cuv, level(4.5)).r * 1.6) * (1.0 - c) * inside;
        float3 haloRGB = hue * halo * 0.35 * u.rim * (0.6 + hb) * paint;
        rgb += rim + haloRGB;
        alpha = max(alpha, saturate(max(rim.r, max(rim.g, rim.b))) * 0.85);
        alpha = max(alpha, halo * 0.3 * paint);

        // Working: the area lit (a flash as it starts), a pink veil, the picture's lines in colours moving through
        // them, a band of light passing, the rainbow round the area's edge.
        if (u.area > 0) {
            float m = 0.0;
            float soft = 0.012;
            if (u.area == 1) m = box(uv, float4(0.0, 0.0, 1.0, 1.0), 0.002) * seen;
            else if (u.area == 2) m = smoothstep(0.08, 0.55, cover.sample(s, cuv, level(2.0)).r) * inside;
            else if (u.area == 3) {
                for (int i = 0; i < u.boxCount; i++) m = max(m, box(uv, u.boxes[i], soft));
                m *= seen;
            } else if (u.area == 4) m = box(uv, u.around, 0.002) * (1.0 - box(uv, float4(0.0, 0.0, 1.0, 1.0), 0.004));
            float on = smoothstep(0.0, 0.3, u.workAge) * u.workLevel;
            float flash = exp(-max(u.workAge - 0.1, 0.0) / 0.35) * on;
            float sweep = 0.5 + 0.5 * sin(dot(uv, float2(0.8, 1.0)) * 7.0 - t * 2.4);
            // The picture's lines: how fast its light changes (inside it; none past its edges).
            float lines = 0.0;
            if (u.hasPicture > 0.5 && inside > 0.5) {
                float2 px = float2(1.0) / float2(picture.get_width(), picture.get_height()) * 2.0;
                float3 w = float3(0.2126, 0.7152, 0.0722);
                float lx = dot(picture.sample(s, cuv + float2(px.x, 0.0), level(1.0)).rgb, w)
                         - dot(picture.sample(s, cuv - float2(px.x, 0.0), level(1.0)).rgb, w);
                float ly = dot(picture.sample(s, cuv + float2(0.0, px.y), level(1.0)).rgb, w)
                         - dot(picture.sample(s, cuv - float2(0.0, px.y), level(1.0)).rgb, w);
                lines = smoothstep(0.03, 0.16, length(float2(lx, ly)));
            } else {
                // Past the picture: light moving in bands.
                lines = 0.35 * (0.5 + 0.5 * sin(dot(uv, float2(3.0, 5.0)) * 6.0 + t * 1.6));
            }
            float3 lineHue = spectrum(t * 0.2 + uv.y * 1.6 + uv.x * 0.7);
            float3 lit = lineHue * lines * (0.3 + 0.9 * sweep) * mix(1.0, u.bright, 0.6 * sweep);
            float veil = u.veil.a * on;
            float3 work = u.veil.rgb * veil + lit * on + float3(1.0) * flash * 0.55 * u.bright;
            float workA = max(veil, flash * 0.55);
            // The area's own rim.
            float edge = ring(smoothstep(0.0, 1.0, m)) * on;
            float3 areaRim = spectrum(t * 0.15 + dot(uv, float2(1.2, 0.8))) * edge * 0.9 * u.bright;
            rgb = rgb * (1.0 - workA * m) + work * m + areaRim;
            alpha = max(alpha, max(workA * m, saturate(max(areaRim.r, max(areaRim.g, areaRim.b))) * 0.8));
        }
        return half4(half3(rgb * u.opacity), half(saturate(alpha) * u.opacity));
    }
    """#
}
