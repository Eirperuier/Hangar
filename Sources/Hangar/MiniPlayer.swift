import HangarCore
import UIKit

/// Photos' small player over a clip's picture in the modes other than Video: a play button 16 in, a thin track, the
/// time played under its left end and how long it plays under its right. The track's dragged to move through it.
@MainActor
final class MiniPlayer: UIView {
    static let height: CGFloat = 44

    weak var player: HangarPlayer? {
        didSet { player?.observe(self) { [weak self] in self?.update() } }
    }

    private let button = UIButton(type: .system)
    private let track = UIView()
    private let fill = UIView()
    private let elapsed = UILabel()
    private let total = UILabel()

    init(style: HangarStyle) {
        super.init(frame: .zero)
        button.tintColor = .white
        button.addAction(UIAction { [weak self] _ in self?.player?.toggle() }, for: .touchUpInside)
        button.accessibilityLabel = "Play"
        track.backgroundColor = UIColor.white.withAlphaComponent(0.35)
        track.layer.cornerRadius = 1.5
        track.clipsToBounds = true
        fill.backgroundColor = .white
        track.addSubview(fill)
        for label in [elapsed, total] {
            label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
            label.textColor = .white
        }
        total.textAlignment = .right
        for view in [button, track, elapsed, total] as [UIView] {
            view.layer.shadowColor = UIColor.black.cgColor
            view.layer.shadowOpacity = 0.35
            view.layer.shadowRadius = 2
            view.layer.shadowOffset = .zero
            addSubview(view)
        }
        track.layer.shadowOpacity = 0
        let drag = UIPanGestureRecognizer(target: self, action: #selector(dragged(_:)))
        addGestureRecognizer(drag)
        isAccessibilityElement = false
        update()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        // The play button's middle 16 in, 14 down; the track beside it, the times under its ends.
        button.frame = CGRect(x: 4, y: 0, width: 40, height: 28)
        track.frame = CGRect(x: 44, y: 12.5, width: max(bounds.width - 44 - 16, 0), height: 3)
        elapsed.frame = CGRect(x: track.frame.minX, y: 20, width: 80, height: 16)
        total.frame = CGRect(x: track.frame.maxX - 80, y: 20, width: 80, height: 16)
        update()
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        // Only its controls: the picture under the rest of it.
        guard point.y < 36, point.x < track.frame.maxX + 8 else { return nil }
        return super.hitTest(point, with: event)
    }

    private func update() {
        guard let player else { return }
        let played = player.played
        let image = UIImage(systemName: player.isPlaying ? "pause.fill" : "play.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .regular))
        if button.image(for: .normal) != image { button.setImage(image, for: .normal) }
        button.accessibilityLabel = player.isPlaying ? "Pause" : "Play"
        elapsed.text = Self.clock(played.time)
        total.text = Self.clock(played.duration)
        let share = played.duration > 0 ? min(max(played.time / played.duration, 0), 1) : 0
        fill.frame = CGRect(x: 0, y: 0, width: track.bounds.width * share, height: track.bounds.height)
    }

    @objc private func dragged(_ pan: UIPanGestureRecognizer) {
        guard let player, track.bounds.width > 0 else { return }
        let share = min(max((pan.location(in: track).x) / track.bounds.width, 0), 1)
        let kept = player.kept
        player.seek(to: kept.start + kept.duration * share)
    }

    /// Photos' "00:03".
    static func clock(_ seconds: Double) -> String {
        let whole = Int(max(seconds, 0).rounded(.down))
        return String(format: "%02d:%02d", whole / 60, whole % 60)
    }
}
