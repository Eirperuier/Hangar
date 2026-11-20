import CoreImage
import MetalKit
import UIKit

/// The picture being edited, drawn by Core Image straight into the screen's buffer each time it changes: a ruler
/// dragged redraws it every frame, on the GPU, from the source kept there (`insertingIntermediate`). The view is the
/// picture's shape; the editor places it.
@MainActor
final class CanvasView: MTKView, MTKViewDelegate {
    /// What's shown: drawn on the next frame.
    var image: CIImage? {
        didSet { setNeedsDisplay() }
    }
    /// Called once, after the first picture is on the screen.
    var onFirstDraw: (@MainActor () -> Void)?

    private let queue: MTLCommandQueue
    private let context: CIContext
    private static let space = CGColorSpace(name: CGColorSpace.displayP3)!

    init() {
        let device = MTLCreateSystemDefaultDevice()!
        queue = device.makeCommandQueue()!
        context = CIContext(mtlCommandQueue: queue, options: [
            .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
            .cacheIntermediates: false,
            .name: "Hangar.canvas",
        ])
        super.init(frame: .zero, device: device)
        delegate = self
        isPaused = true
        enableSetNeedsDisplay = true
        framebufferOnly = false
        colorPixelFormat = .bgra8Unorm
        (layer as? CAMetalLayer)?.colorspace = Self.space
        isOpaque = true
        backgroundColor = .clear
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        setNeedsDisplay()
    }

    func draw(in view: MTKView) {
        let size = drawableSize
        guard let image, size.width > 0, size.height > 0, !image.extent.isEmpty, !image.extent.isInfinite,
              let drawable = currentDrawable, let buffer = queue.makeCommandBuffer() else { return }
        // The picture filling the view, which is its shape.
        let extent = image.extent
        let fitted = image
            .transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            .transformed(by: CGAffineTransform(scaleX: size.width / extent.width, y: size.height / extent.height))
            .samplingLinear()
        let destination = CIRenderDestination(width: Int(size.width), height: Int(size.height), pixelFormat: colorPixelFormat,
                                              commandBuffer: buffer) { drawable.texture }
        destination.colorSpace = Self.space
        _ = try? context.startTask(toRender: fitted, to: destination)
        if let first = onFirstDraw {
            onFirstDraw = nil
            // Back on the main thread once the GPU has drawn it.
            let call = MainThreadCall(first)
            buffer.addCompletedHandler { _ in DispatchQueue.main.async { MainActor.assumeIsolated { call.run() } } }
        }
        buffer.present(drawable)
        buffer.commit()
    }
}

/// A main-thread call carried through another thread, never run there.
private final class MainThreadCall: @unchecked Sendable {
    private let body: @MainActor () -> Void

    init(_ body: @escaping @MainActor () -> Void) {
        self.body = body
    }

    @MainActor func run() {
        body()
    }
}
