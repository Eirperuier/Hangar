import CoreGraphics
import CoreImage
import Foundation
import Testing
@testable import HangarCore

/// A plain picture of a colour, `width` by `height`.
private func plain(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1, width: Int, height: Int) -> CGImage {
    let image = CIImage(color: CIColor(red: r, green: g, blue: b, alpha: a)).cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
    return HangarRenderer.context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))!
}

/// Grey, 60 by 40.
private let grey = CIImage(cgImage: plain(0.5, 0.5, 0.5, width: 60, height: 40))

/// The colour at a point from the top left (y down), with its alpha (not premultiplied).
private func pixel(_ image: CIImage, x: CGFloat, y: CGFloat) -> (r: Double, g: Double, b: Double, a: Double) {
    var p = [UInt8](repeating: 0, count: 4)
    let at = CGRect(x: image.extent.minX + x, y: image.extent.maxY - y - 1, width: 1, height: 1)
    HangarRenderer.context.render(image, toBitmap: &p, rowBytes: 4, bounds: at, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    let a = Double(p[3]) / 255
    guard a > 0 else { return (0, 0, 0, 0) }
    return (Double(p[0]) / 255 / a, Double(p[1]) / 255 / a, Double(p[2]) / 255 / a, a)
}

private func isBlue(_ c: (r: Double, g: Double, b: Double, a: Double)) -> Bool { c.b > 0.9 && c.r < 0.1 && c.a > 0.9 }
private func isGrey(_ c: (r: Double, g: Double, b: Double, a: Double)) -> Bool { abs(c.r - 0.5) < 0.05 && abs(c.b - 0.5) < 0.05 && c.a > 0.9 }

struct StepTests {
    let assets = HangarMemoryAssets()

    private func renderer() -> HangarRenderer { HangarRenderer(assets: assets) }

    @Test func aStepTakesItsPlace() throws {
        var edit = HangarEdit()
        edit.add(HangarStep(tool: "test", takes: [try assets.keep(plain(0, 0, 1, width: 60, height: 40))]))
        let out = renderer().base(edit, grey)
        #expect(out.extent == CGRect(x: 0, y: 0, width: 60, height: 40))
        #expect(isBlue(pixel(out, x: 5, y: 5)))
        #expect(!edit.isOriginal)
        // Without the store, it's left out.
        #expect(isGrey(pixel(HangarRenderer().base(edit, grey), x: 5, y: 5)))
    }

    @Test func aClearStepStaysClear() throws {
        // A background taken out: clear, not the picture under it.
        var edit = HangarEdit()
        edit.add(HangarStep(tool: "test", takes: [try assets.keep(plain(0, 0, 0, 0, width: 60, height: 40))]))
        #expect(pixel(renderer().base(edit, grey), x: 30, y: 20).a < 0.05)
    }

    @Test func aMaskKeepsTheRest() throws {
        // White on its left half: the step there, the picture before it on the right.
        let left = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 30, height: 40))
            .composited(over: CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: 60, height: 40)))
        let mask = HangarRenderer.context.createCGImage(left, from: left.extent)!
        var edit = HangarEdit()
        edit.add(HangarStep(tool: "test", takes: [try assets.keep(plain(0, 0, 1, width: 60, height: 40))], mask: try assets.keep(mask)))
        let out = renderer().base(edit, grey)
        #expect(isBlue(pixel(out, x: 10, y: 20)))
        #expect(isGrey(pixel(out, x: 50, y: 20)))
    }

    @Test func aLargerPictureKeepsItsPixels() throws {
        // Made twice as large: the whole picture is.
        var edit = HangarEdit()
        edit.add(HangarStep(tool: "upscale", takes: [try assets.keep(plain(0, 0, 1, width: 120, height: 80))]))
        #expect(renderer().base(edit, grey).extent == CGRect(x: 0, y: 0, width: 120, height: 80))
        // Part of it drawn at more pixels makes all of it larger, the rest as it was.
        var part = HangarEdit()
        part.add(HangarStep(tool: "test", takes: [try assets.keep(plain(0, 0, 1, width: 60, height: 40))],
                            frame: CGRect(x: 0, y: 0, width: 0.5, height: 0.5)))
        let out = renderer().base(part, grey)
        #expect(out.extent.size == CGSize(width: 120, height: 80))
        #expect(isBlue(pixel(out, x: 10, y: 10)))
        #expect(isGrey(pixel(out, x: 100, y: 70)))
    }

    @Test func moreRoundItKeepsTheCrop() throws {
        // Half as wide again on each side: 120 by 40, the old picture in its middle.
        var edit = HangarEdit()
        edit.geometry.crop = CGRect(x: 0, y: 0, width: 0.5, height: 1)
        edit.add(HangarStep(tool: "expand", takes: [try assets.keep(plain(0, 0, 1, width: 120, height: 40))],
                            frame: CGRect(x: -0.5, y: 0, width: 2, height: 1)))
        #expect(renderer().base(edit, grey).extent.size == CGSize(width: 120, height: 40))
        // The crop on the same part of the picture: its left half, now from a quarter in.
        let crop = try #require(edit.geometry.crop)
        #expect(abs(crop.minX - 0.25) < 1e-9 && abs(crop.width - 0.25) < 1e-9 && crop.height == 1)
    }

    @Test func aWholeRenderDrawsTheSteps() throws {
        var edit = HangarEdit()
        edit.add(HangarStep(tool: "test", takes: [try assets.keep(plain(0, 0, 1, width: 60, height: 40))]))
        edit.geometry.crop = CGRect(x: 0, y: 0, width: 0.5, height: 0.5)
        let out = try #require(renderer().render(edit, to: plain(0.5, 0.5, 0.5, width: 60, height: 40)))
        #expect(out.width == 30 && out.height == 20)
        #expect(isBlue(pixel(CIImage(cgImage: out), x: 5, y: 5)))
    }

    @Test func takesAndModesKeep() throws {
        var edit = HangarEdit()
        edit.add(HangarStep(tool: "vary", takes: ["a", "b"], take: 1, parameters: try HangarValue(["prompt": "night"])))
        edit.modules["markup"] = try HangarValue(["strokes": [[0.1, 0.2], [0.3, 0.4]]])
        let data = try JSONEncoder().encode(edit)
        let back = try JSONDecoder().decode(HangarEdit.self, from: data)
        #expect(back == edit)
        #expect(back.steps[0].asset == "b")
        #expect(back.steps[0].parameters?.decoded(as: [String: String].self) == ["prompt": "night"])
        #expect(back.modules["markup"]?.decoded(as: [String: [[Double]]].self) == ["strokes": [[0.1, 0.2], [0.3, 0.4]]])
        // An edit from before steps opens with none.
        let old = try JSONDecoder().decode(HangarEdit.self, from: Data(#"{"adjustments":{"exposure":0.2}}"#.utf8))
        #expect(old.steps.isEmpty && old.modules.isEmpty)
    }
}
