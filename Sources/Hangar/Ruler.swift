import UIKit

/// Photos' ruler (its `CEKSlider`): 41 marks 9 points apart over the whole range, sliding under the middle, where the
/// value is read. The mark at the value (the last at or before it) stands up in the accent; a mark sitting down goes
/// back on Photos' spring, dark at first. Every tenth is darker; a dot marks the default while the value's away from it. Dragged and flicked as a
/// scroll view is; a tap felt at each mark crossed; held at the default as Photos' holds it (a slow finger within 5
/// points of it is held there until it has gone 5 points past). Across under the tools on a phone, along beside them
/// on an iPad (turned a quarter, larger values up). Off (not taking a finger) while what it changes is being chosen;
/// dimmed then, and while the tool it changes is switched off.
@MainActor
final class Ruler: UIView, UIScrollViewDelegate {
    enum Axis { case across, along }

    /// The marks: how many, how far apart, which are darker; its height across, and where the marks stand in it.
    static let marks = 41
    static let spacing: CGFloat = 9
    static let mainEvery = 10
    static let thickness: CGFloat = 66
    private static let baseline: CGFloat = 47
    /// Photos' hold at the default: a finger slower than this (points a second) within the first distance of it is
    /// held, until it has gone the second past.
    private static let holdSpeed: CGFloat = 30
    private static let holdWithin: CGFloat = 5
    private static let holdUntil: CGFloat = 5
    /// The ends fade out, clear this near them, whole this far in.
    private static let fadeClear: CGFloat = 10
    private static let fadeWhole: CGFloat = 44

    var axis: Axis = .across { didSet { if axis != oldValue { setNeedsLayout() } } }
    var range: ClosedRange<Double> = -1...1 { didSet { if range != oldValue { arrange() } } }
    /// Where it's held: the default.
    var magnet: Double? = 0 { didSet { if magnet != oldValue { arrange() } } }
    /// Where the dot is, while the value's away from it.
    var marked: Double? = 0 { didSet { if marked != oldValue { arrange() } } }
    private(set) var value: Double = 0
    /// Whether it takes a finger, and whether it's dimmed.
    private(set) var isEnabled = true
    private(set) var isDimmed = false
    /// Whether a finger has it, or it's still sliding after one.
    var isMoving: Bool { active }

    /// A finger touched it; a finger took it; its value changed while one held it or it slid after; it came to rest.
    var onTouch: (() -> Void)?
    var onBegin: (() -> Void)?
    var onChange: ((Double) -> Void)?
    var onEnd: ((Double) -> Void)?

    /// The ruler laid across, turned a quarter when along.
    private let content = UIView()
    /// The marks' window, still while they slide in it, its ends faded.
    private let track = UIView()
    private let scroll = LiftScrollView()
    private var ticks: [CALayer] = []
    private let dot = CAShapeLayer()
    private let fade = CAGradientLayer()
    private let reset = UITapGestureRecognizer()
    private let selection = UISelectionFeedbackGenerator()
    private let style: HangarStyle
    /// The mark lit, and the marks standing up (it, and those still sitting down).
    private var lit = -1
    private var standing: Set<Int> = []
    private var dotShown = false
    /// Placing it (not a finger): its scrolling then isn't a change.
    private var setting = false
    private var active = false
    /// Held at the default; where a finger has taken it, held or not (the finger's way counted while held); where
    /// it was last put.
    private var held = false
    private var taken: CGFloat = 0
    private var put: CGFloat = 0
    private var laidFor: (CGSize, Axis)?

    init(style: HangarStyle) {
        self.style = style
        super.init(frame: .zero)
        scroll.delegate = self
        scroll.showsHorizontalScrollIndicator = false
        scroll.showsVerticalScrollIndicator = false
        scroll.decelerationRate = .normal
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.alwaysBounceHorizontal = true
        scroll.onTouch = { [weak self] in self?.touched() }
        // A finger that stops a flick and lifts without dragging: it has come to rest there.
        scroll.onLift = { [weak self] in
            guard let self, self.active, !self.scroll.isTracking, !self.scroll.isDecelerating else { return }
            self.finish()
        }
        addSubview(content)
        content.addSubview(track)
        track.addSubview(scroll)
        track.layer.mask = fade
        fade.colors = [UIColor.clear.cgColor, UIColor.clear.cgColor, UIColor.black.cgColor, UIColor.black.cgColor,
                       UIColor.clear.cgColor, UIColor.clear.cgColor]
        fade.startPoint = CGPoint(x: 0, y: 0.5)
        fade.endPoint = CGPoint(x: 1, y: 0.5)
        for _ in 0..<Self.marks {
            let tick = CALayer()
            tick.anchorPoint = CGPoint(x: 0.5, y: 1)
            tick.cornerRadius = 1
            scroll.layer.addSublayer(tick)
            ticks.append(tick)
        }
        dot.path = UIBezierPath(ovalIn: CGRect(x: 1, y: 1, width: 6, height: 6)).cgPath
        dot.lineWidth = 1 / max(UIScreen.main.scale, 1)
        dot.strokeColor = UIColor.black.withAlphaComponent(0.15).cgColor
        dot.bounds = CGRect(x: 0, y: 0, width: 8, height: 8)
        dot.opacity = 0
        scroll.layer.addSublayer(dot)
        reset.numberOfTapsRequired = 2
        reset.addTarget(self, action: #selector(resetTapped))
        addGestureRecognizer(reset)
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (ruler: Ruler, _: UITraitCollection) in ruler.paint() }
        isAccessibilityElement = true
        accessibilityTraits = .adjustable
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: Where things are

    /// The content's length: the marks from first to last.
    private static var span: CGFloat { spacing * CGFloat(marks - 1) }

    /// Where a value is along the content.
    private func position(of value: Double) -> CGFloat {
        let whole = range.upperBound - range.lowerBound
        guard whole > 0 else { return 1 }
        return 1 + Self.span * CGFloat((value - range.lowerBound) / whole)
    }

    /// The offset that has a value in the middle.
    private func offset(of value: Double) -> CGFloat {
        position(of: value) - length / 2
    }

    private func value(at offset: CGFloat) -> Double {
        let whole = range.upperBound - range.lowerBound
        let v = range.lowerBound + Double((offset + length / 2 - 1) / Self.span) * whole
        return min(max(v, range.lowerBound), range.upperBound)
    }

    /// The mark at a value: the one at it, or the last before it.
    private func mark(at value: Double) -> Int {
        let whole = range.upperBound - range.lowerBound
        guard whole > 0 else { return 0 }
        return min(max(Int(floor((value - range.lowerBound) / whole * Double(Self.marks - 1) + 1e-6)), 0), Self.marks - 1)
    }

    /// The mark lit for a value, and those standing up: it alone.
    private func marks(for value: Double) -> (Int, Set<Int>) {
        let lit = mark(at: value)
        return (lit, [lit])
    }

    /// Its length, across or along.
    private var length: CGFloat { axis == .across ? bounds.width : bounds.height }
    private var along: CGFloat { scroll.contentOffset.x }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Laid out again only for a new size or way: never under a finger.
        if let laid = laidFor, laid.0 == bounds.size, laid.1 == axis { return }
        laidFor = (bounds.size, axis)
        let wasSetting = setting
        setting = true
        content.transform = .identity
        content.bounds = CGRect(x: 0, y: 0, width: length, height: Self.thickness)
        content.center = CGPoint(x: bounds.midX, y: bounds.midY)
        content.transform = axis == .across ? .identity : CGAffineTransform(rotationAngle: -.pi / 2)
        track.frame = content.bounds
        scroll.frame = track.bounds
        scroll.contentSize = CGSize(width: Self.span + 2, height: Self.thickness)
        scroll.contentInset = UIEdgeInsets(top: 0, left: length / 2, bottom: 0, right: length / 2)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fade.frame = track.bounds
        let clear = Self.fadeClear / max(length, 1), whole = min(Self.fadeWhole / max(length, 1), 0.5)
        fade.locations = [0, clear, whole, 1 - whole, 1 - clear, 1].map { NSNumber(value: Double($0)) }
        CATransaction.commit()
        arrange()
        setting = wasSetting
    }

    /// The marks where they go for the range, and the value in the middle.
    private func arrange() {
        guard bounds.width > 0 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, tick) in ticks.enumerated() {
            tick.position = CGPoint(x: 1 + Self.spacing * CGFloat(i), y: Self.baseline)
        }
        (lit, standing) = marks(for: value)
        for i in ticks.indices { shape(i) }
        if let marked { dot.position = CGPoint(x: position(of: marked), y: Self.baseline - 22) }
        CATransaction.commit()
        paint()
        showDot(animated: false)
        if !active {
            let wasSetting = setting
            setting = true
            place(value)
            setting = wasSetting
        }
    }

    /// A mark's height: 28 standing up, 14 the rest.
    private func shape(_ i: Int) {
        ticks[i].bounds = CGRect(x: 0, y: 0, width: 2, height: standing.contains(i) ? 28 : 14)
    }

    /// The marks' colours: the lit one in the accent while it takes a finger, another standing up whole, every tenth
    /// darker, the rest light.
    private func paint() {
        let traits = traitCollection
        let ink = style.foreground.resolvedColor(with: traits)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, tick) in ticks.enumerated() {
            let color: UIColor
            if i == lit {
                color = isEnabled ? style.accent.resolvedColor(with: traits) : ink
            } else if standing.contains(i) {
                color = ink
            } else {
                color = ink.withAlphaComponent(i % Self.mainEvery == 0 ? 0.7 : 0.4)
            }
            tick.backgroundColor = color.cgColor
        }
        dot.fillColor = style.marker.resolvedColor(with: traits).cgColor
        CATransaction.commit()
    }

    /// The dot, at the default, while the value's more than 2% away from it and the ruler isn't dimmed.
    private func showDot(animated: Bool) {
        let whole = range.upperBound - range.lowerBound
        let away = marked.map { abs(value - $0) > 0.01 * whole } ?? false
        let show = away && !isDimmed
        if animated && show == dotShown { return }
        dotShown = show
        CATransaction.begin()
        CATransaction.setAnimationDuration(animated ? 0.25 : 0)
        CATransaction.setDisableActions(!animated)
        dot.opacity = show ? 1 : 0
        CATransaction.commit()
    }

    /// The value moved to `value`'s marks: those leaving sit down and fade from dark, those coming stand up, on
    /// Photos' spring.
    private func stand(for value: Double) {
        let (newLit, newStanding) = marks(for: value)
        guard newLit != lit || newStanding != standing else { return }
        var changed = standing.symmetricDifference(newStanding)
        changed.formUnion([lit, newLit])
        let sitting = standing.subtracting(newStanding)
        let from = Dictionary(uniqueKeysWithValues: changed.filter { ticks.indices.contains($0) }.map {
            ($0, ticks[$0].presentation()?.bounds ?? ticks[$0].bounds)
        })
        lit = newLit
        standing = newStanding
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for i in from.keys { shape(i) }
        CATransaction.commit()
        paint()
        let ink = style.foreground.resolvedColor(with: traitCollection).cgColor
        for (i, bounds) in from where bounds != ticks[i].bounds {
            let spring = CASpringAnimation(perceptualDuration: 0.4, bounce: 0.25)
            spring.keyPath = "bounds"
            spring.fromValue = NSValue(cgRect: bounds)
            spring.toValue = NSValue(cgRect: ticks[i].bounds)
            ticks[i].add(spring, forKey: "bounds")
            if sitting.contains(i) {
                let fade = CABasicAnimation(keyPath: "backgroundColor")
                fade.fromValue = ink
                fade.toValue = ticks[i].backgroundColor
                fade.duration = 0.4
                ticks[i].add(fade, forKey: "backgroundColor")
            }
        }
    }

    // MARK: Showing a value

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
        stand(for: clamped)
        showDot(animated: animated)
        accessibilityValue = Self.percent(clamped)
    }

    private func place(_ value: Double) {
        scroll.contentOffset = CGPoint(x: offset(of: value), y: 0)
    }

    /// Takes a finger or not, dimmed or not (Photos' 0.33, over a quarter of a second). Not taking one, it stops
    /// where it is first (a drag let go, a flick stopped, the value there told as its end).
    func setState(enabled: Bool, dimmed: Bool, animated: Bool) {
        guard enabled != isEnabled || dimmed != isDimmed else { return }
        if !enabled { stop() }
        isEnabled = enabled
        isDimmed = dimmed
        scroll.isUserInteractionEnabled = enabled
        reset.isEnabled = enabled
        isAccessibilityElement = enabled
        UIView.animate(withDuration: animated ? 0.25 : 0, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
            self.content.alpha = dimmed ? 0.33 : 1
        }
        paint()
        showDot(animated: animated)
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

    // MARK: A finger

    private func touched() {
        guard isEnabled else { return }
        selection.prepare()
        onTouch?()
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        active = true
        taken = along
        put = along
        held = magnet.map { value == $0 } ?? false
        onBegin?()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard !setting, active else { return }
        let at = scrollView.isTracking ? hold(along) : along
        let new = value(at: at)
        // A tap felt at each mark crossed.
        if marks(for: new) != (lit, standing) { selection.selectionChanged() }
        stand(for: new)
        guard new != value else { return }
        value = new
        showDot(animated: true)
        accessibilityValue = Self.percent(new)
        onChange?(new)
    }

    /// Photos' hold at the default, for a finger that has just moved the ruler to `at`: where the ruler is put instead.
    private func hold(_ at: CGFloat) -> CGFloat {
        guard let magnet, range.contains(magnet) else { return at }
        taken += at - put
        let target = offset(of: magnet)
        let velocity = -scroll.panGestureRecognizer.velocity(in: scroll).x
        if held {
            if abs(taken - target) > Self.holdUntil { held = false }
        } else if abs(taken - target) <= Self.holdWithin, abs(put - target) > Self.holdWithin,
                  abs(velocity) <= Self.holdSpeed, (target - put) * velocity >= 0 {
            held = true
            selection.selectionChanged()
        }
        let to = held ? target : taken
        put = to
        if abs(to - at) > 0.01 {
            setting = true
            scroll.contentOffset = CGPoint(x: to, y: 0)
            setting = false
        }
        return to
    }

    /// A finger lifted slower than this (points a second) leaves it where it is: Photos' comes to rest as the finger
    /// lifts, sliding on only when flicked.
    private static let flickSpeed: CGFloat = 100

    func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint, targetContentOffset: UnsafeMutablePointer<CGPoint>) {
        // The scroll view's velocity is in points a millisecond.
        if abs(velocity.x) * 1000 < Self.flickSpeed { targetContentOffset.pointee = scrollView.contentOffset }
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
        value = value(at: along)
        stand(for: value)
        showDot(animated: true)
        onChange?(value)
        onEnd?(value)
    }

    @objc private func resetTapped() {
        guard let magnet, value != magnet, isEnabled, !active else { return }
        onBegin?()
        set(magnet, animated: true)
        selection.selectionChanged()
        onChange?(magnet)
        onEnd?(magnet)
    }

    private static func percent(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }

    #if DEBUG
    /// A finger's drag, without one (`Scrub`).
    func debugMove(to value: Double) {
        if !active {
            active = true
            onBegin?()
        }
        scroll.contentOffset = CGPoint(x: offset(of: value), y: 0)
    }

    func debugEnd() {
        finish()
    }
    #endif

    override func accessibilityIncrement() { nudge(1) }
    override func accessibilityDecrement() { nudge(-1) }

    /// A mark at a time.
    private func nudge(_ marks: Double) {
        guard isEnabled, !active else { return }
        onBegin?()
        set(value + marks * (range.upperBound - range.lowerBound) / Double(Self.marks - 1))
        onChange?(value)
        onEnd?(value)
    }
}
