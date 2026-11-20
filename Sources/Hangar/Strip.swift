import CoreImage
import HangarCore
import UIKit
import UIKit.UIGestureRecognizerSubclass

/// What a strip holds: shown chosen (in the middle) or not.
@MainActor
protocol StripItem: UIView {
    func setChosen(_ chosen: Bool)
    /// How it shows turned on a wheel: how narrow (1 facing), and how far into grey as it turns out of sight.
    func turn(squeeze: CGFloat, grey: CGFloat)
}

extension StripItem {
    func turn(squeeze: CGFloat, grey: CGFloat) {}
}

/// A row of things, one in the middle chosen, as Photos' tools and filters are: dragged and flicked, it comes to rest
/// on one; the one passing the middle is chosen as it goes; a tap on one brings it there in a quarter of a second. It
/// says when it starts moving and where it comes to rest, as Photos' does to switch its ruler off meanwhile and set it
/// for what it rests on. Across (a phone) or along (an iPad). Photos' filters turn on a wheel (`wheel`).
@MainActor
final class Strip: UIView, UIScrollViewDelegate {
    /// How it's felt passing things: Photos' tools tap once one is nearly in the middle (at once when flicked fast);
    /// its filters tap as each is chosen, chosen only once well past halfway (a sixth of one more).
    enum Feel { case tools, filters }

    var axis: Ruler.Axis = .across { didSet { setNeedsLayout() } }
    /// From one's middle to the next's, and each one's size.
    var pitch: CGFloat = 71 { didSet { setNeedsLayout() } }
    var itemSize: CGFloat = 51 { didSet { setNeedsLayout() } }
    /// Its ends fade from clear this near them to whole this far in (each a fraction of its length if under 1).
    var fadeClear: CGFloat = 14 { didSet { setNeedsLayout() } }
    var fadeWhole: CGFloat = 40 { didSet { setNeedsLayout() } }
    /// Room kept across it, outside its bounds, for what's drawn beyond them (a chosen thumbnail's frame and dot).
    var overhang: CGFloat = 0 { didSet { setNeedsLayout() } }
    var feel: Feel = .tools
    /// The radius of the wheel the row turns on, if it does (Photos' filters, 200 points): a thing `s` along the row
    /// from the middle shows `radius·sin(s/radius)` from it, narrower the farther it has turned. Three each way show
    /// whole; the fourth in grey, fading out over 18 points; none past it.
    var wheel: CGFloat? { didSet { setNeedsLayout() } }
    /// How far each way from the middle it shows, if not all of it (Photos' tools on an iPad, 361 points); its fade is
    /// at those ends.
    var reach: CGFloat? { didSet { if reach != oldValue { setNeedsLayout() } } }
    /// Something that stays in the middle while the strip slides under it (Photos' frame round the chosen filter).
    var loupe: UIView? {
        didSet {
            oldValue?.removeFromSuperview()
            if let loupe { addSubview(loupe) }
            setNeedsLayout()
        }
    }
    private(set) var items: [any StripItem] = []
    private(set) var chosen = 0

    /// One came to the middle, by a finger or a tap: as it passes, not only where it rests.
    var onChoose: ((Int) -> Void)?
    /// The one in the middle was tapped.
    var onTapChosen: ((Int) -> Void)?
    /// A finger took it or a tap set it moving; it came to rest, on the one in the middle.
    var onMove: (() -> Void)?
    var onRest: ((Int) -> Void)?
    /// What VoiceOver reads for the one in the middle (Photos' strip is one slider: its name, and the chosen one's).
    var spokenValue: ((Int) -> String)?
    /// Whether it's moving, for a finger or a tap.
    private(set) var isMoving = false
    /// Whether a finger moved it (not a tap), until it rests.
    private(set) var isDragged = false

    private let scroll = LiftScrollView()
    private let selection = UISelectionFeedbackGenerator()
    private let fade = CAGradientLayer()
    private var setting = false
    private var animating = false
    /// A tap's slide, a frame at a time (so a wheel turns with it).
    private var link: CADisplayLink?
    private var slideFrom = CGPoint.zero
    private var slideTo = CGPoint.zero
    private var slideStart: CFTimeInterval = 0
    private var slideDone: (() -> Void)?
    /// For Photos' feel of the tools: how fast it's going, and whether the chosen one has been felt.
    private var lastOffset: CGFloat = 0
    private var lastTime: CFTimeInterval = 0
    private var felt = true

    override init(frame: CGRect) {
        super.init(frame: frame)
        scroll.delegate = self
        scroll.showsHorizontalScrollIndicator = false
        scroll.showsVerticalScrollIndicator = false
        scroll.decelerationRate = .fast
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.clipsToBounds = false
        addSubview(scroll)
        scroll.onTouch = { [weak self] in self?.selection.prepare() }
        scroll.onLift = { [weak self] in self?.settle() }
        fade.colors = [UIColor.clear.cgColor, UIColor.clear.cgColor, UIColor.black.cgColor, UIColor.black.cgColor,
                       UIColor.clear.cgColor, UIColor.clear.cgColor]
        layer.mask = fade
        isAccessibilityElement = true
        accessibilityTraits = .adjustable
    }

    override var accessibilityValue: String? {
        get { spokenValue?(chosen) }
        set {}
    }

    override func accessibilityIncrement() { nudge(1) }
    override func accessibilityDecrement() { nudge(-1) }

    /// The next one or the one before to the middle, as a tap on it brings it.
    private func nudge(_ by: Int) {
        let i = chosen + by
        guard items.indices.contains(i), !isMoving else { return }
        move()
        mark(i)
        selection.selectionChanged()
        onChoose?(i)
        slide(to: i, animated: true) { [weak self] in self?.rest() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func setItems(_ new: [any StripItem], chosen index: Int) {
        items.forEach { $0.removeFromSuperview() }
        items = new
        new.forEach(scroll.addSubview)
        // Each is a control, as Photos' cells are: a finger held on one a moment (the scroll view's 150 ms) is the
        // cell's, so it doesn't move the strip, and lifted near it, it's a tap.
        for (i, item) in new.enumerated() {
            (item as? UIControl)?.addAction(UIAction { [weak self] _ in self?.tapped(i) }, for: .touchUpInside)
        }
        chosen = min(max(index, 0), max(new.count - 1, 0))
        for (i, item) in items.enumerated() { item.setChosen(i == chosen) }
        setNeedsLayout()
    }

    private var length: CGFloat { axis == .across ? bounds.width : bounds.height }
    private func along(_ point: CGPoint) -> CGFloat { axis == .across ? point.x : point.y }

    override func layoutSubviews() {
        super.layoutSubviews()
        setting = true
        scroll.frame = bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // On a wheel, the fourth thing each way fades out over 18 points from where the third ends.
        let window = reach.map { min(2 * $0, length) } ?? wheel.map { 2 * ($0 * sin(min(wheelReach / $0, .pi / 2)) + Self.wheelFade) } ?? length
        let cut = (length - window) / 2
        fade.frame = bounds.insetBy(dx: axis == .across ? cut : -overhang, dy: axis == .across ? -overhang : cut)
        let l = max(window, 1)
        var clear = (fadeClear < 1 ? fadeClear * l : fadeClear) / l, whole = min((fadeWhole < 1 ? fadeWhole * l : fadeWhole) / l, 0.5)
        if wheel != nil, reach == nil {
            clear = 0
            whole = (Self.wheelFade - 0.5) / l
        }
        fade.locations = [0, clear, whole, 1 - whole, 1 - clear, 1].map { NSNumber(value: Double($0)) }
        fade.startPoint = axis == .across ? CGPoint(x: 0, y: 0.5) : CGPoint(x: 0.5, y: 0)
        fade.endPoint = axis == .across ? CGPoint(x: 1, y: 0.5) : CGPoint(x: 0.5, y: 1)
        CATransaction.commit()
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
        loupe?.center = CGPoint(x: bounds.midX, y: bounds.midY)
        if !isMoving { scroll.contentOffset = offset(for: chosen) }
        setting = false
        turn()
    }

    /// How far along the row a wheel shows whole: three and a half things, to the third's picture's edge.
    private var wheelReach: CGFloat { pitch * 3.5 - 1 }
    private static let wheelFade: CGFloat = 18

    /// On a wheel, each thing where it shows as the row turns, squeezed as it turns away.
    private func turn() {
        guard let radius = wheel else { return }
        let middle = along(scroll.contentOffset) + length / 2
        let half = itemSize / 2
        func shown(_ s: CGFloat) -> CGFloat { radius * sin(min(max(s / radius, -.pi / 2), .pi / 2)) }
        for (i, item) in items.enumerated() {
            let s = CGFloat(i) * pitch - middle
            let from = shown(s - half), to = shown(s + half)
            // Past the window: out of sight. On a phone's wheel, grey from three and a half out to four.
            item.isHidden = reach.map { min(abs(from), abs(to)) > $0 } ?? (abs(s) > pitch * 4.5)
            guard !item.isHidden else { continue }
            let at = middle + (from + to) / 2
            item.center = axis == .across ? CGPoint(x: at, y: bounds.height / 2) : CGPoint(x: bounds.width / 2, y: at)
            let grey = reach == nil ? min(max((abs(s) - pitch * 3.5) / (pitch / 2), 0), 1) : 0
            item.turn(squeeze: (to - from) / itemSize, grey: grey)
        }
    }

    private func offset(for index: Int) -> CGPoint {
        let p = CGFloat(index) * pitch - length / 2
        return axis == .across ? CGPoint(x: p, y: 0) : CGPoint(x: 0, y: p)
    }

    /// Where in the row the middle is, in items.
    private func place(at offset: CGPoint) -> CGFloat {
        (along(offset) + length / 2) / pitch
    }

    private func nearest(at offset: CGPoint) -> Int {
        min(max(Int(place(at: offset).rounded()), 0), max(items.count - 1, 0))
    }

    /// Brings one to the middle without telling.
    func choose(_ index: Int, animated: Bool) {
        guard items.indices.contains(index) else { return }
        mark(index)
        slide(to: index, animated: animated, then: nil)
    }

    private func slide(to index: Int, animated: Bool, then done: (() -> Void)?) {
        stopSliding()
        guard animated else {
            setting = true
            scroll.contentOffset = offset(for: index)
            setting = false
            turn()
            done?()
            return
        }
        // Photos' quarter of a second, eased in and out, a frame at a time.
        animating = true
        slideFrom = scroll.contentOffset
        slideTo = offset(for: index)
        slideStart = CACurrentMediaTime()
        slideDone = done
        let link = CADisplayLink(target: self, selector: #selector(slideStep(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func slideStep(_ link: CADisplayLink) {
        let t = min((CACurrentMediaTime() - slideStart) / 0.25, 1)
        let eased = t < 0.5 ? 2 * t * t : 1 - pow(2 - 2 * t, 2) / 2
        setting = true
        scroll.contentOffset = CGPoint(x: slideFrom.x + (slideTo.x - slideFrom.x) * eased, y: slideFrom.y + (slideTo.y - slideFrom.y) * eased)
        setting = false
        turn()
        guard t >= 1 else { return }
        let done = slideDone
        stopSliding()
        done?()
    }

    private func stopSliding() {
        link?.invalidate()
        link = nil
        slideDone = nil
        animating = false
    }

    private func mark(_ index: Int) {
        guard index != chosen else { return }
        items[chosen].setChosen(false)
        chosen = index
        items[index].setChosen(true)
    }

    private func move() {
        guard !isMoving else { return }
        isMoving = true
        onMove?()
    }

    /// A finger lifted without flicking it: if that stopped a flick between two, onto the nearer.
    private func settle() {
        guard isMoving, !animating, !scroll.isTracking, !scroll.isDecelerating else { return }
        let index = nearest(at: scroll.contentOffset)
        mark(index)
        slide(to: index, animated: scroll.contentOffset != offset(for: index)) { [weak self] in self?.rest() }
    }

    private func rest() {
        guard isMoving, !animating, !scroll.isTracking, !scroll.isDecelerating else { return }
        isMoving = false
        isDragged = false
        onRest?(chosen)
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        // A finger takes it from a tap's slide where it is.
        stopSliding()
        isDragged = true
        lastOffset = along(scrollView.contentOffset)
        lastTime = CACurrentMediaTime()
        move()
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { settle() }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        settle()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        turn()
        guard !setting, scrollView.isDragging || scrollView.isDecelerating else { return }
        let now = CACurrentMediaTime(), at = along(scrollView.contentOffset)
        let speed = abs(at - lastOffset) / max(now - lastTime, 1 / 240)
        lastOffset = at
        lastTime = now
        let place = place(at: scrollView.contentOffset)
        let next: Int
        switch feel {
        case .tools:
            next = nearest(at: scrollView.contentOffset)
        case .filters:
            // Photos' wheel: past halfway and a sixth of one more before the next is chosen.
            let from = CGFloat(chosen)
            next = abs(place - from) > 0.65 ? min(max(Int(place.rounded()), 0), items.count - 1) : chosen
        }
        if next != chosen {
            mark(next)
            onChoose?(next)
            felt = false
            if feel == .filters || speed > 1500 {
                selection.selectionChanged()
                felt = true
            }
        }
        // Slower, the chosen one's felt as it comes within 6 points of the middle.
        if !felt, abs(place - CGFloat(chosen)) * pitch < 6 {
            selection.selectionChanged()
            felt = true
        }
    }

    func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint, targetContentOffset: UnsafeMutablePointer<CGPoint>) {
        targetContentOffset.pointee = offset(for: nearest(at: targetContentOffset.pointee))
    }

    private func tapped(_ i: Int) {
        guard items.indices.contains(i) else { return }
        if i == chosen {
            guard !isMoving else { return }
            onTapChosen?(i)
        } else {
            move()
            mark(i)
            selection.selectionChanged()
            onChoose?(i)
            slide(to: i, animated: true) { [weak self] in self?.rest() }
        }
    }
}

/// A scroll view that says when a finger touches it and when one lifts from it, on it or on anything in it. A finger
/// that stops a flick and lifts without dragging leaves it at rest without a word to its delegate (Photos' own hear
/// of it privately): the lift is when to see where it is.
@MainActor
final class LiftScrollView: UIScrollView {
    var onTouch: (() -> Void)?
    var onLift: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        let watcher = TouchWatcher()
        watcher.onBegan = { [weak self] in self?.onTouch?() }
        // After the touch's own gestures (a tap) have done what they do.
        watcher.onEnded = { [weak self] in DispatchQueue.main.async { self?.onLift?() } }
        addGestureRecognizer(watcher)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

/// Watches fingers come and go without ever taking them from anything.
@MainActor
private final class TouchWatcher: UIGestureRecognizer, UIGestureRecognizerDelegate {
    var onBegan: (() -> Void)?
    var onEnded: (() -> Void)?
    private var down = 0

    init() {
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
        delegate = self
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        if down == 0 { onBegan?() }
        down += touches.count
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        lift(touches.count)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        lift(touches.count)
    }

    private func lift(_ count: Int) {
        down = max(down - count, 0)
        guard down == 0 else { return }
        onEnded?()
        state = .failed
    }

    override func reset() {
        down = 0
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }
}

/// An adjustment's tool, as Photos draws it (its `PUPhotoEditAdjustmentCell`): its symbol on a round face, a faint
/// ring, and its value an arc round it from the top: the clock's way in the raised colour for more, the other way in
/// the symbols' colour for less. The number takes the symbol's place once it's being changed, until another tool is
/// chosen. Switched off, all of it faint. Auto has no ring: its face is grey, dark once it's on.
@MainActor
final class ToolButton: UIControl, StripItem {
    static let size: CGFloat = 51

    let id: String
    private let range: ClosedRange<Double>
    private let isAuto: Bool
    private let style: HangarStyle
    private let face = CAShapeLayer()
    private let track = CAShapeLayer()
    private let progress = CAShapeLayer()
    private let symbol = UIImageView()
    private let number = UILabel()
    private var chosen = false
    private var value: Double = 0
    private var switchedOff = false
    /// Whether its number shows (from a finger on the ruler or its being switched on, until another tool's chosen).
    private(set) var showsNumber = false

    init(_ adjustment: HangarAdjustment, style: HangarStyle) {
        id = adjustment.id
        range = adjustment.range
        isAuto = adjustment.id == HangarAdjustment.auto.id
        self.style = style
        super.init(frame: .zero)
        track.lineWidth = 2
        track.fillColor = nil
        progress.lineWidth = 1.5
        progress.fillColor = nil
        layer.addSublayer(face)
        layer.addSublayer(track)
        layer.addSublayer(progress)
        symbol.image = HangarSymbols.image(adjustment.symbol)
        symbol.contentMode = .center
        symbol.preferredSymbolConfiguration = Self.symbolConfiguration(auto: isAuto, color: style.foreground)
        addSubview(symbol)
        number.font = style.numberFont
        number.textAlignment = .center
        number.alpha = 0
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
        face.path = UIBezierPath(ovalIn: bounds).cgPath
        // Photos' ring: a circle 2.5 smaller than the face, from the top, the clock's way.
        let radius = (bounds.width - 2.5) / 2
        let circle = UIBezierPath(arcCenter: CGPoint(x: bounds.midX, y: bounds.midY), radius: radius, startAngle: -.pi / 2,
                                  endAngle: 1.5 * .pi, clockwise: true).cgPath
        track.path = circle
        progress.path = circle
        symbol.frame = bounds
        number.frame = bounds
        update()
    }

    /// The value as Photos draws it: -1 to 0 below the default, 0 to 1 above, to the hundredth.
    private var shown: Double {
        let v = min(max(value, range.lowerBound), range.upperBound)
        let mapped = v >= 0 ? (range.upperBound > 0 ? v / range.upperBound : 0) : (range.lowerBound < 0 ? -v / range.lowerBound : 0)
        return (mapped * 100).rounded() / 100
    }

    private func update() {
        let traits = traitCollection
        // Switched off, it shows no value (Photos').
        let v = switchedOff && !isAuto ? 0 : shown
        let ring = (v > 0 ? style.raised : style.foreground).resolvedColor(with: traits)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Auto's on when it has a value and isn't switched off; off, it's grey, not faint.
        let autoOn = value > 0 && !switchedOff
        if isAuto {
            face.fillColor = (autoOn ? style.autoOnFill : style.autoFill).resolvedColor(with: traits).cgColor
            track.isHidden = true
            progress.isHidden = true
            symbol.tintColor = autoOn ? style.autoOnSymbol : style.foreground
            symbol.preferredSymbolConfiguration = Self.symbolConfiguration(auto: true, color: autoOn ? style.autoOnSymbol : style.foreground)
        } else {
            face.fillColor = style.toolFill.resolvedColor(with: traits).cgColor
            track.isHidden = false
            track.strokeColor = ring.withAlphaComponent(0.3).cgColor
            progress.strokeColor = ring.cgColor
            progress.isHidden = v == 0
            progress.lineCap = abs(v) >= 1 ? .butt : .round
            progress.strokeStart = v > 0 ? 0 : CGFloat(1 + v)
            progress.strokeEnd = v > 0 ? CGFloat(v) : 1
        }
        CATransaction.commit()
        number.textColor = ring
        number.text = Self.formatter.string(from: NSNumber(value: v * 100))
        let numbered = showsNumber && !isAuto
        number.alpha = numbered ? 1 : 0
        symbol.alpha = numbered ? 0 : 1
        alpha = switchedOff && !isAuto ? 0.3 : 1
        accessibilityValue = isAuto ? (autoOn ? "On" : "Off") : switchedOff ? "Off" : "\(number.text ?? "0")%"
        accessibilityTraits = chosen ? [.button, .selected] : .button
    }

    /// Photos' symbols are 19 points (its wand, Auto's, larger and bolder: about 25 across, solid).
    private static func symbolConfiguration(auto: Bool, color: UIColor) -> UIImage.SymbolConfiguration {
        auto ? UIImage.SymbolConfiguration(pointSize: 24, weight: .semibold).applying(UIImage.SymbolConfiguration(paletteColors: [color]))
            : UIImage.SymbolConfiguration(pointSize: 19, weight: .regular).applying(UIImage.SymbolConfiguration(hierarchicalColor: color))
    }

    private static let formatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.maximumFractionDigits = 0
        formatter.roundingMode = .halfEven
        return formatter
    }()
}

/// A filter's thumbnail: the picture with it, square in the row (the row's ends rounded), the dot over it when it's
/// the one applied. The frame round the one in the middle is the strip's (`FilterLoupe`), which stays put.
@MainActor
final class FilterThumbnail: UIControl, StripItem {
    /// Photos': 52 points square on a phone, 51 on an iPad, a point in from its slot all round.
    static let side: CGFloat = 52

    let id: String?
    let name: String
    private let picture = UIImageView()
    private let greyPicture = UIImageView()
    private let dot = UIView()
    private let style: HangarStyle
    var axis: Ruler.Axis = .across { didSet { setNeedsLayout() } }
    /// Which of the row's ends it is, if one: its outer corners are rounded.
    var end: (first: Bool, last: Bool) = (false, false) { didSet { setNeedsLayout() } }
    /// Whether it's the filter applied: the dot over it.
    var applied = false { didSet { dot.isHidden = !applied } }

    init(id: String?, name: String, style: HangarStyle) {
        self.id = id
        self.name = name
        self.style = style
        super.init(frame: .zero)
        picture.contentMode = .scaleAspectFill
        picture.clipsToBounds = true
        picture.layer.cornerCurve = .continuous
        picture.backgroundColor = style.toolFill
        addSubview(picture)
        greyPicture.contentMode = .scaleAspectFill
        greyPicture.clipsToBounds = true
        greyPicture.layer.cornerCurve = .continuous
        greyPicture.alpha = 0
        addSubview(greyPicture)
        dot.backgroundColor = style.foreground
        dot.isHidden = true
        addSubview(dot)
        isAccessibilityElement = true
        accessibilityLabel = name
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var image: UIImage? {
        get { picture.image }
        set {
            picture.image = newValue
            greyPicture.image = newValue.flatMap(Self.grey)
        }
    }

    /// The picture without its colours, for when it's turning out of sight.
    private static func grey(_ image: UIImage) -> UIImage? {
        guard let input = CIImage(image: image),
              let cg = HangarRenderer.context.createCGImage(input.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0]),
                                                           from: input.extent) else { return nil }
        return UIImage(cgImage: cg, scale: image.scale, orientation: image.imageOrientation)
    }

    func setChosen(_ chosen: Bool) {
        accessibilityTraits = chosen ? [.button, .selected] : .button
    }

    /// Narrowed as it turns away on the wheel, its dot too; grey as it turns out of sight.
    func turn(squeeze: CGFloat, grey: CGFloat) {
        transform = axis == .across ? CGAffineTransform(scaleX: squeeze, y: 1) : CGAffineTransform(scaleX: 1, y: squeeze)
        greyPicture.alpha = grey
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Photos' cells: 1 point in from each side of their slot.
        picture.frame = bounds.insetBy(dx: 1, dy: 1)
        greyPicture.frame = picture.frame
        var corners: CACornerMask = []
        if end.first { corners.formUnion(axis == .across ? [.layerMinXMinYCorner, .layerMinXMaxYCorner] : [.layerMinXMinYCorner, .layerMaxXMinYCorner]) }
        if end.last { corners.formUnion(axis == .across ? [.layerMaxXMinYCorner, .layerMaxXMaxYCorner] : [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]) }
        for view in [picture, greyPicture] {
            view.layer.cornerRadius = corners.isEmpty ? 0 : 5
            view.layer.maskedCorners = corners
        }
        let side: CGFloat = 5
        dot.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        dot.layer.cornerRadius = side / 2
        // Its middle 9 points beyond the cell's edge: above, or to the left along.
        dot.center = axis == .across ? CGPoint(x: bounds.midX, y: bounds.minY - 9) : CGPoint(x: bounds.minX - 9, y: bounds.midY)
    }
}

/// The frame round the filter in the middle, as Photos' (its wheel's loupe): white, 3 points, its corners 8, a
/// shadow, 3 points out from the thumbnail on each side; it stays in the middle as the thumbnails slide under it.
/// While the filter's ruler moves, the picture in it darkens under how much of the filter there is, in percent.
@MainActor
final class FilterLoupe: UIView {
    private let shade = UIView()
    private let amount = UILabel()
    private var showing = false

    /// Its size for a thumbnail's: 3 points out from it all round.
    var thumbnail: CGFloat {
        get { bounds.width - 6 }
        set { bounds.size = CGSize(width: newValue + 6, height: newValue + 6) }
    }

    init(style: HangarStyle, thumbnail: CGFloat) {
        super.init(frame: CGRect(x: 0, y: 0, width: thumbnail + 6, height: thumbnail + 6))
        isUserInteractionEnabled = false
        shade.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        shade.layer.cornerRadius = 5
        shade.layer.cornerCurve = .continuous
        shade.alpha = 0
        addSubview(shade)
        amount.font = style.numberFont
        amount.textColor = .white
        amount.textAlignment = .center
        shade.addSubview(amount)
        layer.borderColor = style.thumbnailFrame.cgColor
        layer.borderWidth = 3
        layer.cornerRadius = 8
        layer.cornerCurve = .continuous
        layer.shadowColor = UIColor.black.cgColor
        // Photos': dark right at the frame (about half), gone 5 points out.
        layer.shadowOpacity = 0.8
        layer.shadowRadius = 4
        layer.shadowOffset = .zero
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// How much of the filter while its ruler moves, nil once it's let go.
    func show(amount value: Double?) {
        if let value { amount.text = "\(Int((value * 100).rounded()))" }
        let shown = value != nil
        guard shown != showing else { return }
        showing = shown
        UIView.animate(withDuration: 0.2, delay: 0, options: [.beginFromCurrentState]) { self.shade.alpha = shown ? 1 : 0 }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        shade.frame = bounds.insetBy(dx: 3, dy: 3)
        amount.frame = shade.bounds
        // The shadow of the frame alone, not of the picture in it.
        let ring = UIBezierPath(roundedRect: bounds, cornerRadius: 8)
        ring.append(UIBezierPath(roundedRect: bounds.insetBy(dx: 3, dy: 3), cornerRadius: 5).reversing())
        layer.shadowPath = ring.cgPath
    }
}
