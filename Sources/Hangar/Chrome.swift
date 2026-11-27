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

    /// Shows or hides a bar (in an animation, fading): glass by its own coming and going, as faded glass shows as an
    /// empty shell; anything else by its alpha.
    static func show(_ view: UIView, _ shown: Bool) {
        if #available(iOS 26.0, *), let glass = view as? UIVisualEffectView,
           glass.effect is UIGlassEffect || glass.layer.value(forKey: glassKey) != nil {
            if let effect = glass.effect as? UIGlassEffect { glass.layer.setValue(effect, forKey: glassKey) }
            glass.effect = shown ? glass.layer.value(forKey: glassKey) as? UIGlassEffect : nil
            glass.contentView.alpha = shown ? 1 : 0
            glass.alpha = 1
        } else {
            view.alpha = shown ? 1 : 0
        }
    }

    private static let glassKey = "hangar.glass"
    private static let shownKey = "hangar.shown"

    /// A view shown or hidden: at once, or faded in (`animated`), each part its own way (`show`: glass by its own
    /// coming and going, anything else by its alpha). One going is hidden once it's gone, unless it was asked back
    /// meanwhile; one already where it's asked to be is left alone.
    static func fade(_ view: UIView, _ shown: Bool, animated: Bool, duration: TimeInterval = 0.22) {
        let asked = view.layer.value(forKey: shownKey) as? Bool
        view.layer.setValue(shown, forKey: shownKey)
        let parts = parts(of: view)
        guard animated, view.window != nil else {
            view.isHidden = !shown
            for part in parts { show(part, shown) }
            return
        }
        if shown {
            guard view.isHidden || asked == false else { return }
            if view.isHidden {
                for part in parts { show(part, false) }
                view.isHidden = false
            }
            UIView.animate(withDuration: duration, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
                for part in parts { show(part, true) }
            }
        } else {
            guard !view.isHidden, asked != false else { return }
            UIView.animate(withDuration: duration, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
                for part in parts { show(part, false) }
            } completion: { _ in
                if view.layer.value(forKey: shownKey) as? Bool == false { view.isHidden = true }
            }
        }
    }

    /// What of a view fades on its own: itself, unless it holds glass (faded glass is an empty shell), then each of
    /// its parts (a control as a whole: its glass is its own).
    private static func parts(of view: UIView) -> [UIView] {
        guard !isGlass(view), !(view is UIControl), holdsGlass(view) else { return [view] }
        return view.subviews.flatMap(parts)
    }

    private static func isGlass(_ view: UIView) -> Bool {
        guard #available(iOS 26.0, *), let effect = view as? UIVisualEffectView else { return false }
        return effect.effect is UIGlassEffect || effect.layer.value(forKey: glassKey) != nil
    }

    private static func holdsGlass(_ view: UIView) -> Bool {
        isGlass(view) || !(view is UIControl) && view.subviews.contains(where: holdsGlass)
    }

    /// How views look now, to go to how they'll look: a picture of each that's showing, over it, fading out off how
    /// it looks after (a button's new size not cut out of its old one, nothing dimming as both are half there); one
    /// that's coming fading in, one going fading out. Made before the change, run after it.
    @MainActor
    struct Crossfade {
        private var shots: [UIView] = []
        private var shown: Set<ObjectIdentifier> = []
        private let views: [UIView]

        init(_ views: [UIView]) {
            self.views = views
            for view in views where !view.isHidden && view.alpha > 0.01 && view.window != nil {
                guard let superview = view.superview, let shot = view.snapshotView(afterScreenUpdates: false) else { continue }
                shot.frame = view.frame
                shot.isUserInteractionEnabled = false
                superview.insertSubview(shot, aboveSubview: view)
                shots.append(shot)
                shown.insert(ObjectIdentifier(view))
            }
        }

        func run(duration: TimeInterval = 0.25) {
            for view in views where !view.isHidden && !shown.contains(ObjectIdentifier(view)) {
                let parts = Chrome.parts(of: view)
                for part in parts { Chrome.show(part, false) }
                view.layer.setValue(true, forKey: Chrome.shownKey)
                UIView.animate(withDuration: duration, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
                    for part in parts { Chrome.show(part, true) }
                }
            }
            for shot in shots {
                UIView.animate(withDuration: duration, delay: 0, options: [.beginFromCurrentState]) { shot.alpha = 0 } completion: { _ in
                    shot.removeFromSuperview()
                }
            }
        }
    }

    /// Lays out a capsule's corners where they aren't glass's own.
    static func round(_ view: UIVisualEffectView) {
        if #available(iOS 26.0, *), view.effect is UIGlassEffect || view.layer.value(forKey: glassKey) != nil { return }
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
