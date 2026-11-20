import CoreImage
import Foundation

// Photos' tools, in Photos' order, made with Core Image's filters. Each is close to Photos' in what it does and how
// far it goes at its ends, not a copy of it: Photos' own aren't public.

extension HangarAdjustment {
    /// Auto, then Photos' fifteen: Exposure to Vignette.
    public static let standard: [HangarAdjustment] = [
        auto, exposure, brilliance, highlights, shadows, contrast, brightness, blackPoint, saturation, vibrance, warmth, tint,
        sharpness, definition, noiseReduction, vignette,
    ]

    /// Core Image's enhancement of the picture, as much of it as the value.
    public static let auto = HangarAdjustment(id: "auto", name: "Auto", symbol: "wand.and.stars", range: 0...1) { image, value, context in
        image.mixed(toward: context.autoEnhanced(image), value)
    }

    /// Up to a stop and a half either way.
    public static let exposure = HangarAdjustment(id: "exposure", name: "Exposure", symbol: "plusminus.circle") { image, value, _ in
        image.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: value * 1.5])
    }

    /// Shadows up and highlights down together (down and up taken the other way), a little more colour with them.
    public static let brilliance = HangarAdjustment(id: "brilliance", name: "Brilliance", symbol: "swirl.circle.righthalf.filled.inverse") { image, value, _ in
        image
            .applyingFilter("CIHighlightShadowAdjust", parameters: [
                "inputShadowAmount": 0.55 * value,
                "inputHighlightAmount": 1 - 0.35 * max(value, 0),
            ])
            .perceptual { $0.curve(highlights: 0.06 * min(value, 0) * -1, shadows: 0) }
            .applyingFilter("CIVibrance", parameters: ["inputAmount": 0.15 * value])
    }

    /// The bright parts down (to a tenth of them) or up.
    public static let highlights = HangarAdjustment(id: "highlights", name: "Highlights", symbol: "circle.lefthalf.striped.horizontal") { image, value, _ in
        value < 0
            ? image.applyingFilter("CIHighlightShadowAdjust", parameters: ["inputHighlightAmount": 1 + 0.9 * value])
            : image.perceptual { $0.curve(highlights: 0.12 * value, shadows: 0) }
    }

    /// The dark parts up or down.
    public static let shadows = HangarAdjustment(id: "shadows", name: "Shadows", symbol: "circle.lefthalf.striped.horizontal.inverse") { image, value, _ in
        image.applyingFilter("CIHighlightShadowAdjust", parameters: ["inputShadowAmount": value])
    }

    /// Around the middle grey, as it looks.
    public static let contrast = HangarAdjustment(id: "contrast", name: "Contrast", symbol: "circle.lefthalf.filled") { image, value, _ in
        image.perceptual { $0.applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: 1 + 0.28 * value]) }
    }

    /// The middle tones up or down, black and white kept.
    public static let brightness = HangarAdjustment(id: "brightness", name: "Brightness", symbol: "sun.min.fill") { image, value, _ in
        image.perceptual { $0.applyingFilter("CIGammaAdjust", parameters: ["inputPower": pow(2, -0.55 * value)]) }
    }

    /// Where black is: the darkest tenth made black, or black lifted to a tenth grey.
    public static let blackPoint = HangarAdjustment(id: "blackPoint", name: "Black Point", symbol: "smallcircle.filled.circle.fill") { image, value, _ in
        let (scale, bias) = value > 0 ? (1 / (1 - 0.1 * value), -0.1 * value / (1 - 0.1 * value)) : (1 + 0.1 * value, -0.1 * value)
        return image.perceptual { $0.levels(scale: scale, bias: bias) }
    }

    /// Grey at the bottom, twice as much at the top.
    public static let saturation = HangarAdjustment(id: "saturation", name: "Saturation", symbol: "hangar.saturation") { image, value, _ in
        image.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1 + value])
    }

    /// Colour where there's little of it, skin kept.
    public static let vibrance = HangarAdjustment(id: "vibrance", name: "Vibrance", symbol: "hangar.vibrance") { image, value, _ in
        image.applyingFilter("CIVibrance", parameters: ["inputAmount": value])
    }

    /// Blue to yellow.
    public static let warmth = HangarAdjustment(id: "warmth", name: "Warmth", symbol: "thermometer.medium") { image, value, _ in
        image.warmed(value)
    }

    /// Green to magenta.
    public static let tint = HangarAdjustment(id: "tint", name: "Tint", symbol: "drop.halffull") { image, value, _ in
        image.applyingFilter("CITemperatureAndTint", parameters: [
            "inputNeutral": CIVector(x: 6500, y: 0),
            "inputTargetNeutral": CIVector(x: 6500, y: -60 * value),
        ])
    }

    /// Edges crisper, a pixel or two of them.
    public static let sharpness = HangarAdjustment(id: "sharpness", name: "Sharpness", symbol: "righttriangle.fill", range: 0...1) { image, value, context in
        image.clampedToExtent()
            .applyingFilter("CISharpenLuminance", parameters: [kCIInputSharpnessKey: 0.9 * value, kCIInputRadiusKey: max(1.69 * context.scale, 0.5)])
            .cropped(to: image.extent)
    }

    /// Contrast between neighbouring parts: an unsharp mask a hundredth of the picture wide.
    public static let definition = HangarAdjustment(id: "definition", name: "Definition", symbol: "righttriangle.split.diagonal", range: 0...1) { image, value, _ in
        let side = min(image.extent.width, image.extent.height)
        return image.clampedToExtent()
            .applyingFilter("CIUnsharpMask", parameters: [kCIInputRadiusKey: 0.012 * side, kCIInputIntensityKey: 0.5 * value])
            .cropped(to: image.extent)
    }

    /// Grain smoothed out.
    public static let noiseReduction = HangarAdjustment(id: "noiseReduction", name: "Noise Reduction", symbol: "circle.bottomrighthalf.pattern.checkered", range: 0...1) { image, value, _ in
        image.clampedToExtent()
            .applyingFilter("CINoiseReduction", parameters: ["inputNoiseLevel": 0.04 * value, kCIInputSharpnessKey: 0.5])
            .cropped(to: image.extent)
    }

    /// The edges darker (multiplied down to 30% at the corners), or lighter (screened up to 55% white); the middle
    /// kept, a soft ring between them.
    public static let vignette = HangarAdjustment(id: "vignette", name: "Vignette", symbol: "circle.dotted.circle") { image, value, _ in
        let extent = image.extent
        let reach = 0.5 * hypot(extent.width, extent.height)
        let darkening = value > 0
        let ring = CIFilter(name: "CIRadialGradient", parameters: [
            "inputCenter": CIVector(x: extent.midX, y: extent.midY),
            "inputRadius0": 0.4 * reach,
            "inputRadius1": reach,
            "inputColor0": darkening ? CIColor.white : CIColor.black,
            "inputColor1": darkening ? CIColor(red: 1 - 0.7 * value, green: 1 - 0.7 * value, blue: 1 - 0.7 * value)
                : CIColor(red: -0.55 * value, green: -0.55 * value, blue: -0.55 * value),
        ])!.outputImage!.cropped(to: extent)
        return darkening
            ? image.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: ring])
            : ring.applyingFilter("CIScreenBlendMode", parameters: [kCIInputBackgroundImageKey: image])
    }
}

extension HangarFilter {
    /// Photos' nine: Vivid, Dramatic, each warm and cool, and three in black and white.
    public static let standard: [HangarFilter] = [
        vivid, vividWarm, vividCool, dramatic, dramaticWarm, dramaticCool, mono, silvertone, noir,
    ]

    public static let vivid = HangarFilter(id: "vivid", name: "Vivid") { image, _ in image.vivid() }
    public static let vividWarm = HangarFilter(id: "vividWarm", name: "Vivid Warm") { image, _ in image.vivid().warmed(0.35) }
    public static let vividCool = HangarFilter(id: "vividCool", name: "Vivid Cool") { image, _ in image.vivid().warmed(-0.35) }
    public static let dramatic = HangarFilter(id: "dramatic", name: "Dramatic") { image, _ in image.dramatic() }
    public static let dramaticWarm = HangarFilter(id: "dramaticWarm", name: "Dramatic Warm") { image, _ in image.dramatic().warmed(0.4) }
    public static let dramaticCool = HangarFilter(id: "dramaticCool", name: "Dramatic Cool") { image, _ in image.dramatic().warmed(-0.4) }
    public static let mono = HangarFilter(id: "mono", name: "Mono") { image, _ in image.applyingFilter("CIPhotoEffectMono") }
    public static let silvertone = HangarFilter(id: "silvertone", name: "Silvertone") { image, _ in
        image.applyingFilter("CIPhotoEffectTonal")
            .applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: 0.2])
            .perceptual { $0.applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: 1.12]) }
    }
    public static let noir = HangarFilter(id: "noir", name: "Noir") { image, _ in image.applyingFilter("CIPhotoEffectNoir") }
}

extension CIImage {
    /// `body` done to the picture as it's seen (sRGB's curve), not as light adds up: a curve looks as it's drawn.
    public func perceptual(_ body: (CIImage) -> CIImage) -> CIImage {
        body(applyingFilter("CILinearToSRGBToneCurve")).applyingFilter("CISRGBToneCurveToLinear")
    }

    /// The upper quarter raised by `highlights` and the lower by `shadows` (fractions of white), the ends kept.
    func curve(highlights: Double, shadows: Double) -> CIImage {
        applyingFilter("CIToneCurve", parameters: [
            "inputPoint0": CIVector(x: 0, y: 0),
            "inputPoint1": CIVector(x: 0.25, y: 0.25 + shadows),
            "inputPoint2": CIVector(x: 0.5, y: 0.5 + (highlights + shadows) / 4),
            "inputPoint3": CIVector(x: 0.75, y: 0.75 + highlights),
            "inputPoint4": CIVector(x: 1, y: 1),
        ])
    }

    /// Each colour times `scale`, plus `bias`.
    func levels(scale: Double, bias: Double) -> CIImage {
        applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: scale, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: scale, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: scale, w: 0),
            "inputBiasVector": CIVector(x: bias, y: bias, z: bias, w: 0),
        ])
    }

    /// Warmer (toward yellow) for a positive `amount`, cooler (toward blue) for a negative one; 1 is about 2,000 K.
    func warmed(_ amount: Double) -> CIImage {
        applyingFilter("CITemperatureAndTint", parameters: [
            "inputNeutral": CIVector(x: 6500, y: 0),
            "inputTargetNeutral": CIVector(x: 6500 - 2000 * amount, y: 0),
        ])
    }

    /// This picture `amount` of the way to `other` (0 this, 1 the other): a tool's or filter's "how much".
    public func mixed(toward other: CIImage, _ amount: Double) -> CIImage {
        guard amount < 1 else { return other.cropped(to: extent) }
        return applyingFilter("CIDissolveTransition", parameters: [kCIInputTargetImageKey: other, kCIInputTimeKey: amount]).cropped(to: extent)
    }

    func vivid() -> CIImage {
        perceptual { $0.applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: 1.08]) }
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.3])
            .applyingFilter("CIVibrance", parameters: ["inputAmount": 0.15])
    }

    /// Moody: the highlights held well down and the whole a little darker, more contrast in the middle, less colour.
    func dramatic() -> CIImage {
        applyingFilter("CIHighlightShadowAdjust", parameters: ["inputHighlightAmount": 0.35, "inputShadowAmount": -0.1])
            .applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: -0.2])
            .perceptual { $0.applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: 1.12]) }
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0.85])
    }
}
