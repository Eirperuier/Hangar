import CoreGraphics
import CoreImage
import Foundation
import Testing
@testable import HangarCore

private func plain(_ r: Double, _ g: Double, _ b: Double, width: Int, height: Int) -> CGImage {
    let image = CIImage(color: CIColor(red: r, green: g, blue: b)).cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
    return HangarRenderer.context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))!
}

/// The colour at a point of a picture from its top left (y down), with its alpha (not premultiplied).
private func pixel(_ image: CGImage, x: Int, y: Int) -> (r: Double, g: Double, b: Double, a: Double) {
    var p = [UInt8](repeating: 0, count: 4)
    let context = CGContext(data: &p, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
    let a = Double(p[3]) / 255
    guard a > 0 else { return (0, 0, 0, 0) }
    return (Double(p[0]) / 255 / a, Double(p[1]) / 255 / a, Double(p[2]) / 255 / a, a)
}

private func isRed(_ c: (r: Double, g: Double, b: Double, a: Double)) -> Bool { c.r > 0.9 && c.g < 0.15 && c.b < 0.15 && c.a > 0.9 }
private func isGrey(_ c: (r: Double, g: Double, b: Double, a: Double)) -> Bool { abs(c.r - 0.5) < 0.06 && abs(c.b - 0.5) < 0.06 && c.a > 0.9 }

struct DrawingTests {
    @Test func aWebStrokeIsAPenAndAMarkIsAStrokeWithItsKind() throws {
        let web = ##"{"points": [{"x": 0.1, "y": 0.2}, {"x": 0.3, "y": 0.4}], "widthRatio": 0.02, "color": "#ef4444"}"##
        let pen = try JSONDecoder().decode(HangarMark.self, from: Data(web.utf8))
        #expect(pen.kind == .pen)
        #expect(pen.points == [CGPoint(x: 0.1, y: 0.2), CGPoint(x: 0.3, y: 0.4)])
        #expect(pen.stroke.width == 0.02 && pen.stroke.color == "#ef4444")

        let arrow = HangarMark(.arrow, points: [CGPoint(x: 0.1, y: 0.1), CGPoint(x: 0.9, y: 0.5)], width: 0.01, color: "#FFFFFF")
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(arrow)) as! [String: Any]
        #expect(json["kind"] as? String == "arrow")
        #expect(json["widthRatio"] as? Double == 0.01 && json["color"] as? String == "#FFFFFF")
        #expect((json["points"] as? [[String: Double]])?.first == ["x": 0.1, "y": 0.1])
        // As a stroke, it's read as any other.
        #expect(try JSONDecoder().decode(HangarStroke.self, from: JSONEncoder().encode(arrow)) == arrow.stroke)

        // A kind this version doesn't know: a pen's line, not lost.
        let later = try JSONDecoder().decode(HangarMark.self, from: Data(##"{"kind": "cloud", "points": [{"x": 0, "y": 0}], "widthRatio": 0.1, "color": "#000"}"##.utf8))
        #expect(later.kind == .pen && later.points.count == 1)
    }

    @Test func anEditKeepsItsDrawingAndAnOlderOneHasNone() throws {
        var edit = HangarEdit()
        #expect(edit.isOriginal)
        edit.drawing.marks = [HangarMark(.star, points: [CGPoint(x: 0.2, y: 0.2), CGPoint(x: 0.6, y: 0.7)], width: 0.01, color: "#FFCC00")]
        #expect(!edit.isOriginal)
        #expect(try JSONDecoder().decode(HangarEdit.self, from: JSONEncoder().encode(edit)) == edit)
        let older = try JSONDecoder().decode(HangarEdit.self, from: Data(#"{"adjustments": {"exposure": 0.2}}"#.utf8))
        #expect(older.drawing.marks.isEmpty)
        // Only an eraser left: nothing to see.
        edit.drawing.marks = [HangarMark(.eraser, points: [CGPoint(x: 0.5, y: 0.5)], width: 0.1)]
        #expect(edit.drawing.isEmpty && edit.isOriginal)
    }

    @Test func eachShapeFillsItsBox() {
        let size = CGSize(width: 200, height: 100)
        let box = [CGPoint(x: 0.75, y: 0.9), CGPoint(x: 0.25, y: 0.1)]  // dragged up and to the left
        func outline(_ kind: HangarMark.Kind, _ points: [CGPoint] = box) -> HangarMark.Outline? {
            HangarMark(kind, points: points, width: 0.02).outline(size: size).first
        }
        #expect(outline(.rectangle)?.points == [CGPoint(x: 50, y: 10), CGPoint(x: 150, y: 10), CGPoint(x: 150, y: 90), CGPoint(x: 50, y: 90)])
        #expect(outline(.triangle)?.points == [CGPoint(x: 100, y: 10), CGPoint(x: 150, y: 90), CGPoint(x: 50, y: 90)])
        #expect(outline(.diamond)?.points == [CGPoint(x: 100, y: 10), CGPoint(x: 150, y: 50), CGPoint(x: 100, y: 90), CGPoint(x: 50, y: 50)])
        let star = outline(.star)!
        #expect(star.points.count == 10 && star.closed)
        #expect(abs(star.points[0].x - 100) < 1e-9 && abs(star.points[0].y - 10) < 1e-9)
        let heart = outline(.heart)!.points
        // Its point at the bottom middle, its lobes at the top.
        #expect(heart.contains { abs($0.x - 100) < 0.5 && abs($0.y - 90) < 0.5 })
        #expect(abs(heart.map(\.y).min()! - 10) < 0.5)
        let ellipse = outline(.ellipse)!.points
        #expect(abs(ellipse.map(\.x).max()! - 150) < 1e-9 && abs(ellipse.map(\.y).min()! - 10) < 0.1)
        // Three corners: the box as it was shown, here turned a quarter.
        let turned = outline(.rectangle, [CGPoint(x: 0.25, y: 0.9), CGPoint(x: 0.25, y: 0.1), CGPoint(x: 0.75, y: 0.9)])!
        #expect(turned.points == [CGPoint(x: 50, y: 90), CGPoint(x: 50, y: 10), CGPoint(x: 150, y: 10), CGPoint(x: 150, y: 90)])
        // Nothing for a box with no size or a line with no length.
        #expect(outline(.ellipse, [CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.5, y: 0.5)]) == nil)
        #expect(outline(.line, [CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.5, y: 0.5)]) == nil)
    }

    @Test func anArrowHasItsHeadAtItsEnd() {
        // 4 widths long (8 pixels: 0.02 of 100), 30° each side.
        let lines = HangarMark(.arrow, points: [CGPoint(x: 0, y: 0.5), CGPoint(x: 0.5, y: 0.5)], width: 0.02).outline(size: CGSize(width: 200, height: 100))
        #expect(lines.count == 2)
        let head = lines[1].points
        #expect(head[1] == CGPoint(x: 100, y: 50))
        #expect(abs(head[0].x - (100 - 8 * cos(.pi / 6))) < 1e-9 && abs(head[0].y - (50 - 8 * sin(.pi / 6))) < 1e-9)
        #expect(abs(head[2].y - (50 + 8 * sin(.pi / 6))) < 1e-9)
        // A short one's head no more than 45% of it.
        let short = HangarMark(.arrow, points: [CGPoint(x: 0, y: 0.5), CGPoint(x: 0.05, y: 0.5)], width: 0.02).outline(size: CGSize(width: 200, height: 100))
        #expect(abs(short[1].points[1].x - short[1].points[0].x - 4.5 * cos(.pi / 6)) < 1e-9)
    }

    @Test func theEraserTakesOutWhatsDrawnNotThePicture() {
        var drawing = HangarDrawing(marks: [
            HangarMark(.pen, points: [CGPoint(x: 0.1, y: 0.5), CGPoint(x: 0.9, y: 0.5)], width: 0.2, color: "#FF0000"),
            HangarMark(.eraser, points: [CGPoint(x: 0.5, y: 0.1), CGPoint(x: 0.5, y: 0.9)], width: 0.2),
        ])
        let layer = drawing.image(size: CGSize(width: 100, height: 100))!
        #expect(isRed(pixel(layer, x: 25, y: 50)))
        #expect(pixel(layer, x: 50, y: 50).a == 0)
        #expect(pixel(layer, x: 25, y: 20).a == 0)

        // Over a picture: grey where it was erased, not clear.
        var edit = HangarEdit()
        edit.drawing = drawing
        let out = HangarRenderer().render(edit, to: plain(0.5, 0.5, 0.5, width: 100, height: 100))!
        #expect(isRed(pixel(out, x: 25, y: 50)))
        #expect(isGrey(pixel(out, x: 50, y: 50)))
        drawing.marks.removeLast()
        #expect(isRed(pixel(drawing.image(size: CGSize(width: 100, height: 100))!, x: 50, y: 50)))
    }

    @Test func aMarkStaysOnWhatItWasDrawnOn() {
        // A dot at (0.75, 0.25) of a 60 by 40 picture: (45, 10).
        var edit = HangarEdit()
        edit.drawing.marks = [HangarMark(.pen, points: [CGPoint(x: 0.75, y: 0.25)], width: 0.2, color: "#FF0000")]
        let picture = plain(0.5, 0.5, 0.5, width: 60, height: 40)
        let whole = HangarRenderer().render(edit, to: picture)!
        #expect(isRed(pixel(whole, x: 45, y: 10)) && isGrey(pixel(whole, x: 15, y: 30)))
        // Cropped to the right half: at (15, 10) of it.
        edit.geometry.crop = CGRect(x: 0.5, y: 0, width: 0.5, height: 1)
        let cropped = HangarRenderer().render(edit, to: picture)!
        #expect(cropped.width == 30)
        #expect(isRed(pixel(cropped, x: 15, y: 10)) && isGrey(pixel(cropped, x: 15, y: 30)))
        // Turned a quarter to the left as well: where the geometry takes it.
        edit.geometry.turns = 1
        let turned = HangarRenderer().render(edit, to: picture)!
        let at = edit.geometry.shownPoint(CGPoint(x: 45, y: 10), size: CGSize(width: 60, height: 40))
        #expect(isRed(pixel(turned, x: Int(at.x), y: Int(at.y))))
    }

    @Test func aPictureMadeLargerKeepsItsMarksOnTheSamePart() {
        var edit = HangarEdit()
        edit.drawing.marks = [HangarMark(.pen, points: [CGPoint(x: 0.5, y: 0.5), CGPoint(x: 1, y: 1)], width: 0.1)]
        // Twice as wide, half each side: the shorter side's the same.
        edit.add(HangarStep(tool: "extend", takes: [], frame: CGRect(x: -0.5, y: 0, width: 2, height: 1)), aspect: 1.5)
        #expect(edit.drawing.marks[0].points == [CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.75, y: 1)])
        #expect(abs(edit.drawing.marks[0].stroke.width - 0.1) < 1e-9)
        // Twice as tall: the shorter side (the height, 1 of 1.5) twice as long, the mark half as much of it.
        edit.add(HangarStep(tool: "extend", takes: [], frame: CGRect(x: 0, y: -0.5, width: 1, height: 2)), aspect: 3)
        #expect(abs(edit.drawing.marks[0].stroke.width - 0.05) < 1e-9)
        // A part made the whole picture: what was drawn was on another.
        edit.add(HangarStep(tool: "closeUp", takes: [], replaces: true))
        #expect(edit.drawing.marks.isEmpty)
    }

    @Test func coloursAreReadAsTheWebWritesThem() {
        #expect(HangarMark.color("#f00")?.components == [1, 0, 0, 1])
        #expect(HangarMark.color("#2440E6") != nil && HangarMark.color("2440e6") != nil)
        #expect(abs((HangarMark.color("#FF000080")?.alpha ?? 0) - 128 / 255) < 1e-9)
        #expect(HangarMark.color("red") == nil && HangarMark.color("#12345") == nil)
        #expect(HangarMark.hex(CGColor(srgbRed: 1, green: 0.8, blue: 0, alpha: 1)) == "#FFCC00")
        #expect(HangarMark.hex(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.5)) == "#00000080")
    }
}
