import HangarCore
import UIKit

/// A brush in the Tools mode (`HangarToolsModule`): painted over the picture, then what it paints over made again by
/// something else (a model on a server, something on the device), only the painted part kept. Photos' Clean Up is
/// one (`cleanUp`): it works as the finger lifts. One that asks for words (`words`) gathers strokes until they're
/// sent with what's to be done there: an edit of a part of the picture, as Flowith's draw-area edit is.
public struct HangarBrush: Sendable {
    public var id: String
    public var name: String
    public var symbol: String
    /// What it says over the picture while it's chosen and nothing's painted (Photos' Clean Up: "Tap, brush, or
    /// circle what you want to remove. Pinch to pan and zoom."), and while it works ("Cleaning up your photo…").
    public var hint: String
    public var working: String
    /// Asks for words before it works, nil to work as soon as a finger lifts.
    public var words: HangarWords?
    /// The paint on the marked picture a model's given (`HangarBrushRequest.marked`).
    public var mark: CGColor
    /// The picture's longer side given to it, at most; its own if nil.
    public var longestSide: CGFloat?
    /// Whether what it makes has its tones met to the picture's round the paint (`HangarRetouch.matchTones`): for
    /// a model that redraws the whole picture, and may cast it warmer or darker.
    public var matchesTones: Bool
    /// What it makes: one picture, or several takes (the first used), the request's picture's shape. Off the main
    /// thread; cancelled with the editor's Cancel.
    public var make: @Sendable (HangarBrushRequest) async throws -> [CGImage]

    public init(id: String, name: String, symbol: String, hint: String, working: String, words: HangarWords? = nil,
                mark: CGColor = HangarRetouch.mark, longestSide: CGFloat? = nil, matchesTones: Bool = true,
                make: @escaping @Sendable (HangarBrushRequest) async throws -> [CGImage]) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.hint = hint
        self.working = working
        self.words = words
        self.mark = mark
        self.longestSide = longestSide
        self.matchesTones = matchesTones
        self.make = make
    }

    /// Photos' Clean Up: what's painted taken out, the scene drawn in its place, as the finger lifts. What takes it
    /// out is the app's (a model's inpainting, given `marked` and Flowith's eraser words, or `mask`).
    public static func cleanUp(longestSide: CGFloat? = nil, matchesTones: Bool = true,
                               make: @escaping @Sendable (HangarBrushRequest) async throws -> [CGImage]) -> HangarBrush {
        HangarBrush(id: "cleanUp", name: "Clean Up", symbol: "eraser",
                    hint: "Tap, brush, or circle what you want to remove. Pinch to pan and zoom.",
                    working: "Cleaning up your photo…", longestSide: longestSide, matchesTones: matchesTones, make: make)
    }
}

/// What a brush that asks for words asks: a placeholder for them, and words to start from.
public struct HangarWords: Sendable {
    public var placeholder: String
    public var suggestions: [HangarSuggestion]

    public init(placeholder: String, suggestions: [HangarSuggestion] = []) {
        self.placeholder = placeholder
        self.suggestions = suggestions
    }
}

/// Words to start from: a title, and what it puts in the field (after what's there).
public struct HangarSuggestion: Sendable {
    public var title: String
    public var symbol: String?
    public var words: String

    public init(title: String, symbol: String? = nil, words: String) {
        self.title = title
        self.symbol = symbol
        self.words = words
    }
}

/// What a brush's step keeps of what it was asked (`HangarStep.parameters`): its strokes and words, to make it again.
struct BrushAsked: Codable {
    var brush: String
    var strokes: [HangarStroke]
    var words: String?
}
