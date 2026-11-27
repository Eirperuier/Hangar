import HangarCore
import UIKit

/// The picture as the Tools mode shows it: the edit drawn whole, painted on with one finger, pinched and moved with
/// two (Photos' Clean Up: "Pinch to pan and zoom"), the original under a finger held still. Its strokes are in the
/// shown picture's pixels (`picture`), from its top left; the mode takes them back to the picture under the edit's
/// geometry.
@MainActor
final class BrushStage: UIView, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    /// A stroke as it's drawn: its points in the shown picture's pixels, and how wide, in them.
    struct Line {
        var points: [CGPoint]
        var width: CGFloat
    }

    /// Where the picture sits unzoomed (the canvas's place).
    var region = CGRect.zero { didSet { if region != oldValue { setNeedsLayout() } } }
    /// How wide the brush is on the screen, in points.
    var brushWidth: CGFloat = 36
    /// A stroke begun (a finger down and moving, or a tap), drawn, and lifted.
    var onBegin: (() -> Void)?
    var onStroke: ((Line) -> Void)?
    /// Whether it takes a finger to paint.
    var paints = true

    private let scroll = UIScrollView()
    private let picture = UIImageView()
    private let paint = CAShapeLayer()
    private let cursor = CAShapeLayer()
    private let style: HangarStyle
    private var pixels = CGSize(width: 1, height: 1)
    private var shown: UIImage?
    private var original: UIImage?
    private var drawing: Line?
    /// Where the finger came down, in the picture's points: a stroke starts there, not where the pan is first known.
    private var downAt: CGPoint?
    /// The strokes shown (waiting for words, or being worked on).
    private(set) var lines: [Line] = []

    init(style: HangarStyle) {
        self.style = style
        super.init(frame: .zero)
        scroll.delegate = self
        scroll.minimumZoomScale = 1
        scroll.maximumZoomScale = 6
        scroll.showsVerticalScrollIndicator = false
        scroll.showsHorizontalScrollIndicator = false
        scroll.contentInsetAdjustmentBehavior = .never
        // Zoomed, the picture stays in its region, clear of the bars and the tools.
        scroll.clipsToBounds = true
        scroll.decelerationRate = .fast
        // One finger paints; two move and pinch (Photos' Clean Up takes its media view's pan to two fingers).
        scroll.panGestureRecognizer.minimumNumberOfTouches = 2
        addSubview(scroll)
        picture.contentMode = .scaleToFill
        picture.isUserInteractionEnabled = true
        picture.accessibilityIgnoresInvertColors = true
        scroll.addSubview(picture)
        paint.fillColor = nil
        paint.lineCap = .round
        paint.lineJoin = .round
        picture.layer.addSublayer(paint)
        cursor.fillColor = UIColor.white.withAlphaComponent(0.25).cgColor
        cursor.strokeColor = UIColor.white.withAlphaComponent(0.9).cgColor
        cursor.lineWidth = 1.5
        cursor.shadowColor = UIColor.black.cgColor
        cursor.shadowOpacity = 0.3
        cursor.shadowRadius = 2
        cursor.shadowOffset = .zero
        cursor.opacity = 0
        layer.addSublayer(cursor)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
        pan.maximumNumberOfTouches = 1
        pan.delegate = self
        picture.addGestureRecognizer(pan)
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        tap.delegate = self
        picture.addGestureRecognizer(tap)
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(held(_:)))
        hold.minimumPressDuration = 0.3
        hold.allowableMovement = 6
        hold.delegate = self
        picture.addGestureRecognizer(hold)
        tap.require(toFail: hold)
        isAccessibilityElement = false
        picture.isAccessibilityElement = true
        picture.accessibilityTraits = [.image, .allowsDirectInteraction]
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (stage: BrushStage, _) in stage.drawLines() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Shows `image` (the shown picture, `pixels` its size), and the picture without the edit for a finger held.
    func show(_ image: CGImage, original: CGImage?) {
        let size = CGSize(width: image.width, height: image.height)
        let resized = size != pixels
        pixels = size
        shown = UIImage(cgImage: image)
        self.original = original.map { UIImage(cgImage: $0) }
        picture.image = shown
        if resized {
            lines = []
            drawLines()
            unzoom(animated: false)
        }
    }

    var hasPicture: Bool { shown != nil }

    /// Where the picture is, in `view`'s coordinates.
    func pictureFrame(in view: UIView) -> CGRect {
        picture.convert(picture.bounds, to: view)
    }

    /// Back to the whole picture in its place.
    func unzoom(animated: Bool) {
        scroll.setZoomScale(1, animated: animated)
        if !animated { setNeedsLayout() }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard scroll.zoomScale == 1 else { return }
        let fitted = HangarEditor.fit(pixels, in: region, scale: window?.screen.scale ?? 2)
        scroll.frame = region
        scroll.contentSize = fitted.size
        picture.frame = CGRect(origin: .zero, size: fitted.size)
        centre()
        scroll.contentOffset = CGPoint(x: -scroll.contentInset.left, y: -scroll.contentInset.top)
        drawLines()
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        picture
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centre()
    }

    /// The picture in the middle of the region while it's smaller than it.
    private func centre() {
        let inset = CGSize(width: max(0, (scroll.bounds.width - scroll.contentSize.width) / 2),
                           height: max(0, (scroll.bounds.height - scroll.contentSize.height) / 2))
        scroll.contentInset = UIEdgeInsets(top: inset.height, left: inset.width, bottom: inset.height, right: inset.width)
    }

    // MARK: Painting

    /// A point under a finger, in the shown picture's pixels.
    private func pixel(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x / max(picture.bounds.width, 1) * pixels.width, y: point.y / max(picture.bounds.height, 1) * pixels.height)
    }

    /// The brush's width in the shown picture's pixels, at the zoom it's at.
    private var widthInPixels: CGFloat {
        brushWidth / scroll.zoomScale / max(picture.bounds.width, 1) * pixels.width
    }

    @objc private func panned(_ pan: UIPanGestureRecognizer) {
        guard paints else { return }
        let point = pixel(pan.location(in: picture))
        switch pan.state {
        case .began:
            onBegin?()
            drawing = Line(points: [pixel(downAt ?? pan.location(in: picture)), point], width: widthInPixels)
            showCursor(at: pan.location(in: self))
        case .changed:
            drawing?.points.append(point)
            showCursor(at: pan.location(in: self))
        case .ended:
            drawing?.points.append(point)
            finishLine()
        default:
            drawing = nil
            hideCursor()
        }
        drawLines()
    }

    @objc private func tapped(_ tap: UITapGestureRecognizer) {
        guard paints else { return }
        onBegin?()
        drawing = Line(points: [pixel(tap.location(in: picture))], width: widthInPixels)
        finishLine()
        drawLines()
    }

    private func finishLine() {
        hideCursor()
        guard let line = drawing else { return }
        drawing = nil
        lines.append(line)
        onStroke?(line)
    }

    /// The strokes taken off, fading (Photos fades its brush stroke out once it's worked).
    func clear(fading: Bool) {
        lines = []
        guard fading else { return drawLines() }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.duration = 0.3
        paint.add(fade, forKey: "fade")
        drawLines()
    }

    /// The last stroke taken off.
    func removeLast() {
        guard !lines.isEmpty else { return }
        lines.removeLast()
        drawLines()
    }

    private func drawLines() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        paint.frame = picture.bounds
        let toPoints = max(picture.bounds.width, 1) / pixels.width
        let path = CGMutablePath()
        // One path a width: Core Animation strokes a path at one width, so each stroke is its own outline.
        for line in lines + (drawing.map { [$0] } ?? []) {
            let points = line.points.map { CGPoint(x: $0.x * toPoints, y: $0.y * toPoints) }
            let width = line.width * toPoints
            guard let first = points.first else { continue }
            if points.count == 1 {
                path.addEllipse(in: CGRect(x: first.x - width / 2, y: first.y - width / 2, width: width, height: width))
            } else {
                let stroke = CGMutablePath()
                stroke.addLines(between: points)
                path.addPath(stroke.copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 10))
            }
        }
        paint.path = path
        paint.fillColor = style.paint.resolvedColor(with: traitCollection).cgColor
        paint.strokeColor = nil
        paint.fillRule = .nonZero
        CATransaction.commit()
    }

    // MARK: The brush's size

    /// A circle the brush's size, in the middle of the picture (while its ruler moves) or under a finger.
    func showCursor(at point: CGPoint? = nil) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let middle = point ?? CGPoint(x: region.midX, y: region.midY)
        cursor.path = UIBezierPath(ovalIn: CGRect(x: middle.x - brushWidth / 2, y: middle.y - brushWidth / 2,
                                                  width: brushWidth, height: brushWidth)).cgPath
        cursor.opacity = 1
        CATransaction.commit()
    }

    func hideCursor() {
        cursor.opacity = 0
    }

    // MARK: The original

    @objc private func held(_ press: UILongPressGestureRecognizer) {
        switch press.state {
        case .began: showOriginal(true)
        case .ended, .cancelled, .failed: showOriginal(false)
        default: break
        }
    }

    /// The picture before the edit's steps, or the edit again.
    func showOriginal(_ on: Bool) {
        picture.image = on ? original ?? shown : shown
        paint.isHidden = on
    }

    // MARK: Fingers

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        // The hold and the brush wait on each other: a finger that moves paints, one that stays still shows the original.
        g is UILongPressGestureRecognizer && other is UIPanGestureRecognizer && other.view === picture
            || other is UILongPressGestureRecognizer && g is UIPanGestureRecognizer && g.view === picture
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        if g is UIPanGestureRecognizer { downAt = touch.location(in: picture) }
        return true
    }

    override func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        if g is UIPanGestureRecognizer || g is UITapGestureRecognizer { return paints }
        return true
    }
}
