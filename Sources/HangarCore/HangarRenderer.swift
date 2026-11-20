import CoreGraphics
import CoreImage
import Foundation

/// Draws a picture from an edit: every adjustment that applies, in the toolbox's order, then the filter as much as
/// its amount. Any thread; the picture comes out the size it went in.
public struct HangarRenderer: Sendable {
    public var toolbox: HangarToolbox

    public init(toolbox: HangarToolbox = .standard) {
        self.toolbox = toolbox
    }

    /// The edit applied to `image` (which is `context.source`, or the source with something done to it first).
    public func apply(_ edit: HangarEdit, to image: CIImage, context: HangarRenderContext) -> CIImage {
        var out = image
        for adjustment in toolbox.adjustments where edit.applies(adjustment.id) {
            let value = min(max(edit.value(of: adjustment.id), adjustment.range.lowerBound), adjustment.range.upperBound)
            out = adjustment.apply(out, value, context)
        }
        if let id = edit.filter, edit.filterAmount > 0, let filter = toolbox.filter(id) {
            out = out.mixed(toward: filter.apply(out, context), edit.filterAmount)
        }
        return out.cropped(to: image.extent)
    }

    /// The edit applied to a whole picture, drawn into a bitmap in the picture's own colours (sRGB if it has none).
    /// Off the main thread: a large picture takes a while.
    public func render(_ edit: HangarEdit, to picture: CGImage, orientation: CGImagePropertyOrientation = .up) -> CGImage? {
        let source = CIImage(cgImage: picture).oriented(orientation)
        let output = apply(edit, to: source, context: HangarRenderContext(source: source))
        let space = picture.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        return Self.context.createCGImage(output, from: source.extent, format: .RGBA8, colorSpace: space)
    }

    /// One for every render: Core Image's contexts are made to be shared across threads, and costly to make.
    nonisolated(unsafe) public static let context = CIContext(options: [
        .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
        .cacheIntermediates: false,
        .name: "Hangar",
    ])
}
