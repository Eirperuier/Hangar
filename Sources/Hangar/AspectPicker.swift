import UIKit

/// Photos' Aspect Ratio picker (`PUCropAspectViewController` and its flipper), in place of Crop's tools while it's
/// open: upright and level buttons over a row of shapes (Original, Freeform, Square, Wallpaper and six more) that
/// scrolls, the chosen one on a grey capsule; 14-point capitals, 7 in on each side, 10 apart, 90 in from the ends.
@MainActor
final class AspectPicker: UIView {
    /// A shape to crop to, as it's shown.
    enum Choice: Hashable {
        case original, freeform, square, wallpaper
        /// Width to height, the longer first: shown upright or level as the picker is.
        case ratio(Double, Double)

        var name: String {
            switch self {
            case .original: "Original"
            case .freeform: "Freeform"
            case .square: "Square"
            case .wallpaper: "Wallpaper"
            case .ratio(let a, let b): "\(Int(a)):\(Int(b))"
            }
        }

        /// Whether it can be upright or level (Freeform and Square can't).
        var turns: Bool { self != .freeform && self != .square }
    }

    static let choices: [Choice] = [.original, .freeform, .square, .wallpaper,
                                    .ratio(16, 9), .ratio(5, 4), .ratio(7, 5), .ratio(4, 3), .ratio(5, 3), .ratio(3, 2)]

    /// Photos offers Wallpaper on a phone only.
    static var offered: [Choice] {
        UIDevice.current.userInterfaceIdiom == .phone ? choices : choices.filter { $0 != .wallpaper }
    }

    /// On an iPad: one row, the upright and level buttons first, 20 before the shapes, all in the middle (Photos'
    /// sits 5 right of it).
    var inline = false { didSet { setNeedsLayout() } }

    var onChoose: ((Choice) -> Void)?
    /// Upright (true) or level chosen.
    var onUpright: ((Bool) -> Void)?

    private(set) var chosen: Choice = .freeform
    private(set) var upright = false
    private let style: HangarStyle
    private let scroll = UIScrollView()
    private var buttons: [(choice: Choice, button: UIButton)] = []
    private let uprightButton: ShapeButton
    private let levelButton: ShapeButton

    init(style: HangarStyle) {
        self.style = style
        uprightButton = ShapeButton(upright: true, style: style)
        levelButton = ShapeButton(upright: false, style: style)
        super.init(frame: .zero)
        uprightButton.accessibilityLabel = "Vertical"
        levelButton.accessibilityLabel = "Horizontal"
        uprightButton.addAction(UIAction { [weak self] _ in self?.setUpright(true) }, for: .touchUpInside)
        levelButton.addAction(UIAction { [weak self] _ in self?.setUpright(false) }, for: .touchUpInside)
        addSubview(uprightButton)
        addSubview(levelButton)
        scroll.showsHorizontalScrollIndicator = false
        scroll.alwaysBounceHorizontal = true
        scroll.contentInset = UIEdgeInsets(top: 0, left: 90, bottom: 0, right: 90)
        addSubview(scroll)
        for choice in Self.offered {
            let button = UIButton(type: .custom)
            button.titleLabel?.font = Self.font
            button.layer.cornerCurve = .continuous
            button.addAction(UIAction { [weak self] _ in self?.choose(choice) }, for: .touchUpInside)
            scroll.addSubview(button)
            buttons.append((choice, button))
        }
        update()
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (picker: AspectPicker, _: UITraitCollection) in picker.update() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    static let font = UIFont.systemFont(ofSize: 14)

    /// Shown with `chosen`, upright or level, the buttons for it on if it turns.
    func set(chosen: Choice, upright: Bool) {
        self.chosen = chosen
        self.upright = upright
        update()
    }

    /// The row's middle and the buttons' middle, from the picker's top (Photos': the buttons 31 square, their
    /// middles 41 apart).
    var rowMiddle: CGFloat = 0 { didSet { setNeedsLayout() } }
    var buttonsMiddle: CGFloat = 0 { didSet { setNeedsLayout() } }

    override func layoutSubviews() {
        super.layoutSubviews()
        var x: CGFloat = 0
        var widths: [CGFloat] = []
        for (choice, _) in buttons {
            widths.append(ceil((title(for: choice) as NSString).size(withAttributes: [.font: Self.font]).width) + 14)
        }
        let row = widths.reduce(0, +) + 10 * CGFloat(max(widths.count - 1, 0))
        if inline {
            let whole = 72 + 20 + row
            let start = (bounds.midX - whole / 2 + 5).rounded()
            uprightButton.frame = CGRect(x: start, y: buttonsMiddle - 15.5, width: 31, height: 31)
            levelButton.frame = CGRect(x: start + 41, y: buttonsMiddle - 15.5, width: 31, height: 31)
            scroll.contentInset = .zero
            scroll.frame = CGRect(x: start + 92, y: rowMiddle - 11, width: min(row, bounds.width - start - 92), height: 22)
        } else {
            uprightButton.frame = CGRect(x: bounds.midX - 20.5 - 15.5, y: buttonsMiddle - 15.5, width: 31, height: 31)
            levelButton.frame = CGRect(x: bounds.midX + 20.5 - 15.5, y: buttonsMiddle - 15.5, width: 31, height: 31)
            scroll.contentInset = UIEdgeInsets(top: 0, left: 90, bottom: 0, right: 90)
            scroll.frame = CGRect(x: 0, y: rowMiddle - 11, width: bounds.width, height: 22)
        }
        for ((_, button), width) in zip(buttons, widths) {
            button.frame = CGRect(x: x, y: 0, width: width, height: 22)
            button.layer.cornerRadius = 11
            x += width + 10
        }
        scroll.contentSize = CGSize(width: max(0, x - 10), height: 22)
    }

    private func title(for choice: Choice) -> String {
        switch choice {
        case .ratio(let a, let b): upright ? "\(Int(b)):\(Int(a))" : "\(Int(a)):\(Int(b))"
        default: choice.name.uppercased()
        }
    }

    private func spoken(for choice: Choice) -> String {
        switch choice {
        case .ratio(let a, let b): upright ? "\(Int(b)) by \(Int(a))" : "\(Int(a)) by \(Int(b))"
        default: choice.name
        }
    }

    private func update() {
        let traits = traitCollection
        for (choice, button) in buttons {
            let isChosen = choice == chosen
            button.setTitle(title(for: choice), for: .normal)
            // Photos': the label's colour, the others' at 60%; the chosen on a grey capsule.
            button.setTitleColor(isChosen ? style.foreground : style.foreground.withAlphaComponent(0.6), for: .normal)
            button.backgroundColor = isChosen ? style.foreground.resolvedColor(with: traits).withAlphaComponent(0.2) : .clear
            button.accessibilityLabel = spoken(for: choice)
            button.accessibilityTraits = isChosen ? [.button, .selected] : .button
        }
        let turns = chosen.turns
        uprightButton.isEnabled = turns
        levelButton.isEnabled = turns
        uprightButton.isSelected = upright
        levelButton.isSelected = !upright
        setNeedsLayout()
    }

    private func choose(_ choice: Choice) {
        guard choice != chosen else { return }
        chosen = choice
        update()
        onChoose?(choice)
    }

    private func setUpright(_ value: Bool) {
        guard value != upright, chosen.turns else { return }
        upright = value
        update()
        onUpright?(value)
    }

    /// Back at its start, as Photos opens it (it doesn't scroll to the one chosen).
    func scrollToStart() {
        scroll.setContentOffset(CGPoint(x: -scroll.contentInset.left, y: 0), animated: false)
    }
}

/// Photos' upright and level buttons: a rounded rectangle each, filled while chosen, faint while off.
@MainActor
private final class ShapeButton: UIControl {
    private let shape = CAShapeLayer()
    private let upright: Bool
    private let style: HangarStyle

    init(upright: Bool, style: HangarStyle) {
        self.upright = upright
        self.style = style
        super.init(frame: .zero)
        shape.lineWidth = 2
        layer.addSublayer(shape)
        isAccessibilityElement = true
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (button: ShapeButton, _: UITraitCollection) in button.update() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isEnabled: Bool { didSet { update() } }
    override var isSelected: Bool { didSet { update() } }

    override func layoutSubviews() {
        super.layoutSubviews()
        let size = upright ? CGSize(width: 19, height: 29) : CGSize(width: 29, height: 19)
        let rect = CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
        shape.path = UIBezierPath(roundedRect: rect, cornerRadius: 4).cgPath
        update()
    }

    private func update() {
        let traits = traitCollection
        let ink = style.foreground.resolvedColor(with: traits)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if isEnabled {
            shape.strokeColor = ink.cgColor
            shape.fillColor = isSelected ? ink.cgColor : style.toolFill.resolvedColor(with: traits).cgColor
        } else {
            shape.strokeColor = ink.withAlphaComponent(0.15).cgColor
            shape.fillColor = ink.withAlphaComponent(0.06).cgColor
        }
        CATransaction.commit()
        accessibilityTraits = isSelected ? [.button, .selected] : isEnabled ? .button : [.button, .notEnabled]
    }
}
