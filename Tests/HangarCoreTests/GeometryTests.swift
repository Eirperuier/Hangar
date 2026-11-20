import CoreImage
import Foundation
import Testing
@testable import HangarCore

/// A picture 60 wide and 40 high, grey but for a red top left corner (10 square).
private func marked() -> CIImage {
    let grey = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: CGRect(x: 0, y: 0, width: 60, height: 40))
    // Core Image's y goes up: the top left is at the top of the extent.
    let red = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: CGRect(x: 0, y: 30, width: 10, height: 10))
    return red.composited(over: grey)
}

/// The colour at a point given from the top left (y down), as Core Image draws it.
private func colour(_ image: CIImage, x: CGFloat, y: CGFloat) -> (r: Double, g: Double, b: Double) {
    var pixel = [UInt8](repeating: 0, count: 4)
    let at = CGRect(x: image.extent.minX + x, y: image.extent.maxY - y - 1, width: 1, height: 1)
    HangarRenderer.context.render(image, toBitmap: &pixel, rowBytes: 4, bounds: at, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    return (Double(pixel[0]) / 255, Double(pixel[1]) / 255, Double(pixel[2]) / 255)
}

private func isRed(_ c: (r: Double, g: Double, b: Double)) -> Bool { c.r > 0.9 && c.g < 0.1 }

struct GeometryTests {
    @Test func untouchedIsThePicture() {
        let out = HangarGeometry().apply(to: marked())
        #expect(out.extent == CGRect(x: 0, y: 0, width: 60, height: 40))
        #expect(isRed(colour(out, x: 2, y: 2)))
    }

    @Test func aCropKeepsItsPart() {
        var g = HangarGeometry()
        g.crop = CGRect(x: 0, y: 0, width: 0.5, height: 0.5)
        let out = g.apply(to: marked())
        #expect(out.extent == CGRect(x: 0, y: 0, width: 30, height: 20))
        #expect(isRed(colour(out, x: 2, y: 2)))
        #expect(!isRed(colour(out, x: 25, y: 15)))
    }

    @Test func turnsGoLeftAndFlipsMirror() {
        var g = HangarGeometry()
        g.turns = 1
        var out = g.apply(to: marked())
        #expect(out.extent.size == CGSize(width: 40, height: 60))
        // Its top left goes to the bottom left, turned left.
        #expect(isRed(colour(out, x: 2, y: 57)))
        g.turns = 0
        g.flipped = true
        out = g.apply(to: marked())
        #expect(out.extent.size == CGSize(width: 60, height: 40))
        #expect(isRed(colour(out, x: 57, y: 2)))
        // The orientation the editor shows: the same.
        let corner = CGPoint(x: -30, y: -20).applying(HangarGeometry(turns: 1).orientation)
        #expect(corner.x < 0 && corner.y > 0)
    }

    @Test func toolsGoPhotosWay() {
        let size = CGSize(width: 300, height: 200)
        // Straighten turns it counter-clockwise: its top left corner comes down.
        let turned = HangarGeometry(straighten: 0.1).outline(for: size)
        #expect(turned[0].y > -100 + 5)
        // Vertical takes its top back, narrower than its bottom.
        let vertical = HangarGeometry(vertical: 0.3).outline(for: size)
        #expect(vertical[1].x - vertical[0].x < vertical[2].x - vertical[3].x - 10)
        // Horizontal brings its right side nearer, taller than its left.
        let horizontal = HangarGeometry(horizontal: 0.3).outline(for: size)
        #expect(horizontal[2].y - horizontal[1].y > horizontal[3].y - horizontal[0].y + 10)
        // Its middle stays where it was.
        let middle = HangarGeometry(vertical: 0.3, horizontal: -0.2).warp(for: size).apply(.zero)
        #expect(abs(middle.x) < 0.001 && abs(middle.y) < 0.001)
    }

    @Test func theCropStaysInThePicture() {
        let size = CGSize(width: 300, height: 200)
        for g in [HangarGeometry(straighten: 0.3), HangarGeometry(vertical: 0.4), HangarGeometry(straighten: -0.2, vertical: 0.2, horizontal: 0.3)] {
            let outline = g.outline(for: size)
            let fitted = g.fittedCrop(for: size)
            #expect(HangarFit.contains(outline, fitted))
            // The picture's own shape, as large as fits.
            #expect(abs(fitted.width / fitted.height - 1.5) < 0.001)
            #expect(!HangarFit.contains(outline, fitted.insetBy(dx: -2, dy: -2)))
            // Moved off the picture, it comes back in, as large as it was.
            let smaller = fitted.insetBy(dx: fitted.width * 0.05, dy: fitted.height * 0.05)
            let back = HangarFit.moved(smaller.offsetBy(dx: 80, dy: -40), into: outline)
            #expect(HangarFit.contains(outline, back, slack: 0.05))
            #expect(abs(back.width - smaller.width) < 0.01)
        }
        // A straightened crop drawn is the size it says.
        var g = HangarGeometry(straighten: 0.2)
        g.crop = HangarGeometry.unit(g.fittedCrop(for: CGSize(width: 60, height: 40)), CGSize(width: 60, height: 40))
        let out = g.apply(to: marked())
        #expect(out.extent.size == g.shownSize(for: CGSize(width: 60, height: 40)))
    }

    @Test func warpsUndo() {
        let warp = HangarGeometry(straighten: 0.2, vertical: 0.1, horizontal: -0.15).warp(for: CGSize(width: 400, height: 300))
        let p = CGPoint(x: 37, y: -81)
        let back = warp.inverted.apply(warp.apply(p))
        #expect(abs(back.x - p.x) < 0.001 && abs(back.y - p.y) < 0.001)
    }

    @Test func geometryKeepsAndOpensAgain() throws {
        var edit = HangarEdit()
        edit.geometry = HangarGeometry(straighten: 0.1, crop: CGRect(x: 0.1, y: 0.2, width: 0.5, height: 0.4), aspect: .square, turns: 3, flipped: true)
        #expect(!edit.isOriginal)
        let data = try JSONEncoder().encode(edit)
        #expect(try JSONDecoder().decode(HangarEdit.self, from: data) == edit)
        // An edit from before geometry opens untouched.
        let old = try JSONDecoder().decode(HangarEdit.self, from: Data(#"{"adjustments":{"exposure":0.2}}"#.utf8))
        #expect(old.geometry == .identity)
        // A tool switched off is drawn at 0.
        edit.geometry = HangarGeometry(straighten: 0.1)
        edit.switchedOff.insert(HangarGeometry.straightenID)
        #expect(edit.isOriginal)
    }
}
