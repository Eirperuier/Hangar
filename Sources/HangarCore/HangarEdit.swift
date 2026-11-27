import Foundation

/// What's been done to a picture: its crop and the rest of its geometry, a value for each adjustment, a filter and how
/// much of it, what's drawn on it, what an app's own modes keep; and the steps made of pixels (`HangarStep`), by their
/// pictures' ids. The
/// picture is drawn from it each time (`HangarRenderer`), so an edit can be changed later, undone a step at a time,
/// kept beside the original and opened again, as Photos keeps its edits.
public struct HangarEdit: Hashable, Sendable, Codable {
    /// Each adjustment's value by its id (`HangarAdjustment.id`): 0, or not here, is untouched.
    public var adjustments: [String: Double]
    /// Adjustments switched off (their tool tapped again): their values kept, not applied.
    public var switchedOff: Set<String>
    /// The filter laid over the adjusted picture (`HangarFilter.id`); nil is Original.
    public var filter: String?
    /// How much of the filter, 0 to 1.
    public var filterAmount: Double
    /// Crop's: tilted, straightened, cropped, turned and flipped, before anything else (Straighten, Vertical and
    /// Horizontal switched off as adjustments are, in `switchedOff`).
    public var geometry: HangarGeometry
    /// Pictures made from the one before, in turn, under everything else (`HangarStep`).
    public var steps: [HangarStep]
    /// What an app's own modes keep, by the mode's id: theirs to read (`HangarValue.decoded(as:)`).
    public var modules: [String: HangarValue]
    /// What's drawn on the picture (Markup's): over it as it's shown, on the part it was drawn on.
    public var drawing: HangarDrawing

    public init(adjustments: [String: Double] = [:], switchedOff: Set<String> = [], filter: String? = nil, filterAmount: Double = 1,
                geometry: HangarGeometry = .identity, steps: [HangarStep] = [], modules: [String: HangarValue] = [:],
                drawing: HangarDrawing = HangarDrawing()) {
        self.adjustments = adjustments
        self.switchedOff = switchedOff
        self.filter = filter
        self.filterAmount = filterAmount
        self.geometry = geometry
        self.steps = steps
        self.modules = modules
        self.drawing = drawing
    }

    /// A step added after the others. One that makes the picture larger (its frame past the picture's edges) keeps
    /// the crop and what's drawn on the same part of it (as wide on it, if the picture's `aspect` before, its width
    /// for each of its height, is known); one that makes a part of it the whole picture lets the crop go (the part
    /// is what's kept now), its shape with it, and what was drawn on the picture it was.
    public mutating func add(_ step: HangarStep, aspect: CGFloat? = nil) {
        steps.append(step)
        if step.replaces {
            geometry.crop = nil
            geometry.aspect = nil
            drawing = HangarDrawing()
            return
        }
        let reach = step.reach
        drawing.reach(reach, aspect: aspect)
        guard reach != HangarStep.whole, let crop = geometry.crop else { return }
        geometry.crop = CGRect(x: (crop.minX - reach.minX) / reach.width, y: (crop.minY - reach.minY) / reach.height,
                               width: crop.width / reach.width, height: crop.height / reach.height)
    }

    /// The geometry as it's drawn: tools switched off at 0.
    public var appliedGeometry: HangarGeometry {
        geometry.without(switchedOff)
    }

    /// An adjustment's value, 0 if it's untouched.
    public func value(of id: String) -> Double {
        adjustments[id] ?? 0
    }

    /// Whether an adjustment changes the picture: it has a value and isn't switched off.
    public func applies(_ id: String) -> Bool {
        value(of: id) != 0 && !switchedOff.contains(id)
    }

    /// Sets an adjustment's value; 0 takes it out.
    public mutating func set(_ id: String, to value: Double) {
        adjustments[id] = value == 0 ? nil : value
    }

    /// Whether it changes nothing: the original as it was.
    public var isOriginal: Bool {
        !adjustments.keys.contains(where: applies) && (filter == nil || filterAmount == 0) && appliedGeometry.isIdentity
            && steps.isEmpty && drawing.isEmpty
    }

    // An edit kept by an older version opens in a newer one: whatever it lacks is untouched.
    private enum CodingKeys: String, CodingKey {
        case adjustments, switchedOff, filter, filterAmount, geometry, steps, modules, drawing
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        adjustments = try container.decodeIfPresent([String: Double].self, forKey: .adjustments) ?? [:]
        switchedOff = try container.decodeIfPresent(Set<String>.self, forKey: .switchedOff) ?? []
        filter = try container.decodeIfPresent(String.self, forKey: .filter)
        filterAmount = try container.decodeIfPresent(Double.self, forKey: .filterAmount) ?? 1
        geometry = try container.decodeIfPresent(HangarGeometry.self, forKey: .geometry) ?? .identity
        steps = try container.decodeIfPresent([HangarStep].self, forKey: .steps) ?? []
        modules = try container.decodeIfPresent([String: HangarValue].self, forKey: .modules) ?? [:]
        drawing = try container.decodeIfPresent(HangarDrawing.self, forKey: .drawing) ?? HangarDrawing()
    }
}
