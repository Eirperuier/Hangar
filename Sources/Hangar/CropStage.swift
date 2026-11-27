import Flight
import HangarCore
import UIKit

/// Crop's picture, as Photos' (`PUCropToolController` and its overlay, handles and mask): the whole picture tilted,
/// straightened, turned and flipped, the part kept in a box, the rest under a veil (the background half over it, and
/// blurred while nothing moves). The box's corners and edges drag it smaller or larger over the picture; the picture
/// moves and pinches under it, held in by a rubber band; a second after a finger lifts, the box comes back to the
/// middle as large as fits, the picture with it, on Photos' spring (stiffness 300, critically damped).
///
/// Its coordinates: the picture's pixels from its middle (y down); the picture as shown (`display`), tilted and
/// straightened, then turned and flipped, about the same middle; the screen. The crop is kept as shown
/// (`displayCrop`) and the box is where it is on the screen: the picture is drawn so the one fills the other.
@MainActor
final class CropStage: UIView, UIGestureRecognizerDelegate {
    /// Live as anything changes the geometry (the crop with it).
    var onChange: ((HangarGeometry) -> Void)?
    /// Once a change is done: a step to keep.
    var onEnd: ((HangarGeometry) -> Void)?
    /// A finger down on the picture or a handle.
    var onTouch: (() -> Void)?
    /// A handle, the picture or a pinch starting to move (true) and let go (false): Photos hides its bars meanwhile.
    var onGesture: ((Bool) -> Void)?

    /// Where the box may be: Photos' crop canvas (above the tools, below the top bar, 10 in from the sides).
    var region: CGRect = .zero {
        didSet { if region != oldValue, !interacting, transition == nil { box = fitted(displayCrop); layoutPicture() } }
    }

    private(set) var geometry = HangarGeometry()
    /// Tools switched off: drawn at 0.
    private(set) var off: Set<String> = []
    private var pictureSize = CGSize(width: 1, height: 1)
    private(set) var displayCrop = CGRect(x: -0.5, y: -0.5, width: 1, height: 1)
    private(set) var box = CGRect.zero

    private let style: HangarStyle
    /// The picture and everything drawn over it, turned and flipped as one.
    private let content = UIView()
    private let picture = CALayer()
    private let veil: Veil
    private let grid = CAShapeLayer()
    private let lines = CAShapeLayer()
    private let handles = CAShapeLayer()
    private let lock = UIImageView()
    private var handleElements: [UIAccessibilityElement] = []

    private var interacting = false
    private var recompose: DispatchWorkItem?
    private var transition: Transition?
    private var clock: FlightClock?

    init(style: HangarStyle) {
        self.style = style
        veil = Veil(style: style)
        super.init(frame: .zero)
        clipsToBounds = true
        addSubview(content)
        picture.allowsEdgeAntialiasing = true
        picture.minificationFilter = .trilinear
        picture.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        content.layer.addSublayer(picture)
        addSubview(veil)
        grid.fillColor = nil
        grid.strokeColor = UIColor.white.cgColor
        grid.opacity = 0
        lines.fillColor = nil
        lines.lineWidth = 1
        handles.lineWidth = 0
        for shape in [grid, lines, handles] { layer.addSublayer(shape) }
        lock.image = UIImage(systemName: "lock.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 20, weight: .regular))
        lock.tintColor = .white
        lock.alpha = 0
        lock.isAccessibilityElement = true
        lock.accessibilityLabel = "Aspect Ratio Locked"
        addSubview(lock)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
        pan.maximumNumberOfTouches = 1
        pan.delegate = self
        addGestureRecognizer(pan)
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:)))
        pinch.delegate = self
        addGestureRecognizer(pinch)
        let down = TouchDown(target: self, action: #selector(touchedDown(_:)))
        down.delegate = self
        addGestureRecognizer(down)
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (stage: CropStage, _: UITraitCollection) in stage.layoutOverlay() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: What it shows

    /// The picture (its adjustments and filter on it, not its geometry), `size` its pixels, and the geometry to show.
    func load(_ image: CGImage?, size: CGSize, geometry: HangarGeometry, off: Set<String>) {
        stopTransition()
        pictureSize = size
        self.geometry = geometry
        self.off = off
        if let image { show(image) }
        displayCrop = Self.displayRect(geometry.without(off).cropRect(for: size), drawn.orientation)
        box = fitted(displayCrop)
        layoutPicture()
    }

    /// The picture it shows.
    var image: CGImage? {
        guard let contents = picture.contents else { return nil }
        return (contents as! CGImage)
    }

    /// The picture again, its adjustments changed.
    func show(_ image: CGImage) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        picture.contents = image
        CATransaction.commit()
    }

    /// The geometry as it's drawn now, the crop as it is (where it's going, if it's moving on its own).
    var current: HangarGeometry {
        var g = geometry
        let model = Self.displayRect(transition?.to.crop ?? displayCrop, geometry.orientation.inverted())
        g.crop = HangarGeometry.unit(model, pictureSize)
        return g
    }

    /// Whether the crop's shape is held (Photos' lock in the box's corner).
    var aspectLocked: Bool { geometry.aspect != nil }

    /// Straighten, Vertical and Horizontal as drawn while they move on a spring (a reset, a tool switched off).
    private var animatedValues: [Double]?

    private var drawn: HangarGeometry {
        var g = geometry.without(off)
        if let v = animatedValues {
            g.straighten = v[0]
            g.vertical = v[1]
            g.horizontal = v[2]
        }
        return g
    }

    /// A rect from one frame to another by a turn or flip (which keeps rects rects).
    static func displayRect(_ rect: CGRect, _ t: CGAffineTransform) -> CGRect {
        rect.applying(t).standardized
    }

    /// The picture's outline as shown.
    private var outline: [CGPoint] {
        let o = drawn.orientation
        return drawn.outline(for: pictureSize).map { $0.applying(o) }
    }

    /// The box for a crop: its shape as large as fits in the region, in its middle, on whole pixels.
    private func fitted(_ crop: CGRect) -> CGRect {
        guard crop.width > 0, crop.height > 0, region.width > 0 else { return region }
        return HangarEditor.fit(crop.size, in: region, scale: window?.screen.scale ?? 3)
    }

    /// Screen points per pixel of the picture.
    private var scale: CGFloat { box.width / max(displayCrop.width, 0.0001) }

    /// From the picture as shown to the screen.
    private var toScreen: HangarWarp {
        let s = Double(scale)
        return HangarWarp.translation(Double(box.midX), Double(box.midY)) * HangarWarp.scale(s)
            * HangarWarp.translation(-Double(displayCrop.midX), -Double(displayCrop.midY))
    }

    /// From the screen to the picture as shown.
    private func fromScreen(_ p: CGPoint) -> CGPoint {
        CGPoint(x: displayCrop.midX + (p.x - box.midX) / scale, y: displayCrop.midY + (p.y - box.midY) / scale)
    }

    // MARK: Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        content.frame = bounds
        layoutPicture()
    }

    /// The picture placed for the crop and the box, and everything over it.
    func layoutPicture() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        picture.bounds = CGRect(x: -pictureSize.width / 2, y: -pictureSize.height / 2, width: pictureSize.width, height: pictureSize.height)
        picture.position = .zero
        let warp = toScreen * HangarWarp(drawn.orientation) * drawn.warp(for: pictureSize)
        picture.transform = Self.transform(warp)
        CATransaction.commit()
        layoutOverlay()
    }

    /// A plane's projective map as Core Animation's transform (row vectors: x' = x m11 + y m21 + m41, over w).
    static func transform(_ w: HangarWarp) -> CATransform3D {
        let m = w.m.map { CGFloat($0) }
        var t = CATransform3DIdentity
        t.m11 = m[0]; t.m21 = m[1]; t.m41 = m[2]
        t.m12 = m[3]; t.m22 = m[4]; t.m42 = m[5]
        t.m14 = m[6]; t.m24 = m[7]; t.m44 = m[8]
        return t
    }

    /// The veil round the box, its lines and handles, the grid in it: Photos' (lines a point wide just outside the
    /// box; corners 3 thick and 20 long, edges' handles 25 long, outside it; the grid's thirds a pixel wide, white).
    private func layoutOverlay() {
        let b = box
        let w = bounds.width, h = bounds.height
        veil.frame = CGRect(x: 0, y: 0, width: w, height: h)
        veil.hole = b
        let ink = style.foreground.resolvedColor(with: traitCollection).cgColor
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        lines.strokeColor = ink
        lines.path = UIBezierPath(rect: b.insetBy(dx: -0.5, dy: -0.5)).cgPath
        handles.fillColor = ink
        let path = UIBezierPath()
        let (t, l): (CGFloat, CGFloat) = (3, 20)
        // Corners.
        for (x, y, sx, sy) in [(b.minX, b.minY, 1.0, 1.0), (b.maxX, b.minY, -1.0, 1.0), (b.maxX, b.maxY, -1.0, -1.0), (b.minX, b.maxY, 1.0, -1.0)] as [(CGFloat, CGFloat, CGFloat, CGFloat)] {
            let ox = x - sx * t, oy = y - sy * t
            path.append(UIBezierPath(rect: CGRect(x: min(ox, ox + sx * l), y: min(oy, oy + sy * t), width: l, height: t)))
            path.append(UIBezierPath(rect: CGRect(x: min(ox, ox + sx * t), y: min(oy, oy + sy * l), width: t, height: l)))
        }
        // The edges' middles.
        path.append(UIBezierPath(rect: CGRect(x: b.midX - 12.5, y: b.minY - t, width: 25, height: t)))
        path.append(UIBezierPath(rect: CGRect(x: b.midX - 12.5, y: b.maxY, width: 25, height: t)))
        path.append(UIBezierPath(rect: CGRect(x: b.minX - t, y: b.midY - 12.5, width: t, height: 25)))
        path.append(UIBezierPath(rect: CGRect(x: b.maxX, y: b.midY - 12.5, width: t, height: 25)))
        handles.path = path.cgPath
        let pixel = 1 / (window?.screen.scale ?? 3)
        grid.lineWidth = pixel
        let thirds = UIBezierPath()
        for i in 1...2 {
            let fx = ((b.minX + b.width * CGFloat(i) / 3) / pixel).rounded() * pixel + pixel / 2
            thirds.move(to: CGPoint(x: fx, y: b.minY))
            thirds.addLine(to: CGPoint(x: fx, y: b.maxY))
            let fy = ((b.minY + b.height * CGFloat(i) / 3) / pixel).rounded() * pixel + pixel / 2
            thirds.move(to: CGPoint(x: b.minX, y: fy))
            thirds.addLine(to: CGPoint(x: b.maxX, y: fy))
        }
        grid.path = thirds.cgPath
        CATransaction.commit()
        // Photos' lock: 20 in from the box's top right corner.
        let size = lock.intrinsicContentSize
        lock.frame = CGRect(x: b.maxX - 20 - size.width, y: b.minY + 20, width: size.width, height: size.height)
        layoutHandleElements()
    }

    // MARK: Showing and hiding

    /// While something moves: the grid, and the picture outside the box unblurred (Photos' masked content).
    private func showMoving(_ moving: Bool, animated: Bool = true) {
        let change = {
            self.grid.opacity = moving ? 1 : 0
            self.veil.blur.alpha = moving ? 0 : 1
        }
        if animated {
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.25)
            UIView.animate(withDuration: 0.25, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction], animations: change)
            CATransaction.commit()
        } else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            change()
            CATransaction.commit()
        }
    }

    /// The lock in the box's corner, shown while a shape is held (in an animation, fading).
    func showLock(_ shown: Bool) {
        lock.alpha = shown && lines.opacity > 0 ? 1 : 0
    }

    /// The handles, lines, grid and veil, all at once (gone while the picture turns or flips, and while it flies).
    func showOverlay(_ shown: Bool, animated: Bool) {
        let change = {
            self.veil.alpha = shown ? 1 : 0
            self.lock.alpha = shown && self.aspectLocked ? 1 : 0
        }
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        CATransaction.setAnimationDuration(0.25)
        for shape in [lines, handles] { shape.opacity = shown ? 1 : 0 }
        if !shown { grid.opacity = 0 }
        CATransaction.commit()
        if animated {
            UIView.animate(withDuration: 0.25, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction], animations: change)
        } else {
            change()
        }
    }

    /// Photos waits a second after a finger lifts, then brings the box back to the middle, the grid and the
    /// picture outside it going with it.
    private func scheduleRecompose() {
        recompose?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.interacting else { return }
            self.flushEnd()
            self.animate(to: self.target(crop: self.transition?.to.crop ?? self.displayCrop))
        }
        recompose = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    private func touch() {
        recompose?.cancel()
        stopTransition()
        showMoving(true)
        onTouch?()
    }

    // MARK: Fingers

    private enum Drag {
        case handle(Handle, start: CGRect)
        case picture(start: CGRect)
    }

    private struct Handle: OptionSet {
        let rawValue: Int
        static let left = Handle(rawValue: 1), right = Handle(rawValue: 2), top = Handle(rawValue: 4), bottom = Handle(rawValue: 8)
    }

    private var drag: Drag?
    /// Where the finger came down: a drag's handle is found there and it's measured from there, not from where the
    /// pan was first known (a little way on).
    private var downAt: CGPoint?
    private var pinchStart: (crop: CGRect, location: CGPoint, scale: CGFloat)?

    @objc private func touchedDown(_ down: TouchDown) {
        if down.state == .began {
            downAt = down.location(in: self)
            interacting = true
            touch()
        } else if down.state == .ended || down.state == .cancelled || down.state == .failed {
            if drag == nil, pinchStart == nil { finish() }
        }
    }

    /// Photos' handles: the corners 44 square, their middles 7 in from the box's corners; the edges 44 thick
    /// between them, on the edge.
    private func handle(at p: CGPoint) -> Handle? {
        let b = box
        let corners: [(CGPoint, Handle)] = [
            (CGPoint(x: b.minX + 7, y: b.minY + 7), [.left, .top]), (CGPoint(x: b.maxX - 7, y: b.minY + 7), [.right, .top]),
            (CGPoint(x: b.maxX - 7, y: b.maxY - 7), [.right, .bottom]), (CGPoint(x: b.minX + 7, y: b.maxY - 7), [.left, .bottom]),
        ]
        for (c, h) in corners where abs(p.x - c.x) <= 22 && abs(p.y - c.y) <= 22 { return h }
        if p.x > b.minX + 17, p.x < b.maxX - 17 {
            if abs(p.y - b.minY) <= 22 { return .top }
            if abs(p.y - b.maxY) <= 22 { return .bottom }
        }
        if p.y > b.minY + 17, p.y < b.maxY - 17 {
            if abs(p.x - b.minX) <= 22 { return .left }
            if abs(p.x - b.maxX) <= 22 { return .right }
        }
        return nil
    }

    @objc private func panned(_ pan: UIPanGestureRecognizer) {
        if pan.state == .began {
            let start = downAt ?? pan.location(in: self)
            downAt = start
            if let h = handle(at: start) { drag = .handle(h, start: box) } else { drag = .picture(start: displayCrop) }
            beganGesture()
        }
        // The finger's way from where it came down, from the first that's known of it (a drag is known a little way
        // on) to where it's let go.
        if pan.state == .began || pan.state == .changed || pan.state == .ended {
            let now = pan.location(in: self), from = downAt ?? now
            let t = CGPoint(x: now.x - from.x, y: now.y - from.y)
            switch drag {
            case .handle(let h, let start)?: resize(h, from: start, by: t)
            case .picture(let start)?: if pinchStart == nil { move(from: start, by: t) }
            case nil: break
            }
        }
        switch pan.state {
        case .began, .changed: break
        default:
            if case .picture? = drag, pinchStart == nil { settleInside() }
            drag = nil
            if pinchStart == nil { finish() }
        }
    }

    @objc private func pinched(_ pinch: UIPinchGestureRecognizer) {
        switch pinch.state {
        case .began:
            if case .handle? = drag { return }
            drag = nil
            pinchStart = (displayCrop, pinch.location(in: self), scale)
            beganGesture()
        case .changed:
            guard let start = pinchStart else { return }
            zoom(from: start, by: pinch.scale, to: pinch.location(in: self))
        default:
            guard pinchStart != nil else { return }
            pinchStart = nil
            settleInside()
            finish()
        }
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        g.view == self && other.view == self
    }

    /// A gesture ended: kept, the grid gone and the picture round the box blurred at once, the box brought back a
    /// second later.
    private func finish() {
        guard interacting else { return }
        interacting = false
        if gesturing {
            gesturing = false
            onGesture?(false)
        }
        showMoving(false)
        // Photos keeps it as the box comes back, a second later (RESET and Done change then), or as Crop is left.
        endPending = true
        scheduleRecompose()
    }

    /// A finger's change not yet reported.
    private var endPending = false

    private func ended() {
        endPending = false
        onEnd?(current)
    }

    private func flushEnd() {
        if endPending { ended() }
    }

    private var gesturing = false

    private func beganGesture() {
        guard !gesturing else { return }
        gesturing = true
        onGesture?(true)
    }

    /// A handle dragged: the box's edges with it, the picture still; no smaller than Photos' 64 points, never off
    /// the picture or out of the region; a held shape kept.
    private func resize(_ h: Handle, from start: CGRect, by t: CGPoint) {
        func candidate(_ k: CGFloat, _ kx: CGFloat? = nil, _ ky: CGFloat? = nil) -> CGRect {
            var minX = start.minX, maxX = start.maxX, minY = start.minY, maxY = start.maxY
            let dx = t.x * (kx ?? k), dy = t.y * (ky ?? k)
            if h.contains(.left) { minX = min(minX + dx, maxX - Self.smallest) }
            if h.contains(.right) { maxX = max(maxX + dx, minX + Self.smallest) }
            if h.contains(.top) { minY = min(minY + dy, maxY - Self.smallest) }
            if h.contains(.bottom) { maxY = max(maxY + dy, minY + Self.smallest) }
            var r = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
            if let ratio = displayRatio { r = held(r, ratio: ratio, handle: h, start: start) }
            return r
        }
        let quad = outline.map(toScreen.apply)
        func fits(_ r: CGRect) -> Bool {
            HangarFit.contains(quad, r, slack: 0.5) && region.insetBy(dx: -0.5, dy: -0.5).contains(r)
        }
        var best = candidate(1)
        if !fits(best) {
            // As far along the finger as it can go, then each way on its own as far again.
            var lo: CGFloat = 0, hi: CGFloat = 1
            for _ in 0..<20 { let mid = (lo + hi) / 2; if fits(candidate(mid)) { lo = mid } else { hi = mid } }
            var (kx, ky) = (lo, lo)
            if displayRatio == nil {
                var a = lo, b: CGFloat = 1
                for _ in 0..<20 { let mid = (a + b) / 2; if fits(candidate(0, mid, ky)) { a = mid } else { b = mid } }
                kx = a
                a = lo; b = 1
                for _ in 0..<20 { let mid = (a + b) / 2; if fits(candidate(0, kx, mid)) { a = mid } else { b = mid } }
                ky = a
            }
            best = candidate(0, kx, ky)
            if !fits(best) { best = fits(start) ? start : best }
        }
        // The picture stays where it is: the crop is what's now in the box.
        let topLeft = fromScreen(best.origin), bottomRight = fromScreen(CGPoint(x: best.maxX, y: best.maxY))
        displayCrop = CGRect(x: topLeft.x, y: topLeft.y, width: bottomRight.x - topLeft.x, height: bottomRight.y - topLeft.y)
        box = best
        layoutPicture()
        onChange?(current)
    }

    /// Photos' smallest box: 64 points each way.
    private static let smallest: CGFloat = 64

    /// The shape held, as it's shown (its own turned with the picture).
    private var displayRatio: Double? {
        guard let aspect = geometry.aspect else { return nil }
        return geometry.isSideways ? aspect.turned.value : aspect.value
    }

    /// A box dragged by a handle with its shape held: from the corner opposite the handle (an edge's handle keeps the
    /// box's middle across it).
    private func held(_ r: CGRect, ratio: Double, handle h: Handle, start: CGRect) -> CGRect {
        let corner = h.contains(.left) || h.contains(.right)
        let upright = h.contains(.top) || h.contains(.bottom)
        var w = r.width, ht = r.height
        if corner && upright {
            if w / ht > ratio { ht = w / ratio } else { w = ht * ratio }
        } else if corner {
            ht = w / ratio
        } else {
            w = ht * ratio
        }
        w = max(w, Self.smallest); ht = max(ht, Self.smallest)
        let x = h.contains(.left) ? start.maxX - w : h.contains(.right) ? start.minX : start.midX - w / 2
        let y = h.contains(.top) ? start.maxY - ht : h.contains(.bottom) ? start.minY : start.midY - ht / 2
        return CGRect(x: x, y: y, width: w, height: ht)
    }

    /// The picture dragged under the box: held in by a rubber band past its edges.
    private func move(from start: CGRect, by t: CGPoint) {
        let s = scale
        let candidate = start.offsetBy(dx: -t.x / s, dy: -t.y / s)
        let inside = HangarFit.moved(candidate, into: outline)
        displayCrop = rubber(candidate, inside)
        layoutPicture()
        onChange?(current)
    }

    /// The picture pinched about the fingers, and moved with them; no further out than the picture fills the box
    /// (a rubber band past it), no further in than a fifteenth of its shorter side.
    private func zoom(from start: (crop: CGRect, location: CGPoint, scale: CGFloat), by k: CGFloat, to location: CGPoint) {
        let least = min(pictureSize.width, pictureSize.height) / 15
        let k = min(k, start.crop.width / max(least, 1), start.crop.height / max(least, 1))
        let s0 = start.scale
        // The point under the fingers when they came down, as shown.
        let anchor = CGPoint(x: start.crop.midX + (start.location.x - box.midX) / s0, y: start.crop.midY + (start.location.y - box.midY) / s0)
        var r = CGRect(x: anchor.x + (start.crop.minX - anchor.x) / k, y: anchor.y + (start.crop.minY - anchor.y) / k,
                       width: start.crop.width / k, height: start.crop.height / k)
        r = r.offsetBy(dx: -(location.x - start.location.x) / (s0 * k), dy: -(location.y - start.location.y) / (s0 * k))
        let inside = HangarFit.moved(r, into: outline)
        displayCrop = rubber(r, inside)
        layoutPicture()
        onChange?(current)
    }

    /// `wanted` drawn toward `allowed` by a rubber band (UIScrollView's), measured on the screen.
    private func rubber(_ wanted: CGRect, _ allowed: CGRect) -> CGRect {
        let s = scale
        func band(_ over: CGFloat, _ length: CGFloat) -> CGFloat {
            let x = over * s
            let banded = (1 - 1 / (abs(x) * 0.55 / max(length, 1) + 1)) * length
            return (x < 0 ? -banded : banded) / s
        }
        let minX = allowed.minX + band(wanted.minX - allowed.minX, box.width)
        let maxX = allowed.maxX + band(wanted.maxX - allowed.maxX, box.width)
        let minY = allowed.minY + band(wanted.minY - allowed.minY, box.height)
        let maxY = allowed.maxY + band(wanted.maxY - allowed.maxY, box.height)
        // The shape kept (the box doesn't change while the picture moves).
        let w = maxX - minX, h = w * displayCrop.height / max(displayCrop.width, 0.0001)
        return CGRect(x: minX, y: (minY + maxY) / 2 - h / 2, width: w, height: h)
    }

    /// Let go off the picture or pinched out past it: it comes back in, the box where it is.
    private func settleInside() {
        let inside = HangarFit.moved(displayCrop, into: outline)
        guard inside != displayCrop else { return }
        animate(to: Target(crop: inside, box: box, values: values(of: geometry)))
    }

    // MARK: Straighten, Vertical, Horizontal

    private var toolStart: (crop: CGRect, middle: CGPoint)?

    /// A tool's ruler touched: the grid and the picture round the box show while it moves.
    func beginTool() {
        interacting = true
        touch()
        // The point of the picture in the box's middle stays there as the picture turns or tilts.
        let toDisplay = HangarWarp(drawn.orientation) * drawn.warp(for: pictureSize)
        toolStart = (displayCrop, toDisplay.inverted.apply(CGPoint(x: displayCrop.midX, y: displayCrop.midY)))
    }

    /// A tool moved: the picture with it under the box, the crop as large as it was where it fits.
    func setTool(_ id: String, value: Double, off newOff: Set<String>) {
        if toolStart == nil {
            let toDisplay = HangarWarp(drawn.orientation) * drawn.warp(for: pictureSize)
            toolStart = (displayCrop, toDisplay.inverted.apply(CGPoint(x: displayCrop.midX, y: displayCrop.midY)))
        }
        guard let start = toolStart else { return }
        geometry.set(id, to: value)
        off = newOff
        displayCrop = refit(start)
        layoutPicture()
        onChange?(current)
    }

    func endTool() {
        toolStart = nil
        finish()
    }

    /// A tool switched off or on: the picture as it is without it (or with it again), the box where it is.
    func setOff(_ newOff: Set<String>) {
        let toDisplay = HangarWarp(drawn.orientation) * drawn.warp(for: pictureSize)
        let start = (displayCrop, toDisplay.inverted.apply(CGPoint(x: displayCrop.midX, y: displayCrop.midY)))
        let from = Target(crop: displayCrop, box: box, values: values(of: drawn))
        off = newOff
        let crop = refit(start)
        transitionFrom(from, to: Target(crop: crop, box: fitted(crop), values: values(of: drawn)))
        ended()
    }

    /// The crop at `start`'s size about where the same point of the picture now is, smaller if it must be to fit.
    private func refit(_ start: (crop: CGRect, middle: CGPoint)) -> CGRect {
        let toDisplay = HangarWarp(drawn.orientation) * drawn.warp(for: pictureSize)
        let middle = toDisplay.apply(start.middle)
        let r = CGRect(x: middle.x - start.crop.width / 2, y: middle.y - start.crop.height / 2, width: start.crop.width, height: start.crop.height)
        let scaled = HangarFit.scaled(r, into: outline)
        return HangarFit.moved(scaled, into: outline)
    }

    // MARK: Flip, Rotate, Aspect, Reset

    /// Photos' Rotate: a quarter to the left, the box with it, coming to rest as large as fits.
    func rotate() {
        recompose?.cancel()
        stopTransition()
        var next = geometry
        // A quarter left as it's shown: flipped, that's a quarter right of the picture before its flip.
        next.turns = (geometry.turns + (geometry.flipped ? 3 : 1)) % 4
        let turn = CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: 0)
        let crop = Self.displayRect(displayCrop, turn)
        let newBox = fitted(crop)
        // Turned a quarter left about the box's middle, scaled onto the new box, its middle moving onto the new
        // box's: each frame worked out (a quarter turn and a scale together aren't animated as a turn otherwise).
        let k = newBox.height / box.width
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let pivot = CGPoint(x: box.midX - center.x, y: box.midY - center.y)
        let to = CGPoint(x: newBox.midX - center.x, y: newBox.midY - center.y)
        let turning: (Double) -> CATransform3D = { p in
            let angle = -CGFloat.pi / 2 * CGFloat(p), scale = 1 + (k - 1) * CGFloat(p)
            let at = CGPoint(x: pivot.x + (to.x - pivot.x) * CGFloat(p), y: pivot.y + (to.y - pivot.y) * CGFloat(p))
            let t = CGAffineTransform(translationX: -pivot.x, y: -pivot.y)
                .concatenating(CGAffineTransform(rotationAngle: angle))
                .concatenating(CGAffineTransform(scaleX: scale, y: scale))
                .concatenating(CGAffineTransform(translationX: at.x, y: at.y))
            return CATransform3DMakeAffineTransform(t)
        }
        geometryChange(.turn(turning)) {
            self.geometry = next
            self.displayCrop = crop
            self.box = newBox
        }
    }

    /// Photos' Flip: mirrored left to right, turning over about the box's upright middle.
    func flip() {
        recompose?.cancel()
        stopTransition()
        var next = geometry
        next.flipped.toggle()
        // Flipping the picture as shown mirrors the crop about the picture's middle.
        let crop = Self.displayRect(displayCrop, CGAffineTransform(scaleX: -1, y: 1))
        geometryChange(.flip) {
            self.geometry = next
            self.displayCrop = crop
        }
    }

    private enum Change {
        /// The picture's transform as it goes, 0 to 1.
        case turn((Double) -> CATransform3D)
        case flip
    }

    /// Turning and flipping: the picture alone, clipped to the box, the rest gone meanwhile (Photos hides its
    /// content views); then everything back over it.
    private func geometryChange(_ change: Change, apply: @escaping () -> Void) {
        showOverlay(false, animated: false)
        let mask = UIView(frame: box)
        mask.backgroundColor = .black
        content.mask = mask
        let done = {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.content.layer.removeAllAnimations()
            self.content.transform3D = CATransform3DIdentity
            self.content.mask = nil
            apply()
            self.layoutPicture()
            CATransaction.commit()
            self.showOverlay(true, animated: true)
            self.ended()
        }
        switch change {
        case .turn(let transform):
            // Photos' default timing: a critically damped spring, about 0.4 of a second.
            CATransaction.begin()
            CATransaction.setCompletionBlock(done)
            content.layer.add(Self.springFrames(0.4, transform), forKey: "turn")
            CATransaction.commit()
        case .flip:
            CATransaction.begin()
            CATransaction.setCompletionBlock(done)
            content.layer.add(Self.flipFrames(about: box.midX - bounds.midX), forKey: "flip")
            CATransaction.commit()
        }
    }

    /// A half turn over about an upright `offset` from the middle, seen in perspective, frame by frame on a
    /// critically damped spring (Core Animation can't tell a half turn from a mirror by their matrices).
    private static func flipFrames(about offset: CGFloat) -> CAKeyframeAnimation {
        springFrames(0.45) { progress in
            var t = CATransform3DIdentity
            t.m34 = -1 / 1000
            t = CATransform3DTranslate(t, offset, 0, 0)
            t = CATransform3DRotate(t, CGFloat(progress) * .pi, 0, 1, 0)
            return CATransform3DTranslate(t, -offset, 0, 0)
        }
    }

    /// A transform going 0 to 1 on a critically damped spring of `response` seconds, frame by frame, held at the end.
    private static func springFrames(_ response: Double, _ transform: (Double) -> CATransform3D) -> CAKeyframeAnimation {
        let duration = response * 4 / 3, frames = Int(duration * 120)
        let omega = 2 * Double.pi / response
        var values: [NSValue] = []
        for i in 0...frames {
            let time = duration * Double(i) / Double(frames)
            let progress = i == frames ? 1 : 1 - (1 + omega * time) * exp(-omega * time)
            values.append(NSValue(caTransform3D: transform(progress)))
        }
        let animation = CAKeyframeAnimation(keyPath: "transform")
        animation.values = values
        animation.duration = duration
        animation.calculationMode = .linear
        animation.fillMode = .forwards
        animation.isRemovedOnCompletion = false
        return animation
    }

    /// A shape held (nil: any), as it's taken in the picture's own frame: the crop the largest of it in the crop
    /// there was, about its middle.
    func setAspect(_ aspect: HangarRatio?) {
        recompose?.cancel()
        stopTransition()
        geometry.aspect = aspect
        guard let ratio = displayRatio else {
            ended()
            layoutOverlay()
            return
        }
        let shaped = HangarGeometry.shapedRect(displayCrop, ratio)
        let crop = HangarFit.moved(shaped, into: outline)
        transitionFrom(Target(crop: displayCrop, box: box, values: values(of: drawn)),
                       to: Target(crop: crop, box: fitted(crop), values: values(of: drawn)))
        ended()
    }

    /// Photos' Reset: straight, untilted, the whole picture, any shape; still turned and flipped as it was; `off` the
    /// tools switched off now (none).
    func reset(off newOff: Set<String>) {
        recompose?.cancel()
        stopTransition()
        let from = Target(crop: displayCrop, box: box, values: values(of: drawn))
        off = newOff
        geometry.straighten = 0
        geometry.vertical = 0
        geometry.horizontal = 0
        geometry.crop = nil
        geometry.aspect = nil
        let crop = Self.displayRect(drawn.cropRect(for: pictureSize), drawn.orientation)
        transitionFrom(from, to: Target(crop: crop, box: fitted(crop), values: values(of: drawn)))
        ended()
    }

    // MARK: Moving on a spring

    /// Where things are going: the crop as shown, the box, and Straighten, Vertical and Horizontal (as drawn).
    struct Target {
        var crop: CGRect
        var box: CGRect
        var values: [Double]
    }

    private struct Transition {
        var from: Target
        var to: Target
        var spring: SpringVector
        var done: (() -> Void)?
    }

    private func values(of g: HangarGeometry) -> [Double] { [g.straighten, g.vertical, g.horizontal] }

    /// The box for a crop, the crop and tools as they are.
    private func target(crop: CGRect) -> Target {
        Target(crop: crop, box: fitted(crop), values: values(of: drawn))
    }

    /// From where it is to `target`, on Photos' spring.
    func animate(to target: Target, done: (() -> Void)? = nil) {
        transitionFrom(Target(crop: displayCrop, box: box, values: values(of: drawn)), to: target, done: done)
    }

    /// Photos' spring: stiffness 300, critically damped.
    static let spring = FlightSpring(response: 2 * .pi / sqrt(300), dampingRatio: 1)

    private func transitionFrom(_ from: Target, to: Target, done: (() -> Void)? = nil) {
        stopTransition()
        transition = Transition(from: from, to: to, spring: SpringVector(values: [0], tolerances: [0.0005], spring: Self.spring), done: done)
        transition?.spring.retarget([1])
        if clock == nil {
            clock = FlightClock { [weak self] dt in self?.tick(dt) }
        }
        clock?.start()
        tick(0)
    }

    private func tick(_ dt: Double) {
        guard var t = transition else { clock?.stop(); return }
        #if DEBUG
        let settled = t.spring.step(dt * HangarEditor.debugSpeed)
        #else
        let settled = t.spring.step(dt)
        #endif
        let p = settled ? 1 : t.spring.values[0]
        transition = t
        func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * CGFloat(p) }
        func mix(_ a: CGRect, _ b: CGRect) -> CGRect {
            CGRect(x: mix(a.minX, b.minX), y: mix(a.minY, b.minY), width: mix(a.width, b.width), height: mix(a.height, b.height))
        }
        displayCrop = mix(t.from.crop, t.to.crop)
        box = mix(t.from.box, t.to.box)
        animatedValues = settled || t.from.values == t.to.values ? nil : zip(t.from.values, t.to.values).map { $0 + ($1 - $0) * p }
        layoutPicture()
        if settled {
            transition = nil
            clock?.stop()
            t.done?()
        }
    }

    private func stopTransition() {
        guard let t = transition else { return }
        transition = nil
        clock?.stop()
        // Wherever it was going, it's there.
        displayCrop = t.to.crop
        box = t.to.box
        animatedValues = nil
        layoutPicture()
        t.done?()
    }

    /// The transition the editor's flying in and out follow: from the canvas's frame (the crop filling it) to
    /// the box, and back.
    func fly(from frame: CGRect, done: (() -> Void)? = nil) {
        let target = Target(crop: displayCrop, box: fitted(displayCrop), values: values(of: drawn))
        transitionFrom(Target(crop: displayCrop, box: frame, values: target.values), to: target, done: done)
    }

    func fly(to frame: CGRect, done: (() -> Void)? = nil) {
        recompose?.cancel()
        transitionFrom(Target(crop: displayCrop, box: box, values: values(of: drawn)),
                       to: Target(crop: displayCrop, box: frame, values: values(of: drawn)), done: done)
    }

    /// Stops a recompose waiting (the editor leaving Crop).
    func cancelPending() {
        recompose?.cancel()
        flushEnd()
        stopTransition()
    }

    // MARK: VoiceOver

    private func layoutHandleElements() {
        let names = ["Top left crop handle", "Top crop handle", "Top right crop handle", "Left crop handle", "Right crop handle",
                     "Bottom left crop handle", "Bottom crop handle", "Bottom right crop handle"]
        if handleElements.isEmpty {
            handleElements = names.map { name in
                let e = UIAccessibilityElement(accessibilityContainer: self)
                e.accessibilityLabel = name
                return e
            }
        }
        let b = box
        let frames = [
            CGRect(x: b.minX - 15, y: b.minY - 15, width: 44, height: 44),
            CGRect(x: b.minX + 17, y: b.minY - 22, width: max(0, b.width - 34), height: 44),
            CGRect(x: b.maxX - 29, y: b.minY - 15, width: 44, height: 44),
            CGRect(x: b.minX - 22, y: b.minY + 17, width: 44, height: max(0, b.height - 34)),
            CGRect(x: b.maxX - 22, y: b.minY + 17, width: 44, height: max(0, b.height - 34)),
            CGRect(x: b.minX - 15, y: b.maxY - 29, width: 44, height: 44),
            CGRect(x: b.minX + 17, y: b.maxY - 22, width: max(0, b.width - 34), height: 44),
            CGRect(x: b.maxX - 29, y: b.maxY - 29, width: 44, height: 44),
        ]
        for (e, f) in zip(handleElements, frames) { e.accessibilityFrameInContainerSpace = f }
        let crop = UIAccessibilityElement(accessibilityContainer: self)
        crop.accessibilityLabel = "Crop area"
        crop.accessibilityFrameInContainerSpace = b
        accessibilityElements = handleElements + [crop, lock]
    }
}

/// The veil over the picture outside the box (Photos' `PUCropMaskView`): the background half over it, the picture
/// blurred (thin material) but while something moves. One blur over everything with the box cut out of it, as
/// Photos' is, so the picture in the box blurs out over its edges where there's no picture outside it.
@MainActor
private final class Veil: UIView {
    let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterial))
    private let dim = UIView()
    private let dimMask = Hole()
    private let blurMask = Hole()

    /// What it leaves clear: the box.
    var hole: CGRect = .zero { didSet { if hole != oldValue { layoutMasks() } } }

    init(style: HangarStyle) {
        super.init(frame: .zero)
        dim.backgroundColor = style.background.withAlphaComponent(0.5)
        for view in [dim, blur] {
            view.frame = bounds
            view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            addSubview(view)
        }
        // A blur's mask goes on the effect view itself, never a view above it.
        dim.mask = dimMask
        blur.mask = blurMask
        isUserInteractionEnabled = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        layoutMasks()
    }

    private func layoutMasks() {
        for mask in [dimMask, blurMask] { mask.set(bounds, cut: hole) }
    }
}

/// A mask: all of it but a rectangle.
@MainActor
private final class Hole: UIView {
    override class var layerClass: AnyClass { CAShapeLayer.self }

    func set(_ whole: CGRect, cut: CGRect) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        frame = whole
        let shape = layer as! CAShapeLayer
        let path = UIBezierPath(rect: CGRect(origin: .zero, size: whole.size))
        path.append(UIBezierPath(rect: cut))
        shape.fillRule = .evenOdd
        shape.path = path.cgPath
        CATransaction.commit()
    }
}

/// Recognizes a finger coming down at once, and its lifting, beside the others.
@MainActor
private final class TouchDown: UIGestureRecognizer {
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        if state == .possible { state = .began }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        if numberOfTouches(after: touches, event) == 0 { state = .ended }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        state = .cancelled
    }

    private func numberOfTouches(after ended: Set<UITouch>, _ event: UIEvent) -> Int {
        (event.touches(for: self) ?? []).filter { !ended.contains($0) && $0.phase != .ended && $0.phase != .cancelled }.count
    }
}

extension HangarGeometry {
    /// The largest of `ratio`'s shape in `rect`, about its middle.
    static func shapedRect(_ rect: CGRect, _ ratio: Double) -> CGRect {
        var size = rect.size
        if size.width / size.height > ratio { size.width = size.height * ratio } else { size.height = size.width / ratio }
        return CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height)
    }
}
