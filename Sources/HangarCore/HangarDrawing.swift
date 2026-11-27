import CoreGraphics
import CoreImage
import Foundation

/// Something drawn on a picture: a line a finger drew (a pen), a shape dragged out, or a stroke of the eraser taking
/// out what was drawn under it (never the picture). Its points are where it is, 0 to 1 each way from the picture's top
/// left (the picture under the edit's geometry, as its steps make it: a crop later keeps it on what it was drawn on),
/// its width as much of the picture's shorter side, its colour "#RRGGBB" ("#RRGGBBAA" for one you see through).
///
/// It's kept as a stroke is (`HangarStroke`, as Flowith's web canvas keeps one) with what it is beside it:
/// `{"kind": "arrow", "points": [{"x", "y"}], "widthRatio", "color"}`. A stroke with no kind is a pen's.
///
/// A pen's and the eraser's points are the line, in order (one point is a dot). A line's and an arrow's are its two
/// ends (the arrow's head at the second). A shape's are its box: two opposite corners (the box upright on the
/// picture), or the box's top left, top right and bottom left as it was shown (on a picture shown turned or
/// straightened, the shape upright as it was drawn). The shapes fill their box (`outline`).
public struct HangarMark: Hashable, Sendable, Codable {
    public enum Kind: String, Hashable, Sendable, Codable, CaseIterable {
        case pen, line, arrow, rectangle, ellipse, triangle, diamond, star, heart, eraser

        /// Dragged out by two corners or two ends, not drawn along.
        public var isShape: Bool { self != .pen && self != .eraser }
        /// Its points are two ends rather than a box.
        public var isLine: Bool { self == .line || self == .arrow }
    }

    public var kind: Kind
    public var stroke: HangarStroke

    public init(_ kind: Kind, points: [CGPoint], width: CGFloat, color: String? = nil) {
        self.kind = kind
        stroke = HangarStroke(points: points, width: width, color: color)
    }

    public init(_ kind: Kind = .pen, stroke: HangarStroke) {
        self.kind = kind
        self.stroke = stroke
    }

    public var points: [CGPoint] {
        get { stroke.points }
        set { stroke.points = newValue }
    }

    private enum CodingKeys: String, CodingKey {
        case kind
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // A kind this version doesn't know is drawn as a pen's line through its points: seen, not lost.
        kind = (try? container.decodeIfPresent(Kind.self, forKey: .kind)) ?? .pen
        stroke = try HangarStroke(from: decoder)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try stroke.encode(to: encoder)
    }

    // MARK: Its outline

    /// Where it's drawn on a picture of `size` (its pixels from its top left, y down): lines through points, each
    /// closed or not, drawn `lineWidth` wide with round ends and corners. The one place what each kind looks like is
    /// said, for anything that draws one (the web canvas draws the same lines).
    ///
    /// - A pen, the eraser: one line through its points.
    /// - A line: its two ends. An arrow: that and a head at its second end, two lines back from it 30° each side of
    ///   it, 4 widths long (no more than 45% of the arrow).
    /// - In the box (0 to 1 each way from its top left): a rectangle its edges; an ellipse inside them; a triangle
    ///   (½, 0), (1, 1), (0, 1); a diamond the edges' middles; a five-pointed star, its points on the ellipse, the
    ///   first at the top, the corners between them 0.382 of the way in (a regular star's); a heart from (½, 0.3)
    ///   round to the left as the curves in `heartCurves` go and back.
    /// - Nothing for a shape whose box has no size, or a line with no length.
    public func outline(size: CGSize) -> [Outline] {
        let pixels = points.map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) }
        guard let first = pixels.first else { return [] }
        switch kind {
        case .pen, .eraser:
            return [Outline(points: pixels.count == 1 ? [first, first] : pixels, closed: false)]
        case .line, .arrow:
            guard pixels.count >= 2, distance(first, pixels[1]) > 0.5 else { return [] }
            let (from, to) = (first, pixels[1])
            var lines = [Outline(points: [from, to], closed: false)]
            if kind == .arrow {
                let along = distance(from, to)
                let head = min(4 * lineWidth(size: size), along * 0.45)
                let back = atan2(from.y - to.y, from.x - to.x)
                let side = { (turn: CGFloat) in CGPoint(x: to.x + head * cos(back + turn), y: to.y + head * sin(back + turn)) }
                lines.append(Outline(points: [side(.pi / 6), to, side(-.pi / 6)], closed: false))
            }
            return lines
        default:
            guard let box = box(pixels), box.across.length > 0.5, box.down.length > 0.5 else { return [] }
            let unit: [CGPoint]
            switch kind {
            case .rectangle: unit = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1)]
            case .ellipse: unit = (0..<96).map { i in
                    let a = CGFloat(i) / 96 * 2 * .pi
                    return CGPoint(x: 0.5 + 0.5 * cos(a), y: 0.5 + 0.5 * sin(a))
                }
            case .triangle: unit = [CGPoint(x: 0.5, y: 0), CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1)]
            case .diamond: unit = [CGPoint(x: 0.5, y: 0), CGPoint(x: 1, y: 0.5), CGPoint(x: 0.5, y: 1), CGPoint(x: 0, y: 0.5)]
            case .star: unit = (0..<10).map { i in
                    let a = -CGFloat.pi / 2 + CGFloat(i) * .pi / 5
                    let r: CGFloat = i % 2 == 0 ? 0.5 : 0.5 * Self.starInner
                    return CGPoint(x: 0.5 + r * cos(a), y: 0.5 + r * sin(a))
                }
            default: unit = Self.heart
            }
            return [Outline(points: unit.map(box.place), closed: true)]
        }
    }

    /// How wide it's drawn on a picture of `size`, in its pixels.
    public func lineWidth(size: CGSize) -> CGFloat {
        max(stroke.width * min(size.width, size.height), 0.5)
    }

    /// A line it's drawn along: closed back to its first point, or not.
    public struct Outline: Hashable, Sendable {
        public var points: [CGPoint]
        public var closed: Bool
    }

    /// A regular five-pointed star's inner corners, as far out as its points.
    public static let starInner: CGFloat = 0.381966

    /// The heart's curves in its box (0 to 1 each way, y down), each from where the last ended: from (½, 0.3) up and
    /// round its left lobe, down to its point at the bottom, up round its right lobe and back.
    public static let heartCurves: [(CGPoint, CGPoint, CGPoint)] = [
        (CGPoint(x: 0.5, y: 0.12), CGPoint(x: 0.38, y: 0), CGPoint(x: 0.25, y: 0)),
        (CGPoint(x: 0.1, y: 0), CGPoint(x: 0, y: 0.12), CGPoint(x: 0, y: 0.3)),
        (CGPoint(x: 0, y: 0.55), CGPoint(x: 0.25, y: 0.75), CGPoint(x: 0.5, y: 1)),
        (CGPoint(x: 0.75, y: 0.75), CGPoint(x: 1, y: 0.55), CGPoint(x: 1, y: 0.3)),
        (CGPoint(x: 1, y: 0.12), CGPoint(x: 0.9, y: 0), CGPoint(x: 0.75, y: 0)),
        (CGPoint(x: 0.62, y: 0), CGPoint(x: 0.5, y: 0.12), CGPoint(x: 0.5, y: 0.3)),
    ]

    /// The heart's curves as points, 24 along each.
    private static let heart: [CGPoint] = {
        var points: [CGPoint] = []
        var from = CGPoint(x: 0.5, y: 0.3)
        for (c1, c2, to) in heartCurves {
            for i in 0..<24 {
                let t = CGFloat(i) / 24, u = 1 - t
                points.append(CGPoint(x: u * u * u * from.x + 3 * u * u * t * c1.x + 3 * u * t * t * c2.x + t * t * t * to.x,
                                      y: u * u * u * from.y + 3 * u * u * t * c1.y + 3 * u * t * t * c2.y + t * t * t * to.y))
            }
            from = to
        }
        return points
    }()

    /// A shape's box from its points (in pixels): its top left and its edges along and down, as vectors.
    private func box(_ pixels: [CGPoint]) -> Box? {
        if pixels.count >= 3 {
            let corner = pixels[0]
            return Box(corner: corner, across: Vector(pixels[1].x - corner.x, pixels[1].y - corner.y),
                       down: Vector(pixels[2].x - corner.x, pixels[2].y - corner.y))
        }
        guard pixels.count == 2 else { return nil }
        let (a, b) = (pixels[0], pixels[1])
        return Box(corner: CGPoint(x: min(a.x, b.x), y: min(a.y, b.y)), across: Vector(abs(b.x - a.x), 0), down: Vector(0, abs(b.y - a.y)))
    }

    private struct Vector {
        var dx: CGFloat
        var dy: CGFloat
        init(_ dx: CGFloat, _ dy: CGFloat) {
            self.dx = dx
            self.dy = dy
        }

        var length: CGFloat { (dx * dx + dy * dy).squareRoot() }
    }

    private struct Box {
        var corner: CGPoint
        var across: Vector
        var down: Vector

        func place(_ unit: CGPoint) -> CGPoint {
            CGPoint(x: corner.x + unit.x * across.dx + unit.y * down.dx, y: corner.y + unit.x * across.dy + unit.y * down.dy)
        }
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        ((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y)).squareRoot()
    }

    // MARK: Colours

    /// A colour as it's kept: "#RGB", "#RRGGBB" or "#RRGGBBAA" (either case), in sRGB; nil if it isn't one.
    public static func color(_ hex: String) -> CGColor? {
        var digits = hex.trimmingCharacters(in: .whitespaces)
        if digits.hasPrefix("#") { digits.removeFirst() }
        if digits.count == 3 { digits = digits.map { "\($0)\($0)" }.joined() }
        guard digits.count == 6 || digits.count == 8, let value = UInt64(digits, radix: 16) else { return nil }
        let rgba = digits.count == 6 ? value << 8 | 0xFF : value
        let part = { (shift: UInt64) in CGFloat((rgba >> shift) & 0xFF) / 255 }
        return CGColor(srgbRed: part(24), green: part(16), blue: part(8), alpha: part(0))
    }

    /// A colour as it's kept ("#RRGGBB", "#RRGGBBAA" if it's at all see-through), from sRGB.
    public static func hex(_ color: CGColor) -> String {
        let srgb = color.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil) ?? color
        let c = srgb.components ?? [0, 0, 0, 1]
        let rgba = c.count >= 4 ? c : [c[0], c[0], c[0], c.count > 1 ? c[1] : 1]
        let byte = { (v: CGFloat) in Int((min(max(v, 0), 1) * 255).rounded()) }
        let rgb = String(format: "#%02X%02X%02X", byte(rgba[0]), byte(rgba[1]), byte(rgba[2]))
        return byte(rgba[3]) < 255 ? rgb + String(format: "%02X", byte(rgba[3])) : rgb
    }
}

/// What's drawn on a picture, in the order it was (the eraser taking out what's before it): a layer over the picture
/// as the edit shows it, its geometry's, never touching its pixels or tinted by its adjustments and filter.
/// Kept as `{"marks": [...]}`.
public struct HangarDrawing: Hashable, Sendable, Codable {
    public var marks: [HangarMark]

    public init(marks: [HangarMark] = []) {
        self.marks = marks
    }

    /// Whether anything's left to see (an eraser with nothing before it isn't).
    public var isEmpty: Bool {
        !marks.contains { $0.kind != .eraser }
    }

    /// Draws the marks into `context` (y down) for a picture of `size`, each point placed by `place` (where a point
    /// of the picture, in its pixels, goes in the context: the identity for the picture itself) and each line
    /// `scale` times its width there. The eraser clears what's drawn before it in the context: draw into one of its
    /// own (a transparency layer over anything else).
    public func draw(in context: CGContext, size: CGSize, scale: CGFloat = 1, place: (CGPoint) -> CGPoint = { $0 }) {
        context.saveGState()
        defer { context.restoreGState() }
        context.setLineCap(.round)
        context.setLineJoin(.round)
        for mark in marks {
            let outlines = mark.outline(size: size)
            guard !outlines.isEmpty else { continue }
            let path = CGMutablePath()
            for outline in outlines {
                path.addLines(between: outline.points.map(place))
                if outline.closed { path.closeSubpath() }
            }
            context.setLineWidth(mark.lineWidth(size: size) * scale)
            if mark.kind == .eraser {
                context.setBlendMode(.clear)
                context.setStrokeColor(CGColor(gray: 0, alpha: 1))
            } else {
                context.setBlendMode(.normal)
                context.setStrokeColor(mark.stroke.color.flatMap(HangarMark.color) ?? CGColor(gray: 1, alpha: 1))
            }
            context.addPath(path)
            context.strokePath()
        }
    }

    /// The marks on a clear picture of `size` (in pixels), in sRGB; nil if there's nothing to see.
    public func image(size: CGSize) -> CGImage? {
        let width = Int(size.width.rounded()), height = Int(size.height.rounded())
        guard !isEmpty, width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        draw(in: context, size: CGSize(width: width, height: height))
        return context.makeImage()
    }

    /// The marks on a picture made larger by a step reaching `reach` (it being 0 to 1 each way), the picture
    /// `aspect` wide for each of its height before: on the same part of it, as wide on it.
    public mutating func reach(_ reach: CGRect, aspect: CGFloat?) {
        guard reach != HangarStep.whole else { return }
        // Their width's a share of the shorter side, which may now be another side, or longer.
        let shorter = aspect.map { a in min(a, 1) / min(a * reach.width, reach.height) } ?? 1
        for i in marks.indices {
            marks[i].points = marks[i].points.map { CGPoint(x: ($0.x - reach.minX) / reach.width, y: ($0.y - reach.minY) / reach.height) }
            marks[i].stroke.width *= shorter
        }
    }
}
