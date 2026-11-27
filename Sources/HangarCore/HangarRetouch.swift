import CoreGraphics
import CoreImage
import Foundation

/// A line a finger drew over a picture, kept as values so it can be drawn at any size: its points 0 to 1 each way
/// from the picture's top left (the picture under the edit's geometry, as its steps make it), and how wide it is, as
/// much of the picture's shorter side. A single point is a dot. Its colour, if it has one of its own ("#2440E6"),
/// for a mark of more than one colour.
///
/// It's kept as Flowith's web canvas keeps a stroke, and as its agent sends one:
/// `{"points": [{"x", "y"}], "widthRatio", "color"}`, its width the same share of the shorter side; one kept by an
/// older Hangar (`{"points": [[x, y]], "width"}`) still opens.
public struct HangarStroke: Hashable, Sendable, Codable {
    public var points: [CGPoint]
    public var width: CGFloat
    public var color: String?

    public init(points: [CGPoint], width: CGFloat, color: String? = nil) {
        self.points = points
        self.width = width
        self.color = color
    }

    private enum CodingKeys: String, CodingKey {
        case points, widthRatio, color, width
    }

    private struct Point: Codable {
        var x: CGFloat
        var y: CGFloat
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let points = try? container.decode([Point].self, forKey: .points) {
            self.points = points.map { CGPoint(x: $0.x, y: $0.y) }
        } else {
            points = try container.decode([CGPoint].self, forKey: .points)
        }
        width = try container.decodeIfPresent(CGFloat.self, forKey: .widthRatio) ?? container.decode(CGFloat.self, forKey: .width)
        color = try container.decodeIfPresent(String.self, forKey: .color)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(points.map { Point(x: $0.x, y: $0.y) }, forKey: .points)
        try container.encode(width, forKey: .widthRatio)
        try container.encodeIfPresent(color, forKey: .color)
    }

    /// The part of the picture it covers, 0 to 1 each way, its width round it.
    public func bounds(aspect: CGFloat) -> CGRect {
        guard let first = points.first else { return .null }
        var box = CGRect(origin: first, size: .zero)
        for point in points { box = box.union(CGRect(origin: point, size: .zero)) }
        // Its width is the shorter side's: as much of each side as that is.
        let half = width / 2
        let across = aspect >= 1 ? CGSize(width: half / aspect, height: half) : CGSize(width: half, height: half * aspect)
        return box.insetBy(dx: -across.width, dy: -across.height)
    }
}

/// A picture an app gives a tool to go by (a product to put in, a style to take), with its id in the app's store,
/// so the step can say which it was.
public struct HangarReference: @unchecked Sendable {
    public var id: String
    public var picture: CGImage

    public init(id: String, picture: CGImage) {
        self.id = id
        self.picture = picture
    }
}

/// Text found on a picture, and what it's to say instead: where it is, 0 to 1 each way from the picture's top left.
public struct HangarTextChange: Hashable, Sendable, Codable {
    public var box: CGRect
    public var from: String
    public var to: String

    public init(box: CGRect, from: String, to: String) {
        self.box = box
        self.from = from
        self.to = to
    }
}

/// What a tool asks of whatever makes its pictures (a model on a server, something on the device): the picture as
/// the edit's steps make it, and what was asked of it, as much as the tool asks. Where it's to change, if only a part
/// is (`mask`: white there, black not, the picture's size): what was painted (`strokes`, and the picture with the
/// paint on it as it was shown, `marked`, for a model that reads marks drawn on a picture), or the boxes of text to
/// say something else (`texts`). Words, and pictures to go by (`references`). More of the scene round it (`frame`,
/// and the picture on a canvas that size, `canvas`, where `mask` is white what's to be drawn). A part to make the
/// whole picture (`region`, `part`). Values set on the picture (a new camera angle, a light: `values`).
public struct HangarToolRequest: @unchecked Sendable {
    public let picture: CGImage
    public let mask: CGImage?
    public let marked: CGImage?
    public let strokes: [HangarStroke]
    public let words: String?
    public let references: [HangarReference]
    public let texts: [HangarTextChange]
    /// The picture's new edges, it being 0 to 1 each way: past them, to be drawn.
    public let frame: CGRect?
    public let canvas: CGImage?
    /// The part to be made the whole picture, 0 to 1 each way from its top left, and that part.
    public let region: CGRect?
    public let part: CGImage?
    public let values: [String: Double]

    private init(picture: CGImage, mask: CGImage? = nil, marked: CGImage? = nil, strokes: [HangarStroke] = [], words: String? = nil,
                 references: [HangarReference] = [], texts: [HangarTextChange] = [], frame: CGRect? = nil, canvas: CGImage? = nil,
                 region: CGRect? = nil, part: CGImage? = nil, values: [String: Double] = [:]) {
        self.picture = picture
        self.mask = mask
        self.marked = marked
        self.strokes = strokes
        self.words = words
        self.references = references
        self.texts = texts
        self.frame = frame
        self.canvas = canvas
        self.region = region
        self.part = part
        self.values = values
    }

    /// `strokes` over `picture` (none: all of it), the marked picture marked as `marking` says, as Flowith's web canvas
    /// marks a picture for its model. `shownWidth`: the picture's width as it was shown while it was painted, in
    /// points (the eraser's outline is so many of them).
    public static func painted(_ picture: CGImage, strokes: [HangarStroke], words: String? = nil, references: [HangarReference] = [],
                               marking: HangarMarking = .drawArea(), shownWidth: CGFloat) throws -> HangarToolRequest {
        guard !strokes.isEmpty else { return HangarToolRequest(picture: picture, words: words, references: references) }
        let size = CGSize(width: picture.width, height: picture.height)
        guard let mask = HangarRetouch.mask(strokes, size: size),
              let marked = HangarRetouch.marked(picture, strokes, marking: marking, shownWidth: shownWidth) else { throw HangarRetouchError.unpainted }
        return HangarToolRequest(picture: picture, mask: mask, marked: marked, strokes: strokes, words: words, references: references)
    }

    /// The text in `texts`' boxes to say what they say instead; `mask` the boxes.
    public static func text(_ picture: CGImage, changes texts: [HangarTextChange]) throws -> HangarToolRequest {
        guard !texts.isEmpty, let mask = HangarRetouch.mask(boxes: texts.map(\.box), size: CGSize(width: picture.width, height: picture.height))
        else { throw HangarRetouchError.unpainted }
        return HangarToolRequest(picture: picture, mask: mask, words: nil, texts: texts)
    }

    /// More of the scene round `picture`, out to `frame`: the picture on a canvas that size, grey round it,
    /// `mask` white where it's grey.
    public static func extend(_ picture: CGImage, to frame: CGRect, words: String? = nil) throws -> HangarToolRequest {
        let size = CGSize(width: picture.width, height: picture.height)
        guard frame.contains(HangarStep.whole.insetBy(dx: 1e-6, dy: 1e-6)), frame != HangarStep.whole,
              let laid = HangarRetouch.canvas(picture, frame: frame), let mask = HangarRetouch.mask(around: size, frame: frame, feather: 0)
        else { throw HangarRetouchError.unpainted }
        return HangarToolRequest(picture: picture, mask: mask, words: words, frame: frame, canvas: laid)
    }

    /// `region` of `picture` to be made the whole picture.
    public static func part(_ picture: CGImage, region: CGRect, words: String? = nil) throws -> HangarToolRequest {
        let w = CGFloat(picture.width), h = CGFloat(picture.height)
        let pixels = CGRect(x: region.minX * w, y: region.minY * h, width: region.width * w, height: region.height * h).integral
            .intersection(CGRect(x: 0, y: 0, width: w, height: h))
        guard !pixels.isEmpty, let part = picture.cropping(to: pixels) else { throw HangarRetouchError.unpainted }
        return HangarToolRequest(picture: picture, words: words, region: region, part: part)
    }

    /// The whole picture made again with `values` (`HangarReframe`'s, `HangarRelight`'s).
    public static func values(_ picture: CGImage, _ values: [String: Double], words: String? = nil) -> HangarToolRequest {
        HangarToolRequest(picture: picture, words: words, values: values)
    }
}

/// How strokes are marked on the picture a model's given (`HangarToolRequest.marked`), as Flowith's web canvas marks
/// them, for the model's words that name the marks.
public enum HangarMarking: Hashable, Sendable {
    /// The web's draw-area edit's: each stroke in its own colour, or this one, 45% through.
    case drawArea(color: String = HangarMarking.blue)
    /// The web's eraser's: each stroke white 72% through and 6 shown points wider, then blue 40% through.
    case eraser

    /// Flowith's blue.
    public static let blue = "#2440E6"
    /// The web canvas's draw-area colours to choose from.
    public static let colors = ["#2440E6", "#0F80F0", "#27A06E", "#FFBF00", "#FF4794", "#F04438"]

    /// How wide the brush goes on the screen, in points, and how wide it is at first: the web canvas's.
    public var brushWidths: ClosedRange<CGFloat> {
        switch self {
        case .drawArea: 8...64
        case .eraser: 8...48
        }
    }

    public static let firstBrushWidth: CGFloat = 36

    /// A colour written as the web writes it ("#2440E6"), opaque; Flowith's blue if it isn't one.
    public static func color(_ hex: String) -> CGColor {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return color(blue) }
        return CGColor(srgbRed: CGFloat(value >> 16 & 0xFF) / 255, green: CGFloat(value >> 8 & 0xFF) / 255,
                       blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }
}

/// What can go wrong laying what a brush made back over the picture.
public enum HangarRetouchError: LocalizedError, Sendable {
    /// Nothing was painted.
    case unpainted
    /// It came back another shape than the picture: it can't be laid back over it.
    case reshaped
    /// Nothing came back.
    case empty

    public var errorDescription: String? {
        switch self {
        case .unpainted: "Show what you want to change first."
        case .reshaped: "This edit changed the shape of the picture, so it can’t be laid back over it."
        case .empty: "Nothing came back for this edit. Try again."
        }
    }
}

/// Laying what was made from a painted part of a picture back over it: only the paint's part of it kept (a little
/// wider, its edge feathered), so a model that redrew the whole picture changes only where it was asked; and its
/// tones made to meet the picture's round that part, so a model that made the whole of it warmer or darker leaves
/// no seam (Flowith's "change only the painted area": its 2% wider, 2% feather and tone matching). Any thread.
public enum HangarRetouch {
    /// How much wider than the paint what's kept is, and how far its edge fades, of the picture's shorter side.
    public static let grow: CGFloat = 0.02
    public static let feather: CGFloat = 0.01
    /// How far a made picture's shape can be from the picture's (its width over its height, either way) and still be
    /// laid over it.
    public static let reshapeTolerance: CGFloat = 0.03

    /// The strokes drawn white on black, `size` pixels: where it was painted.
    public static func mask(_ strokes: [HangarStroke], size: CGSize) -> CGImage? {
        let w = Int(size.width.rounded()), h = Int(size.height.rounded())
        guard w > 0, h > 0, let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                                    space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: w, height: h))
        context.setFillColor(gray: 1, alpha: 1)
        context.setStrokeColor(gray: 1, alpha: 1)
        draw(strokes, in: context, size: CGSize(width: w, height: h), extra: 0)
        return context.makeImage()
    }

    /// Boxes (0 to 1 each way from the top left) drawn white on black, `size` pixels.
    public static func mask(boxes: [CGRect], size: CGSize) -> CGImage? {
        let w = Int(size.width.rounded()), h = Int(size.height.rounded())
        guard w > 0, h > 0, let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                                    space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: w, height: h))
        context.setFillColor(gray: 1, alpha: 1)
        for box in boxes {
            // The context's y goes up.
            context.fill(CGRect(x: box.minX * size.width, y: (1 - box.maxY) * size.height, width: box.width * size.width, height: box.height * size.height))
        }
        return context.makeImage()
    }

    /// A canvas `frame`'s size (a picture `size` being 0 to 1 each way in it), white round the picture and black on
    /// it: what's to be drawn. Its edge fades `feather` (of the picture's shorter side) into the picture, where the
    /// picture has more round it, so what's drawn meets the picture's pixels without a seam.
    public static func mask(around size: CGSize, frame: CGRect, feather: CGFloat) -> CGImage? {
        let canvas = CGSize(width: (frame.width * size.width).rounded(), height: (frame.height * size.height).rounded())
        guard canvas.width > 0, canvas.height > 0 else { return nil }
        // The picture on the canvas (Core Image's y going up).
        let p = CGRect(x: -frame.minX * size.width, y: (frame.maxY - 1) * size.height, width: size.width, height: size.height)
        let f = feather * min(size.width, size.height)
        let far = 4 * f + 4
        // The black inset by the fade on each side something's drawn past; past the canvas's edge where nothing is.
        let inner = CGRect(x: p.minX > 0.5 ? p.minX + f : -far, y: p.minY > 0.5 ? p.minY + f : -far,
                           width: 0, height: 0)
        let maxX = p.maxX < canvas.width - 0.5 ? p.maxX - f : canvas.width + far
        let maxY = p.maxY < canvas.height - 0.5 ? p.maxY - f : canvas.height + far
        let black = CGRect(x: inner.minX, y: inner.minY, width: max(0, maxX - inner.minX), height: max(0, maxY - inner.minY))
        let all = CGRect(origin: .zero, size: canvas)
        var out = CIImage(color: .black).cropped(to: black).composited(over: CIImage(color: .white).cropped(to: all.insetBy(dx: -far, dy: -far)))
        if f > 0 { out = out.applyingGaussianBlur(sigma: f / 3) }
        return HangarRenderer.context.createCGImage(out.cropped(to: all), from: all, format: .L8, colorSpace: CGColorSpaceCreateDeviceGray())
    }

    /// The picture on a canvas `frame`'s size, mid grey round it.
    static func canvas(_ picture: CGImage, frame: CGRect) -> CGImage? {
        let w = CGFloat(picture.width), h = CGFloat(picture.height)
        let size = CGSize(width: (frame.width * w).rounded(), height: (frame.height * h).rounded())
        guard size.width > 0, size.height > 0, let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                                                                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.setFillColor(gray: 0.5, alpha: 1)
        context.fill(CGRect(origin: .zero, size: size))
        context.draw(picture, in: CGRect(x: -frame.minX * w, y: (frame.maxY - 1) * h, width: w, height: h))
        return context.makeImage()
    }

    /// The picture with the strokes marked on it as Flowith's web canvas marks them (`marking`), stroke by stroke in
    /// the order they were drawn: pixel for pixel but for the picture's size. `shownWidth`: the picture's width as it
    /// was shown, in points.
    public static func marked(_ picture: CGImage, _ strokes: [HangarStroke], marking: HangarMarking, shownWidth: CGFloat) -> CGImage? {
        let w = picture.width, h = picture.height
        guard let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let size = CGSize(width: w, height: h)
        context.draw(picture, in: CGRect(origin: .zero, size: size))
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        let shorter = min(size.width, size.height)
        for stroke in strokes {
            let points = stroke.points.map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) }
            switch marking {
            case .drawArea(let color):
                // The draw-area edit's: the stroke's colour, the whole stroke 45% through.
                let width = max(1, stroke.width * shorter)
                context.setAlpha(0.45)
                mark(points, width: width, dot: width, color: HangarMarking.color(stroke.color ?? color), in: context)
                context.setAlpha(1)
            case .eraser:
                // The eraser's: white 6 shown points wider, then the blue (a dot's both its size: the blue over the white).
                let width = stroke.width * shorter
                let outline = 6 * size.width / max(shownWidth, 1)
                mark(points, width: width + outline, dot: width, color: CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.72), in: context)
                mark(points, width: width, dot: width, color: CGColor(srgbRed: 36 / 255, green: 64 / 255, blue: 230 / 255, alpha: 0.4), in: context)
            }
        }
        return context.makeImage()
    }

    /// One stroke as a canvas strokes a path (its own overlaps not twice), a single point a dot `dot` across.
    private static func mark(_ points: [CGPoint], width: CGFloat, dot: CGFloat, color: CGColor, in context: CGContext) {
        guard let first = points.first else { return }
        context.setFillColor(color)
        context.setStrokeColor(color)
        if points.count == 1 {
            context.fillEllipse(in: CGRect(x: first.x - dot / 2, y: first.y - dot / 2, width: dot, height: dot))
            return
        }
        context.setLineWidth(width)
        context.beginPath()
        context.addLines(between: points)
        context.strokePath()
    }

    private static func draw(_ strokes: [HangarStroke], in context: CGContext, size: CGSize, extra: CGFloat) {
        context.saveGState()
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        let shorter = min(size.width, size.height)
        for stroke in strokes {
            let width = max(1, stroke.width * shorter) + extra
            let points = stroke.points.map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) }
            guard let first = points.first else { continue }
            if points.count == 1 || points.dropFirst().allSatisfy({ hypot($0.x - first.x, $0.y - first.y) < 0.5 }) {
                context.fillEllipse(in: CGRect(x: first.x - width / 2, y: first.y - width / 2, width: width, height: width))
                continue
            }
            context.setLineWidth(width)
            context.beginPath()
            context.addLines(between: points)
            context.strokePath()
        }
        context.restoreGState()
    }

    /// Where what's made is kept: the paint `grow` wider and its edge feathered, the picture's size.
    public static func kept(_ painted: CGImage) -> CGImage? {
        let image = CIImage(cgImage: painted)
        let e = image.extent
        let shorter = min(e.width, e.height)
        let out = image.clampedToExtent()
            .applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: max(1, grow * shorter)])
            .applyingGaussianBlur(sigma: max(0.5, feather * shorter / 2))
            .cropped(to: e)
        return HangarRenderer.context.createCGImage(out, from: e, format: .L8, colorSpace: CGColorSpaceCreateDeviceGray())
    }

    /// What was made from `request`'s picture, laid back over the part it asked to change (`request.mask`: what
    /// was painted, the text's boxes): each take the picture's size (an error if it came back another shape), its
    /// tones met to the picture's round that part (`matchingTones`), kept only there (`kept`).
    /// `wholes`: each take as it came (the picture's size), for the step laid whole; none if its tones weren't met
    /// (the takes are as they came).
    public static func made(_ takes: [CGImage], for request: HangarToolRequest, matchingTones: Bool = true) throws -> (takes: [CGImage], mask: CGImage, wholes: [CGImage]) {
        guard !takes.isEmpty else { throw HangarRetouchError.empty }
        guard let asked = request.mask, let mask = kept(asked) else { throw HangarRetouchError.unpainted }
        let picture = request.picture
        let size = CGSize(width: picture.width, height: picture.height)
        let original = CIImage(cgImage: picture)
        let space = picture.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        var out: [CGImage] = [], wholes: [CGImage] = []
        for take in takes {
            let image = try fitted(take, to: size)
            let all = CGRect(origin: .zero, size: size)
            guard matchingTones else {
                out.append(try drawn(image, all, space))
                continue
            }
            out.append(try drawn(matchTones(image, to: original, inside: CIImage(cgImage: mask)), all, space))
            wholes.append(try drawn(image, all, space))
        }
        return (out, mask, wholes)
    }

    /// What was made from `request`'s canvas (`HangarToolRequest.extend`), laid round the picture: each take the
    /// canvas's size (an error if it came back another shape), the picture's own pixels kept on it, what's drawn
    /// round it met to its tones (`matchingTones`). Its frame is the request's.
    public static func extended(_ takes: [CGImage], for request: HangarToolRequest, matchingTones: Bool = true) throws -> (takes: [CGImage], mask: CGImage, wholes: [CGImage]) {
        guard !takes.isEmpty else { throw HangarRetouchError.empty }
        let picture = request.picture
        let size = CGSize(width: picture.width, height: picture.height)
        guard let frame = request.frame, let mask = mask(around: size, frame: frame, feather: extendFeather) else { throw HangarRetouchError.unpainted }
        let canvas = CGSize(width: mask.width, height: mask.height)
        // The picture where it is on the canvas, clear round it.
        let original = CIImage(cgImage: picture).transformed(by: CGAffineTransform(translationX: -frame.minX * size.width, y: (frame.maxY - 1) * size.height))
            .composited(over: CIImage(color: .clear).cropped(to: CGRect(origin: .zero, size: canvas)))
            .cropped(to: CGRect(origin: .zero, size: canvas))
        let space = picture.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let all = CGRect(origin: .zero, size: canvas)
        var out: [CGImage] = [], wholes: [CGImage] = []
        for take in takes {
            let image = try fitted(take, to: canvas)
            guard matchingTones else {
                out.append(try drawn(image, all, space))
                continue
            }
            out.append(try drawn(matchTones(image, to: original, inside: CIImage(cgImage: mask)), all, space))
            wholes.append(try drawn(image, all, space))
        }
        return (out, mask, wholes)
    }

    /// Extend's takes laid over the picture by its mask already, each the picture from then on (a step that
    /// `replaces` it); each as it was made beside them, if its tones were met.
    public static func extendedWhole(_ takes: [CGImage], for request: HangarToolRequest, matchingTones: Bool = true) throws -> (takes: [CGImage], wholes: [CGImage]) {
        let made = try extended(takes, for: request, matchingTones: matchingTones)
        guard let frame = request.frame else { throw HangarRetouchError.unpainted }
        let picture = CIImage(cgImage: request.picture), mask = CIImage(cgImage: made.mask)
        let space = request.picture.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let laid = try made.takes.map { take in
            let out = HangarRenderer.lay(CIImage(cgImage: take), mask: mask, in: frame, over: picture)
            return try drawn(out, out.extent, space)
        }
        return (laid, made.wholes)
    }

    /// How far into the picture what's drawn round it fades, of its shorter side.
    public static let extendFeather: CGFloat = 0.015

    /// What was made to be the whole of a picture `size`'s shape (the picture made again, or a part made the whole of
    /// it): each take at its own pixels, its middle cut to that shape if it came back another.
    public static func shaped(_ takes: [CGImage], like size: CGSize) throws -> [CGImage] {
        guard !takes.isEmpty else { throw HangarRetouchError.empty }
        let aspect = size.width / max(size.height, 1)
        return takes.map { take in
            let w = CGFloat(take.width), h = CGFloat(take.height)
            guard abs((w / h) / aspect - 1) > 0.002 else { return take }
            let cut = w / h > aspect
                ? CGRect(x: ((w - h * aspect) / 2).rounded(), y: 0, width: (h * aspect).rounded(), height: h)
                : CGRect(x: 0, y: ((h - w / aspect) / 2).rounded(), width: w, height: (w / aspect).rounded())
            return take.cropping(to: cut) ?? take
        }
    }

    private static func drawn(_ image: CIImage, _ rect: CGRect, _ space: CGColorSpace) throws -> CGImage {
        guard let out = HangarRenderer.context.createCGImage(image, from: rect, format: .RGBA8, colorSpace: space) else { throw HangarRetouchError.empty }
        return out
    }

    /// `take` scaled to `size`, if it's that shape.
    static func fitted(_ take: CGImage, to size: CGSize) throws -> CIImage {
        let image = CIImage(cgImage: take)
        let e = image.extent
        let ratio = (e.width / e.height) / (size.width / size.height)
        guard abs(ratio - 1) <= reshapeTolerance else { throw HangarRetouchError.reshaped }
        guard e.size != size else { return image }
        return image.clampedToExtent()
            .transformed(by: CGAffineTransform(scaleX: size.width / e.width, y: size.height / e.height))
            .cropped(to: CGRect(origin: .zero, size: size))
    }

    // MARK: Meeting the picture's tones

    /// How many cells the gains are worked out on, along the picture's longer side; how many times they're smoothed.
    static let grid = 256
    static let rounds = 500
    /// How far round the paint's edge a gain can be from their middle, either way, before it's pulled back to it.
    static let spread: Float = 0.1

    /// `made` with its tones met to `original`'s round `inside` (white where it's kept): Flowith's "simplified
    /// Poisson blend in log space". On a grid over the picture, each cell outside is the picture's light over the
    /// made one's, channel by channel (as logs); inside, the smoothest gains that meet those at its edge (Laplace's
    /// equation, by successive over-relaxation); the gains along the edge first held to within `spread` of their
    /// middle, so something the model moved beside the paint doesn't bleed its colour in. Then `made` times the
    /// gains: a model's cast over the whole picture undone at the seam, what it drew inside keeping its own colour.
    public static func matchTones(_ made: CIImage, to original: CIImage, inside: CIImage) -> CIImage {
        let e = made.extent
        let longer = max(e.width, e.height)
        let cells = CGSize(width: max(2, (e.width / longer * CGFloat(grid)).rounded()), height: max(2, (e.height / longer * CGFloat(grid)).rounded()))
        let w = Int(cells.width), h = Int(cells.height)
        guard let a = sample(original, cells), let b = sample(made, cells), let m = sample(inside, cells) else { return made }

        // The cells laid over (unknown) and the picture's cells with something of both in them (known).
        var unknown = [Bool](repeating: false, count: w * h)
        var gains = [[Float]](repeating: [Float](repeating: 0, count: w * h), count: 3)
        var usable = [Bool](repeating: false, count: w * h)
        for i in 0..<(w * h) {
            unknown[i] = m[i * 4] > 0.02
            let alphaA = a[i * 4 + 3], alphaB = b[i * 4 + 3]
            usable[i] = alphaA > 0.5 && alphaB > 0.5
            for c in 0..<3 where usable[i] {
                gains[c][i] = log((a[i * 4 + c] + 0.004) / (b[i * 4 + c] + 0.004))
            }
        }
        // The edge: known cells beside an unknown one.
        var edge: [Int] = []
        for y in 0..<h {
            for x in 0..<w {
                let i = y * w + x
                guard !unknown[i], usable[i] else { continue }
                let beside = [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)].contains { nx, ny in
                    nx >= 0 && ny >= 0 && nx < w && ny < h && unknown[ny * w + nx]
                }
                if beside { edge.append(i) }
            }
        }
        guard !edge.isEmpty else { return made }
        // The cells inside, each with its neighbours.
        var inside: [(Int, [Int])] = []
        for y in 0..<h {
            for x in 0..<w where unknown[y * w + x] {
                var around: [Int] = []
                if x > 0 { around.append(y * w + x - 1) }
                if x < w - 1 { around.append(y * w + x + 1) }
                if y > 0 { around.append(y * w + x - w) }
                if y < h - 1 { around.append(y * w + x + w) }
                inside.append((y * w + x, around))
            }
        }
        let limit = log(1 + spread)
        for c in 0..<3 {
            let sorted = edge.map { gains[c][$0] }.sorted()
            let middle = sorted[sorted.count / 2]
            for i in 0..<(w * h) where !unknown[i] {
                gains[c][i] = usable[i] ? min(max(gains[c][i], middle - limit), middle + limit) : middle
            }
            for i in 0..<(w * h) where unknown[i] { gains[c][i] = middle }
            // Laplace inside, the edge held: only the cells inside are worked on.
            let omega: Float = 1.9
            gains[c].withUnsafeMutableBufferPointer { g in
                for _ in 0..<rounds {
                    for (i, around) in inside {
                        var sum: Float = 0
                        for j in around { sum += g[j] }
                        g[i] += omega * (sum / Float(around.count) - g[i])
                    }
                }
            }
        }
        // The gains as a picture, laid over `made` at its size.
        var pixels = [Float](repeating: 1, count: w * h * 4)
        for i in 0..<(w * h) {
            for c in 0..<3 { pixels[i * 4 + c] = exp(gains[c][i]) }
        }
        let data = pixels.withUnsafeBufferPointer { Data(buffer: $0) }
        let field = CIImage(bitmapData: data, bytesPerRow: w * 16, size: cells, format: .RGBAf, colorSpace: nil)
            .transformed(by: CGAffineTransform(scaleX: e.width / cells.width, y: e.height / cells.height))
            .transformed(by: CGAffineTransform(translationX: e.minX, y: e.minY))
        let smooth = field.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: e.width / cells.width])
        // Its colours times the gains, its alpha as it was (a picture with its background taken out keeps it out).
        let opaque = made.applyingFilter("CIUnpremultiply").applyingFilter("CIColorMatrix", parameters: [
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1),
        ])
        let multiplied = opaque.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: smooth])
        return multiplied.applyingFilter("CIBlendWithAlphaMask", parameters: [
            kCIInputBackgroundImageKey: CIImage.empty(), kCIInputMaskImageKey: made,
        ]).cropped(to: e)
    }

    /// `image` drawn into `cells`, in linear light, its rows as Core Image's bitmaps have them (the gains are made
    /// back into a picture the same way, so which row is first doesn't matter).
    private static func sample(_ image: CIImage, _ cells: CGSize) -> [Float]? {
        let e = image.extent
        let scaled = image.clampedToExtent()
            .transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
            .applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: cells.height / e.height,
                                                                    kCIInputAspectRatioKey: (cells.width / e.width) / (cells.height / e.height)])
        let w = Int(cells.width), h = Int(cells.height)
        var out = [Float](repeating: 0, count: w * h * 4)
        out.withUnsafeMutableBytes { bytes in
            HangarRenderer.context.render(scaled, toBitmap: bytes.baseAddress!, rowBytes: w * 16,
                                          bounds: CGRect(origin: .zero, size: cells), format: .RGBAf, colorSpace: nil)
        }
        return out
    }
}
