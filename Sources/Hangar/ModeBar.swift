import UIKit

/// The editor's modes on a capsule of glass, each its symbol over its name, as Photos' (iOS 27): 62 points high, the
/// modes 46.8 apart and 37.2 in from its ends; the chosen one's symbol filled, it and its name dark, the others grey;
/// the accent's small mark (5 by 4.3) over it, 4 points in from the edge (beside it, along the side of an iPad).
@MainActor
final class ModeBar: UIView {
    struct Mode: Equatable {
        let id: String
        let name: String
        let symbol: String
        /// Its symbol when chosen.
        let chosenSymbol: String
    }

    var axis: Ruler.Axis = .across { didSet { setNeedsLayout() } }
    private(set) var chosen: String
    var onChoose: ((String) -> Void)?

    private let surface: UIVisualEffectView
    private var items: [(mode: Mode, icon: UIImageView, label: UILabel, control: UIControl)] = []
    private let mark = CAShapeLayer()
    private let style: HangarStyle

    /// Photos': its thickness; from one mode's middle to the next's, and the first's from the end (all larger down
    /// the side of an iPad).
    private var thickness: CGFloat { axis == .across ? 62 : 76.5 }
    private var pitch: CGFloat { axis == .across ? 46.8 : 64 }
    private var inset: CGFloat { axis == .across ? 37.2 : 50.25 }
    /// A mode's symbol's middle and its name's baseline, from its middle.
    private var symbolMiddle: CGFloat { axis == .across ? -9.7 : -8 }
    private static let nameBaseline: CGFloat = 16

    init(modes: [Mode], chosen: String, style: HangarStyle) {
        self.chosen = chosen
        self.style = style
        surface = Chrome.capsule(style)
        super.init(frame: .zero)
        addSubview(surface)
        for mode in modes {
            let control = UIControl()
            let icon = UIImageView()
            icon.contentMode = .center
            // Photos' are about 21 points.
            icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 21, weight: .regular)
            let label = UILabel()
            label.text = mode.name
            label.textAlignment = .center
            control.addSubview(icon)
            control.addSubview(label)
            control.isAccessibilityElement = true
            control.accessibilityLabel = mode.name
            control.addAction(UIAction { [weak self] _ in self?.tap(mode.id) }, for: .touchUpInside)
            surface.contentView.addSubview(control)
            items.append((mode, icon, label, control))
        }
        mark.path = Self.markPath()
        layer.addSublayer(mark)
        update()
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (bar: ModeBar, _: UITraitCollection) in bar.update() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// A small triangle pointing down from its top, 5 wide and 4.3 high.
    private static func markPath() -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: -2.5, y: 0))
        path.addLine(to: CGPoint(x: 2.5, y: 0))
        path.addLine(to: CGPoint(x: 0, y: 4.3))
        path.closeSubpath()
        return path
    }

    /// Its size laid out along `axis`.
    func fittingSize(for axis: Ruler.Axis) -> CGSize {
        let was = self.axis
        self.axis = axis
        defer { self.axis = was }
        let length = 2 * inset + CGFloat(max(items.count - 1, 0)) * pitch
        return axis == .across ? CGSize(width: length, height: thickness) : CGSize(width: thickness, height: length)
    }

    func choose(_ id: String) {
        chosen = id
        update()
    }

    private func tap(_ id: String) {
        guard id != chosen else { return }
        choose(id)
        onChoose?(id)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        surface.frame = bounds
        Chrome.round(surface)
        let length = axis == .across ? bounds.width : bounds.height
        for (i, entry) in items.enumerated() {
            let middle = inset + CGFloat(i) * pitch
            // Each takes its share of the length (the ends to the capsule's ends), all of its thickness.
            let from = i == 0 ? 0 : middle - pitch / 2
            let to = i == items.count - 1 ? length : middle + pitch / 2
            entry.control.frame = axis == .across ? CGRect(x: from, y: 0, width: to - from, height: thickness)
                : CGRect(x: 0, y: from, width: thickness, height: to - from)
            // The mode's middle in its control.
            let center = axis == .across ? CGPoint(x: middle - from, y: thickness / 2) : CGPoint(x: thickness / 2, y: middle - from)
            let font = entry.label.font ?? style.modeFont
            entry.icon.frame = CGRect(x: center.x - 20, y: center.y + symbolMiddle - 14, width: 40, height: 28)
            entry.label.frame = CGRect(x: center.x - 30, y: center.y + Self.nameBaseline - font.ascender, width: 60, height: ceil(font.lineHeight))
        }
        placeMark()
    }

    /// Over the chosen mode's symbol, 4 points in from the edge; beside it, pointing at it, 18.5 in, down an iPad's side.
    private func placeMark() {
        let middle = inset + CGFloat(items.firstIndex { $0.mode.id == chosen } ?? 0) * pitch
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if axis == .across {
            mark.position = CGPoint(x: middle, y: 4)
            mark.setAffineTransform(.identity)
        } else {
            mark.position = CGPoint(x: 18.5, y: middle + symbolMiddle)
            mark.setAffineTransform(CGAffineTransform(rotationAngle: -.pi / 2))
        }
        CATransaction.commit()
    }

    private func update() {
        for entry in items {
            let isChosen = entry.mode.id == chosen
            entry.icon.image = UIImage(systemName: isChosen ? entry.mode.chosenSymbol : entry.mode.symbol)
            entry.icon.tintColor = isChosen ? style.foreground : style.idle
            entry.label.font = isChosen ? style.chosenModeFont : style.modeFont
            entry.label.textColor = isChosen ? style.foreground : style.idle
            entry.control.accessibilityTraits = isChosen ? [.button, .selected] : .button
        }
        mark.fillColor = style.accent.resolvedColor(with: traitCollection).cgColor
        setNeedsLayout()
    }
}
