import CoreImage
import Foundation
import Testing
@testable import HangarCore

/// Every tool at both ends and every filter, on a photo, in one picture, to look at while tuning them: runs only with
/// `HANGAR_SHEET` set to a photo (`TEST_RUNNER_HANGAR_SHEET` through xcodebuild), written beside it as `-sheet.png`.
struct ContactSheet {
    @Test func drawSheet() throws {
        guard let path = ProcessInfo.processInfo.environment["HANGAR_SHEET"], let photo = CIImage(contentsOf: URL(fileURLWithPath: path)) else { return }
        let cell: CGFloat = 320
        let scale = cell / max(photo.extent.width, photo.extent.height)
        let small = photo.transformed(by: CGAffineTransform(scaleX: scale, y: scale)).insertingIntermediate(cache: true)
        let context = HangarRenderContext(source: small, scale: Double(scale))
        let renderer = HangarRenderer()
        var tiles: [CIImage] = [small]
        for adjustment in HangarToolbox.standard.adjustments {
            for value in [adjustment.range.lowerBound, adjustment.range.upperBound] {
                var edit = HangarEdit()
                edit.set(adjustment.id, to: value)
                tiles.append(value == 0 ? small : renderer.apply(edit, to: small, context: context))
            }
        }
        for filter in HangarToolbox.standard.filters {
            var edit = HangarEdit()
            edit.filter = filter.id
            tiles.append(renderer.apply(edit, to: small, context: context))
        }
        let columns = 6
        let rows = (tiles.count + columns - 1) / columns
        let w = small.extent.width.rounded(.up), h = small.extent.height.rounded(.up)
        var sheet = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: CGFloat(columns) * (w + 4), height: CGFloat(rows) * (h + 4)))
        for (i, tile) in tiles.enumerated() {
            let x = CGFloat(i % columns) * (w + 4), y = CGFloat(rows - 1 - i / columns) * (h + 4)
            sheet = tile.transformed(by: CGAffineTransform(translationX: x - tile.extent.minX, y: y - tile.extent.minY)).composited(over: sheet)
        }
        let out = URL(fileURLWithPath: path).deletingPathExtension().appendingPathExtension("sheet.png")
        try HangarRenderer.context.writePNGRepresentation(of: sheet, to: out, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
    }
}
