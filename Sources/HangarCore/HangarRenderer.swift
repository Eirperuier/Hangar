import CoreGraphics
import CoreImage
import Foundation

/// Draws a picture from an edit: its steps' pictures (`HangarStep`, from `assets`), its geometry (the crop, turned
/// and flipped), then every adjustment that applies, in the toolbox's order, then the filter as much as its amount.
/// Any thread.
public struct HangarRenderer: Sendable {
    public var toolbox: HangarToolbox
    /// Where the steps' pictures are kept: without it, steps are left out.
    public var assets: (any HangarAssets)?

    public init(toolbox: HangarToolbox = .standard, assets: (any HangarAssets)? = nil) {
        self.toolbox = toolbox
        self.assets = assets
    }

    /// What the edit's steps make of `source`, its corner at the origin: at the source's pixels, or more where a step
    /// drew more than its part of the picture had (a picture made larger keeps its pixels). The picture itself if
    /// there are none.
    public func base(_ edit: HangarEdit, _ source: CIImage) -> CIImage {
        var out = source.transformed(by: CGAffineTransform(translationX: -source.extent.minX, y: -source.extent.minY))
        guard let assets else { return out }
        for step in edit.steps {
            guard let id = step.asset, let made = assets.picture(id) else { continue }
            let mask = step.mask.flatMap { assets.picture($0) }.map { CIImage(cgImage: $0) }
            out = Self.lay(CIImage(cgImage: made), mask: mask, in: step.frame, over: out)
        }
        return out
    }

    /// `made` over `below` where `frame` says (`below` 0 to 1 each way, from its top left), as much as `mask` says
    /// (all of the frame without one): it takes the frame's place, clear where it's clear.
    static func lay(_ made: CIImage, mask: CIImage?, in frame: CGRect, over below: CIImage) -> CIImage {
        let e = below.extent
        var under = below
        // Core Image's y goes up.
        var place = CGRect(x: frame.minX * e.width, y: (1 - frame.maxY) * e.height, width: frame.width * e.width, height: frame.height * e.height)
        // Drawn at its own pixels: the picture under it made as much larger if it has more.
        let gain = made.extent.width / max(place.width, 1)
        if gain > 1.001 {
            let size = CGSize(width: (e.width * gain).rounded(), height: (e.height * gain).rounded())
            under = below.clampedToExtent()
                .applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: gain, kCIInputAspectRatioKey: 1])
                .cropped(to: CGRect(origin: .zero, size: size))
            place = CGRect(x: place.minX * gain, y: place.minY * gain, width: place.width * gain, height: place.height * gain)
        }
        let into = CGAffineTransform(translationX: -made.extent.minX, y: -made.extent.minY)
            .concatenating(CGAffineTransform(scaleX: place.width / made.extent.width, y: place.height / made.extent.height))
            .concatenating(CGAffineTransform(translationX: place.minX, y: place.minY))
        let laid = made.transformed(by: into)
        let kept = mask.map { m in
            m.transformed(by: CGAffineTransform(translationX: -m.extent.minX, y: -m.extent.minY)
                .concatenating(CGAffineTransform(scaleX: place.width / m.extent.width, y: place.height / m.extent.height))
                .concatenating(CGAffineTransform(translationX: place.minX, y: place.minY)))
                .cropped(to: place)
        } ?? CIImage(color: .white).cropped(to: place)
        let out = laid.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: under, kCIInputMaskImageKey: kept])
        let reach = under.extent.union(place).integral
        return out.cropped(to: reach).transformed(by: CGAffineTransform(translationX: -reach.minX, y: -reach.minY))
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
        let source = base(edit, CIImage(cgImage: picture).oriented(orientation))
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
