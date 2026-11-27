import AVFoundation
import CoreGraphics
import Foundation
import ImageIO

/// What's done to a clip beyond what's done to each of its frames (which is the rest of the edit, as for a picture):
/// the part kept, its sound muted or not, how fast it plays, where it plays slowly, and music under it. Values, so a
/// trim can be changed later and undone as anything else.
public struct HangarClipEdit: Hashable, Sendable, Codable {
    /// The part kept, in the clip's own seconds (as its steps make it); all of it if nil.
    public var trim: HangarTimeRange?
    /// The clip's own sound left out.
    public var muted: Bool
    /// How fast the whole of it plays: 1 as it was shot, 2 twice as fast.
    public var speed: Double
    /// Where a slow-motion clip plays slowly; nil for its first slow part (`HangarSlowMotion.standard`), as Photos
    /// shows a slow-motion clip before it's edited. Not read for a clip that isn't slow motion.
    public var slowMotion: HangarSlowMotion?
    /// Music under it.
    public var soundtrack: HangarSoundtrack?

    public init(trim: HangarTimeRange? = nil, muted: Bool = false, speed: Double = 1, slowMotion: HangarSlowMotion? = nil,
                soundtrack: HangarSoundtrack? = nil) {
        self.trim = trim
        self.muted = muted
        self.speed = speed
        self.slowMotion = slowMotion
        self.soundtrack = soundtrack
    }

    /// Whether it changes nothing: the clip plays as it came.
    public var isOriginal: Bool {
        trim == nil && !muted && speed == 1 && slowMotion == nil && soundtrack == nil
    }

    /// The trim, the whole clip if there's none, within `duration`.
    public func kept(of duration: Double) -> HangarTimeRange {
        let whole = HangarTimeRange(0, duration)
        guard let trim else { return whole }
        let start = min(max(trim.start, 0), duration), end = min(max(trim.end, start), duration)
        return HangarTimeRange(start, end)
    }

    private enum CodingKeys: String, CodingKey {
        case trim, muted, speed, slowMotion, soundtrack
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        trim = try container.decodeIfPresent(HangarTimeRange.self, forKey: .trim)
        muted = try container.decodeIfPresent(Bool.self, forKey: .muted) ?? false
        speed = try container.decodeIfPresent(Double.self, forKey: .speed) ?? 1
        slowMotion = try container.decodeIfPresent(HangarSlowMotion.self, forKey: .slowMotion)
        soundtrack = try container.decodeIfPresent(HangarSoundtrack.self, forKey: .soundtrack)
    }
}

/// A stretch of a clip, in seconds.
public struct HangarTimeRange: Hashable, Sendable, Codable {
    public var start: Double
    public var end: Double

    public init(_ start: Double, _ end: Double) {
        self.start = start
        self.end = end
    }

    public var duration: Double { max(end - start, 0) }

    public func contains(_ time: Double) -> Bool {
        time >= start && time <= end
    }

    /// The same stretch of a clip `duration` long played backwards.
    public func mirrored(in duration: Double) -> HangarTimeRange {
        HangarTimeRange(duration - end, duration - start)
    }

    var cmRange: CMTimeRange {
        CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600), end: CMTime(seconds: end, preferredTimescale: 600))
    }
}

/// Where a slow-motion clip plays slowly, and how slowly: `rate` of the time it was shot in (a 240-frames-a-second
/// clip played at 30 is 1/8). An empty range plays it all as it was shot.
public struct HangarSlowMotion: Hashable, Sendable, Codable {
    public var range: HangarTimeRange
    public var rate: Double

    public init(range: HangarTimeRange, rate: Double) {
        self.range = range
        self.rate = rate
    }

    /// Photos' first slow part of a slow-motion clip: its middle two thirds, at 30 frames a second.
    public static func standard(for info: HangarClipInfo) -> HangarSlowMotion {
        HangarSlowMotion(range: HangarTimeRange(info.duration / 6, info.duration * 5 / 6), rate: rate(for: info))
    }

    /// How slowly a clip shot at its frame rate plays where it's slow: at 30 frames a second.
    public static func rate(for info: HangarClipInfo) -> Double {
        min(1, 30 / max(info.frameRate, 1))
    }
}

/// Music under a clip: a sound kept in the store (`HangarAssets.file`), how loud (0 to 1), and its name to show.
/// It starts with the clip's kept part and plays again from its start until the clip ends.
public struct HangarSoundtrack: Hashable, Sendable, Codable {
    public var asset: String
    public var volume: Double
    public var name: String?

    public init(asset: String, volume: Double = 1, name: String? = nil) {
        self.asset = asset
        self.volume = volume
        self.name = name
    }
}

/// What a clip is, read from its file: how long, how many frames a second, its frames' size upright, how they're
/// turned to be upright, and whether it has sound.
public struct HangarClipInfo: Hashable, Sendable {
    public var duration: Double
    public var frameRate: Double
    /// Its frames upright, in pixels.
    public var size: CGSize
    /// How its frames as stored are turned to be upright (from its track's transform).
    public var orientation: CGImagePropertyOrientation
    public var hasSound: Bool

    public init(duration: Double, frameRate: Double, size: CGSize, orientation: CGImagePropertyOrientation = .up, hasSound: Bool) {
        self.duration = duration
        self.frameRate = frameRate
        self.size = size
        self.orientation = orientation
        self.hasSound = hasSound
    }

    /// Photos reads a clip shot at 100 frames a second or more as slow motion.
    public var isSlowMotion: Bool { frameRate >= 100 }

    /// The clip's info, read from its file.
    public static func load(_ url: URL) async throws -> HangarClipInfo {
        try await load(AVURLAsset(url: url))
    }

    public static func load(_ asset: AVAsset) async throws -> HangarClipInfo {
        let duration = try await asset.load(.duration)
        guard let video = try await asset.loadTracks(withMediaType: .video).first else { throw CocoaError(.fileReadCorruptFile) }
        let (natural, transform, rate) = try await video.load(.naturalSize, .preferredTransform, .nominalFrameRate)
        let sound = try await !asset.loadTracks(withMediaType: .audio).isEmpty
        let orientation = CGImagePropertyOrientation(transform)
        let upright = orientation.turnsSideways ? CGSize(width: natural.height, height: natural.width) : natural
        return HangarClipInfo(duration: duration.seconds, frameRate: Double(rate), size: CGSize(width: abs(upright.width), height: abs(upright.height)),
                              orientation: orientation, hasSound: sound)
    }
}

extension CGImagePropertyOrientation {
    /// How frames stored with a track's transform are turned to be upright.
    public init(_ transform: CGAffineTransform) {
        let (a, b, c, d) = (transform.a.rounded(), transform.b.rounded(), transform.c.rounded(), transform.d.rounded())
        switch (a, b, c, d) {
        case (0, 1, -1, 0): self = .right
        case (0, -1, 1, 0): self = .left
        case (-1, 0, 0, -1): self = .down
        case (-1, 0, 0, 1): self = .upMirrored
        case (1, 0, 0, -1): self = .downMirrored
        case (0, 1, 1, 0): self = .leftMirrored
        case (0, -1, -1, 0): self = .rightMirrored
        default: self = .up
        }
    }

    /// Whether it turns the frame a quarter: its width and height swap.
    public var turnsSideways: Bool {
        switch self {
        case .left, .right, .leftMirrored, .rightMirrored: true
        default: false
        }
    }
}

/// When a clip plays, as its edit says: the parts of it kept, each at its rate (its speed, and slower where it's slow
/// motion), one after another. A time on the clip goes to a time it's played at and back. The trimmer, the player,
/// the slow-motion bar and the export all read it.
public struct HangarClipTiming: Hashable, Sendable {
    /// A part of the clip, in its own seconds, and how fast it plays (1 as shot, 0.5 at half speed).
    public struct Part: Hashable, Sendable {
        public var range: HangarTimeRange
        public var rate: Double

        /// How long it takes to play.
        public var played: Double { range.duration / rate }
    }

    public let parts: [Part]

    /// The clip `info` describes with `edit`: its kept part (all of it unless `trimmed`), at its speed, slower where
    /// it's slow motion.
    public init(_ edit: HangarClipEdit, info: HangarClipInfo, trimmed: Bool = true) {
        let kept = trimmed ? edit.kept(of: info.duration) : HangarTimeRange(0, info.duration)
        let speed = min(max(edit.speed, 0.1), 10)
        var parts: [Part] = []
        let slow = info.isSlowMotion ? (edit.slowMotion ?? .standard(for: info)) : nil
        if let slow, slow.range.duration > 0, slow.range.end > kept.start, slow.range.start < kept.end {
            let start = max(slow.range.start, kept.start), end = min(slow.range.end, kept.end)
            if start > kept.start { parts.append(Part(range: HangarTimeRange(kept.start, start), rate: speed)) }
            parts.append(Part(range: HangarTimeRange(start, end), rate: speed * min(max(slow.rate, 0.01), 1)))
            if end < kept.end { parts.append(Part(range: HangarTimeRange(end, kept.end), rate: speed)) }
        } else {
            parts.append(Part(range: kept, rate: speed))
        }
        self.parts = parts.filter { $0.range.duration > 0 }.isEmpty ? [Part(range: kept, rate: speed)] : parts.filter { $0.range.duration > 0 }
    }

    /// The clip's seconds it covers.
    public var range: HangarTimeRange {
        HangarTimeRange(parts.first?.range.start ?? 0, parts.last?.range.end ?? 0)
    }

    /// How long it plays.
    public var duration: Double {
        parts.reduce(0) { $0 + $1.played }
    }

    /// When a time on the clip is played, from the start of what's played (held within it).
    public func played(at time: Double) -> Double {
        var at = 0.0
        for part in parts {
            if time <= part.range.end {
                return at + max(time - part.range.start, 0) / part.rate
            }
            at += part.played
        }
        return at
    }

    /// The time on the clip played at `played`, from the start of what's played (held within it).
    public func time(at played: Double) -> Double {
        var at = 0.0
        for part in parts {
            if played <= at + part.played {
                return part.range.start + max(played - at, 0) * part.rate
            }
            at += part.played
        }
        return range.end
    }
}

public extension HangarEdit {
    /// How a step that's a clip changes the clip's timing (`add(_:timing:)`).
    enum ClipTiming: Sendable {
        /// As long as the one before, frame for frame (upscaled, changed in words): the trim and slow part kept.
        case kept
        /// Another length (continued): the trim and slow part let go.
        case new
        /// The one before played backwards, `duration` long: the same part kept, mirrored.
        case reversed(duration: Double)
    }

    /// A step that's a clip (`HangarStep.clip`): the clip from then on. What's drawn on it is kept, as its frames
    /// are the same shape; its timing as `timing` says.
    mutating func add(_ step: HangarStep, timing: ClipTiming) {
        steps.append(step)
        switch timing {
        case .kept: break
        case .new:
            clip.trim = nil
            clip.slowMotion = nil
        case .reversed(let duration):
            clip.trim = clip.trim?.mirrored(in: duration)
            if let slow = clip.slowMotion { clip.slowMotion = HangarSlowMotion(range: slow.range.mirrored(in: duration), rate: slow.rate) }
        }
    }

    /// The clip as its steps make it: the last step's that's a clip (in `assets`), or `source`.
    func clipSource(_ source: URL, assets: (any HangarAssets)?) -> URL {
        guard let assets, let step = steps.last(where: \.clip), let id = step.asset, let file = assets.file(id) else { return source }
        return file
    }
}
