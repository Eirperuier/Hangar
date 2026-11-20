import CoreGraphics
import CoreImage
import Foundation

/// Draws a picture from an edit: its geometry (the crop, turned and flipped), then every adjustment that applies, in
/// the toolbox's order, then the filter as much as its amount. Any thread.
public struct HangarRenderer: Sendable {
    public var toolbox: HangarToolbox

    public init(toolbox: HangarToolbox = .standard) {
        self.toolbox = toolbox
    }

    /// The edit's adjustments and filter applied to `image` (the picture, shaped already): it comes out the size it
    /// went in.
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
        let shaped = shape(edit, source)
        // Auto reads the whole picture, as the editor's does.
        let context = HangarRenderContext(source: source).resized(to: shaped, scale: 1)
        let output = apply(edit, to: shaped, context: context)
        let space = picture.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        return Self.context.createCGImage(output, from: shaped.extent, format: .RGBA8, colorSpace: space)
    }

    /// The picture with the edit's geometry: cropped, turned and flipped, its corner at the origin.
    public func shape(_ edit: HangarEdit, _ image: CIImage) -> CIImage {
        let g = edit.appliedGeometry
        guard !g.isIdentity else { return image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY)) }
        return g.apply(to: image)
    }

    /// One for every render: Core Image's contexts are made to be shared across threads, and costly to make.
    nonisolated(unsafe) public static let context = CIContext(options: [
        .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
        .cacheIntermediates: false,
        .name: "Hangar",
    ])
}
