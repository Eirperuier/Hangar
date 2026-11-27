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
    /// Whether the mode that asks for it shows it working, over its own picture (Tools); the editor does otherwise.
    public var shownByMode = false
    /// The edit's geometry, for a job given the picture as it shapes it (cropped, straightened, tilted; not turned
    /// or flipped): what it makes `replaces` the picture, and the geometry goes but for its turns and flip.
    public var shaped: HangarGeometry?
    /// What it makes from the picture. Off the main thread; cancelled if the editor's Cancel is tapped.
    public var make: @Sendable (_ picture: CGImage) async throws -> HangarMade

    public init(tool: String, name: String, region: CGRect? = nil, longestSide: CGFloat? = nil, parameters: HangarValue? = nil,
                addsTakes: Bool = false, shaped: HangarGeometry? = nil, make: @escaping @Sendable (_ picture: CGImage) async throws -> HangarMade) {
        self.tool = tool
        self.name = name
        self.region = region
        self.longestSide = longestSide
        self.parameters = parameters
        self.addsTakes = addsTakes
        self.shaped = shaped
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

/// A clip made elsewhere from the clip being edited (a model's: changed in words, continued, upscaled; or on the
/// device: reversed): given the clip as the edit's steps make it, the frame shown and what was asked; what it makes
/// (files, one or several takes) is the clip from then on, a step to undo (`HangarStep.clip`). The picture works
/// meanwhile, and Cancel stops it.
public struct HangarClipJob: Sendable {
    /// How what it makes plays against the clip it was given (`HangarEdit.ClipTiming`).
    public enum Timing: Sendable {
        /// As long, frame for frame: the trim and slow part kept.
        case kept
        /// Another length: the trim and slow part let go.
        case new
        /// Backwards: the same part kept, mirrored.
        case reversed
    }

    public var tool: String
    /// What it's doing, for VoiceOver ("Reversing").
    public var name: String
    /// The part of the frame it works on, 0 to 1 each way: where it shimmers. All of it if nil.
    public var region: CGRect?
    public var parameters: HangarValue?
    public var timing: Timing
    /// More takes of the edit's last step (asked again the same way): given the clip before that step.
    public var addsTakes: Bool
    /// Whether the mode that asks for it shows it working, over its own picture (Tools).
    public var shownByMode = false
    /// What it makes: files of clips, the first used. Off the main thread; cancelled with Cancel.
    public var make: @Sendable (HangarClipRequest) async throws -> [URL]

    public init(tool: String, name: String, region: CGRect? = nil, parameters: HangarValue? = nil, timing: Timing = .kept,
                addsTakes: Bool = false, make: @escaping @Sendable (HangarClipRequest) async throws -> [URL]) {
        self.tool = tool
        self.name = name
        self.region = region
        self.parameters = parameters
        self.timing = timing
        self.addsTakes = addsTakes
        self.make = make
    }
}

/// What a clip job's given: the clip as the edit's steps make it (a file), what it is, the frame shown (upright, as
/// the steps make it, nothing else of the edit on it) and its time, the part kept; and what a tool asked (`words`,
/// the painted part's `boxes` on the frame, 0 to 1 each way, the frame `marked` as the web marks it, its `mask`).
public struct HangarClipRequest: @unchecked Sendable {
    public var clip: URL
    public var info: HangarClipInfo
    public var frame: CGImage
    public var time: Double
    public var trim: HangarTimeRange?
    public var words: String?
    public var boxes: [CGRect]
    public var marked: CGImage?
    public var mask: CGImage?

    public init(clip: URL, info: HangarClipInfo, frame: CGImage, time: Double, trim: HangarTimeRange? = nil, words: String? = nil,
                boxes: [CGRect] = [], marked: CGImage? = nil, mask: CGImage? = nil) {
        self.clip = clip
        self.info = info
        self.frame = frame
        self.time = time
        self.trim = trim
        self.words = words
        self.boxes = boxes
        self.marked = marked
        self.mask = mask
    }
}

/// Something More offers that's a job and nothing else (Remove Background, Upscale; for a clip, Reverse): no mode of
/// its own. Its price, if the app asks one, under its title ("30 credits"); or a choice of jobs (Upscale's 2K, 4K and
/// 8K), each an action, in a menu of their own. A picture's job is offered for a picture, a clip job for a clip.
public struct HangarAction: Sendable {
    public var title: String
    public var symbol: String
    public var price: String?
    public var job: HangarJob?
    public var clipJob: HangarClipJob?
    public var choices: [HangarAction]

    public init(title: String, symbol: String, price: String? = nil, job: HangarJob) {
        self.title = title
        self.symbol = symbol
        self.price = price
        self.job = job
        choices = []
    }

    public init(title: String, symbol: String, price: String? = nil, clipJob: HangarClipJob) {
        self.title = title
        self.symbol = symbol
        self.price = price
        self.clipJob = clipJob
        choices = []
    }

    public init(title: String, symbol: String, choices: [HangarAction]) {
        self.title = title
        self.symbol = symbol
        job = nil
        self.choices = choices
    }

    /// Whether it's offered for `media`: its job is for it, or one of its choices is.
    func offered(for media: HangarMedia) -> Bool {
        switch media {
        case .picture: job != nil || choices.contains { $0.offered(for: media) }
        case .clip: clipJob != nil || choices.contains { $0.offered(for: media) }
        }
    }
}
