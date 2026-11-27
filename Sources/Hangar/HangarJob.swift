import HangarCore
import UIKit

/// Pixels made elsewhere: the picture as it is under the edit (its steps', no geometry, adjustments or filter) given
/// to something that makes another from it (a model on a server, Vision on the device), and what that makes kept as
/// a step (`HangarStep`), one to undo. The editor shows the picture working meanwhile, and Cancel stops it.
public struct HangarJob: Sendable {
    /// What makes it (kept in the step).
    public var tool: String
    /// What it's doing, for VoiceOver ("Removing Background").
    public var name: String
    /// The part of the picture it works on, 0 to 1 each way from its top left: where it shimmers. All of it if nil.
    public var region: CGRect?
    /// The picture's longer side given to it, at most; its own if nil.
    public var longestSide: CGFloat?
    /// What it was asked, kept in the step: to make it again, or open its mode as it was.
    public var parameters: HangarValue?
    /// Whether what it makes is more takes of the edit's last step (asked again, the same way) rather than a step of
    /// its own: it's given the picture before that step, and its takes go after that step's, the first of them used.
    public var addsTakes: Bool
    /// What it makes from the picture. Off the main thread; cancelled if the editor's Cancel is tapped.
    public var make: @Sendable (_ picture: CGImage) async throws -> HangarMade

    public init(tool: String, name: String, region: CGRect? = nil, longestSide: CGFloat? = nil, parameters: HangarValue? = nil,
                addsTakes: Bool = false, make: @escaping @Sendable (_ picture: CGImage) async throws -> HangarMade) {
        self.tool = tool
        self.name = name
        self.region = region
        self.longestSide = longestSide
        self.parameters = parameters
        self.addsTakes = addsTakes
        self.make = make
    }
}

/// What a job made: one picture or several takes of it (the first used), where it goes over the picture it was given
/// (all of it, or more round it), and where it's kept (`HangarStep`); or the picture from then on (`replaces`: a part
/// made the whole of it).
public struct HangarMade: Sendable {
    public var takes: [CGImage]
    public var frame: CGRect
    public var mask: CGImage?
    /// Each take as it was made, where the takes were changed to be laid by the mask (`HangarStep.wholes`).
    public var wholes: [CGImage]
    public var replaces: Bool

    public init(_ picture: CGImage, frame: CGRect = HangarStep.whole, mask: CGImage? = nil, replaces: Bool = false) {
        self.init(takes: [picture], frame: frame, mask: mask, replaces: replaces)
    }

    public init(takes: [CGImage], frame: CGRect = HangarStep.whole, mask: CGImage? = nil, wholes: [CGImage] = [], replaces: Bool = false) {
        self.takes = takes
        self.frame = frame
        self.mask = mask
        self.wholes = wholes
        self.replaces = replaces
    }
}

/// Something More offers that's a job and nothing else (Remove Background, Upscale): no mode of its own. Its price,
/// if the app asks one, under its title ("30 credits"); or a choice of jobs (Upscale's 2K, 4K and 8K), each an
/// action, in a menu of their own.
public struct HangarAction: Sendable {
    public var title: String
    public var symbol: String
    public var price: String?
    public var job: HangarJob?
    public var choices: [HangarAction]

    public init(title: String, symbol: String, price: String? = nil, job: HangarJob) {
        self.title = title
        self.symbol = symbol
        self.price = price
        self.job = job
        choices = []
    }

    public init(title: String, symbol: String, choices: [HangarAction]) {
        self.title = title
        self.symbol = symbol
        job = nil
        self.choices = choices
    }
}

/// Over the picture while a job works: light passing over the part it works on, again and again.
@MainActor
final class Shimmer: UIView {
    private let band = CAGradientLayer()
    private let clip = CALayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        clip.masksToBounds = true
        layer.addSublayer(clip)
        band.colors = [UIColor.white.withAlphaComponent(0).cgColor, UIColor.white.withAlphaComponent(0.45).cgColor,
                       UIColor.white.withAlphaComponent(0).cgColor]
        band.locations = [0, 0.5, 1]
        band.startPoint = CGPoint(x: 0, y: 0.5)
        band.endPoint = CGPoint(x: 1, y: 0.5)
        clip.addSublayer(band)
        alpha = 0
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Shimmering over `region` (in its own coordinates), or still.
    func run(over region: CGRect?) {
        let area = region ?? bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        clip.frame = area
        let width = max(area.width, area.height) * 0.6
        band.frame = CGRect(x: -width, y: -area.height * 0.5, width: width, height: area.height * 2)
        band.setAffineTransform(CGAffineTransform(rotationAngle: .pi / 12))
        CATransaction.commit()
        let sweep = CABasicAnimation(keyPath: "position.x")
        sweep.fromValue = -width / 2
        sweep.toValue = area.width + width / 2
        sweep.duration = 1.4
        sweep.repeatCount = .infinity
        sweep.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        band.add(sweep, forKey: "sweep")
        UIView.animate(withDuration: 0.25) { self.alpha = 1 }
    }

    func stop() {
        UIView.animate(withDuration: 0.25) { self.alpha = 0 } completion: { _ in self.band.removeAllAnimations() }
    }
}
