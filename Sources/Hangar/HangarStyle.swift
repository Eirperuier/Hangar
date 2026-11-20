import UIKit

/// How the editor looks: its colours, its type, whether its bars are glass. Photos' by default (`system`), light or
/// dark as the device is; an app sets its own design's here, its tokens for these roles.
public struct HangarStyle {
    /// Behind the picture.
    public var background: UIColor = .systemBackground
    /// Symbols and words, and the line where a ruler's value is read.
    public var foreground: UIColor = .label
    /// A tool's or filter's name over them, a mode not chosen.
    public var secondary: UIColor = .secondaryLabel
    /// What's chosen and what's changed: the mark at the chosen mode, an adjustment's value round its tool, a ruler's 0.
    public var accent: UIColor = .systemYellow
    /// A tool's ring.
    public var toolRing: UIColor = .systemGray2
    /// The chosen tool's fill.
    public var toolFill: UIColor = .systemGray4
    /// A ruler's marks, and every fifth.
    public var tick: UIColor = .systemGray3
    public var majorTick: UIColor = .systemGray
    /// A chosen filter's frame.
    public var thumbnailFrame: UIColor = .white
    /// A tool's or filter's name, in capitals.
    public var nameFont: UIFont = .systemFont(ofSize: 15)
    /// The modes' names under their symbols.
    public var modeFont: UIFont = .systemFont(ofSize: 11, weight: .medium)
    /// The chosen mode's name.
    public var chosenModeFont: UIFont = .systemFont(ofSize: 11, weight: .semibold)
    /// Bars and buttons of glass (iOS 26 and later), or of the system's material before it; false for plain ones.
    public var glass: Bool = true

    public init() {}

    /// Photos'.
    public static var system: HangarStyle { HangarStyle() }
}
