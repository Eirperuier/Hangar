import CoreGraphics
import CoreImage
import CoreText
import Foundation
import Hangar
import HangarCore
import PhotosUI
import UIKit

/// The example's tools, every one made on the device: what an app with no model of its own can do, so the tools can
/// be tried end to end. An app gives its models instead (a server's inpainting for Clean Up, given `request.marked`
/// or `request.mask`; an image model for the rest, given what each request carries). The prices are made up, to
/// show where an app's go.
extension HangarTool {
    /// Clean Up: what's painted filled from round it (a push-pull fill: the picture averaged down to coarser and
    /// coarser grids without the paint, then the paint filled back up from them).
    static let localCleanUp = HangarTool.cleanUp(longestSide: 1024, matchesTones: false) { request in
        try Task.checkCancellation()
        guard let hole = request.mask, let filled = PushPull.fill(request.picture, hole: hole) else { throw Failed.fill }
        return [filled]
    }

    /// An edit in words: the colour named (or a picture's to go by) laid over the part painted, or the whole
    /// picture; cast a little warmer all over, as a model may, so Hangar's meeting of the tones can be seen.
    static let localEdit = HangarTool.edit(words: HangarWords(placeholder: "Describe the change", suggestions: [
        HangarSuggestion(title: "Make It Red", symbol: "paintpalette", words: "make it red"),
        HangarSuggestion(title: "Make It Blue", symbol: "paintpalette", words: "make it blue"),
        HangarSuggestion(title: "Golden Hour", symbol: "sun.horizon", words: "golden hour light"),
    ]), price: "4 credits", longestSide: 1536, pickReference: pickPicture) { request in
        try await Task.sleep(for: .seconds(1.2))
        let colour = request.words.flatMap(named) ?? request.references.first.map { average($0.picture) } ?? CGColor(srgbRed: 0.85, green: 0.2, blue: 0.75, alpha: 1)
        let w = request.picture.width, h = request.picture.height
        let context = try canvas(w, h)
        let all = CGRect(x: 0, y: 0, width: w, height: h)
        context.draw(request.picture, in: all)
        context.setBlendMode(.multiply)
        context.setFillColor(red: 1, green: 0.94, blue: 0.84, alpha: 1)
        context.fill(all)
        if let mask = request.mask { context.clip(to: all, mask: mask) }
        context.setBlendMode(.color)
        context.setFillColor(colour.copy(alpha: request.mask == nil ? 0.45 : 0.9) ?? colour)
        context.fill(all)
        guard let out = context.makeImage() else { throw Failed.fill }
        return [out]
    }

    /// Text: each box covered in the colour round it, its new words written in it.
    static let localText = HangarTool.text(price: "4 credits", longestSide: 2048) { request in
        try await Task.sleep(for: .seconds(1))
        let w = request.picture.width, h = request.picture.height
        let pixels = try Pixels(request.picture)
        let context = try canvas(w, h)
        context.draw(request.picture, in: CGRect(x: 0, y: 0, width: w, height: h))
        for change in request.texts {
            let box = CGRect(x: change.box.minX * CGFloat(w), y: change.box.minY * CGFloat(h), width: change.box.width * CGFloat(w), height: change.box.height * CGFloat(h))
            let ground = pixels.ring(round: box.insetBy(dx: -3, dy: -3))
            // The context's y goes up.
            let flipped = CGRect(x: box.minX, y: CGFloat(h) - box.maxY, width: box.width, height: box.height)
            context.setFillColor(ground)
            context.fill(flipped.insetBy(dx: -box.height * 0.12, dy: -box.height * 0.12))
            guard !change.to.isEmpty else { continue }
            let light = (ground.components?.prefix(3).reduce(0, +) ?? 1.5) / 3 > 0.5
            let ink = CGColor(gray: light ? 0.08 : 0.97, alpha: 1)
            var size = box.height * 0.82
            var line = textLine(change.to, size: size, colour: ink)
            let width = CTLineGetTypographicBounds(line, nil, nil, nil)
            if width > box.width * 1.05 {
                size *= box.width * 1.05 / width
                line = textLine(change.to, size: size, colour: ink)
            }
            let drawn = CTLineGetTypographicBounds(line, nil, nil, nil)
            context.textPosition = CGPoint(x: flipped.midX - drawn / 2, y: flipped.midY - size * 0.36)
            CTLineDraw(line, context)
        }
        guard let out = context.makeImage() else { throw Failed.fill }
        return [out]
    }

    /// Extend: the canvas filled out from the picture's edges (the same push-pull fill as Clean Up's).
    static let localExtend = HangarTool.extend(words: HangarWords(placeholder: "What’s round it (optional)"), price: "3 credits",
                                               longestSide: 768, matchesTones: false) { request in
        try Task.checkCancellation()
        guard let canvas = request.canvas, let hole = request.mask, let filled = PushPull.fill(canvas, hole: hole) else { throw Failed.fill }
        return [filled]
    }

    /// Reframe: the picture seen from the new angle as the tool shows it, at its pixels.
    static let localReframe = HangarTool.reframe(price: "6 credits", longestSide: 2048) { request in
        try await Task.sleep(for: .seconds(0.8))
        return [try render(HangarReframe.apply(CIImage(cgImage: request.picture), values: request.values))]
    }

    /// Light: the picture lit as the tool shows it, at its pixels.
    static let localLight = HangarTool.light(price: "6 credits", longestSide: 2048) { request in
        try await Task.sleep(for: .seconds(0.8))
        return [try render(HangarRelight.apply(CIImage(cgImage: request.picture), values: request.values))]
    }

    /// Close-Up: the part made twice as large (up to 2048 pixels along it) and sharpened.
    static let localCloseUp = HangarTool.closeUp(price: "5 credits") { request in
        try await Task.sleep(for: .seconds(0.8))
        guard let part = request.part else { throw Failed.fill }
        let image = CIImage(cgImage: part)
        let scale = min(2, 2048 / max(image.extent.width, image.extent.height))
        let large = image.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: max(1, scale), kCIInputAspectRatioKey: 1])
            .applyingFilter("CISharpenLuminance", parameters: [kCIInputSharpnessKey: 0.6, kCIInputRadiusKey: 2])
        return [try render(large.cropped(to: large.extent.integral))]
    }

    static let local: [HangarTool] = [.localCleanUp, .localEdit, .localText, .localExtend, .localReframe, .localLight, .localCloseUp]

    // MARK: Helpers

    /// A picture to go by, picked from Photos over the editor.
    @MainActor static func pickPicture(_ over: UIViewController) async -> HangarReference? {
        await withCheckedContinuation { continuation in
            var configuration = PHPickerConfiguration()
            configuration.filter = .images
            let picker = PHPickerViewController(configuration: configuration)
            let delegate = PickOne { image in
                continuation.resume(returning: image.flatMap { $0.preparingThumbnail(of: CGSize(width: 1024, height: 1024 * $0.size.height / max($0.size.width, 1))) }
                    .flatMap(\.cgImage).map { HangarReference(id: UUID().uuidString, picture: $0) })
            }
            picker.delegate = delegate
            objc_setAssociatedObject(picker, &PickOne.key, delegate, .OBJC_ASSOCIATION_RETAIN)
            over.present(picker, animated: true)
        }
    }

    /// A colour named in the words, if one is.
    static func named(_ words: String) -> CGColor? {
        let w = words.lowercased()
        let colours: [(String, CGColor)] = [
            ("red", CGColor(srgbRed: 0.9, green: 0.12, blue: 0.1, alpha: 1)), ("blue", CGColor(srgbRed: 0.1, green: 0.35, blue: 0.95, alpha: 1)),
            ("green", CGColor(srgbRed: 0.15, green: 0.75, blue: 0.25, alpha: 1)), ("yellow", CGColor(srgbRed: 0.95, green: 0.85, blue: 0.1, alpha: 1)),
            ("golden", CGColor(srgbRed: 1, green: 0.7, blue: 0.25, alpha: 1)), ("purple", CGColor(srgbRed: 0.6, green: 0.2, blue: 0.85, alpha: 1)),
            ("orange", CGColor(srgbRed: 1, green: 0.5, blue: 0.1, alpha: 1)), ("pink", CGColor(srgbRed: 1, green: 0.4, blue: 0.7, alpha: 1)),
        ]
        return colours.first { w.contains($0.0) }?.1
    }

    /// A picture's colour on average.
    private static func average(_ picture: CGImage) -> CGColor {
        var p = [UInt8](repeating: 0, count: 4)
        let context = CGContext(data: &p, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        context?.interpolationQuality = .medium
        context?.draw(picture, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return CGColor(srgbRed: CGFloat(p[0]) / 255, green: CGFloat(p[1]) / 255, blue: CGFloat(p[2]) / 255, alpha: 1)
    }

    private static func canvas(_ w: Int, _ h: Int) throws -> CGContext {
        guard let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw Failed.fill }
        return context
    }

    private static func textLine(_ text: String, size: CGFloat, colour: CGColor) -> CTLine {
        CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
            .font: CTFontCreateWithName("HelveticaNeue-Bold" as CFString, size, nil), .foregroundColor: colour,
        ]))
    }

    private static func render(_ image: CIImage) throws -> CGImage {
        guard let out = CIContext().createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) else { throw Failed.fill }
        return out
    }
}

/// Upscale, in More: the picture made larger by Lanczos, as an app's model would make it with more detail.
extension HangarAction {
    static let upscale = HangarAction(title: "Upscale", symbol: "arrow.up.left.and.arrow.down.right.square", choices: [
        tier("2K", 2048, price: "2 credits"), tier("4K", 4096, price: "4 credits"), tier("8K", 8192, price: "8 credits"),
    ])

    private static func tier(_ name: String, _ longest: CGFloat, price: String) -> HangarAction {
        HangarAction(title: name, symbol: "arrow.up.left.and.arrow.down.right", price: price, job: HangarJob(tool: "upscale", name: "Upscaling to \(name)") { picture in
            let image = CIImage(cgImage: picture)
            let scale = longest / max(image.extent.width, image.extent.height)
            guard scale > 1.01 else { throw Failed.larger(name) }
            let large = image.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1])
            guard let out = CIContext().createCGImage(large, from: large.extent.integral, format: .RGBA8, colorSpace: picture.colorSpace)
            else { throw Failed.fill }
            return HangarMade(out)
        })
    }
}

private enum Failed: LocalizedError {
    case fill
    case larger(String)

    var errorDescription: String? {
        switch self {
        case .fill: "The picture couldn’t be made."
        case .larger(let name): "This photo is already \(name) or larger."
        }
    }
}

/// A picture's pixels, to read colours from.
private struct Pixels {
    let w: Int, h: Int
    let bytes: [UInt8]

    init(_ picture: CGImage) throws {
        let w = picture.width, h = picture.height
        self.w = w
        self.h = h
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.draw(picture, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { throw Failed.fill }
        self.bytes = bytes
    }

    /// The colour along a box's edge (from the top left), on average.
    func ring(round box: CGRect) -> CGColor {
        var sum = [0.0, 0.0, 0.0], n = 0.0
        let x0 = max(0, Int(box.minX)), x1 = min(w - 1, Int(box.maxX)), y0 = max(0, Int(box.minY)), y1 = min(h - 1, Int(box.maxY))
        guard x0 < x1, y0 < y1 else { return CGColor(gray: 0.5, alpha: 1) }
        func add(_ x: Int, _ y: Int) {
            let i = (y * w + x) * 4
            for c in 0..<3 { sum[c] += Double(bytes[i + c]) }
            n += 1
        }
        for x in stride(from: x0, through: x1, by: 2) { add(x, y0); add(x, y1) }
        for y in stride(from: y0, through: y1, by: 2) { add(x0, y); add(x1, y) }
        return CGColor(srgbRed: sum[0] / n / 255, green: sum[1] / n / 255, blue: sum[2] / n / 255, alpha: 1)
    }
}

/// Picks one picture, then lets go.
private final class PickOne: NSObject, PHPickerViewControllerDelegate {
    nonisolated(unsafe) static var key = 0
    private var done: ((UIImage?) -> Void)?

    init(_ done: @escaping (UIImage?) -> Void) {
        self.done = done
    }

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        guard let provider = results.first?.itemProvider, provider.canLoadObject(ofClass: UIImage.self) else { return finish(nil) }
        provider.loadObject(ofClass: UIImage.self) { [weak self] object, _ in
            let image = object as? UIImage
            DispatchQueue.main.async { self?.finish(image) }
        }
    }

    private func finish(_ image: UIImage?) {
        done?(image)
        done = nil
    }
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
