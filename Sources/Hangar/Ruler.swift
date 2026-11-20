import UIKit

/// Photos' ruler: marks that slide under a line where the value is read, 0 marked in the accent, fading toward the
/// ends. Dragged and flicked as a scroll view is (its own deceleration); near 0 it holds there, with a tap felt.
/// Across (under the tools on a phone) or along (beside them on an iPad).
@MainActor
final class Ruler: UIView, UIScrollViewDelegate {
    enum Axis { case across, along }

    /// Points a whole of the value takes: 1% is three points, a mark every 2%, a long one every 10%.
    static let pointsPerUnit: CGFloat = 300
    static let markEvery = 0.02
    static let longEvery = 5

    var axis: Axis = .across { didSet { setNeedsLayout() } }
    var range: ClosedRange<Double> = -1...1 { didSet { if range != oldValue { setNeedsLayout() } } }
    private(set) var value: Double = 0

    /// A finger took it; its value changed while one held it or it slid after; it came to rest (and the value then).
    var onBegin: (() -> Void)?
    var onChange: ((Double) -> Void)?
    var onEnd: ((Double) -> Void)?

    private let scroll = UIScrollView()
    private let marks = CAShapeLayer()
    private let longMarks = CAShapeLayer()
    private let zero = CAShapeLayer()
    private let line = CALayer()
    private let fade = CAGradientLayer()
    private let haptics = Haptics()
    private var setting = false
    private var active = false
    private let style: HangarStyle

    init(style: HangarStyle) {
        self.style = style
        super.init(frame: .zero)
        scroll.delegate = self
        scroll.showsHorizontalScrollIndicator = false
        scroll.showsVerticalScrollIndicator = false
        scroll.decelerationRate = .normal
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.alwaysBounceHorizontal = false
        addSubview(scroll)
        for layer in [marks, longMarks, zero] {
            layer.fillColor = nil
            layer.lineCap = .round
            scroll.layer.addSublayer(layer)
        }
        marks.lineWidth = 1
        longMarks.lineWidth = 1.5
        zero.lineWidth = 2
        layer.addSublayer(line)
        fade.colors = [UIColor.clear.cgColor, UIColor.black.cgColor, UIColor.black.cgColor, UIColor.clear.cgColor]
        fade.locations = [0, 0.3, 0.7, 1]
        scroll.layer.mask = fade
        let reset = UITapGestureRecognizer(target: self, action: #selector(resetTapped))
        reset.numberOfTapsRequired = 2
        addGestureRecognizer(reset)
        applyColors()
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (ruler: Ruler, _: UITraitCollection) in ruler.applyColors() }
        isAccessibilityElement = true
        accessibilityTraits = .adjustable
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func applyColors() {
        marks.strokeColor = style.tick.resolvedColor(with: traitCollection).cgColor
        longMarks.strokeColor = style.majorTick.resolvedColor(with: traitCollection).cgColor
        zero.strokeColor = style.accent.resolvedColor(with: traitCollection).cgColor
        line.backgroundColor = style.foreground.resolvedColor(with: traitCollection).cgColor
    }

    /// Where the value's mark is along the content.
    private func position(of value: Double) -> CGFloat {
        CGFloat(value - range.lowerBound) * Self.pointsPerUnit
    }

    private var length: CGFloat { axis == .across ? bounds.width : bounds.height }
    private var thickness: CGFloat { axis == .across ? bounds.height : bounds.width }

    override func layoutSubviews() {
        super.layoutSubviews()
        let wasSetting = setting
        setting = true
        scroll.frame = bounds
        fade.frame = scroll.bounds
        fade.startPoint = axis == .across ? CGPoint(x: 0, y: 0.5) : CGPoint(x: 0.5, y: 0)
        fade.endPoint = axis == .across ? CGPoint(x: 1, y: 0.5) : CGPoint(x: 0.5, y: 1)
        let span = position(of: range.upperBound)
        let half = length / 2
        if axis == .across {
            scroll.contentSize = CGSize(width: span, height: bounds.height)
            scroll.contentInset = UIEdgeInsets(top: 0, left: half, bottom: 0, right: half)
            line.frame = CGRect(x: half - 1, y: thickness * 0.1, width: 2, height: thickness * 0.8)
        } else {
            scroll.contentSize = CGSize(width: bounds.width, height: span)
            scroll.contentInset = UIEdgeInsets(top: half, left: 0, bottom: half, right: 0)
            line.frame = CGRect(x: thickness * 0.1, y: half - 1, width: thickness * 0.8, height: 2)
        }
        line.cornerRadius = 1
        drawMarks()
        place(value)
        setting = wasSetting
    }

    private func drawMarks() {
        guard bounds.width > 0 else { return }
        let short = CGMutablePath(), long = CGMutablePath(), origin = CGMutablePath()
        let count = Int(((range.upperBound - range.lowerBound) / Self.markEvery).rounded())
        let t = thickness
        for i in 0...count {
            let v = range.lowerBound + Double(i) * Self.markEvery
            let p = position(of: v)
            let isZero = abs(v) < Self.markEvery / 2
            let isLong = Int((v / Self.markEvery).rounded()) % Self.longEvery == 0
            let (inset, path): (CGFloat, CGMutablePath) = isZero ? (0.18, origin) : isLong ? (0.28, long) : (0.36, short)
            if axis == .across {
                path.move(to: CGPoint(x: p, y: t * inset))
                path.addLine(to: CGPoint(x: p, y: t * (1 - inset)))
            } else {
                path.move(to: CGPoint(x: t * inset, y: p))
                path.addLine(to: CGPoint(x: t * (1 - inset), y: p))
            }
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        marks.path = short
        longMarks.path = long
        zero.path = origin
        CATransaction.commit()
    }

    /// Shows a value, without telling.
    func set(_ value: Double, animated: Bool = false) {
        let clamped = min(max(value, range.lowerBound), range.upperBound)
        self.value = clamped
        guard !active else { return }
        setting = true
        if animated {
            UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 1, initialSpringVelocity: 0) { self.place(clamped) } completion: { _ in }
        } else {
            place(clamped)
        }
        setting = false
        accessibilityValue = "\(Int((clamped * 100).rounded()))"
    }

    private func place(_ value: Double) {
        let p = position(of: value) - length / 2
        scroll.contentOffset = axis == .across ? CGPoint(x: p, y: 0) : CGPoint(x: 0, y: p)
    }

    private func value(at offset: CGPoint) -> Double {
        let p = (axis == .across ? offset.x : offset.y) + length / 2
        return min(max(range.lowerBound + Double(p / Self.pointsPerUnit), range.lowerBound), range.upperBound)
    }

    // MARK: Scrolling

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        active = true
        onBegin?()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard !setting, active else { return }
        let new = value(at: scrollView.contentOffset)
        // A tap felt crossing 0, and on reaching either end.
        if (value < 0) != (new < 0) || (value > 0) != (new > 0) || ((new == range.lowerBound || new == range.upperBound) && new != value) {
            haptics.detent()
        }
        guard new != value else { return }
        value = new
        accessibilityValue = "\(Int((new * 100).rounded()))"
        onChange?(new)
    }

    func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint, targetContentOffset: UnsafeMutablePointer<CGPoint>) {
        // Coming to rest within 2% of 0, it rests on 0.
        let landing = value(at: targetContentOffset.pointee)
        if abs(landing) < 0.02 {
            let p = position(of: 0) - length / 2
            targetContentOffset.pointee = axis == .across ? CGPoint(x: p, y: 0) : CGPoint(x: 0, y: p)
        }
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { finish() }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        finish()
    }

    private func finish() {
        guard active else { return }
        active = false
        let rest = value(at: scroll.contentOffset)
        value = abs(rest) < 0.005 ? 0 : rest
        onChange?(value)
        onEnd?(value)
    }

    @objc private func resetTapped() {
        guard value != 0 else { return }
        onBegin?()
        set(0, animated: true)
        haptics.detent()
        onChange?(0)
        onEnd?(0)
    }

    override func accessibilityIncrement() { nudge(0.05) }
    override func accessibilityDecrement() { nudge(-0.05) }

    private func nudge(_ by: Double) {
        onBegin?()
        set(value + by)
        onChange?(value)
        onEnd?(value)
    }
}
