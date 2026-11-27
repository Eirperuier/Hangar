import AVFoundation
import HangarCore
import QuartzCore
import UIKit

/// The clip being edited, played as its edit says (`HangarClipRenderer.playable`: at its speed, slow where it's slow
/// motion, muted or not, its music under it; the whole of it, so the trimmer can show any of it), stopping at the
/// trim's end. Each frame comes off it at about the screen's size, upright, and goes to the canvas, where the edit is
/// drawn over it. Times are the clip's own seconds (as its steps make it), wherever it's played slowly or fast.
@MainActor
public final class HangarPlayer {
    /// What the clip is (nil until it's read).
    public private(set) var info: HangarClipInfo?
    /// When it plays, all of it (not trimmed): what the player plays.
    public private(set) var timing: HangarClipTiming?
    /// The clip's seconds of the frame shown.
    public private(set) var time: Double
    public private(set) var isPlaying = false
    /// The clip as the edit's steps make it.
    public private(set) var source: URL?

    /// Each frame, upright, at about the screen's size, and its time.
    var onFrame: ((CIImage, Double) -> Void)?
    /// Playing stopped, or a seek came to rest: the frame shown is the one that stays.
    var onSettle: (() -> Void)?

    private let player = AVPlayer()
    private var output: AVPlayerItemVideoOutput?
    private var link: CADisplayLink?
    private var edit = HangarClipEdit()
    /// What the item was made for (a new one's made when it changes; a trim alone only moves where it stops).
    private var madeFor: (URL, Double, HangarSlowMotion?, Bool, HangarSoundtrack?)?
    private var loading: Task<Void, Never>?
    private var seeking = false
    private var nextSeek: Double?
    /// A frame's wanted though nothing plays (after a seek, a new item).
    private var wantsFrame = false
    /// Ticks waited for that frame: it may have come already (a pause on the frame shown).
    private var waited = 0
    private var longest: CGFloat = 1
    private var observers: [(owner: () -> AnyObject?, changed: @MainActor () -> Void)] = []
    nonisolated(unsafe) private var ended: NSObjectProtocol?

    init(time: Double) {
        self.time = time
        player.actionAtItemEnd = .pause
        // Frames come when asked for; nothing waits to buffer more than it needs.
        player.automaticallyWaitsToMinimizeStalling = false
    }

    deinit {
        if let ended { NotificationCenter.default.removeObserver(ended) }
    }

    /// Told whenever the time, playing or the clip changes, while `owner` is there.
    public func observe(_ owner: AnyObject, _ changed: @escaping @MainActor () -> Void) {
        observers.append(({ [weak owner] in owner }, changed))
    }

    private func changed() {
        observers.removeAll { $0.owner() == nil }
        for observer in observers { observer.changed() }
    }

    /// The part played: the trim, all of it if none.
    public var kept: HangarTimeRange {
        edit.kept(of: info?.duration ?? 0)
    }

    /// The time played since the kept part's start, and how long it plays (at its speed, slow where it's slow).
    public var played: (time: Double, duration: Double) {
        guard let info else { return (0, 0) }
        let timing = HangarClipTiming(edit, info: info)
        return (timing.played(at: time), timing.duration)
    }

    // MARK: Loading

    /// The clip as `edit` has it (its source as its steps make it), frames at most `longest` pixels on their longer
    /// side. A new item only if its source, speed, slow part or sound changed; a trim only moves where it stops.
    func load(_ edit: HangarEdit, source: URL, renderer: HangarClipRenderer, longest: CGFloat) {
        self.edit = edit.clip
        self.longest = longest
        let url = edit.clipSource(source, assets: renderer.renderer.assets)
        let key = (url, edit.clip.speed, edit.clip.slowMotion, edit.clip.muted, edit.clip.soundtrack)
        if let madeFor, madeFor.0 == key.0, madeFor.1 == key.1, madeFor.2 == key.2, madeFor.3 == key.3, madeFor.4 == key.4 {
            setEnd()
            return
        }
        madeFor = key
        loading?.cancel()
        let wasPlaying = isPlaying
        pause()
        loading = Task { [weak self] in
            do {
                let playable = try await renderer.playable(edit, source: source, trimmed: false)
                guard let self, !Task.isCancelled else { return }
                self.use(playable, source: url, play: wasPlaying)
            } catch {
                self?.madeFor = nil
            }
        }
    }

    private func use(_ playable: HangarClipRenderer.Playable, source url: URL, play: Bool) {
        let changedSource = source != url
        source = url
        // A clip another length (continued, reversed): the time held within it.
        info = playable.info
        timing = playable.timing
        time = min(max(time, 0), playable.info.duration)
        let item = AVPlayerItem(asset: playable.composition)
        item.audioMix = playable.audioMix
        item.audioTimePitchAlgorithm = .spectral
        let info = playable.info
        let fit = min(1, longest / max(info.size.width, info.size.height))
        // Its frames as stored (turned upright after): the output scales them.
        let stored = info.orientation.turnsSideways ? CGSize(width: info.size.height, height: info.size.width) : info.size
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int((stored.width * fit).rounded()),
            kCVPixelBufferHeightKey as String: Int((stored.height * fit).rounded()),
        ])
        item.add(output)
        self.output = output
        if let ended { NotificationCenter.default.removeObserver(ended) }
        ended = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reachedEnd() }
        }
        player.replaceCurrentItem(with: item)
        setEnd()
        seek(to: time)
        if changedSource { changed() }
        if play { self.play() }
    }

    /// Where playing stops: the trim's end.
    private func setEnd() {
        guard let timing, let item = player.currentItem else { return }
        let end = kept.end
        item.forwardPlaybackEndTime = end >= (info?.duration ?? 0) - 0.001 ? .invalid : CMTime(seconds: timing.played(at: end), preferredTimescale: 6000)
        changed()
    }

    // MARK: Playing

    /// Plays from the frame shown to the trim's end (from the trim's start if it's there already).
    public func play() {
        guard let timing, player.currentItem != nil else { return }
        let kept = self.kept
        let frame = 1 / max(info?.frameRate ?? 30, 1)
        if time >= kept.end - frame || time < kept.start - frame {
            time = kept.start
            player.seek(to: CMTime(seconds: timing.played(at: time), preferredTimescale: 6000), toleranceBefore: .zero, toleranceAfter: .zero)
        }
        isPlaying = true
        player.play()
        startLink()
        changed()
    }

    public func pause() {
        guard isPlaying else { return }
        isPlaying = false
        player.pause()
        // The frame it stopped on.
        if let timing { time = timing.time(at: player.currentTime().seconds) }
        wantsFrame = true
        waited = 0
        startLink()
        changed()
    }

    public func toggle() {
        if isPlaying { pause() } else { play() }
    }

    private func reachedEnd() {
        guard isPlaying else { return }
        isPlaying = false
        time = kept.end
        changed()
        onSettle?()
    }

    /// Shows the frame at a time on the clip (exactly: a seek in flight is followed by the latest one asked for).
    public func seek(to time: Double) {
        if isPlaying {
            isPlaying = false
            player.pause()
        }
        self.time = min(max(time, 0), info?.duration ?? time)
        changed()
        guard timing != nil else { return }
        if seeking {
            nextSeek = self.time
            return
        }
        startSeek(self.time)
    }

    private func startSeek(_ time: Double) {
        guard let timing else { return }
        seeking = true
        player.seek(to: CMTime(seconds: timing.played(at: time), preferredTimescale: 6000), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.seeking = false
                    self.wantsFrame = true
                    self.waited = 0
                    self.startLink()
                    if let next = self.nextSeek {
                        self.nextSeek = nil
                        if abs(next - time) > 0.0005 { return self.startSeek(next) }
                    }
                }
            }
        }
    }

    // MARK: Frames

    private func startLink() {
        guard link == nil else { return }
        let link = CADisplayLink(target: LinkTarget { [weak self] in self?.tick() }, selector: #selector(LinkTarget.tick))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    private func stopLink() {
        link?.invalidate()
        link = nil
    }

    private func tick() {
        guard let output, let timing, let info else { return stopLink() }
        let itemTime = isPlaying ? output.itemTime(forHostTime: CACurrentMediaTime()) : player.currentTime()
        if output.hasNewPixelBuffer(forItemTime: itemTime), let pixels = output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: nil) {
            let frame = CIImage(cvPixelBuffer: pixels).oriented(info.orientation)
            let upright = frame.transformed(by: CGAffineTransform(translationX: -frame.extent.minX, y: -frame.extent.minY))
            if isPlaying { time = timing.time(at: itemTime.seconds) }
            onFrame?(upright, time)
            if isPlaying { changed() }
            if !isPlaying, !seeking, wantsFrame {
                wantsFrame = false
                onSettle?()
            }
        }
        if !isPlaying, !seeking, wantsFrame {
            waited += 1
            if waited > 12 {
                wantsFrame = false
                onSettle?()
            }
        }
        if !isPlaying, !seeking, !wantsFrame { stopLink() }
    }

    /// Stops for good (the editor's closing).
    func close() {
        loading?.cancel()
        stopLink()
        player.pause()
        player.replaceCurrentItem(with: nil)
    }
}

/// A display link's target that doesn't keep what it calls.
private final class LinkTarget: NSObject {
    private let body: @MainActor () -> Void

    init(_ body: @escaping @MainActor () -> Void) {
        self.body = body
    }

    @MainActor @objc func tick() {
        body()
    }
}
