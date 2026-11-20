import CoreImage
import Foundation
import Testing
import UIKit
@testable import Hangar
@testable import HangarCore

/// A picture to try tools on: dark to light from left to right, a little warm, 64 wide.
private func sample() -> CIImage {
    CIFilter(name: "CILinearGradient", parameters: [
        "inputPoint0": CIVector(x: 0, y: 0), "inputPoint1": CIVector(x: 64, y: 0),
        "inputColor0": CIColor(red: 0.08, green: 0.07, blue: 0.06), "inputColor1": CIColor(red: 0.85, green: 0.8, blue: 0.72),
    ])!.outputImage!.cropped(to: CGRect(x: 0, y: 0, width: 64, height: 64))
}

/// Mean red, green and blue (0 to 1, as shown) over a part of the picture.
private func mean(_ image: CIImage, in rect: CGRect? = nil) -> (r: Double, g: Double, b: Double) {
    let area = rect ?? image.extent
    var pixel = [UInt8](repeating: 0, count: 4)
    let averaged = image.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: area)])
    HangarRenderer.context.render(averaged, toBitmap: &pixel, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                                  format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    return (Double(pixel[0]) / 255, Double(pixel[1]) / 255, Double(pixel[2]) / 255)
}

private func brightness(_ c: (r: Double, g: Double, b: Double)) -> Double { (c.r + c.g + c.b) / 3 }

private func applying(_ id: String, _ value: Double, to image: CIImage = sample()) -> CIImage {
    var edit = HangarEdit()
    edit.set(id, to: value)
    return HangarRenderer().apply(edit, to: image, context: HangarRenderContext(source: image))
}

private let left = CGRect(x: 0, y: 0, width: 12, height: 64)
private let right = CGRect(x: 52, y: 0, width: 12, height: 64)

struct ToolTests {
    @Test func exposureAndBrightnessGoTheirWay() {
        let base = brightness(mean(sample()))
        #expect(brightness(mean(applying("exposure", 1))) > base + 0.05)
        #expect(brightness(mean(applying("exposure", -1))) < base - 0.05)
        #expect(brightness(mean(applying("brightness", 1))) > base + 0.03)
        #expect(brightness(mean(applying("brightness", -1))) < base - 0.03)
    }

    @Test func highlightsAndShadowsTouchTheirEnd() {
        let base = sample()
        #expect(brightness(mean(applying("highlights", -1), in: right)) < brightness(mean(base, in: right)) - 0.02)
        #expect(brightness(mean(applying("highlights", 1), in: right)) > brightness(mean(base, in: right)) + 0.01)
        #expect(brightness(mean(applying("shadows", 1), in: left)) > brightness(mean(base, in: left)) + 0.02)
    }

    @Test func contrastAndBlackPointSpreadTheTones() {
        let base = sample()
        let spread = { (image: CIImage) in brightness(mean(image, in: right)) - brightness(mean(image, in: left)) }
        #expect(spread(applying("contrast", 1)) > spread(base) + 0.03)
        #expect(spread(applying("contrast", -1)) < spread(base) - 0.03)
        #expect(brightness(mean(applying("blackPoint", 1), in: left)) < brightness(mean(base, in: left)) - 0.01)
        #expect(brightness(mean(applying("blackPoint", -1), in: left)) > brightness(mean(base, in: left)) + 0.01)
    }

    @Test func warmthIsYellowAndTintIsMagenta() {
        let base = mean(sample())
        let warm = mean(applying("warmth", 1)), cool = mean(applying("warmth", -1))
        #expect(warm.r - warm.b > base.r - base.b + 0.02)
        #expect(cool.r - cool.b < base.r - base.b - 0.02)
        let magenta = mean(applying("tint", 1)), green = mean(applying("tint", -1))
        #expect(magenta.g - (magenta.r + magenta.b) / 2 < base.g - (base.r + base.b) / 2 - 0.01)
        #expect(green.g - (green.r + green.b) / 2 > base.g - (base.r + base.b) / 2 + 0.01)
    }

    @Test func saturationDownIsGrey() {
        let grey = mean(applying("saturation", -1))
        #expect(abs(grey.r - grey.b) < 0.01)
    }

    @Test func vignetteDarkensTheCorners() {
        let flat = CIImage(color: CIColor(red: 0.6, green: 0.6, blue: 0.6)).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 64))
        let corner = CGRect(x: 0, y: 0, width: 6, height: 6), middle = CGRect(x: 29, y: 29, width: 6, height: 6)
        let dark = applying("vignette", 1, to: flat)
        #expect(brightness(mean(dark, in: corner)) < brightness(mean(dark, in: middle)) - 0.05)
        let light = applying("vignette", -1, to: flat)
        #expect(brightness(mean(light, in: corner)) > brightness(mean(light, in: middle)) + 0.02)
    }

    @Test func everyToolAndFilterDrawsTheSameSize() {
        let base = sample()
        let context = HangarRenderContext(source: base)
        for adjustment in HangarToolbox.standard.adjustments {
            for value in [adjustment.range.lowerBound, adjustment.range.upperBound] where value != 0 {
                let out = applying(adjustment.id, value)
                #expect(out.extent == base.extent, "\(adjustment.id) \(value)")
            }
        }
        for filter in HangarToolbox.standard.filters {
            let out = filter.apply(base, context).cropped(to: base.extent)
            #expect(out.extent == base.extent, "\(filter.id)")
            let a = mean(out), b = mean(base)
            #expect(abs(a.r - b.r) + abs(a.g - b.g) + abs(a.b - b.b) > 0.005, "\(filter.id) changes nothing")
        }
    }

    @Test func untouchedIsTheOriginal() {
        var edit = HangarEdit()
        #expect(edit.isOriginal)
        edit.set("exposure", to: 0.4)
        #expect(!edit.isOriginal)
        edit.switchedOff.insert("exposure")
        #expect(edit.isOriginal)
        edit.set("exposure", to: 0)
        #expect(edit.adjustments.isEmpty)
    }

    @Test func editsKeepAndOpenAgain() throws {
        var edit = HangarEdit()
        edit.set("warmth", to: -0.3)
        edit.filter = "noir"
        edit.filterAmount = 0.5
        let data = try JSONEncoder().encode(edit)
        #expect(try JSONDecoder().decode(HangarEdit.self, from: data) == edit)
        // One kept with less (an older version) opens.
        #expect(try JSONDecoder().decode(HangarEdit.self, from: Data("{}".utf8)) == HangarEdit())
    }

    @MainActor @Test func everySymbolIsThere() {
        for adjustment in HangarToolbox.standard.adjustments {
            #expect(UIImage(systemName: adjustment.symbol) != nil, "\(adjustment.symbol)")
        }
        for symbol in ["dial.medium", "dial.medium.fill", "camera.filters", "xmark", "checkmark", "ellipsis", "arrow.uturn.backward", "arrow.uturn.forward"] {
            #expect(UIImage(systemName: symbol) != nil, "\(symbol)")
        }
    }

    @MainActor @Test func fitKeepsTheShapeOnPixels() {
        let frame = HangarEditor.fit(CGSize(width: 3000, height: 2000), in: CGRect(x: 0, y: 100, width: 402, height: 500), scale: 3)
        #expect(abs(frame.width / frame.height - 1.5) < 0.01)
        #expect(frame.width == 402)
        #expect(abs(frame.midY - 350) < 0.5)
    }
}
