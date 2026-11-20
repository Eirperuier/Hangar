import CoreImage
import Foundation

/// One of Adjust's tools: a value on a ruler, from `range`'s lower bound to its upper (0 untouched), and what it does to
/// the picture. Photos' sixteen are `HangarToolbox.standard`'s; an app adds its own the same way.
public struct HangarAdjustment: Identifiable, Sendable {
    /// Its key in an edit (`HangarEdit.adjustments`): keep it, or edits kept with it lose its value.
    public let id: String
    /// Shown over the tools, in capitals, while it's the one chosen.
    public var name: String
    /// Its tool's symbol: an SF Symbol's name.
    public var symbol: String
    /// Its values: -1 to 1 for one that goes either way, 0 to 1 for one that only adds.
    public var range: ClosedRange<Double>
    /// The picture changed by `value` (never 0), drawn at the context's scale. Any thread.
    public var apply: @Sendable (_ image: CIImage, _ value: Double, _ context: HangarRenderContext) -> CIImage

    public init(id: String, name: String, symbol: String, range: ClosedRange<Double> = -1...1,
                apply: @escaping @Sendable (_ image: CIImage, _ value: Double, _ context: HangarRenderContext) -> CIImage) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.range = range
        self.apply = apply
    }
}

/// One of Filters' looks: laid over the adjusted picture, as much of it as its amount (0 to 1). Photos' nine are
/// `HangarToolbox.standard`'s.
public struct HangarFilter: Identifiable, Sendable {
    /// Its key in an edit (`HangarEdit.filter`).
    public let id: String
    /// Shown over the filters, in capitals, while it's the one chosen.
    public var name: String
    /// The picture with the whole look. Any thread.
    public var apply: @Sendable (_ image: CIImage, _ context: HangarRenderContext) -> CIImage

    public init(id: String, name: String, apply: @escaping @Sendable (_ image: CIImage, _ context: HangarRenderContext) -> CIImage) {
        self.id = id
        self.name = name
        self.apply = apply
    }
}

/// The tools an editor has, in the order it shows them and applies them: Photos' by default (`standard`). An app adds
/// its own (`adjustments.append(…)`), takes some out, or puts them in another order; each is applied in turn, every
/// adjustment, then the filter.
public struct HangarToolbox: Sendable {
    public var adjustments: [HangarAdjustment]
    public var filters: [HangarFilter]

    public init(adjustments: [HangarAdjustment], filters: [HangarFilter]) {
        self.adjustments = adjustments
        self.filters = filters
    }

    /// Photos' tools: Auto and fifteen adjustments, nine filters.
    public static let standard = HangarToolbox(adjustments: HangarAdjustment.standard, filters: HangarFilter.standard)

    public func adjustment(_ id: String) -> HangarAdjustment? {
        adjustments.first { $0.id == id }
    }

    public func filter(_ id: String) -> HangarFilter? {
        filters.first { $0.id == id }
    }
}

/// What a tool is drawing for: the picture as it came (Auto reads it), and how many of the picture's pixels a pixel
/// here is, so a tool working over a distance (a vignette, definition) looks the same small and full size.
public final class HangarRenderContext: @unchecked Sendable {
    /// The picture before anything was done to it, at the size being drawn.
    public let source: CIImage
    /// This drawing's pixels a pixel of the full picture: 1 full size, less for a preview.
    public let scale: Double

    private let lock = NSLock()
    private var autoFilters: [CIFilter]?

    public init(source: CIImage, scale: Double = 1) {
        self.source = source
        self.scale = scale
    }

    /// Core Image's enhancement of the source (`autoAdjustmentFilters`), worked out once: what Auto applies.
    public func autoEnhanced(_ image: CIImage) -> CIImage {
        lock.lock()
        if autoFilters == nil {
            autoFilters = source.autoAdjustmentFilters(options: [.redEye: false])
        }
        let filters = autoFilters ?? []
        lock.unlock()
        var out = image
        for filter in filters {
            guard let copy = filter.copy() as? CIFilter else { continue }
            copy.setValue(out, forKey: kCIInputImageKey)
            out = copy.outputImage ?? out
        }
        return out
    }
}
