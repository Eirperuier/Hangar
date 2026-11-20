import UIKit

/// The bars' surfaces and buttons: glass where there is (iOS 26), the system's material before it.
@MainActor
enum Chrome {
    /// A capsule to put buttons on.
    static func capsule(_ style: HangarStyle) -> UIVisualEffectView {
        let view: UIVisualEffectView
        if style.glass, #available(iOS 26.0, *) {
            let glass = UIGlassEffect()
            glass.isInteractive = true
            view = UIVisualEffectView(effect: glass)
            view.cornerConfiguration = .capsule()
        } else {
            view = UIVisualEffectView(effect: style.glass ? UIBlurEffect(style: .systemThickMaterial) : nil)
            view.layer.cornerCurve = .continuous
            view.clipsToBounds = true
        }
        return view
    }

    /// A round button with a symbol, on its own glass; `prominent` in the accent (Done, with something to keep).
    static func button(_ symbol: String, label: String, style: HangarStyle, prominent: Bool = false) -> UIButton {
        var configuration: UIButton.Configuration
        if style.glass, #available(iOS 26.0, *) {
            configuration = prominent ? .prominentGlass() : .glass()
        } else {
            configuration = prominent ? .filled() : .gray()
        }
        configuration.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .medium))
        configuration.cornerStyle = .capsule
        configuration.baseForegroundColor = prominent ? .black : style.foreground
        if prominent { configuration.baseBackgroundColor = style.accent }
        configuration.contentInsets = .zero
        let button = UIButton(configuration: configuration)
        button.accessibilityLabel = label
        return button
    }

    /// A plain symbol button, for a capsule.
    static func plainButton(_ symbol: String, label: String, style: HangarStyle) -> UIButton {
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .medium))
        configuration.baseForegroundColor = style.foreground
        configuration.contentInsets = .zero
        let button = UIButton(configuration: configuration)
        button.accessibilityLabel = label
        return button
    }

    /// Lays out a capsule's corners where they aren't glass's own.
    static func round(_ view: UIVisualEffectView) {
        if #available(iOS 26.0, *), view.effect is UIGlassEffect { return }
        view.layer.cornerRadius = min(view.bounds.width, view.bounds.height) / 2
    }
}

/// Feels a step under the finger.
@MainActor
final class Haptics {
    private let selection = UISelectionFeedbackGenerator()
    private let impact = UIImpactFeedbackGenerator(style: .light)

    func step() {
        selection.selectionChanged()
    }

    func detent() {
        impact.impactOccurred()
    }
}
