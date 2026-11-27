import AVFoundation
import Hangar
import HangarCore
import ImagePreview
import UIKit

/// A clip, as the viewer shows it (Flight's `PreviewContent`): the original and its edit, playing the edited clip once
/// it's exported, its still the frame it shows. An edit kept shows its frame at once; the clip follows when it's
/// written.
@MainActor
final class Clip: PreviewContent {
    let original: URL
    private(set) var edit = HangarEdit()
    /// The edited clip, once it's written.
    private(set) var edited: URL?
    /// What's shown until it plays: its first frame, then the edited one.
    private(set) var poster: UIImage?
    private var changed: (@MainActor () -> Void)?
    private lazy var player: AVPlayer = {
        let player = AVPlayer(url: shown)
        player.actionAtItemEnd = .none
        looping = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main) { [weak player] note in
            guard let item = note.object as? AVPlayerItem, item === player?.currentItem else { return }
            MainActor.assumeIsolated { player?.seek(to: .zero) }
        }
        return player
    }()
    private var looping: (any NSObjectProtocol)?

    init(_ original: URL) {
        self.original = original
    }

    var shown: URL { edited ?? original }

    /// Its first frame, for the grid.
    func makePoster() async {
        guard poster == nil, let frame = try? await HangarClipRenderer.frame(of: original, at: 0, longest: 1200) else { return }
        poster = UIImage(cgImage: frame)
    }

    func still() -> UIImage? { poster }

    func load(changed: @escaping @MainActor () -> Void) {
        self.changed = changed
        Task {
            await makePoster()
            changed()
        }
    }

    func cancel() {
        changed = nil
        player.pause()
    }

    func makeView(for place: PreviewContentPlace) -> UIView? {
        ClipView(player: player)
    }

    func setState(_ state: PreviewContentState) {
        if state == .offScreen { player.pause() } else { player.play() }
    }

    /// The editor's frame at once; the clip when it's written (a trimmed one as a new clip says so in its name).
    func keep(_ result: HangarResult, then done: @escaping @MainActor () -> Void) {
        edit = result.edit
        poster = result.preview
        changed?()
        done()
        guard !result.edit.isOriginal else {
            edited = nil
            player.replaceCurrentItem(with: AVPlayerItem(url: original))
            return
        }
        Task {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("edited-\(UUID().uuidString).mov")
            do {
                try await result.export(to: url)
            } catch {
                print("Export failed: \(error)")
                return
            }
            guard self.edit == result.edit else { return }
            self.edited = url
            self.player.replaceCurrentItem(with: AVPlayerItem(url: url))
            self.player.play()
            self.changed?()
            done()
        }
    }
}

/// A player's video, fitted in the view.
final class ClipView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }

    init(player: AVPlayer) {
        super.init(frame: .zero)
        (layer as! AVPlayerLayer).player = player
        (layer as! AVPlayerLayer).videoGravity = .resizeAspect
        isUserInteractionEnabled = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
