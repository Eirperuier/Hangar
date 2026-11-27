import CoreGraphics
import CoreImage
import Foundation

/// A line a finger drew over a picture, kept as values so it can be drawn at any size: its points 0 to 1 each way
/// from the picture's top left (the picture under the edit's geometry, as its steps make it), and how wide it is, as
/// much of the picture's shorter side. A single point is a dot.
public struct HangarStroke: Hashable, Sendable, Codable {
    public var points: [CGPoint]
    public var width: CGFloat

    public init(points: [CGPoint], width: CGFloat) {
        self.points = points
        self.width = width
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

/// What a brush asks of whatever makes its pictures (a model on a server, something on the device): the picture as
/// the edit's steps make it, where it was painted (a mask: white painted, black not, the picture's size), the
/// picture with the paint on it as it was shown (for a model that reads marks drawn on a picture), the strokes
/// themselves, and the words, for a brush that asks for them.
public struct HangarBrushRequest: @unchecked Sendable {
    public let picture: CGImage
    public let mask: CGImage
    public let marked: CGImage
    public let strokes: [HangarStroke]
    public let words: String?

    /// The request for `strokes` over `picture`, the marked picture's paint `mark`'s colour (see through it as
    /// much as its alpha says) outlined in white, as Flowith's draw-area edit marks a picture for its model.
    public init(picture: CGImage, strokes: [HangarStroke], words: String? = nil, mark: CGColor = HangarRetouch.mark) throws {
        guard !strokes.isEmpty else { throw HangarRetouchError.unpainted }
        self.picture = picture
        self.strokes = strokes
        self.words = words
        let size = CGSize(width: picture.width, height: picture.height)
        guard let mask = HangarRetouch.mask(strokes, size: size),
              let marked = HangarRetouch.marked(picture, strokes, mark: mark) else { throw HangarRetouchError.unpainted }
        self.mask = mask
        self.marked = marked
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
        case .unpainted: "Brush over what you want to change first."
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
    /// Flowith's mark for a draw-area edit: its blue, 45% through.
    public static let mark = CGColor(srgbRed: 0x24 / 255, green: 0x40 / 255, blue: 0xE6 / 255, alpha: 0.45)
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

    /// The picture with the strokes painted on it in `mark`, each outlined in white (3 points of the picture's
    /// thousand wider each side, as Flowith's eraser outlines its strokes).
    public static func marked(_ picture: CGImage, _ strokes: [HangarStroke], mark: CGColor) -> CGImage? {
        let w = picture.width, h = picture.height
        guard let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let size = CGSize(width: w, height: h)
        context.draw(picture, in: CGRect(origin: .zero, size: size))
        // Each stroke drawn whole then laid on (its overlaps not darker), as a canvas strokes a path.
        context.setAlpha(0.72)
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        context.setStrokeColor(gray: 1, alpha: 1)
        context.setFillColor(gray: 1, alpha: 1)
        draw(strokes, in: context, size: size, extra: 6 * min(size.width, size.height) / 1000)
        context.endTransparencyLayer()
        context.setAlpha(mark.alpha)
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        let solid = mark.copy(alpha: 1) ?? mark
        context.setStrokeColor(solid)
        context.setFillColor(solid)
        draw(strokes, in: context, size: size, extra: 0)
        context.endTransparencyLayer()
        return context.makeImage()
    }

    /// The strokes as round lines (y down, so flipped into the context's), each `extra` pixels wider.
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

    /// What was made from `request`'s picture, laid back over it: each take the picture's size (an error if it came
    /// back another shape), its tones met to the picture's round the paint (`matchingTones`), kept only where the
    /// paint was (`kept`).
    public static func made(_ takes: [CGImage], for request: HangarBrushRequest, matchingTones: Bool = true) throws -> (takes: [CGImage], mask: CGImage) {
        guard !takes.isEmpty else { throw HangarRetouchError.empty }
        guard let mask = kept(request.mask) else { throw HangarRetouchError.unpainted }
        let picture = request.picture
        let size = CGSize(width: picture.width, height: picture.height)
        let original = CIImage(cgImage: picture)
        let out = try takes.map { take -> CGImage in
            var image = try fitted(take, to: size)
            if matchingTones { image = matchTones(image, to: original, inside: CIImage(cgImage: mask)) }
            guard let made = HangarRenderer.context.createCGImage(image, from: CGRect(origin: .zero, size: size), format: .RGBA8,
                                                                  colorSpace: picture.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!)
            else { throw HangarRetouchError.empty }
            return made
        }
        return (out, mask)
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
