import Foundation

/// What's been done to a picture: its crop and the rest of its geometry, a value for each adjustment, a filter and how
/// much of it; never its pixels. The
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

    public init(adjustments: [String: Double] = [:], switchedOff: Set<String> = [], filter: String? = nil, filterAmount: Double = 1,
                geometry: HangarGeometry = .identity) {
        self.adjustments = adjustments
        self.switchedOff = switchedOff
        self.filter = filter
        self.filterAmount = filterAmount
        self.geometry = geometry
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
    }

    // An edit kept by an older version opens in a newer one: whatever it lacks is untouched.
    private enum CodingKeys: String, CodingKey {
        case adjustments, switchedOff, filter, filterAmount, geometry
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        adjustments = try container.decodeIfPresent([String: Double].self, forKey: .adjustments) ?? [:]
        switchedOff = try container.decodeIfPresent(Set<String>.self, forKey: .switchedOff) ?? []
        filter = try container.decodeIfPresent(String.self, forKey: .filter)
        filterAmount = try container.decodeIfPresent(Double.self, forKey: .filterAmount) ?? 1
        geometry = try container.decodeIfPresent(HangarGeometry.self, forKey: .geometry) ?? .identity
    }
}
