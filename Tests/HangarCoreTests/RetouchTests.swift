import CoreGraphics
import CoreImage
import Foundation
import Testing
@testable import HangarCore

/// A picture whose every pixel says where it is: red its x, green its y (0 to 1 across it), in linear light.
private func coded(_ size: CGSize) -> CIImage {
    let x = CIFilter(name: "CILinearGradient", parameters: [
        "inputPoint0": CIVector(x: 0, y: 0), "inputPoint1": CIVector(x: size.width, y: 0),
        "inputColor0": CIColor(red: 0, green: 0, blue: 0), "inputColor1": CIColor(red: 1, green: 0, blue: 0),
    ])!.outputImage!
    // Core Image's y goes up: green 0 at the top.
    let y = CIFilter(name: "CILinearGradient", parameters: [
        "inputPoint0": CIVector(x: 0, y: size.height), "inputPoint1": CIVector(x: 0, y: 0),
        "inputColor0": CIColor(red: 0, green: 0, blue: 0), "inputColor1": CIColor(red: 0, green: 1, blue: 0),
    ])!.outputImage!
    return x.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: y]).cropped(to: CGRect(origin: .zero, size: size))
}

/// The linear colour at a point given from the top left (y down).
private func linear(_ image: CIImage, _ p: CGPoint) -> [Float] {
    var pixel = [Float](repeating: 0, count: 4)
    let at = CGRect(x: image.extent.minX + floor(p.x), y: image.extent.maxY - floor(p.y) - 1, width: 1, height: 1)
    HangarRenderer.context.render(image, toBitmap: &pixel, rowBytes: 16, bounds: at, format: .RGBAf, colorSpace: nil)
    return pixel
}

/// The colour at a point from the top left of a picture (sRGB, 0 to 1).
private func colour(_ image: CGImage, _ x: Int, _ y: Int) -> [Double] {
    var p = [UInt8](repeating: 0, count: 4)
    let context = CGContext(data: &p, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
    return p.map { Double($0) / 255 }
}

private func plain(_ r: Double, _ g: Double, _ b: Double, width: Int, height: Int) -> CGImage {
    let image = CIImage(color: CIColor(red: r, green: g, blue: b)).cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
    return HangarRenderer.context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))!
}

struct RetouchTests {
    // MARK: A point on the picture shown, back on the picture

    /// Every kind of shape, alone and together.
    static let shapes: [HangarGeometry] = {
        var crop = HangarGeometry()
        crop.crop = CGRect(x: 0.1, y: 0.2, width: 0.5, height: 0.6)
        var all = HangarGeometry(straighten: 0.12, vertical: 0.15, horizontal: -0.1)
        let size = CGSize(width: 400, height: 300)
        all.crop = HangarGeometry.unit(HangarFit.scaled(CGRect(x: -120, y: -80, width: 200, height: 150), into: all.outline(for: size)), size)
        all.turns = 3
        all.flipped = true
        var cropped = crop
        cropped.turns = 1
        return [HangarGeometry(), crop, HangarGeometry(straighten: 0.2), HangarGeometry(vertical: 0.2), HangarGeometry(horizontal: -0.25),
                HangarGeometry(turns: 1), HangarGeometry(turns: 2), HangarGeometry(flipped: true), cropped, all]
    }()

    @Test(arguments: shapes) func aPointShownIsWhereThePictureIs(_ g: HangarGeometry) {
        let size = CGSize(width: 400, height: 300)
        let out = g.apply(to: coded(size))
        let shown = out.extent.size
        for fx in [0.2, 0.5, 0.8] as [CGFloat] {
            for fy in [0.25, 0.5, 0.75] as [CGFloat] {
                // A pixel's middle on the shown picture, and what it shows of the picture.
                let s = CGPoint(x: floor(fx * shown.width) + 0.5, y: floor(fy * shown.height) + 0.5)
                let c = linear(out, s)
                let p = g.picturePoint(s, size: size)
                #expect(abs(CGFloat(c[0]) * size.width - p.x) < 1.5, "x at \(s) in \(g)")
                #expect(abs(CGFloat(c[1]) * size.height - p.y) < 1.5, "y at \(s) in \(g)")
                // And there and back again.
                let back = g.shownPoint(p, size: size)
                #expect(abs(back.x - s.x) < 0.01 && abs(back.y - s.y) < 0.01)
            }
        }
    }

    // MARK: Paint

    @Test func strokesPaintTheirWidth() throws {
        let size = CGSize(width: 200, height: 100)
        // Across the middle, a tenth of the shorter side wide (10 pixels); and a dot.
        let mask = try #require(HangarRetouch.mask([
            HangarStroke(points: [CGPoint(x: 0.1, y: 0.5), CGPoint(x: 0.6, y: 0.5)], width: 0.1),
            HangarStroke(points: [CGPoint(x: 0.85, y: 0.2)], width: 0.2),
        ], size: size))
        #expect(mask.width == 200 && mask.height == 100)
        #expect(colour(mask, 60, 50)[0] > 0.99)
        #expect(colour(mask, 60, 53)[0] > 0.99)
        #expect(colour(mask, 60, 58)[0] < 0.01)
        #expect(colour(mask, 150, 50)[0] < 0.01)
        #expect(colour(mask, 170, 20)[0] > 0.99)
        #expect(colour(mask, 170, 32)[0] < 0.01)
    }

    @Test func whatsKeptIsALittleWiderAndSoft() throws {
        let size = CGSize(width: 400, height: 400)
        let painted = try #require(HangarRetouch.mask([HangarStroke(points: [CGPoint(x: 0.5, y: 0.5)], width: 0.1)], size: size))
        let kept = try #require(HangarRetouch.kept(painted))
        // The paint whole (its edge 20 out), 2% (8 pixels) past it nearly, then fading, far off none.
        #expect(colour(kept, 200, 200)[0] > 0.99)
        #expect(colour(kept, 219, 200)[0] > 0.97)
        #expect(colour(kept, 226, 200)[0] > 0.3)
        #expect(colour(kept, 240, 200)[0] < 0.02)
        #expect(colour(kept, 50, 50)[0] < 0.01)
    }

    @Test func theMarkedPictureIsMarkedOnlyWherePainted() throws {
        let picture = plain(0.5, 0.5, 0.5, width: 100, height: 100)
        let request = try HangarToolRequest.painted(picture, strokes: [HangarStroke(points: [CGPoint(x: 0.5, y: 0.5)], width: 0.2)], words: "red")
        let marked = try #require(request.marked)
        let under = colour(marked, 50, 50)
        #expect(under[2] > under[0] + 0.15, "blue over the grey")
        let off = colour(marked, 10, 10)
        #expect(abs(off[0] - 0.5) < 0.02 && abs(off[2] - 0.5) < 0.02)
        #expect(request.words == "red")
        // Nothing painted: all of it, nothing marked.
        let whole = try HangarToolRequest.painted(picture, strokes: [], words: "red")
        #expect(whole.mask == nil && whole.marked == nil)
        #expect(throws: HangarRetouchError.self) { try HangarRetouch.made([picture], for: whole) }
    }

    // MARK: Laid back

    @Test func aMadePictureOfAnotherShapeIsRefused() throws {
        let picture = plain(0.5, 0.5, 0.5, width: 100, height: 100)
        let request = try HangarToolRequest.painted(picture, strokes: [HangarStroke(points: [CGPoint(x: 0.5, y: 0.5)], width: 0.2)])
        #expect(throws: HangarRetouchError.self) { try HangarRetouch.made([plain(1, 0, 0, width: 120, height: 100)], for: request) }
        #expect(throws: HangarRetouchError.self) { try HangarRetouch.made([], for: request) }
        // Another size, the same shape: made the picture's.
        let made = try HangarRetouch.made([plain(1, 0, 0, width: 50, height: 51)], for: request, matchingTones: false)
        #expect(made.takes[0].width == 100 && made.takes[0].height == 100)
        #expect(made.mask.width == 100 && made.mask.height == 100)
    }

    @Test func aCastIsUndoneRoundThePaint() throws {
        // A grey picture; what comes back is cast warmer and darker all over, red where it was painted.
        let size = 200
        let picture = plain(0.5, 0.5, 0.5, width: size, height: size)
        let strokes = [HangarStroke(points: [CGPoint(x: 0.5, y: 0.5)], width: 0.2)]
        let request = try HangarToolRequest.painted(picture, strokes: strokes)
        let cast = CIImage(cgImage: plain(0.55, 0.45, 0.33, width: size, height: size))
        let red = CIImage(color: CIColor(red: 0.9, green: 0.1, blue: 0.1)).cropped(to: CGRect(x: 90, y: 90, width: 20, height: 20))
        let back = HangarRenderer.context.createCGImage(red.composited(over: cast), from: cast.extent, format: .RGBA8,
                                                        colorSpace: CGColorSpace(name: CGColorSpace.sRGB))!
        let made = try HangarRetouch.made([back], for: request)
        // Just inside what's kept, past the paint: the picture's grey again, not the cast.
        let seam = colour(made.takes[0], 100, 100 - 26)
        #expect(abs(seam[0] - 0.5) < 0.04 && abs(seam[1] - 0.5) < 0.04 && abs(seam[2] - 0.5) < 0.04, "\(seam)")
        // The middle still red, nearly as it came (only the cast taken off it).
        let middle = colour(made.takes[0], 100, 100)
        #expect(middle[0] > 0.7 && middle[1] < 0.3 && middle[2] < 0.35, "\(middle)")
        // Without matching, the cast stays.
        let unmatched = try HangarRetouch.made([back], for: request, matchingTones: false)
        #expect(colour(unmatched.takes[0], 100, 74)[2] < 0.4)
    }

    @Test func aClearPartStaysClear() throws {
        // A picture with its background out: matching tones keeps what's clear, clear.
        let w = 100
        let subject = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: CGRect(x: 0, y: 0, width: 50, height: w))
        let picture = HangarRenderer.context.createCGImage(subject, from: CGRect(x: 0, y: 0, width: w, height: w), format: .RGBA8,
                                                           colorSpace: CGColorSpace(name: CGColorSpace.sRGB))!
        let request = try HangarToolRequest.painted(picture, strokes: [HangarStroke(points: [CGPoint(x: 0.4, y: 0.5)], width: 0.2)])
        let made = try HangarRetouch.made([picture], for: request)
        #expect(colour(made.takes[0], 90, 50)[3] < 0.01)
        #expect(colour(made.takes[0], 20, 50)[3] > 0.99)
    }

    @Test func aStrokesBoundsAreItsWidthRoundIt() {
        let stroke = HangarStroke(points: [CGPoint(x: 0.5, y: 0.5)], width: 0.1)
        // On a picture twice as wide as high, its width (a tenth of the height) is a twentieth of the width.
        let box = stroke.bounds(aspect: 2)
        #expect(abs(box.width - 0.05) < 1e-9 && abs(box.height - 0.1) < 1e-9)
    }
}

/// The other tools' steps: text, more round it, a part made the whole, the picture made again.
struct ToolStepTests {
    @Test func aStepKeptBeforeTheFlagsOpensLaidByItsMask() throws {
        let json = #"{"tool":"cleanUp","takes":["a"],"take":0,"frame":[[0,0],[1,1]],"mask":"m"}"#
        let step = try JSONDecoder().decode(HangarStep.self, from: Data(json.utf8))
        #expect(step.masked && !step.replaces && step.mask == "m")
        let again = try JSONDecoder().decode(HangarStep.self, from: JSONEncoder().encode(HangarStep(tool: "t", takes: ["a"], masked: false, replaces: true)))
        #expect(!again.masked && again.replaces)
    }

    @Test func aStepSwitchedToItsWholeResultIsLaidWhole() throws {
        let assets = HangarMemoryAssets()
        let picture = CIImage(cgImage: plain(0.5, 0.5, 0.5, width: 100, height: 100))
        let red = try assets.keep(plain(1, 0, 0, width: 100, height: 100))
        // Kept only on the left half.
        let left = try assets.keep(try #require(HangarRetouch.mask(boxes: [CGRect(x: 0, y: 0, width: 0.5, height: 1)], size: CGSize(width: 100, height: 100))))
        var edit = HangarEdit()
        edit.add(HangarStep(tool: "t", takes: [red], mask: left))
        let renderer = HangarRenderer(assets: assets)
        func at(_ x: Int) throws -> [Double] {
            let out = renderer.base(edit, picture)
            return colour(try #require(HangarRenderer.context.createCGImage(out, from: out.extent)), x, 50)
        }
        #expect(try at(20)[0] > 0.95 && at(80)[0] < 0.6)
        edit.steps[0].masked = false
        #expect(try at(20)[0] > 0.95 && at(80)[0] > 0.95)
    }

    @Test func aPartMadeTheWholeIsThePictureFromThenOn() throws {
        let assets = HangarMemoryAssets()
        let picture = CIImage(cgImage: plain(0.5, 0.5, 0.5, width: 400, height: 300))
        let part = try assets.keep(plain(0, 0, 1, width: 320, height: 240))
        var edit = HangarEdit()
        edit.geometry.crop = CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5)
        edit.geometry.aspect = HangarRatio(1, 1)
        edit.geometry.straighten = 0.1
        edit.add(HangarStep(tool: "closeUp", takes: [part], replaces: true))
        #expect(edit.geometry.crop == nil && edit.geometry.aspect == nil && edit.geometry.straighten == 0.1)
        #expect(edit.steps[0].changesShape)
        let out = HangarRenderer(assets: assets).base(edit, picture)
        #expect(out.extent.size == CGSize(width: 320, height: 240))
    }

    @Test func textIsAskedInItsBoxes() throws {
        let picture = plain(0.5, 0.5, 0.5, width: 200, height: 100)
        let request = try HangarToolRequest.text(picture, changes: [HangarTextChange(box: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.2), from: "OPEN", to: "SHUT")])
        let mask = try #require(request.mask)
        #expect(colour(mask, 50, 30)[0] > 0.99)
        #expect(colour(mask, 50, 60)[0] < 0.01)
        #expect(colour(mask, 100, 30)[0] < 0.01)
        #expect(request.texts.first?.to == "SHUT")
    }

    @Test func moreRoundThePictureKeepsItsPixelsAndMeetsItsTones() throws {
        // A grey picture made half as wide again to the right: what comes back is cast warmer and darker all over.
        let picture = plain(0.5, 0.5, 0.5, width: 200, height: 100)
        let frame = CGRect(x: 0, y: 0, width: 1.5, height: 1)
        let request = try HangarToolRequest.extend(picture, to: frame)
        let canvas = try #require(request.canvas)
        #expect(canvas.width == 300 && canvas.height == 100)
        #expect(colour(canvas, 100, 50)[0] > 0.45 && colour(canvas, 100, 50)[0] < 0.55)
        let asked = try #require(request.mask)
        #expect(colour(asked, 250, 50)[0] > 0.99 && colour(asked, 150, 50)[0] < 0.01)
        let cast = CIImage(cgImage: plain(0.55, 0.42, 0.3, width: 300, height: 100))
        let back = HangarRenderer.context.createCGImage(cast, from: cast.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))!
        let made = try HangarRetouch.extended([back], for: request)
        // The mask: the picture's own pixels kept (black) well inside it, what's drawn (white) past it.
        #expect(colour(made.mask, 100, 50)[0] < 0.01)
        #expect(colour(made.mask, 260, 50)[0] > 0.99)
        // Just past the picture, its grey, not the cast.
        let seam = colour(made.takes[0], 205, 50)
        #expect(abs(seam[0] - 0.5) < 0.05 && abs(seam[2] - 0.5) < 0.05, "\(seam)")
        // Laid: the picture's grey where it was, larger.
        let assets = HangarMemoryAssets()
        var edit = HangarEdit()
        edit.add(HangarStep(tool: "extend", takes: [try assets.keep(made.takes[0])], frame: frame, mask: try assets.keep(made.mask)))
        let out = HangarRenderer(assets: assets).base(edit, CIImage(cgImage: picture))
        #expect(out.extent.size == CGSize(width: 300, height: 100))
        let laid = try #require(HangarRenderer.context.createCGImage(out, from: out.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)))
        let kept = colour(laid, 100, 50)
        #expect(abs(kept[0] - 0.5) < 0.02 && abs(kept[2] - 0.5) < 0.02, "\(kept)")
        #expect(throws: HangarRetouchError.self) { try HangarRetouch.extended([plain(1, 0, 0, width: 200, height: 100)], for: request) }
    }

    @Test func whatsMadeWholeIsCutToThePicturesShape() throws {
        let made = try HangarRetouch.shaped([plain(1, 0, 0, width: 1536, height: 1024)], like: CGSize(width: 400, height: 300))
        #expect(made[0].width == 1365 && made[0].height == 1024)
        let same = try HangarRetouch.shaped([plain(1, 0, 0, width: 800, height: 600)], like: CGSize(width: 400, height: 300))
        #expect(same[0].width == 800)
    }

    @Test func aPartIsCutFromThePicture() throws {
        let request = try HangarToolRequest.part(plain(0.5, 0.5, 0.5, width: 400, height: 200), region: CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5))
        #expect(request.part?.width == 200 && request.part?.height == 100)
    }

    @Test func aNewAngleAtRestIsThePicture() {
        let size = CGSize(width: 400, height: 300)
        let corners = HangarReframe.corners([:], size: size)
        #expect(corners == [CGPoint(x: 0, y: 0), CGPoint(x: 400, y: 0), CGPoint(x: 400, y: 300), CGPoint(x: 0, y: 300)])
        // Turned right: its right side nearer, so taller.
        let turned = HangarReframe.corners(["horizontal": 1], size: size)
        #expect(turned[2].y - turned[1].y > turned[3].y - turned[0].y)
        // Twice as near.
        let near = HangarReframe.corners(["zoom": 1], size: size)
        #expect(abs(near[0].x + 200) < 0.01 && abs(near[2].x - 600) < 0.01)
        let out = HangarReframe.apply(CIImage(cgImage: plain(0.5, 0.5, 0.5, width: 400, height: 300)), values: ["horizontal": 0.5, "zoom": -0.5])
        #expect(out.extent == CGRect(origin: .zero, size: size))
    }

    @Test func aLightIsBrighterNearIt() throws {
        let image = CIImage(cgImage: plain(0.5, 0.5, 0.5, width: 200, height: 200))
        let lit = HangarRelight.apply(image, values: ["x": 0.1, "y": 0.1, "intensity": 0.8, "warmth": 0.5])
        let out = try #require(HangarRenderer.context.createCGImage(lit, from: lit.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)))
        let near = colour(out, 20, 20), far = colour(out, 190, 190)
        #expect(near[0] > far[0] + 0.2)
        // Warm: more red than blue near it.
        #expect(near[0] > near[2] + 0.05)
        // Unlit, it's the picture.
        let none = HangarRelight.apply(image, values: ["intensity": 0])
        let flat = try #require(HangarRenderer.context.createCGImage(none, from: none.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)))
        #expect(abs(colour(flat, 100, 100)[0] - 0.5) < 0.02)
    }
}

extension HangarGeometry: CustomTestStringConvertible {
    public var testDescription: String {
        "straighten \(straighten) vertical \(vertical) horizontal \(horizontal) crop \(crop.map { "\($0)" } ?? "none") turns \(turns) flipped \(flipped)"
    }
}
