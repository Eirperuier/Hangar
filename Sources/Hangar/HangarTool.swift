import HangarCore
import UIKit
import Vision

/// A tool in the Tools mode (`HangarToolsModule`): what's asked of the picture shown over it (painted, a box drawn, a
/// frame pulled out, a camera moved, a light placed), then the picture made again by something else (a model on a
/// server, something on the device) and laid back as one step to undo. Hangar has nothing that makes pictures of its
/// own: the app gives each tool its maker (`make`), and a price to show if it asks one.
///
/// Photos' Clean Up (`cleanUp`), Extend (`extend`) and Reframe (`reframe`) are three; an edit in words (`edit`), the
/// text changed (`text`), a light (`light`) and a part made the whole picture (`closeUp`) are made the same way.
public struct HangarTool: Sendable {
    /// What's asked, and how what's made is laid back.
    public enum Kind: Sendable {
        /// Painted, made again as the finger lifts; only the painted part kept, its tones met to the picture's.
        case cleanUp
        /// Words (and pictures to go by) for the whole picture, or a part painted first: that part kept, as Clean
        /// Up's is; all of it if nothing was.
        case edit(HangarWords)
        /// The text found on the picture (`find`), each piece tapped and changed; only their boxes kept.
        case text(find: @Sendable (CGImage) async throws -> [HangarFoundText])
        /// A frame pulled out past the picture, words for what's to be there if it asks for them; the picture's own
        /// pixels kept, what's round it met to its tones.
        case extend(HangarWords?)
        /// A new camera angle (`HangarReframe`), shown as it's set; the whole picture made again.
        case reframe
        /// A light placed and set (`HangarRelight`), shown as it's set; the whole picture made again.
        case light
        /// A box over a part: that part made the whole picture, at more pixels.
        case closeUp
    }

    public var id: String
    public var name: String
    public var symbol: String
    public var kind: Kind
    /// What it says over the picture while it's chosen (Photos' Clean Up: "Tap, brush, or circle what you want to
    /// remove. Pinch to pan and zoom."), while it works ("Cleaning up your photo…"), and once it's done.
    public var hint: String
    public var working: String
    public var done: String?
    /// The button that sets it working, for a tool that has one ("EXTEND EDGES").
    public var action: String?
    /// What it costs, as the app says it ("90 credits"); nil for nothing shown.
    public var price: String?
    /// How the marked picture a model's given is marked (`HangarToolRequest.marked`), as the web canvas marks it for
    /// the same model; and how wide its brush goes.
    public var marking: HangarMarking
    /// The picture's longer side given to it, at most; its own if nil.
    public var longestSide: CGFloat?
    /// Whether what it makes has its tones met to the picture's round the part it changed (`HangarRetouch.matchTones`):
    /// for a model that redraws the whole picture, and may cast it warmer or darker.
    public var matchesTones: Bool
    /// Pictures to go by, for a tool in words: the app shows its own picker over the editor and gives back what was
    /// picked (nil: none offered).
    public var pickReference: (@MainActor (UIViewController) async -> HangarReference?)?
    /// What it makes: one picture or several takes (the first used). Off the main thread; cancelled with the
    /// editor's Cancel.
    public var make: @Sendable (HangarToolRequest) async throws -> [CGImage]

    public init(id: String, name: String, symbol: String, kind: Kind, hint: String, working: String, done: String? = nil,
                action: String? = nil, price: String? = nil, marking: HangarMarking = .drawArea(), longestSide: CGFloat? = nil,
                matchesTones: Bool = true, pickReference: (@MainActor (UIViewController) async -> HangarReference?)? = nil,
                make: @escaping @Sendable (HangarToolRequest) async throws -> [CGImage]) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.kind = kind
        self.hint = hint
        self.working = working
        self.done = done
        self.action = action
        self.price = price
        self.marking = marking
        self.longestSide = longestSide
        self.matchesTones = matchesTones
        self.pickReference = pickReference
        self.make = make
    }

    /// Photos' Clean Up: what's painted taken out, the scene drawn in its place, as the finger lifts. What takes it
    /// out is the app's (a model's inpainting, given `marked` and Flowith's eraser words, or `mask`).
    public static func cleanUp(price: String? = nil, longestSide: CGFloat? = nil, matchesTones: Bool = true,
                               make: @escaping @Sendable (HangarToolRequest) async throws -> [CGImage]) -> HangarTool {
        HangarTool(id: "cleanUp", name: "Clean Up", symbol: "eraser", kind: .cleanUp,
                   hint: "Tap, brush, or circle what you want to remove. Pinch to pan and zoom.",
                   working: "Cleaning up your photo…", done: "Objects in your scene have been removed. Tap and hold to see the original.",
                   price: price, marking: .eraser, longestSide: longestSide, matchesTones: matchesTones, make: make)
    }

    /// An edit in words: of the whole picture, or of a part painted first.
    public static func edit(words: HangarWords = HangarWords(placeholder: "Describe the change"), price: String? = nil,
                            longestSide: CGFloat? = nil, matchesTones: Bool = true,
                            pickReference: (@MainActor (UIViewController) async -> HangarReference?)? = nil,
                            make: @escaping @Sendable (HangarToolRequest) async throws -> [CGImage]) -> HangarTool {
        HangarTool(id: "edit", name: "Edit", symbol: "wand.and.rays", kind: .edit(words),
                   hint: "Say how to change the photo. Brush over a part first to change only that.",
                   working: "Editing your photo…", done: "Your photo has been edited. Tap and hold to see the original.",
                   price: price, longestSide: longestSide, matchesTones: matchesTones, pickReference: pickReference, make: make)
    }

    /// The text on the picture changed: found on the device (Vision, unless `find` is given), each piece tapped
    /// and said again.
    public static func text(price: String? = nil, longestSide: CGFloat? = nil, matchesTones: Bool = true,
                            find: @escaping @Sendable (CGImage) async throws -> [HangarFoundText] = HangarFoundText.recognize,
                            make: @escaping @Sendable (HangarToolRequest) async throws -> [CGImage]) -> HangarTool {
        HangarTool(id: "text", name: "Text", symbol: "textformat", kind: .text(find: find),
                   hint: "Tap the text you want to change.", working: "Changing the text…", done: "The text has been changed.",
                   action: "Change Text", price: price, longestSide: longestSide, matchesTones: matchesTones, make: make)
    }

    /// Photos' Extend: the frame pulled out past the picture, the scene drawn round it.
    public static func extend(words: HangarWords? = nil, price: String? = nil, longestSide: CGFloat? = nil, matchesTones: Bool = true,
                              make: @escaping @Sendable (HangarToolRequest) async throws -> [CGImage]) -> HangarTool {
        HangarTool(id: "extend", name: "Extend", symbol: "arrow.up.left.and.arrow.down.right", kind: .extend(words),
                   hint: "Drag the frame out, or choose a shape, to add more to your scene.",
                   working: "Extending your photo…", done: "Your photo has been extended.",
                   action: "Extend Edges", price: price, longestSide: longestSide, matchesTones: matchesTones, make: make)
    }

    /// Photos' Reframe: a new camera angle.
    public static func reframe(price: String? = nil, longestSide: CGFloat? = nil,
                               make: @escaping @Sendable (HangarToolRequest) async throws -> [CGImage]) -> HangarTool {
        HangarTool(id: "reframe", name: "Reframe", symbol: "camera.rotate", kind: .reframe,
                   hint: "Touch and drag to adjust the perspective. Use two fingers to pan, zoom, or rotate.",
                   working: "Reframing your photo…", done: "Your photo has been reframed.",
                   action: "Reframe", price: price, longestSide: longestSide, matchesTones: false, make: make)
    }

    /// A light placed on the picture.
    public static func light(price: String? = nil, longestSide: CGFloat? = nil,
                             make: @escaping @Sendable (HangarToolRequest) async throws -> [CGImage]) -> HangarTool {
        HangarTool(id: "light", name: "Light", symbol: "light.max", kind: .light,
                   hint: "Drag to place the light. Set how it looks below.",
                   working: "Relighting your photo…", done: "Your photo has been relit.",
                   action: "Relight", price: price, longestSide: longestSide, matchesTones: false, make: make)
    }

    /// A part of the picture made the whole of it, with the detail a closer look would have.
    public static func closeUp(price: String? = nil, longestSide: CGFloat? = nil,
                               make: @escaping @Sendable (HangarToolRequest) async throws -> [CGImage]) -> HangarTool {
        HangarTool(id: "closeUp", name: "Close-Up", symbol: "plus.magnifyingglass", kind: .closeUp,
                   hint: "Move and size the box over the part to bring close.",
                   working: "Bringing it close…", done: "That part is your photo now.",
                   action: "Close-Up", price: price, longestSide: longestSide, matchesTones: false, make: make)
    }

    /// Whether a finger paints with it.
    var paints: Bool {
        switch kind {
        case .cleanUp, .edit: true
        default: false
        }
    }

    /// The words it asks for, if it does.
    var words: HangarWords? {
        switch kind {
        case .edit(let words): words
        case .extend(let words): words
        default: nil
        }
    }

    /// The values it sets on the picture, shown as they're set.
    var parameters: [HangarParameter] {
        switch kind {
        case .reframe: HangarReframe.shown
        case .light: HangarRelight.shown
        default: []
        }
    }
}

/// What a tool in words asks: a placeholder for them, and words to start from.
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

/// Text found on a picture: what it says, and its box, 0 to 1 each way from the picture's top left.
public struct HangarFoundText: Hashable, Sendable {
    public var text: String
    public var box: CGRect

    public init(text: String, box: CGRect) {
        self.text = text
        self.box = box
    }

    /// The text Vision reads on the picture, line by line, in any language it knows.
    @Sendable public static func recognize(_ picture: CGImage) async throws -> [HangarFoundText] {
        try await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.automaticallyDetectsLanguage = true
            try VNImageRequestHandler(cgImage: picture).perform([request])
            return (request.results ?? []).compactMap { found -> HangarFoundText? in
                guard let text = found.topCandidates(1).first?.string, !text.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
                // Vision's y goes up.
                let b = found.boundingBox
                return HangarFoundText(text: text, box: CGRect(x: b.minX, y: 1 - b.maxY, width: b.width, height: b.height))
            }
        }.value
    }
}

/// What a tool's step keeps of what it was asked (`HangarStep.parameters`): to make it again, or open the tool as it
/// was.
struct ToolAsked: Codable {
    var tool: String
    var strokes: [HangarStroke] = []
    var words: String?
    var references: [String] = []
    var texts: [HangarTextChange] = []
    var frame: CGRect?
    var region: CGRect?
    var values: [String: Double] = [:]
}
