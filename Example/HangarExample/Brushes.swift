import CoreGraphics
import Foundation
import Hangar
import HangarCore

/// The example's brushes. Clean Up fills what's painted from round it, on the device (a push-pull fill: the picture
/// averaged down to coarser and coarser grids without the paint, then the paint filled back up from them, each finer
/// grid's own pixels kept where it has them). A model on a server does far better (`request.marked` with Flowith's
/// eraser words, or `request.mask`); this is what an app with none has.
extension HangarBrush {
    static let localCleanUp = HangarBrush.cleanUp(longestSide: 1024, matchesTones: false) { request in
        try Task.checkCancellation()
        guard let filled = PushPull.fill(request.picture, hole: request.mask) else { throw FillFailed() }
        return [filled]
    }

    #if DEBUG
    /// For the UI tests (`-testSteps 1`): a brush that asks for words, made the way a model's is. It paints its
    /// part the colour named (red, green, blue, yellow; magenta otherwise) and, as a model may, casts the whole
    /// picture warmer and darker: what Hangar keeps is the part, its cast undone round it.
    static let testEdit = HangarBrush(
        id: "testEdit", name: "Test Edit", symbol: "paintbrush.pointed", hint: "Brush over what to change, then say how.",
        working: "Testing…", words: HangarWords(placeholder: "Describe the change", suggestions: [
            HangarSuggestion(title: "Make It Red", symbol: "paintpalette", words: "red"),
            HangarSuggestion(title: "Make It Blue", symbol: "paintpalette", words: "blue"),
        ])
    ) { request in
        try await Task.sleep(for: .seconds(1.2))
        let words = request.words?.lowercased() ?? ""
        let colour: (CGFloat, CGFloat, CGFloat) = words.contains("red") ? (0.9, 0.1, 0.1) : words.contains("green") ? (0.1, 0.8, 0.2)
            : words.contains("blue") ? (0.1, 0.3, 0.95) : words.contains("yellow") ? (0.95, 0.85, 0.1) : (0.9, 0.1, 0.8)
        let w = request.picture.width, h = request.picture.height
        guard let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw FillFailed() }
        let all = CGRect(x: 0, y: 0, width: w, height: h)
        context.draw(request.picture, in: all)
        // The cast: warmer, darker, everywhere.
        context.setBlendMode(.multiply)
        context.setFillColor(red: 1, green: 0.9, blue: 0.72, alpha: 1)
        context.fill(all)
        // The part, the colour named.
        context.setBlendMode(.normal)
        context.clip(to: all, mask: request.mask)
        context.setFillColor(red: colour.0, green: colour.1, blue: colour.2, alpha: 1)
        context.fill(all)
        guard let out = context.makeImage() else { throw FillFailed() }
        return [out]
    }
    #endif
}

private struct FillFailed: LocalizedError {
    var errorDescription: String? { "The picture couldn’t be filled in." }
}

/// A push-pull fill: what's under `hole` (white) filled from round it.
enum PushPull {
    static func fill(_ picture: CGImage, hole: CGImage) -> CGImage? {
        let w = picture.width, h = picture.height
        guard let colours = pixels(picture, w, h, gray: false), let holes = pixels(hole, w, h, gray: true) else { return nil }
        // Each pixel's colour and how much it's known (not under the paint, a few pixels round it too).
        var level = Level(w: w, h: h)
        let grown = grow(holes, w, h, by: max(2, min(w, h) / 200))
        for i in 0..<(w * h) {
            let known: Float = grown[i] ? 0 : 1
            level.weight[i] = known
            for c in 0..<3 { level.colour[i * 3 + c] = Float(colours[i * 4 + c]) / 255 * known }
        }
        // Down: each coarser grid the sum of the four under it.
        var levels = [level]
        while levels.last!.w > 1 || levels.last!.h > 1 {
            let fine = levels.last!
            var coarse = Level(w: (fine.w + 1) / 2, h: (fine.h + 1) / 2)
            for y in 0..<fine.h {
                for x in 0..<fine.w {
                    let i = y * fine.w + x, j = (y / 2) * coarse.w + x / 2
                    coarse.weight[j] += fine.weight[i]
                    for c in 0..<3 { coarse.colour[j * 3 + c] += fine.colour[i * 3 + c] }
                }
            }
            // Held to whole pixels' worth, so a grid with all it needs doesn't count for more than one.
            for j in 0..<(coarse.w * coarse.h) where coarse.weight[j] > 1 {
                let s = 1 / coarse.weight[j]
                coarse.weight[j] = 1
                for c in 0..<3 { coarse.colour[j * 3 + c] *= s }
            }
            levels.append(coarse)
        }
        // Up: each finer grid's gaps filled from the coarser one, smoothly.
        for k in stride(from: levels.count - 2, through: 0, by: -1) {
            let coarse = levels[k + 1]
            var fine = levels[k]
            for y in 0..<fine.h {
                for x in 0..<fine.w {
                    let i = y * fine.w + x
                    let lack = 1 - min(fine.weight[i], 1)
                    guard lack > 0 else { continue }
                    let from = coarse.sample(x: (CGFloat(x) + 0.5) / 2 - 0.5, y: (CGFloat(y) + 0.5) / 2 - 0.5)
                    for c in 0..<3 { fine.colour[i * 3 + c] += from[c] * lack }
                    fine.weight[i] = 1
                }
            }
            levels[k] = fine
        }
        let top = levels[0]
        var out = colours
        for i in 0..<(w * h) where grown[i] {
            for c in 0..<3 { out[i * 4 + c] = UInt8(max(0, min(255, top.colour[i * 3 + c] * 255)).rounded()) }
            out[i * 4 + 3] = 255
        }
        let data = Data(out) as CFData
        guard let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    struct Level {
        let w: Int, h: Int
        var colour: [Float]
        var weight: [Float]

        init(w: Int, h: Int) {
            self.w = w
            self.h = h
            colour = [Float](repeating: 0, count: w * h * 3)
            weight = [Float](repeating: 0, count: w * h)
        }

        /// Its colour at a point between pixels, as known (its weight taken out), bilinearly.
        func sample(x: CGFloat, y: CGFloat) -> [Float] {
            let x0 = max(0, min(w - 1, Int(floor(x)))), y0 = max(0, min(h - 1, Int(floor(y))))
            let x1 = min(w - 1, x0 + 1), y1 = min(h - 1, y0 + 1)
            let fx = Float(max(0, min(1, x - CGFloat(x0)))), fy = Float(max(0, min(1, y - CGFloat(y0))))
            var out: [Float] = [0, 0, 0]
            var total: Float = 0
            for (px, py, f) in [(x0, y0, (1 - fx) * (1 - fy)), (x1, y0, fx * (1 - fy)), (x0, y1, (1 - fx) * fy), (x1, y1, fx * fy)] {
                let i = py * w + px
                let wt = weight[i] * f
                guard weight[i] > 0 else { continue }
                total += wt
                for c in 0..<3 { out[c] += colour[i * 3 + c] / weight[i] * wt }
            }
            return total > 0 ? out.map { $0 / total } : out
        }
    }

    private static func pixels(_ image: CGImage, _ w: Int, _ h: Int, gray: Bool) -> [UInt8]? {
        var out = [UInt8](repeating: 0, count: w * h * (gray ? 1 : 4))
        let drawn = out.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * (gray ? 1 : 4),
                                          space: gray ? CGColorSpaceCreateDeviceGray() : CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: gray ? CGImageAlphaInfo.none.rawValue : CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return drawn ? out : nil
    }

    /// The hole, `by` pixels wider (a square's reach: enough to leave the edge of what's painted out).
    private static func grow(_ hole: [UInt8], _ w: Int, _ h: Int, by r: Int) -> [Bool] {
        var rows = [Bool](repeating: false, count: w * h)
        // Across, then down.
        for y in 0..<h {
            var near = Int.min / 2
            var ahead = [Int](repeating: Int.max / 2, count: w)
            var next = Int.max / 2
            for x in stride(from: w - 1, through: 0, by: -1) {
                if hole[y * w + x] > 127 { next = x }
                ahead[x] = next
            }
            for x in 0..<w {
                if hole[y * w + x] > 127 { near = x }
                rows[y * w + x] = x - near <= r || ahead[x] - x <= r
            }
        }
        var out = [Bool](repeating: false, count: w * h)
        for x in 0..<w {
            var near = Int.min / 2
            var ahead = [Int](repeating: Int.max / 2, count: h)
            var next = Int.max / 2
            for y in stride(from: h - 1, through: 0, by: -1) {
                if rows[y * w + x] { next = y }
                ahead[y] = next
            }
            for y in 0..<h {
                if rows[y * w + x] { near = y }
                out[y * w + x] = y - near <= r || ahead[y] - y <= r
            }
        }
        return out
    }
}
