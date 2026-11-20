import UIKit

/// The editor's modes on a capsule of glass, each its symbol over its name: the chosen one's filled and darker, the
/// accent's small mark over it (beside it, along the side of an iPad).
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

    static let itemSize = CGSize(width: 52, height: 46)

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
            icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 17, weight: .regular)
            let label = UILabel()
            label.text = mode.name
            label.textAlignment = .center
            label.adjustsFontSizeToFitWidth = true
            label.minimumScaleFactor = 0.8
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

    /// A small triangle pointing down, 6 wide.
    private static func markPath() -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: -3, y: -2))
        path.addLine(to: CGPoint(x: 3, y: -2))
        path.addLine(to: CGPoint(x: 0, y: 2))
        path.closeSubpath()
        return path
    }

    /// Its size laid out along `axis`.
    func fittingSize(for axis: Ruler.Axis) -> CGSize {
        let n = CGFloat(items.count)
        let item = Self.itemSize
        return axis == .across ? CGSize(width: n * item.width + 16, height: item.height + 12)
            : CGSize(width: item.width + 8, height: n * item.height + 16)
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
        let item = Self.itemSize
        for (i, entry) in items.enumerated() {
            let origin = axis == .across ? CGPoint(x: 8 + CGFloat(i) * item.width, y: 6) : CGPoint(x: 4, y: 8 + CGFloat(i) * item.height)
            entry.control.frame = CGRect(origin: origin, size: item)
            entry.icon.frame = CGRect(x: 0, y: 3, width: item.width, height: 24)
            entry.label.frame = CGRect(x: 2, y: 28, width: item.width - 4, height: 14)
        }
        placeMark()
    }

    private func placeMark() {
        guard let entry = items.first(where: { $0.mode.id == chosen }) else { return }
        let frame = entry.control.frame
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if axis == .across {
            mark.position = CGPoint(x: frame.midX, y: frame.minY + 1)
            mark.setAffineTransform(.identity)
        } else {
            mark.position = CGPoint(x: frame.minX + 4, y: frame.minY + 15)
            mark.setAffineTransform(CGAffineTransform(rotationAngle: -.pi / 2))
        }
        CATransaction.commit()
    }

    private func update() {
        for entry in items {
            let isChosen = entry.mode.id == chosen
            entry.icon.image = UIImage(systemName: isChosen ? entry.mode.chosenSymbol : entry.mode.symbol)
            entry.icon.tintColor = isChosen ? style.foreground : style.secondary
            entry.label.font = isChosen ? style.chosenModeFont : style.modeFont
            entry.label.textColor = isChosen ? style.foreground : style.secondary
            entry.control.accessibilityTraits = isChosen ? [.button, .selected] : .button
        }
        mark.fillColor = style.accent.resolvedColor(with: traitCollection).cgColor
        setNeedsLayout()
    }
}
