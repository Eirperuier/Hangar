import CoreImage
import Metal
import QuartzCore
import UIKit

/// The picture being edited, drawn by Core Image straight into the screen's buffer each time it changes. As Photos'
/// does, it never has the main thread wait for the GPU and never falls behind: a picture is made and drawn on a queue
/// of its own, one at a time, and a change that comes meanwhile takes the place of any still waiting, so what's drawn
/// next is always the latest. A ruler dragged moves with the finger however long the picture takes, and the picture
/// follows as fast as the GPU can draw it. The view is the picture's shape; the editor places it.
@MainActor
final class CanvasView: UIView {
    /// A picture to show, made where it's drawn (not on the main thread).
    typealias Picture = @Sendable () -> CIImage?

    override class var layerClass: AnyClass { CAMetalLayer.self }

    /// Called once, after the first picture is on the screen.
    var onFirstDraw: (@MainActor () -> Void)?

    private let drawer: Drawer
    /// The last asked for (drawn again at a new size), and one asked for while another was being drawn.
    private var latest: Picture?
    private var waiting: Picture?
    private var busy = false
    private var size = CGSize.zero
    #if DEBUG
    var stats = CanvasStats()
    private var askedAt: CFTimeInterval = 0
    #endif

    init() {
        let device = MTLCreateSystemDefaultDevice()!
        drawer = Drawer(device: device)
        super.init(frame: .zero)
        let layer = layer as! CAMetalLayer
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = false
        layer.colorspace = Drawer.space
        layer.isOpaque = true
        drawer.layer = layer
        backgroundColor = .clear
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Shows a picture, drawn as soon as the one being drawn is done.
    func show(_ picture: @escaping Picture) {
        latest = picture
        waiting = picture
        #if DEBUG
        stats.asked += 1
        askedAt = CACurrentMediaTime()
        #endif
        drawNext()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let scale = window?.screen.scale ?? traitCollection.displayScale
        size = CGSize(width: (bounds.width * scale).rounded(), height: (bounds.height * scale).rounded())
        layer.contentsScale = scale
        if waiting == nil, size != drawer.size { waiting = latest }
        drawNext()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil, waiting == nil { waiting = latest }
        drawNext()
    }

    private func drawNext() {
        guard !busy, window != nil, size.width > 0, size.height > 0, let picture = waiting else { return }
        waiting = nil
        busy = true
        // The drawable's size changes only between pictures, never while one's being drawn.
        if size != drawer.size {
            (layer as! CAMetalLayer).drawableSize = size
            drawer.size = size
        }
        let first = onFirstDraw
        onFirstDraw = nil
        #if DEBUG
        let asked = askedAt
        #endif
        let done = MainThreadCall<Drawer.Times?> { [weak self] times in
            guard let self else { return }
            #if DEBUG
            if let times { self.record(times, asked: asked) }
            #endif
            self.drew(times, first: first)
        }
        drawer.queue.async { [drawer] in
            drawer.draw(picture) { times in
                DispatchQueue.main.async { MainActor.assumeIsolated { done.run(times) } }
            }
        }
    }

    private func drew(_ times: Drawer.Times?, first: (@MainActor () -> Void)?) {
        busy = false
        if times != nil {
            first?()
        } else if let first, onFirstDraw == nil {
            onFirstDraw = first
        }
        drawNext()
    }

    #if DEBUG
    private func record(_ times: Drawer.Times, asked: CFTimeInterval) {
        stats.drawn += 1
        stats.gpu.append(times.gpu)
        stats.make.append(times.make)
        stats.latency.append(CACurrentMediaTime() - asked)
    }
    #endif
}

/// Draws pictures into the canvas's layer, on its own queue.
private final class Drawer: @unchecked Sendable {
    struct Times: Sendable {
        /// Making and encoding the picture; the GPU drawing it.
        var make: Double
        var gpu: Double
    }

    static let space = CGColorSpace(name: CGColorSpace.displayP3)!
    let queue = DispatchQueue(label: "Hangar.canvas", qos: .userInteractive)
    /// Set on the main thread: the layer before the first picture, the size only while none is being drawn.
    var layer: CAMetalLayer?
    var size = CGSize.zero
    private let commands: MTLCommandQueue
    private let context: CIContext

    init(device: MTLDevice) {
        commands = device.makeCommandQueue()!
        context = CIContext(mtlCommandQueue: commands, options: [
            .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
            .cacheIntermediates: false,
            .name: "Hangar.canvas",
        ])
    }

    /// On `queue`: makes the picture and draws it filling the layer; `done` once the GPU has (nil if nothing was).
    func draw(_ picture: CanvasView.Picture, done: @escaping @Sendable (Times?) -> Void) {
        let began = CACurrentMediaTime()
        guard let layer, let image = picture(), !image.extent.isEmpty, !image.extent.isInfinite,
              let drawable = layer.nextDrawable(), let buffer = commands.makeCommandBuffer() else { return done(nil) }
        let texture = drawable.texture
        let extent = image.extent
        // The picture filling the view, which is its shape: already its size, unless the view is changing size.
        var fitted = image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
        if Int(extent.width.rounded()) != texture.width || Int(extent.height.rounded()) != texture.height {
            fitted = fitted
                .transformed(by: CGAffineTransform(scaleX: CGFloat(texture.width) / extent.width, y: CGFloat(texture.height) / extent.height))
                .samplingLinear()
        }
        let destination = CIRenderDestination(width: texture.width, height: texture.height, pixelFormat: texture.pixelFormat,
                                              commandBuffer: buffer) { texture }
        destination.colorSpace = Self.space
        _ = try? context.startTask(toRender: fitted, to: destination)
        let make = CACurrentMediaTime() - began
        buffer.addCompletedHandler { buffer in
            done(Times(make: make, gpu: buffer.gpuEndTime - buffer.gpuStartTime))
        }
        buffer.present(drawable)
        buffer.commit()
    }
}

/// A main-thread call carried through another thread, never run there.
private final class MainThreadCall<Value>: @unchecked Sendable {
    private let body: @MainActor (Value) -> Void

    init(_ body: @escaping @MainActor (Value) -> Void) {
        self.body = body
    }

    @MainActor func run(_ value: Value) {
        body(value)
    }
}
