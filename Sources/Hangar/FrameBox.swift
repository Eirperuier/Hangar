import UIKit

/// A frame over the picture, its corners and sides dragged, the whole of it moved by a finger inside it, as Crop's
/// is: round the picture and past it (Extend: what's to be drawn), or over a part of it (Close-Up: what's to be
/// brought close). Its rect is in the picture's units (0 to 1 each way from its top left); it's held to a shape if
/// it's given one.
@MainActor
final class FrameBox: UIView {
    enum Kind {
        /// Round the picture: it holds the picture whole, and stays inside `limit`.
        case around
        /// Over a part of it: inside the picture, no smaller than `smallest` points a side.
        case inside
    }

    var kind = Kind.inside { didSet { setNeedsLayout() } }
    /// Where the picture is, in its coordinates.
    var picture = CGRect.zero { didSet { setNeedsLayout() } }
    /// The frame, in the picture's units.
    var rect = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5) { didSet { setNeedsLayout() } }
    /// Its shape, its width over its height (as it's shown, the picture's own shape being its pixels'); nil for any.
    var ratio: CGFloat?
    /// Where a frame round the picture can go, in its coordinates.
    var limit = CGRect.zero
    var smallest: CGFloat = 60
    /// While it's dragged, and once it's let go.
    var onChange: ((CGRect) -> Void)?
    var onEnd: ((CGRect) -> Void)?

    private let shade = CAShapeLayer()
    private let border = CAShapeLayer()
    private let corners = CAShapeLayer()
    private let grid = CAShapeLayer()
    /// Which sides a drag moves (-1 the left or top, 1 the right or bottom, 0 neither; both 0 moves it whole), and
    /// where the frame was as it began.
    private var grip = (x: 0, y: 0)
    private var start = CGRect.zero
    private var downAt: CGPoint?
    /// Where the frame and the picture are drawn while they glide to where they're set, as the picture under it
    /// does (`glide`).
    private var drawn: (frame: CGRect, picture: CGRect)?
    private var glideFrom = (frame: CGRect.zero, picture: CGRect.zero)
    private var glideStart: CFTimeInterval = 0
    private var link: CADisplayLink?

    override init(frame: CGRect) {
        super.init(frame: frame)
        shade.fillRule = .evenOdd
        border.fillColor = nil
        border.strokeColor = UIColor.white.cgColor
        border.lineWidth = 1.5
        corners.fillColor = nil
        corners.strokeColor = UIColor.white.cgColor
        corners.lineWidth = 3
        corners.lineCap = .square
        grid.fillColor = nil
        grid.strokeColor = UIColor.white.withAlphaComponent(0.4).cgColor
        grid.lineWidth = 0.5
        for layer in [shade, grid, border, corners] { self.layer.addSublayer(layer) }
        for layer in [border, corners] {
            layer.shadowColor = UIColor.black.cgColor
            layer.shadowOpacity = 0.35
            layer.shadowRadius = 2
            layer.shadowOffset = .zero
        }
        addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(dragged(_:))))
        isAccessibilityElement = true
        accessibilityTraits = .adjustable
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The frame in its coordinates.
    var shown: CGRect { screen(rect) }

    /// The frame and the picture as they're drawn now (on their way, while they glide).
    var onScreen: (frame: CGRect, picture: CGRect) { drawn ?? (shown, picture) }

    private func screen(_ r: CGRect, in picture: CGRect? = nil) -> CGRect {
        let picture = picture ?? self.picture
        return CGRect(x: picture.minX + r.minX * picture.width, y: picture.minY + r.minY * picture.height,
                      width: r.width * picture.width, height: r.height * picture.height)
    }

    /// From where they were drawn (`from`) to where they're set now, as UIKit's animations ease in and out over
    /// `duration`: with the picture under it, moved and sized at once.
    func glide(from: (frame: CGRect, picture: CGRect), duration: Double = 0.3) {
        guard from.frame != shown || from.picture != picture else { return }
        glideFrom = from
        drawn = from
        glideStart = CACurrentMediaTime()
        if link == nil {
            let link = CADisplayLink(target: self, selector: #selector(gliding))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
            link.add(to: .main, forMode: .common)
            self.link = link
        }
        glideDuration = duration
        setNeedsLayout()
    }

    private var glideDuration = 0.3

    @objc private func gliding() {
        var p = (CACurrentMediaTime() - glideStart) / glideDuration
        #if DEBUG
        p *= HangarEditor.debugSpeed
        #endif
        guard p < 1 else {
            drawn = nil
            link?.invalidate()
            link = nil
            setNeedsLayout()
            return
        }
        // Core Animation's ease in and out (0.42, 0, 0.58, 1), near enough.
        let e = CGFloat(p * p * (3 - 2 * p))
        func mix(_ a: CGRect, _ b: CGRect) -> CGRect {
            CGRect(x: a.minX + (b.minX - a.minX) * e, y: a.minY + (b.minY - a.minY) * e,
                   width: a.width + (b.width - a.width) * e, height: a.height + (b.height - a.height) * e)
        }
        drawn = (mix(glideFrom.frame, shown), mix(glideFrom.picture, picture))
        setNeedsLayout()
    }

    private func units(_ r: CGRect) -> CGRect {
        CGRect(x: (r.minX - picture.minX) / max(picture.width, 1), y: (r.minY - picture.minY) / max(picture.height, 1),
               width: r.width / max(picture.width, 1), height: r.height / max(picture.height, 1))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let (f, picture) = onScreen
        // Inside: the rest of the picture dimmed. Round it: what's to be drawn, a veil over the editor's ground.
        let veil = UIBezierPath(rect: kind == .inside ? picture : f)
        veil.append(UIBezierPath(rect: kind == .inside ? f : picture))
        shade.path = veil.cgPath
        shade.fillColor = kind == .inside ? UIColor.black.withAlphaComponent(0.45).cgColor
            : UIColor.label.withAlphaComponent(0.1).resolvedColor(with: traitCollection).cgColor
        border.path = UIBezierPath(rect: f).cgPath
        border.strokeColor = (kind == .around && traitCollection.userInterfaceStyle == .light ? UIColor.label : UIColor.white).cgColor
        corners.strokeColor = border.strokeColor
        let thirds = CGMutablePath()
        for i in 1...2 {
            let x = f.minX + f.width * CGFloat(i) / 3, y = f.minY + f.height * CGFloat(i) / 3
            thirds.move(to: CGPoint(x: x, y: f.minY))
            thirds.addLine(to: CGPoint(x: x, y: f.maxY))
            thirds.move(to: CGPoint(x: f.minX, y: y))
            thirds.addLine(to: CGPoint(x: f.maxX, y: y))
        }
        grid.path = kind == .inside ? thirds : nil
        // Crop's corners: 20 points along each side, just outside the frame.
        let arm: CGFloat = min(20, f.width / 3, f.height / 3), o: CGFloat = 1.5
        let path = CGMutablePath()
        for (cx, cy, dx, dy) in [(f.minX - o, f.minY - o, 1.0, 1.0), (f.maxX + o, f.minY - o, -1.0, 1.0),
                                 (f.maxX + o, f.maxY + o, -1.0, -1.0), (f.minX - o, f.maxY + o, 1.0, -1.0)] {
            path.move(to: CGPoint(x: cx + dx * arm, y: cy))
            path.addLine(to: CGPoint(x: cx, y: cy))
            path.addLine(to: CGPoint(x: cx, y: cy + dy * arm))
        }
        corners.path = path
        CATransaction.commit()
        accessibilityFrame = UIAccessibility.convertToScreenCoordinates(f, in: self)
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        // Only the frame and a little round it: elsewhere the picture under it is held for the original.
        shown.insetBy(dx: -24, dy: -24).contains(point)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        downAt = touches.first?.location(in: self)
        super.touchesBegan(touches, with: event)
    }

    @objc private func dragged(_ pan: UIPanGestureRecognizer) {
        if pan.state == .began {
            // Taken up where it's going, if it's on its way.
            drawn = nil
            link?.invalidate()
            link = nil
            start = shown
            held = rect
            // Where the finger came down, not where the drag was first known (a little way on).
            let p = downAt ?? pan.location(in: self)
            downAt = p
            let reach: CGFloat = 28
            func side(_ v: CGFloat, _ low: CGFloat, _ high: CGFloat) -> Int {
                abs(v - low) < reach && abs(v - low) <= abs(v - high) ? -1 : abs(v - high) < reach ? 1 : 0
            }
            grip = (side(p.x, start.minX, start.maxX), side(p.y, start.minY, start.maxY))
        }
        switch pan.state {
        case .began, .changed, .ended:
            // From the first that's known of the drag to where it's let go.
            let now = pan.location(in: self), from = downAt ?? now
            let t = CGPoint(x: now.x - from.x, y: now.y - from.y)
            // As far as it can go toward the finger: the most of the way that keeps it whole; past that it gives a
            // little, less the further it's pulled, as Crop's does, and goes back as it's let go.
            let low = reach(t)
            held = units(candidate(t, low))
            let over = hypot(t.x, t.y) * (1 - low)
            let give = over > 0 ? Self.stretch(over) / hypot(t.x, t.y) : 0
            rect = units(candidate(t, low + give))
            onChange?(held)
            guard pan.state == .ended else { return }
            fallthrough
        case .cancelled:
            let was = onScreen
            rect = held
            glide(from: was, duration: 0.25)
            onEnd?(rect)
        default: break
        }
    }

    /// Where it was let go of, held to where it can be.
    private var held = CGRect.zero

    /// How much of the way of `t` it can go.
    private func reach(_ t: CGPoint) -> CGFloat {
        guard !valid(candidate(t, 1)) else { return 1 }
        var low: CGFloat = 0, high: CGFloat = 1
        for _ in 0..<18 {
            let mid = (low + high) / 2
            if valid(candidate(t, mid)) { low = mid } else { high = mid }
        }
        return low
    }

    /// How far it goes for a finger `over` points past where it can: UIScrollView's rubber band.
    private static func stretch(_ over: CGFloat) -> CGFloat {
        let d: CGFloat = 120
        return (1 - 1 / (over * 0.55 / d + 1)) * d
    }

    /// The frame dragged `k` of the way of `t`.
    private func candidate(_ t: CGPoint, _ k: CGFloat) -> CGRect {
        let dx = t.x * k, dy = t.y * k
        guard grip != (0, 0) else { return start.offsetBy(dx: dx, dy: dy) }
        var minX = start.minX, maxX = start.maxX, minY = start.minY, maxY = start.maxY
        if grip.x == -1 { minX += dx } else if grip.x == 1 { maxX += dx }
        if grip.y == -1 { minY += dy } else if grip.y == 1 { maxY += dy }
        guard let ratio else { return CGRect(x: min(minX, maxX), y: min(minY, maxY), width: abs(maxX - minX), height: abs(maxY - minY)) }
        var w = maxX - minX, h = maxY - minY
        if grip.x != 0, grip.y != 0 {
            // A corner: the larger change, the other side kept to the shape; the far corner stays.
            if w / max(h, 1) > ratio { h = w / ratio } else { w = h * ratio }
            let x = grip.x == -1 ? start.maxX - w : start.minX
            let y = grip.y == -1 ? start.maxY - h : start.minY
            return CGRect(x: x, y: y, width: w, height: h)
        }
        // A side: the other way grown about its middle.
        if grip.x != 0 {
            h = w / ratio
            return CGRect(x: grip.x == -1 ? start.maxX - w : start.minX, y: start.midY - h / 2, width: w, height: h)
        }
        w = h * ratio
        return CGRect(x: start.midX - w / 2, y: grip.y == -1 ? start.maxY - h : start.minY, width: w, height: h)
    }

    private func valid(_ r: CGRect) -> Bool {
        let slack: CGFloat = 0.5
        switch kind {
        case .around:
            return r.insetBy(dx: -slack, dy: -slack).contains(picture) && limit.insetBy(dx: -slack, dy: -slack).contains(r)
        case .inside:
            return picture.insetBy(dx: -slack, dy: -slack).contains(r) && r.width >= smallest && r.height >= smallest
        }
    }
}
