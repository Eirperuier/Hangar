import UIKit

/// Photos' ruler: marks that slide under a line where the value is read, 0 marked in the accent, its ends fading out.
/// Dragged and flicked as a scroll view is (its own deceleration). As Photos' does, it holds at 0: a finger moving
/// slowly within a few points of it is held there until it has gone a few points past, a flick coming to rest near it
/// rests on it, and a tap is felt each time it gets there. Across (under the tools on a phone) or along (beside them
/// on an iPad). Switched off (dimmed, not taking a finger) while its tools move, so it only ever changes the one it
/// was set to.
@MainActor
final class Ruler: UIView, UIScrollViewDelegate {
    enum Axis { case across, along }

    /// Points a whole of the value takes: 1% is three points, a mark every 2%, a long one every 10%.
    static let pointsPerUnit: CGFloat = 300
    static let markEvery = 0.02
    static let longEvery = 5
    /// Photos' hold at 0 (its ruler's snapping): a finger slower than this, in points a second, comes within the
    /// first distance of 0 and is held there until it has gone the second distance past it.
    private static let holdSpeed: CGFloat = 30
    private static let holdWithin: CGFloat = 5
    private static let holdUntil: CGFloat = 5
    /// The ends fade out from clear at the first distance from them to whole at the second, as Photos' do: the last
    /// few marks, not the ruler.
    private static let fadeClear: CGFloat = 8
    private static let fadeWhole: CGFloat = 44

    var axis: Axis = .across { didSet { if axis != oldValue { setNeedsLayout() } } }
    var range: ClosedRange<Double> = -1...1 { didSet { if range != oldValue { setNeedsLayout() } } }
    private(set) var value: Double = 0
    /// Whether a finger can take it: not while what it changes is being chosen.
    private(set) var isEnabled = true
    /// Whether a finger has it, or it's still sliding after one.
    var isMoving: Bool { active }

    /// A finger took it; its value changed while one held it or it slid after; it came to rest (and the value then).
    var onBegin: (() -> Void)?
    var onChange: ((Double) -> Void)?
    var onEnd: ((Double) -> Void)?

    /// What dims: the marks and the line.
    private let content = UIView()
    /// The marks' window, still while they slide in it, its ends faded.
    private let track = UIView()
    private let scroll = LiftScrollView()
    private let marks = CAShapeLayer()
    private let longMarks = CAShapeLayer()
    private let zero = CAShapeLayer()
    private let line = CALayer()
    private let fade = CAGradientLayer()
    private let reset = UITapGestureRecognizer()
    private let haptics = Haptics()
    private let style: HangarStyle
    /// Placing it (not a finger): its scrolling then isn't a change.
    private var setting = false
    private var active = false
    /// Whether it's held at 0; where a finger has taken it, held or not (as Photos', the finger's way is counted
    /// while it's held); and where it was last put.
    private var held = false
    private var taken: CGFloat = 0
    private var put: CGFloat = 0
    private var drawnFor: (CGSize, Axis, ClosedRange<Double>)?

    init(style: HangarStyle) {
        self.style = style
        super.init(frame: .zero)
        scroll.delegate = self
        scroll.showsHorizontalScrollIndicator = false
        scroll.showsVerticalScrollIndicator = false
        scroll.decelerationRate = .normal
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.alwaysBounceHorizontal = false
        // A finger that stops a flick and lifts without dragging: it has come to rest there.
        scroll.onLift = { [weak self] in
            guard let self, self.active, !self.scroll.isTracking, !self.scroll.isDecelerating else { return }
            self.finish()
        }
        addSubview(content)
        content.addSubview(track)
        track.addSubview(scroll)
        track.layer.mask = fade
        for layer in [marks, longMarks, zero] {
            layer.fillColor = nil
            layer.lineCap = .round
            scroll.layer.addSublayer(layer)
        }
        marks.lineWidth = 1
        longMarks.lineWidth = 1.5
        zero.lineWidth = 2
        content.layer.addSublayer(line)
        fade.colors = [UIColor.clear.cgColor, UIColor.clear.cgColor, UIColor.black.cgColor, UIColor.black.cgColor,
                       UIColor.clear.cgColor, UIColor.clear.cgColor]
        reset.numberOfTapsRequired = 2
        reset.addTarget(self, action: #selector(resetTapped))
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

    /// The offset that has a value under the line.
    private func offset(of value: Double) -> CGFloat {
        position(of: value) - length / 2
    }

    private var length: CGFloat { axis == .across ? bounds.width : bounds.height }
    private var thickness: CGFloat { axis == .across ? bounds.height : bounds.width }
    private var along: CGFloat { axis == .across ? scroll.contentOffset.x : scroll.contentOffset.y }

    private func point(_ along: CGFloat) -> CGPoint {
        axis == .across ? CGPoint(x: along, y: 0) : CGPoint(x: 0, y: along)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        content.frame = bounds
        track.frame = bounds
        // Drawn again only for a new size, way or range: never under a finger.
        if let drawn = drawnFor, drawn.0 == bounds.size, drawn.1 == axis, drawn.2 == range { return }
        drawnFor = (bounds.size, axis, range)
        let wasSetting = setting
        setting = true
        scroll.frame = track.bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fade.frame = track.bounds
        let clear = Self.fadeClear / max(length, 1), whole = min(Self.fadeWhole / max(length, 1), 0.5)
        fade.locations = [0, clear, whole, 1 - whole, 1 - clear, 1].map { NSNumber(value: Double($0)) }
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
        CATransaction.commit()
        if !active { place(value) }
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
        marks.path = short
        longMarks.path = long
        zero.path = origin
    }

    /// Shows a value, without telling. Not while a finger has it or it's sliding after one: what it says then is
    /// the finger's.
    func set(_ value: Double, animated: Bool = false) {
        guard !active else { return }
        let clamped = min(max(value, range.lowerBound), range.upperBound)
        self.value = clamped
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
        scroll.contentOffset = point(offset(of: value))
    }

    private func value(at along: CGFloat) -> Double {
        let p = along + length / 2
        return min(max(range.lowerBound + Double(p / Self.pointsPerUnit), range.lowerBound), range.upperBound)
    }

    /// Takes a finger or not. Switched off, it stops where it is (a drag let go, a flick stopped, the value there
    /// told as its end), dimmed as Photos' is while a finger moves its tools (not for a tap's moment).
    func setEnabled(_ enabled: Bool, dimmed: Bool = true, animated: Bool) {
        let alpha: CGFloat = enabled || !dimmed ? 1 : 0.3
        guard enabled != isEnabled || alpha != content.alpha else { return }
        isEnabled = enabled
        if !enabled { stop() }
        scroll.isUserInteractionEnabled = enabled
        reset.isEnabled = enabled
        isAccessibilityElement = enabled
        UIView.animate(withDuration: animated ? 0.25 : 0, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
            self.content.alpha = alpha
        }
    }

    /// If a finger has it or it's sliding, it stops where it is and comes to rest there, saying so.
    func stop() {
        guard active else { return }
        // Setting the offset it's at ends a flick; a finger's drag is let go by taking its gesture away a moment.
        scroll.setContentOffset(scroll.contentOffset, animated: false)
        if scroll.isTracking {
            scroll.panGestureRecognizer.isEnabled = false
            scroll.panGestureRecognizer.isEnabled = true
        }
        finish()
    }

    // MARK: Scrolling

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        active = true
        taken = along
        put = along
        held = value == 0 && range.contains(0)
        onBegin?()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard !setting, active else { return }
        let at = scrollView.isTracking ? hold(along) : along
        let new = value(at: at)
        // A tap felt on getting to 0 (or over it), and to either end.
        let arrived = new == 0 && value != 0
        let over = (value > 0 && new < 0) || (value < 0 && new > 0)
        let ended = (new == range.lowerBound || new == range.upperBound) && new != value
        if arrived || over || ended { haptics.detent() }
        guard new != value else { return }
        value = new
        accessibilityValue = "\(Int((new * 100).rounded()))"
        onChange?(new)
    }

    /// Photos' hold at 0, for a finger that has just moved the ruler to `at`: where the ruler is put instead.
    private func hold(_ at: CGFloat) -> CGFloat {
        guard range.contains(0) else { return at }
        taken += at - put
        let zeroAt = offset(of: 0)
        let velocity = scroll.panGestureRecognizer.velocity(in: scroll)
        let speed = abs(axis == .across ? velocity.x : velocity.y)
        if held {
            if abs(taken - zeroAt) > Self.holdUntil { held = false }
        } else if abs(taken - zeroAt) < Self.holdWithin, speed < Self.holdSpeed {
            held = true
        }
        let to = held ? zeroAt : taken
        put = to
        if abs(to - at) > 0.01 {
            setting = true
            scroll.contentOffset = point(to)
            setting = false
        }
        return to
    }

    func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint, targetContentOffset: UnsafeMutablePointer<CGPoint>) {
        // Coming to rest within 2% of 0, it rests on 0.
        let target = axis == .across ? targetContentOffset.pointee.x : targetContentOffset.pointee.y
        if abs(value(at: target)) < 0.02 {
            targetContentOffset.pointee = point(offset(of: 0))
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
        held = false
        let rest = value(at: along)
        value = abs(rest) < 0.005 ? 0 : rest
        onChange?(value)
        onEnd?(value)
    }

    @objc private func resetTapped() {
        guard value != 0, isEnabled, !active else { return }
        onBegin?()
        set(0, animated: true)
        haptics.detent()
        onChange?(0)
        onEnd?(0)
    }

    #if DEBUG
    /// A finger's drag, without one (`Scrub`).
    func debugMove(to value: Double) {
        if !active {
            active = true
            onBegin?()
        }
        scroll.contentOffset = point(offset(of: value))
    }

    func debugEnd() {
        finish()
    }
    #endif

    override func accessibilityIncrement() { nudge(0.05) }
    override func accessibilityDecrement() { nudge(-0.05) }

    private func nudge(_ by: Double) {
        guard isEnabled, !active else { return }
        onBegin?()
        set(value + by)
        onChange?(value)
        onEnd?(value)
    }
}
