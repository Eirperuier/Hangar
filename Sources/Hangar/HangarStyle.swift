import UIKit

/// How the editor looks: its colours, its type, whether its bars are glass. Photos' by default (`system`), light or
/// dark as the device is, each read off Photos on iOS 27; an app sets its own design's here, its tokens for these roles.
public struct HangarStyle {
    /// Behind the picture.
    public var background: UIColor = .systemBackground
    /// Symbols and words; a tool's ring and number at 0 or less; a ruler's marks.
    public var foreground: UIColor = .label
    /// A tool's or filter's name over them.
    public var secondary: UIColor = HangarStyle.dynamic(light: UIColor(white: 152 / 255, alpha: 1), dark: UIColor(white: 137 / 255, alpha: 1))
    /// A mode not chosen: its symbol and name.
    public var idle: UIColor = HangarStyle.dynamic(light: UIColor(white: 112 / 255, alpha: 1), dark: UIColor(white: 150 / 255, alpha: 1))
    /// The mark at a ruler's value and at the chosen mode.
    public var accent: UIColor = .systemYellow
    /// An adjustment raised: its tool's ring and number (Photos' deeper yellow in light, its yellow in dark).
    public var raised: UIColor = HangarStyle.dynamic(light: UIColor(red: 0.98, green: 0.667, blue: 0, alpha: 1), dark: .systemYellow)
    /// A tool's face (Photos' is the thinnest material, which this is on the editor's background).
    public var toolFill: UIColor = HangarStyle.dynamic(light: UIColor(white: 245 / 255, alpha: 1), dark: UIColor(white: 31 / 255, alpha: 1))
    /// Auto's face, off and on, and its symbol on.
    public var autoFill: UIColor = HangarStyle.dynamic(light: UIColor(white: 200 / 255, alpha: 1), dark: UIColor(white: 56 / 255, alpha: 1))
    public var autoOnFill: UIColor = HangarStyle.dynamic(light: UIColor(white: 82 / 255, alpha: 1), dark: UIColor(white: 200 / 255, alpha: 1))
    public var autoOnSymbol: UIColor = .systemBackground
    /// The dot on a ruler where its default is, when the value's away from it.
    public var marker: UIColor = HangarStyle.dynamic(light: UIColor(white: 172 / 255, alpha: 1), dark: UIColor(white: 84 / 255, alpha: 1))
    /// What a brush lays over the picture as it's painted (Tools).
    public var paint: UIColor = UIColor.white.withAlphaComponent(0.55)
    /// What's said over the picture in Tools (what to do, what it's doing), and the words asked for.
    public var hintFont: UIFont = .systemFont(ofSize: 13, weight: .medium)
    public var wordsFont: UIFont = .systemFont(ofSize: 17)
    /// A chosen filter's frame.
    public var thumbnailFrame: UIColor = .white
    /// The mode's name over an iPad's editor, and its colour.
    public var titleFont: UIFont = .systemFont(ofSize: 14, weight: .medium)
    public var title: UIColor = .secondaryLabel
    /// A tool's or filter's name, in capitals.
    public var nameFont: UIFont = HangarStyle.rounded(15.5)
    /// The number on a tool while it's being changed.
    public var numberFont: UIFont = .monospacedDigitSystemFont(ofSize: 14, weight: .medium)
    /// The modes' names under their symbols, and the chosen one's (Photos' are the same, the chosen one darker).
    public var modeFont: UIFont = .systemFont(ofSize: 10, weight: .medium)
    public var chosenModeFont: UIFont = .systemFont(ofSize: 10, weight: .medium)
    /// Bars and buttons of glass (iOS 26 and later), or of the system's material before it; false for plain ones.
    public var glass: Bool = true

    public init() {}

    /// Photos'.
    public static var system: HangarStyle { HangarStyle() }

    /// A colour for light and one for dark.
    public static func dynamic(light: UIColor, dark: UIColor) -> UIColor {
        UIColor { $0.userInterfaceStyle == .dark ? dark : light }
    }

    /// The system's rounded face, as Photos' names are.
    public static func rounded(_ size: CGFloat, weight: UIFont.Weight = .regular) -> UIFont {
        let font = UIFont.systemFont(ofSize: size, weight: weight)
        return font.fontDescriptor.withDesign(.rounded).map { UIFont(descriptor: $0, size: size) } ?? font
    }
}
