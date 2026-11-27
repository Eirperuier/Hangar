import AVFoundation
import HangarCore
import UIKit

/// Photos' Video mode, a clip's first (iOS 27): its trimmer where the tools are (`Trimmer`: play, the frames between
/// two handles, the playhead; a slow-motion bar under it for a slow-motion clip), Volume alone on the capsule where
/// Undo and Redo are (they're in More, named for what they undo), and the clip's speed in More.
@MainActor
public final class HangarVideoModule: HangarModule {
    public let item = HangarModeItem(id: HangarMode.video.id, name: "Video", symbol: "video", chosenSymbol: "video.fill")

    private weak var host: (any HangarHost)?
    private let trimmer = Trimmer()
    private var volumeBar: UIVisualEffectView!
    private var volumeButton: UIButton!
    private var moreButton: UIButton!
    private var chosen = false
    private var sideways = false

    /// Photos' speeds aren't a tool for a clip shot at 30 or 60; these are the web canvas's.
    public var speeds: [Double] = [0.5, 1, 1.5, 2]

    public init() {}

    public func takes(_ media: HangarMedia) -> Bool { media == .clip }
    public var ownsTopBar: Bool { true }
    public var showsPlayer: Bool { false }
    public var chrome: [UIView] { [trimmer, volumeBar, moreButton] }

    public func load(in host: any HangarHost) {
        self.host = host
        let style = host.style
        volumeBar = Chrome.capsule(style)
        volumeButton = Chrome.plainButton("speaker.wave.2.fill", label: "Volume", style: style)
        volumeButton.accessibilityIdentifier = "edit.muteButton"
        volumeButton.addAction(UIAction { [weak self] _ in self?.toggleSound() }, for: .touchUpInside)
        volumeBar.contentView.addSubview(volumeButton)
        moreButton = Chrome.button("ellipsis", label: "More", style: style)
        moreButton.showsMenuAsPrimaryAction = true
        moreButton.menu = UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] completion in
            completion(self?.host?.moreMenu() ?? [])
        }])
        trimmer.onPlay = { [weak self] in self?.host?.player?.toggle() }
        trimmer.onSeek = { [weak self] time, _ in self?.host?.player?.seek(to: time) }
        trimmer.onTrim = { [weak self] range, done in self?.trimmed(range, done: done) }
        trimmer.onSlow = { [weak self] range, done in self?.slowed(range, done: done) }
        host.add(trimmer, at: .controls)
        host.add(volumeBar, at: .controls)
        host.add(moreButton, at: .controls)
        host.player?.observe(self) { [weak self] in self?.playerChanged() }
    }

    public func layout(_ layout: HangarLayout) {
        sideways = layout.sideways
        let height = trimmer.fittingHeight
        if layout.sideways {
            // Photos' iPad: 457 wide in the middle, its top 72 + 51 off the bottom.
            trimmer.frame = CGRect(x: layout.bounds.midX - 457 / 2, y: layout.bounds.maxY - 72 - Trimmer.height, width: 457, height: height)
        } else {
            // Photos' phone: where the tools are (113 over the mode bar), 15 in from each side.
            trimmer.frame = CGRect(x: layout.bounds.minX + 15, y: layout.modeBar.minY - 113, width: layout.bounds.width - 30, height: height)
        }
        // Volume alone on glass where Undo and Redo are (first on the iPad's capsule).
        volumeBar.frame = CGRect(x: layout.history.minX, y: layout.history.minY, width: 44, height: 44)
        Chrome.round(volumeBar)
        volumeButton.frame = volumeBar.bounds
        moreButton.frame = layout.more
    }

    public func show(_ shown: Bool) {
        chosen = shown
        trimmer.isHidden = !shown
        volumeBar.isHidden = !shown
        moreButton.isHidden = !shown
        if shown {
            host?.showName(nil)
            sync()
        }
    }

    public func left() {
        host?.player?.pause()
    }

    public func stop() {
        trimmer.isPlaying = host?.player?.isPlaying ?? false
    }

    public func sync() {
        guard let host, let player = host.player else { return }
        let clip = host.edit.clip
        if let info = player.info {
            trimmer.duration = info.duration
            trimmer.kept = clip.kept(of: info.duration)
            trimmer.slow = info.isSlowMotion ? (clip.slowMotion ?? .standard(for: info)) : nil
            volumeButton.isEnabled = info.hasSound
            // The slow-motion bar under it, once it's known to be slow motion.
            trimmer.frame.size.height = trimmer.fittingHeight
        }
        let muted = clip.muted
        var configuration = volumeButton.configuration
        configuration?.image = UIImage(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                                       withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .medium))
        volumeButton.configuration = configuration
        volumeButton.accessibilityValue = muted ? "Muted" : "Unmuted"
        trimmer.setNeedsLayout()
    }

    public func pictureChanged() {
        syncClip()
    }

    /// The player's time, playing, or clip changed: the playhead with it, the frames from a new clip.
    private func playerChanged() {
        guard let player = host?.player else { return }
        trimmer.isPlaying = player.isPlaying
        trimmer.time = player.time
        syncClip()
    }

    private var shownSource: URL?

    private func syncClip() {
        guard let player = host?.player, let source = player.source, source != shownSource else { return }
        shownSource = source
        trimmer.asset = AVURLAsset(url: source)
        sync()
    }

    // MARK: Changing it

    private func trimmed(_ range: HangarTimeRange, done: Bool) {
        guard let host, let info = host.player?.info else { return }
        let whole = range.start <= 0.0005 && range.end >= info.duration - 0.0005
        host.edit.clip.trim = whole ? nil : range
        // The playhead at the trim's start once a handle's let go (Photos').
        if done {
            host.player?.seek(to: range.start)
            host.commit()
        }
    }

    private func slowed(_ range: HangarTimeRange, done: Bool) {
        guard let host, let info = host.player?.info else { return }
        host.edit.clip.slowMotion = HangarSlowMotion(range: range, rate: HangarSlowMotion.rate(for: info))
        if done { host.commit() }
    }

    private func toggleSound() {
        guard let host else { return }
        host.edit.clip.muted.toggle()
        host.commit()
    }

    private func setSpeed(_ speed: Double) {
        guard let host else { return }
        host.edit.clip.speed = speed
        host.commit()
    }

    // MARK: More

    public func menu() -> [UIMenuElement] {
        guard let host else { return [] }
        let speed = host.edit.clip.speed
        let speeds = UIMenu(title: "Speed", image: UIImage(systemName: "gauge.with.dots.needle.67percent"), children: speeds.map { s in
            UIAction(title: s == 1 ? "Normal" : String(format: "%g×", s), state: abs(s - speed) < 0.001 ? .on : .off) { [weak self] _ in self?.setSpeed(s) }
        })
        speeds.subtitle = abs(speed - 1) < 0.001 ? nil : String(format: "%g×", speed)
        // Undo and Redo, named for what they change (Photos': Undo Trim, Undo Slo-mo Edit).
        let undo = UIAction(title: name("Undo", from: host.edit, to: host.undoEdit), image: UIImage(systemName: "arrow.uturn.backward"),
                            attributes: host.undoEdit == nil ? .disabled : []) { [weak self] _ in self?.host?.step(-1) }
        let redo = UIAction(title: name("Redo", from: host.edit, to: host.redoEdit), image: UIImage(systemName: "arrow.uturn.forward"),
                            attributes: host.redoEdit == nil ? .disabled : []) { [weak self] _ in self?.host?.step(1) }
        var items: [UIMenuElement] = [speeds]
        if let music = musicMenu() { items.append(music) }
        return items + [UIMenu(options: .displayInline, children: [undo, redo])]
    }

    /// Music under the clip: added from the app's picker, its volume, taken out.
    private func musicMenu() -> UIMenuElement? {
        guard let host, host.offersMusic else { return nil }
        guard let soundtrack = host.edit.clip.soundtrack else {
            return UIAction(title: "Add Music…", image: UIImage(systemName: "music.note")) { [weak self] _ in self?.host?.addMusic() }
        }
        let volumes = UIMenu(title: "Volume", image: UIImage(systemName: "speaker.wave.2"), children: [1, 0.75, 0.5, 0.25].map { v in
            UIAction(title: "\(Int(v * 100))%", state: abs(v - soundtrack.volume) < 0.001 ? .on : .off) { [weak self] _ in
                guard let host = self?.host, host.edit.clip.soundtrack != nil else { return }
                host.edit.clip.soundtrack?.volume = v
                host.commit()
            }
        })
        volumes.subtitle = "\(Int((soundtrack.volume * 100).rounded()))%"
        let menu = UIMenu(title: "Music", image: UIImage(systemName: "music.note"), children: [
            UIAction(title: "Replace Music…", image: UIImage(systemName: "arrow.triangle.2.circlepath")) { [weak self] _ in self?.host?.addMusic() },
            volumes,
            UIAction(title: "Remove Music", image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in
                guard let host = self?.host else { return }
                host.edit.clip.soundtrack = nil
                host.commit()
            },
        ])
        menu.subtitle = soundtrack.name
        return menu
    }

    private func name(_ verb: String, from now: HangarEdit, to other: HangarEdit?) -> String {
        guard let other else { return verb }
        var rest = now, otherRest = other
        rest.clip = HangarClipEdit()
        otherRest.clip = HangarClipEdit()
        guard rest == otherRest else { return verb }
        let a = now.clip, b = other.clip
        if a.trim != b.trim { return "\(verb) Trim" }
        if a.slowMotion != b.slowMotion { return "\(verb) Slo-mo Edit" }
        if a.speed != b.speed { return "\(verb) Speed" }
        if a.muted != b.muted { return "\(verb) Mute" }
        if a.soundtrack != b.soundtrack { return "\(verb) Music" }
        return verb
    }
}
