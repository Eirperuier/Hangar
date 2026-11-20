import HangarCore
import UIKit

/// What a strip holds: shown chosen (in the middle) or not.
@MainActor
protocol StripItem: UIView {
    func setChosen(_ chosen: Bool)
}

/// A row of things, one in the middle chosen, as Photos' tools and filters are: dragged and flicked, it comes to rest
/// on one; passing one chooses it (felt); a tap on one brings it to the middle. It says when it starts moving and where
/// it comes to rest, as Photos' does to dim its ruler meanwhile and set it for the tool it rests on. Across (a phone)
/// or along (an iPad).
@MainActor
final class Strip: UIView, UIScrollViewDelegate {
    var axis: Ruler.Axis = .across { didSet { setNeedsLayout() } }
    /// From one's middle to the next's.
    var pitch: CGFloat = 72 { didSet { setNeedsLayout() } }
    var itemSize: CGFloat = 48 { didSet { setNeedsLayout() } }
    private(set) var items: [any StripItem] = []
    private(set) var chosen = 0

    /// One came to the middle, by a finger or a tap: as it passes, not only where it rests.
    var onChoose: ((Int) -> Void)?
    /// The one in the middle was tapped.
    var onTapChosen: ((Int) -> Void)?
    /// A finger took it (dragged) or a tap set it moving; it came to rest, on the one in the middle.
    var onMove: ((_ dragged: Bool) -> Void)?
    var onRest: ((Int) -> Void)?
    /// Whether it's moving, for a finger or a tap.
    private(set) var isMoving = false

    private let scroll = LiftScrollView()
    private let haptics = Haptics()
    private let fade = CAGradientLayer()
    private var setting = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        scroll.delegate = self
        scroll.showsHorizontalScrollIndicator = false
        scroll.showsVerticalScrollIndicator = false
        scroll.decelerationRate = .fast
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.clipsToBounds = false
        addSubview(scroll)
        scroll.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped(_:))))
        scroll.onLift = { [weak self] in self?.settle() }
        // Its ends fade out: what's beyond them isn't shown.
        fade.colors = [UIColor.clear.cgColor, UIColor.black.cgColor, UIColor.black.cgColor, UIColor.clear.cgColor]
        layer.mask = fade
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func setItems(_ new: [any StripItem], chosen index: Int) {
        items.forEach { $0.removeFromSuperview() }
        items = new
        new.forEach(scroll.addSubview)
        chosen = min(max(index, 0), max(new.count - 1, 0))
        for (i, item) in items.enumerated() { item.setChosen(i == chosen) }
        setNeedsLayout()
    }

    private var length: CGFloat { axis == .across ? bounds.width : bounds.height }

    override func layoutSubviews() {
        super.layoutSubviews()
        setting = true
        scroll.frame = bounds
        // Room round the strip for a chosen thumbnail grown, and its dot, inside the mask.
        fade.frame = bounds.insetBy(dx: axis == .across ? 0 : -14, dy: axis == .across ? -14 : 0)
        let edge: NSNumber = axis == .across ? 0.06 : 0.15
        fade.locations = [0, edge, NSNumber(value: 1 - edge.doubleValue), 1]
        fade.startPoint = axis == .across ? CGPoint(x: 0, y: 0.5) : CGPoint(x: 0.5, y: 0)
        fade.endPoint = axis == .across ? CGPoint(x: 1, y: 0.5) : CGPoint(x: 0.5, y: 1)
        let span = pitch * CGFloat(max(items.count - 1, 0))
        let half = length / 2
        if axis == .across {
            scroll.contentSize = CGSize(width: span, height: bounds.height)
            scroll.contentInset = UIEdgeInsets(top: 0, left: half, bottom: 0, right: half)
        } else {
            scroll.contentSize = CGSize(width: bounds.width, height: span)
            scroll.contentInset = UIEdgeInsets(top: half, left: 0, bottom: half, right: 0)
        }
        for (i, item) in items.enumerated() {
            let p = CGFloat(i) * pitch
            item.bounds = CGRect(x: 0, y: 0, width: itemSize, height: itemSize)
            item.center = axis == .across ? CGPoint(x: p, y: bounds.height / 2) : CGPoint(x: bounds.width / 2, y: p)
        }
        scroll.contentOffset = offset(for: chosen)
        setting = false
    }

    private func offset(for index: Int) -> CGPoint {
        let p = CGFloat(index) * pitch - length / 2
        return axis == .across ? CGPoint(x: p, y: 0) : CGPoint(x: 0, y: p)
    }

    private func index(at offset: CGPoint) -> Int {
        let p = (axis == .across ? offset.x : offset.y) + length / 2
        return min(max(Int((p / pitch).rounded()), 0), max(items.count - 1, 0))
    }

    /// Brings one to the middle without telling.
    func choose(_ index: Int, animated: Bool) {
        guard items.indices.contains(index) else { return }
        mark(index)
        setting = true
        scroll.setContentOffset(offset(for: index), animated: animated)
        if !animated { setting = false }
    }

    private func mark(_ index: Int) {
        guard index != chosen else { return }
        items[chosen].setChosen(false)
        chosen = index
        items[index].setChosen(true)
    }

    private func move(dragged: Bool) {
        guard !isMoving || dragged else { return }
        isMoving = true
        onMove?(dragged)
    }

    /// A finger lifted without flicking it: if that stopped a flick between two, onto the nearer.
    private func settle() {
        guard isMoving, !setting, !scroll.isTracking, !scroll.isDecelerating else { return }
        let target = offset(for: index(at: scroll.contentOffset))
        guard scroll.contentOffset != target else { return rest() }
        setting = true
        scroll.setContentOffset(target, animated: true)
    }

    private func rest() {
        guard isMoving, !scroll.isTracking, !scroll.isDecelerating else { return }
        isMoving = false
        onRest?(chosen)
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        setting = false
        move(dragged: true)
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { rest() }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        rest()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard !setting, scrollView.isDragging || scrollView.isDecelerating else { return }
        let nearest = index(at: scrollView.contentOffset)
        guard nearest != chosen else { return }
        mark(nearest)
        haptics.step()
        onChoose?(nearest)
    }

    func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint, targetContentOffset: UnsafeMutablePointer<CGPoint>) {
        targetContentOffset.pointee = offset(for: index(at: targetContentOffset.pointee))
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        setting = false
        rest()
    }

    @objc private func tapped(_ tap: UITapGestureRecognizer) {
        let at = tap.location(in: scroll)
        guard let i = items.firstIndex(where: { $0.frame.insetBy(dx: -8, dy: -8).contains(at) }) else { return }
        if i == chosen {
            guard !isMoving else { return }
            onTapChosen?(i)
        } else {
            move(dragged: false)
            let there = scroll.contentOffset == offset(for: i)
            choose(i, animated: true)
            haptics.step()
            onChoose?(i)
            if there {
                setting = false
                rest()
            }
        }
    }
}

/// A scroll view that says when a finger lifts from it. A finger that stops a flick and lifts without dragging leaves
/// it at rest without a word to its delegate (Photos' own hear of it privately): the lift is when to see where it is.
@MainActor
final class LiftScrollView: UIScrollView {
    var onLift: (() -> Void)?

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesEnded(touches, with: event)
        lifted()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesCancelled(touches, with: event)
        lifted()
    }

    /// After the touch's own gestures (a tap) have done what they do.
    private func lifted() {
        DispatchQueue.main.async { [weak self] in self?.onLift?() }
    }
}

/// An adjustment's tool: its symbol in a ring, filled when chosen, its value an arc of the accent round it (the
/// clock's way for more, the other way for less), the number in place of the symbol while it's being changed.
@MainActor
final class ToolButton: UIView, StripItem {
    let id: String
    private let range: ClosedRange<Double>
    private let style: HangarStyle
    private let ring = CAShapeLayer()
    private let arc = CAShapeLayer()
    private let symbol = UIImageView()
    private let number = UILabel()
    private var chosen = false
    private var value: Double = 0
    private var switchedOff = false
    private var showsNumber = false

    init(_ adjustment: HangarAdjustment, style: HangarStyle) {
        id = adjustment.id
        range = adjustment.range
        self.style = style
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        ring.lineWidth = 1.5
        arc.lineWidth = 2
        arc.fillColor = nil
        arc.lineCap = .round
        layer.addSublayer(ring)
        layer.addSublayer(arc)
        symbol.image = UIImage(systemName: adjustment.symbol) ?? UIImage(systemName: "circle")
        symbol.contentMode = .center
        addSubview(symbol)
        number.font = .monospacedDigitSystemFont(ofSize: 15, weight: .medium)
        number.textAlignment = .center
        number.isHidden = true
        addSubview(number)
        isAccessibilityElement = true
        accessibilityLabel = adjustment.name
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (button: ToolButton, _: UITraitCollection) in button.update() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func setChosen(_ chosen: Bool) {
        self.chosen = chosen
        if !chosen { showsNumber = false }
        update()
    }

    func show(value: Double, switchedOff: Bool, number showsNumber: Bool) {
        self.value = value
        self.switchedOff = switchedOff
        self.showsNumber = showsNumber && chosen
        update()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let inset = ring.lineWidth / 2
        let circle = UIBezierPath(ovalIn: bounds.insetBy(dx: inset, dy: inset)).cgPath
        ring.path = circle
        // From the top, the clock's way.
        let radius = bounds.width / 2 - inset
        let path = UIBezierPath(arcCenter: CGPoint(x: bounds.midX, y: bounds.midY), radius: radius, startAngle: -.pi / 2,
                                endAngle: 1.5 * .pi, clockwise: true)
        arc.frame = bounds
        arc.path = path.cgPath
        symbol.frame = bounds
        number.frame = bounds
        symbol.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: bounds.width * 0.36, weight: .regular)
        update()
    }

    private func update() {
        let traits = traitCollection
        ring.strokeColor = style.toolRing.resolvedColor(with: traits).cgColor
        ring.fillColor = chosen ? style.toolFill.resolvedColor(with: traits).cgColor : UIColor.clear.cgColor
        arc.strokeColor = style.accent.resolvedColor(with: traits).cgColor
        let reach = max(abs(range.lowerBound), abs(range.upperBound))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        arc.strokeEnd = CGFloat(min(abs(value) / max(reach, 0.0001), 1))
        arc.isHidden = value == 0
        // Less goes the other way round: the arc mirrored about the middle.
        arc.setAffineTransform(value < 0 ? CGAffineTransform(scaleX: -1, y: 1) : .identity)
        CATransaction.commit()
        symbol.tintColor = style.foreground
        number.textColor = style.foreground
        number.text = "\(Int((value * 100).rounded()))"
        number.isHidden = !showsNumber
        symbol.isHidden = showsNumber
        alpha = switchedOff ? 0.4 : 1
        accessibilityValue = switchedOff ? "Off" : "\(Int((value * 100).rounded()))"
        accessibilityTraits = chosen ? [.button, .selected] : .button
    }
}

/// A filter's thumbnail: the picture with it; chosen, a size larger in a frame, a dot over it.
@MainActor
final class FilterThumbnail: UIView, StripItem {
    let id: String?
    let name: String
    private let picture = UIImageView()
    private let dot = UIView()
    private let style: HangarStyle
    private var chosen = false
    var axis: Ruler.Axis = .across { didSet { setNeedsLayout() } }

    init(id: String?, name: String, style: HangarStyle) {
        self.id = id
        self.name = name
        self.style = style
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        picture.contentMode = .scaleAspectFill
        picture.clipsToBounds = true
        picture.layer.cornerCurve = .continuous
        picture.backgroundColor = style.toolFill
        addSubview(picture)
        dot.backgroundColor = style.foreground
        dot.layer.cornerRadius = 2
        addSubview(dot)
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOffset = CGSize(width: 0, height: 1)
        layer.shadowRadius = 3
        isAccessibilityElement = true
        accessibilityLabel = name
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var image: UIImage? {
        get { picture.image }
        set { picture.image = newValue }
    }

    func setChosen(_ chosen: Bool) {
        self.chosen = chosen
        UIView.animate(withDuration: 0.2) { self.layoutSubviews() }
        accessibilityTraits = chosen ? [.button, .selected] : .button
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let grow: CGFloat = chosen ? 1.13 : 1
        let side = bounds.width * grow
        picture.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        picture.center = CGPoint(x: bounds.midX, y: bounds.midY)
        picture.layer.cornerRadius = chosen ? 6 : 3
        picture.layer.borderWidth = chosen ? 2.5 : 0
        picture.layer.borderColor = style.thumbnailFrame.resolvedColor(with: traitCollection).cgColor
        layer.shadowOpacity = chosen ? 0.25 : 0
        dot.isHidden = !chosen
        dot.bounds = CGRect(x: 0, y: 0, width: 4, height: 4)
        dot.center = axis == .across ? CGPoint(x: bounds.midX, y: bounds.midY - side / 2 - 8)
            : CGPoint(x: bounds.midX - side / 2 - 8, y: bounds.midY)
    }
}
