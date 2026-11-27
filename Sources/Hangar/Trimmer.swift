import AVFoundation
import HangarCore
import UIKit

/// Photos' trimmer (iOS 27), 51 high: a 48-wide play cell, a white line, then the clip's frames between two handles
/// (18 wide, a chevron each) with a 4-wide white playhead over them; grey (#B2B2B3), the frame and handles yellow
/// (#FFCC00) round the part kept once it's trimmed, what's left out darkened. A finger on a handle trims, anywhere
/// else on the frames moves the playhead; a timecode (00:08.61) shows over it meanwhile. Held still half a second,
/// the frames zoom in round the finger (the handles off the ends), and out as it lifts. A slow-motion clip has a bar
/// under it (22 high, 3 under): ticks along the clip, far apart where it's slow, and a grabber at each end of the slow
/// part.
@MainActor
final class Trimmer: UIView {
    static let height: CGFloat = 51
    static let slowHeight: CGFloat = 22
    static let slowGap: CGFloat = 3
    private static let cell: CGFloat = 48
    private static let handle: CGFloat = 18
    private static let inset: CGFloat = 5
    private static let radius: CGFloat = 5
    static let grey = UIColor(red: 0xB2 / 255.0, green: 0xB2 / 255.0, blue: 0xB3 / 255.0, alpha: 1)
    static let yellow = UIColor(red: 1, green: 0xCC / 255.0, blue: 0, alpha: 1)

    /// The clip's length, its kept part, the playhead, the slow part (nil: not slow motion), in its seconds.
    var duration: Double = 1 { didSet { setNeedsLayout() } }
    var kept = HangarTimeRange(0, 1) { didSet { setNeedsLayout() } }
    var time: Double = 0 { didSet { placePlayhead() } }
    var slow: HangarSlowMotion? { didSet { setNeedsLayout() } }
    var isPlaying = false { didSet { if isPlaying != oldValue { setPlayGlyph() } } }
    /// Each frame's source, for its thumbnails.
    var asset: AVAsset? { didSet { thumbnails.removeAll(); asked.removeAll(); generator = nil; setNeedsLayout() } }

    var onPlay: (() -> Void)?
    /// The playhead moved to a time (`done` as the finger lifts).
    var onSeek: ((Double, _ done: Bool) -> Void)?
    var onTrim: ((HangarTimeRange, _ done: Bool) -> Void)?
    var onSlow: ((HangarTimeRange, _ done: Bool) -> Void)?

    private let playCell = UIControl()
    private let playGlyph = UIImageView()
    private let line = UIView()
    private let scrubber = UIView()
    private let strip = UIView()
    private let frameLayer = CAShapeLayer()
    private let leftHandle = UIImageView()
    private let rightHandle = UIImageView()
    private let dimLeft = UIView()
    private let dimRight = UIView()
    private let playhead = UIView()
    private let bubble = UILabel()
    private let bubbleLine = UIView()
    private let slowBar = UIView()
    private let slowTicks = CAShapeLayer()
    private let slowGrabbers = CAShapeLayer()
    private var tiles: [UIImageView] = []
    private let haptics = Haptics()

    /// The seconds the frames show: all of the clip, or less while zoomed.
    private var zoomWindow: HangarTimeRange?
    private var shown: HangarTimeRange { zoomWindow ?? HangarTimeRange(0, duration) }
    private var zoomLink: CADisplayLink?
    private var zoomFrom = HangarTimeRange(0, 1), zoomTo: HangarTimeRange?, zoomStart: CFTimeInterval = 0

    /// What a finger's moving, where it was held still since, and the timer that zooms.
    private enum Dragging { case playhead, start, end, slowStart, slowEnd }
    private var dragging: Dragging?
    private var stillAt: CGPoint = .zero
    private var holdTimer: Timer?

    private var thumbnails: [Int: UIImage] = [:]
    private var generator: AVAssetImageGenerator?
    private var asked: Set<Int> = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        playCell.backgroundColor = Self.grey
        playCell.layer.cornerRadius = Self.radius
        playCell.layer.maskedCorners = [.layerMinXMinYCorner, .layerMinXMaxYCorner]
        playCell.accessibilityLabel = "Play"
        playCell.accessibilityTraits = .button
        playCell.isAccessibilityElement = true
        playCell.addAction(UIAction { [weak self] _ in self?.onPlay?() }, for: .touchUpInside)
        playGlyph.tintColor = .white
        playGlyph.contentMode = .center
        playCell.addSubview(playGlyph)
        setPlayGlyph()
        line.backgroundColor = .white
        scrubber.backgroundColor = Self.grey
        scrubber.layer.cornerRadius = Self.radius
        scrubber.layer.maskedCorners = [.layerMaxXMinYCorner, .layerMaxXMaxYCorner]
        // Zoomed in, the handles go off its ends.
        scrubber.clipsToBounds = true
        scrubber.isAccessibilityElement = true
        scrubber.accessibilityLabel = "Media scrubber"
        strip.clipsToBounds = true
        scrubber.addSubview(strip)
        for dim in [dimLeft, dimRight] {
            dim.backgroundColor = UIColor(red: 22 / 255.0, green: 22 / 255.0, blue: 24 / 255.0, alpha: 0.6)
            scrubber.addSubview(dim)
        }
        frameLayer.fillRule = .evenOdd
        scrubber.layer.addSublayer(frameLayer)
        for (handle, symbol) in [(leftHandle, "chevron.compact.left"), (rightHandle, "chevron.compact.right")] {
            handle.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 22, weight: .bold))
            handle.contentMode = .center
            scrubber.addSubview(handle)
        }
        playhead.backgroundColor = .white
        playhead.layer.cornerRadius = 2
        playhead.layer.shadowColor = UIColor.black.cgColor
        playhead.layer.shadowOpacity = 0.3
        playhead.layer.shadowRadius = 1.5
        playhead.layer.shadowOffset = .zero
        playhead.isAccessibilityElement = true
        playhead.accessibilityLabel = "Key frame"
        scrubber.addSubview(playhead)
        slowBar.backgroundColor = Self.grey
        slowBar.layer.cornerRadius = Self.radius
        slowTicks.fillColor = UIColor.black.withAlphaComponent(0.85).cgColor
        slowGrabbers.fillColor = UIColor.black.cgColor
        slowBar.layer.addSublayer(slowTicks)
        slowBar.layer.addSublayer(slowGrabbers)
        slowBar.accessibilityLabel = "Slow motion"
        slowBar.isAccessibilityElement = true
        bubble.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        bubble.textColor = UIColor(white: 0.1, alpha: 1)
        bubble.textAlignment = .center
        bubble.backgroundColor = Self.grey
        bubble.layer.cornerRadius = 4
        bubble.clipsToBounds = true
        bubble.alpha = 0
        bubbleLine.backgroundColor = UIColor(white: 0.1, alpha: 1)
        bubbleLine.alpha = 0
        for view in [playCell, line, scrubber, slowBar, bubbleLine, bubble] as [UIView] { addSubview(view) }
        let press = UILongPressGestureRecognizer(target: self, action: #selector(pressed(_:)))
        press.minimumPressDuration = 0
        press.allowableMovement = .greatestFiniteMagnitude
        press.delegate = self
        addGestureRecognizer(press)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Its height: the trimmer, and the slow-motion bar under it for a slow-motion clip.
    var fittingHeight: CGFloat {
        slow == nil ? Self.height : Self.height + Self.slowGap + Self.slowHeight
    }

    private func setPlayGlyph() {
        playGlyph.image = UIImage(systemName: isPlaying ? "pause.fill" : "play.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 22, weight: .regular))
        playCell.accessibilityLabel = isPlaying ? "Pause" : "Play"
    }

    // MARK: Layout

    /// The frames' strip, in the scrubber's coordinates: between the handles' places at the clip's ends.
    private var stripFrame: CGRect {
        CGRect(x: Self.handle, y: Self.inset, width: max(scrubber.bounds.width - 2 * Self.handle, 1), height: Self.height - 2 * Self.inset)
    }

    /// Where a time is along the strip, in the scrubber's coordinates.
    private func x(_ time: Double) -> CGFloat {
        let s = stripFrame, w = shown
        return s.minX + CGFloat((time - w.start) / max(w.duration, 0.0001)) * s.width
    }

    private func time(at x: CGFloat) -> Double {
        let s = stripFrame, w = shown
        return w.start + Double((x - s.minX) / s.width) * w.duration
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        playCell.frame = CGRect(x: 0, y: 0, width: Self.cell, height: Self.height)
        playGlyph.frame = playCell.bounds
        line.frame = CGRect(x: Self.cell, y: 0, width: 1, height: Self.height)
        scrubber.frame = CGRect(x: Self.cell + 1, y: 0, width: bounds.width - Self.cell - 1, height: Self.height)
        strip.frame = stripFrame
        layoutTiles()
        let trimmed = kept.start > 0.0005 || kept.end < duration - 0.0005
        let left = x(kept.start), right = x(kept.end)
        // The frame round the part kept: grey at the ends untrimmed, yellow round the part once trimmed.
        let outer = CGRect(x: left - Self.handle, y: 0, width: right - left + 2 * Self.handle, height: Self.height)
        let path = UIBezierPath(roundedRect: outer, cornerRadius: Self.radius)
        path.append(UIBezierPath(rect: CGRect(x: left, y: Self.inset, width: max(right - left, 0), height: Self.height - 2 * Self.inset)))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        frameLayer.path = path.cgPath
        frameLayer.fillColor = (trimmed ? Self.yellow : Self.grey).cgColor
        CATransaction.commit()
        leftHandle.frame = CGRect(x: left - Self.handle, y: 0, width: Self.handle, height: Self.height)
        rightHandle.frame = CGRect(x: right, y: 0, width: Self.handle, height: Self.height)
        leftHandle.tintColor = trimmed ? .black : .white
        rightHandle.tintColor = trimmed ? .black : .white
        let s = stripFrame
        dimLeft.frame = CGRect(x: s.minX, y: s.minY, width: max(left - Self.handle - s.minX, 0), height: s.height)
        dimRight.frame = CGRect(x: right + Self.handle, y: s.minY, width: max(s.maxX - right - Self.handle, 0), height: s.height)
        dimLeft.isHidden = !trimmed
        dimRight.isHidden = !trimmed
        placePlayhead()
        slowBar.isHidden = slow == nil
        slowBar.frame = CGRect(x: 0, y: Self.height + Self.slowGap, width: bounds.width, height: Self.slowHeight)
        drawSlow()
    }

    private func placePlayhead() {
        let px = x(min(max(time, 0), duration))
        playhead.frame = CGRect(x: px - 2, y: Self.inset - 2, width: 4, height: Self.height - 2 * Self.inset + 4)
        playhead.isHidden = px < stripFrame.minX - 2 || px > stripFrame.maxX + 2
        playhead.accessibilityValue = Self.timecode(time)
        if bubble.alpha > 0, dragging == .playhead { placeBubble(at: px, time: time) }
    }

    /// Thumbnails across the strip, each the frame at its middle, as many as fit at the clip's shape.
    private func layoutTiles() {
        let s = stripFrame
        let aspect = thumbnailAspect
        let width = max(s.height * aspect, 8)
        let count = Int(ceil(s.width / width))
        while tiles.count < count {
            let tile = UIImageView()
            tile.contentMode = .scaleAspectFill
            tile.clipsToBounds = true
            strip.addSubview(tile)
            tiles.append(tile)
        }
        for (i, tile) in tiles.enumerated() {
            tile.isHidden = i >= count
            guard i < count else { continue }
            tile.frame = CGRect(x: CGFloat(i) * width, y: 0, width: width, height: s.height)
            let middle = time(at: s.minX + (CGFloat(i) + 0.5) * width)
            tile.image = thumbnail(near: middle)
        }
    }

    private var thumbnailAspect: CGFloat = 16 / 9

    /// The thumbnail nearest a time (made if it's not yet), its key a thirtieth of a second.
    private func thumbnail(near time: Double) -> UIImage? {
        let key = Int((min(max(time, 0), duration) * 30).rounded())
        if let image = thumbnails[key] { return image }
        ask(key)
        // Meanwhile the nearest one made.
        return thumbnails.min { abs($0.key - key) < abs($1.key - key) }?.value
    }

    private func ask(_ key: Int) {
        guard let asset, !asked.contains(key) else { return }
        asked.insert(key)
        if generator == nil {
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 160, height: 160)
            generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 10)
            generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 10)
            self.generator = generator
        }
        guard let generator else { return }
        let time = CMTime(value: CMTimeValue(key), timescale: 30)
        let made = ObjectIdentifier(generator)
        generator.generateCGImageAsynchronously(for: time) { [weak self] image, _, _ in
            guard let image else { return }
            let picture = UIImage(cgImage: image)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.generator.map(ObjectIdentifier.init) == made else { return }
                    self.thumbnailAspect = picture.size.width / max(picture.size.height, 1)
                    self.thumbnails[key] = picture
                    self.setNeedsLayout()
                }
            }
        }
    }

    /// The slow-motion bar: ticks a playing time apart (3 points where it plays as shot, 9 where it's slow), each end
    /// of the slow part a grabber.
    private func drawSlow() {
        guard let slow else { return }
        let ticks = UIBezierPath(), grabbers = UIBezierPath()
        let offset = scrubber.frame.minX
        let s = stripFrame
        var px = s.minX
        while px <= s.maxX {
            let t = time(at: px)
            ticks.append(UIBezierPath(rect: CGRect(x: offset + px - 0.5, y: 7.5, width: 1, height: 7)))
            px += slow.range.contains(t) && slow.range.duration > 0 ? 9 : 3
        }
        for t in [slow.range.start, slow.range.end] {
            let gx = offset + x(t)
            guard gx >= offset + s.minX - 2, gx <= offset + s.maxX + 2 else { continue }
            grabbers.append(UIBezierPath(roundedRect: CGRect(x: gx - 1.25, y: 3.5, width: 2.5, height: 15), cornerRadius: 1.25))
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        slowTicks.path = ticks.cgPath
        slowGrabbers.path = grabbers.cgPath
        CATransaction.commit()
    }

    // MARK: Fingers

    @objc private func pressed(_ press: UILongPressGestureRecognizer) {
        let point = press.location(in: scrubber)
        switch press.state {
        case .began:
            dragging = target(at: press.location(in: self))
            guard let dragging else { return }
            stillAt = point
            haptics.step()
            moved(dragging, to: point.x, done: false)
            holdStill()
        case .changed:
            guard let dragging else { return }
            if hypot(point.x - stillAt.x, point.y - stillAt.y) > 3 {
                stillAt = point
                holdStill()
            }
            moved(dragging, to: point.x, done: false)
        case .ended, .cancelled, .failed:
            holdTimer?.invalidate()
            guard let dragging else { return }
            moved(dragging, to: point.x, done: true)
            self.dragging = nil
            showBubble(false)
            if zoomWindow != nil { zoom(to: nil) }
        default: break
        }
    }

    /// What a finger at `point` (in the trimmer's coordinates) moves: a handle or a grabber near it, else the playhead.
    private func target(at point: CGPoint) -> Dragging? {
        if point.y > Self.height {
            guard let slow else { return nil }
            let px = point.x - scrubber.frame.minX
            let a = abs(px - x(slow.range.start)), b = abs(px - x(slow.range.end))
            return min(a, b) < 22 ? (a <= b ? .slowStart : .slowEnd) : nil
        }
        guard point.x > scrubber.frame.minX else { return nil }
        let px = point.x - scrubber.frame.minX
        let left = x(kept.start) - Self.handle / 2, right = x(kept.end) + Self.handle / 2
        if abs(px - left) < 20 || abs(px - right) < 20 { return abs(px - left) <= abs(px - right) ? .start : .end }
        return .playhead
    }

    private var shortest: Double { min(0.1, duration) }

    private func moved(_ what: Dragging, to px: CGFloat, done: Bool) {
        switch what {
        case .playhead:
            let t = min(max(time(at: px), kept.start), kept.end)
            placeBubble(at: x(t), time: t)
            onSeek?(t, done)
        case .start:
            let t = min(max(time(at: px + Self.handle / 2), 0), kept.end - shortest)
            kept = HangarTimeRange(t, kept.end)
            placeBubble(at: x(t), time: t)
            if !done { onSeek?(t, false) }
            onTrim?(kept, done)
        case .end:
            let t = max(min(time(at: px - Self.handle / 2), duration), kept.start + shortest)
            kept = HangarTimeRange(kept.start, t)
            placeBubble(at: x(t), time: t)
            if !done { onSeek?(t, false) }
            onTrim?(kept, done)
        case .slowStart, .slowEnd:
            guard let range = slow?.range else { return }
            let t = min(max(time(at: px), 0), duration)
            let moved = what == .slowStart ? HangarTimeRange(min(t, range.end), range.end) : HangarTimeRange(range.start, max(t, range.start))
            slow?.range = moved
            placeBubble(at: x(t), time: t)
            onSeek?(what == .slowStart ? moved.start : moved.end, false)
            onSlow?(moved, done)
        }
    }

    // MARK: The timecode

    private func placeBubble(at px: CGFloat, time: Double) {
        bubble.text = Self.timecode(time)
        let size = CGSize(width: bubble.intrinsicContentSize.width + 10, height: 16)
        let cx = scrubber.frame.minX + px
        bubble.frame = CGRect(x: cx - size.width / 2, y: -14 - size.height, width: size.width, height: size.height)
        bubbleLine.frame = CGRect(x: cx - 0.5, y: -14, width: 1, height: 12)
        showBubble(true)
    }

    private func showBubble(_ shown: Bool) {
        let alpha: CGFloat = shown ? 1 : 0
        guard bubble.alpha != alpha else { return }
        UIView.animate(withDuration: shown ? 0.12 : 0.2, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
            self.bubble.alpha = alpha
            self.bubbleLine.alpha = alpha
        }
    }

    /// Photos' "00:08.61": minutes, seconds and hundredths.
    static func timecode(_ seconds: Double) -> String {
        let hundredths = Int((max(seconds, 0) * 100).rounded())
        return String(format: "%02d:%02d.%02d", hundredths / 6000, (hundredths / 100) % 60, hundredths % 100)
    }

    // MARK: Zooming

    /// A finger held still half a second zooms the frames in round it.
    private func holdStill() {
        holdTimer?.invalidate()
        guard zoomWindow == nil else { return }
        let timer = Timer(timeInterval: 0.5, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.zoomIn() }
        }
        // While a finger tracks, the run loop runs in its tracking mode.
        RunLoop.main.add(timer, forMode: .common)
        holdTimer = timer
    }

    private func zoomIn() {
        guard dragging != nil, zoomWindow == nil, duration > 0 else { return }
        // A tenth of the clip (no less than a second) across the strip, the time under the finger staying under it.
        let span = min(duration, max(duration / 10, 1))
        let s = stripFrame
        let share = Double(min(max((stillAt.x - s.minX) / s.width, 0), 1))
        let under = time(at: stillAt.x)
        let start = under - share * span
        haptics.detent()
        zoom(to: HangarTimeRange(start, start + span))
    }

    /// The frames' window moved to `to` (nil: all of the clip) over a quarter of a second.
    private func zoom(to target: HangarTimeRange?) {
        zoomFrom = shown
        zoomTo = target ?? HangarTimeRange(0, duration)
        zoomStart = CACurrentMediaTime()
        if target == nil { pendingUnzoom = true }
        if zoomLink == nil {
            let link = CADisplayLink(target: TrimmerLink { [weak self] in self?.stepZoom() }, selector: #selector(TrimmerLink.tick))
            link.add(to: .main, forMode: .common)
            zoomLink = link
        }
    }

    private var pendingUnzoom = false

    private func stepZoom() {
        guard let zoomTo else { return }
        let p = min((CACurrentMediaTime() - zoomStart) / 0.25, 1)
        let e = 1 - pow(1 - p, 3)
        zoomWindow = HangarTimeRange(zoomFrom.start + (zoomTo.start - zoomFrom.start) * e, zoomFrom.end + (zoomTo.end - zoomFrom.end) * e)
        setNeedsLayout()
        layoutIfNeeded()
        if p >= 1 {
            if pendingUnzoom { zoomWindow = nil; pendingUnzoom = false }
            self.zoomTo = nil
            zoomLink?.invalidate()
            zoomLink = nil
            setNeedsLayout()
        }
    }
}

extension Trimmer: UIGestureRecognizerDelegate {
    override func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
        // The play cell's taps are its own.
        guard gesture is UILongPressGestureRecognizer else { return true }
        let point = gesture.location(in: self)
        return target(at: point) != nil
    }
}

/// A display link's target that doesn't keep what it calls.
private final class TrimmerLink: NSObject {
    private let body: @MainActor () -> Void

    init(_ body: @escaping @MainActor () -> Void) {
        self.body = body
    }

    @MainActor @objc func tick() {
        body()
    }
}
