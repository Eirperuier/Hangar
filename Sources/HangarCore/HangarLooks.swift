import CoreGraphics
import CoreImage
import Foundation

/// A value a tool sets on the picture (a camera's angle, a light's warmth): its id, its name, how far it goes each
/// way, and where it starts.
public struct HangarParameter: Hashable, Sendable {
    public var id: String
    public var name: String
    public var range: ClosedRange<Double>
    public var start: Double

    public init(id: String, name: String, range: ClosedRange<Double> = -1...1, start: Double = 0) {
        self.id = id
        self.name = name
        self.range = range
        self.start = start
    }
}

/// A new camera angle on the picture (Photos' Reframe: "Touch and drag to adjust the perspective. Use two fingers to
/// pan, zoom, or rotate."): turned left or right, tilted up or down, rolled, moved and nearer or further. What a tool
/// shows as it's set, and what an app with no model of its own can make of it: the picture laid on a plane, the plane
/// moved, and seen from where it was taken, over a blurred copy where it no longer reaches.
public enum HangarReframe {
    public static let horizontal = HangarParameter(id: "horizontal", name: "Horizontal")
    public static let vertical = HangarParameter(id: "vertical", name: "Vertical")
    public static let zoom = HangarParameter(id: "zoom", name: "Zoom")
    public static let straighten = HangarParameter(id: "straighten", name: "Straighten")
    /// Moved across and down, as much of the picture's width and height.
    public static let panX = HangarParameter(id: "panX", name: "Pan Across")
    public static let panY = HangarParameter(id: "panY", name: "Pan Down")
    /// The ones on its chips and ruler (the pan is two fingers').
    public static let shown = [horizontal, vertical, zoom, straighten]
    public static let all = shown + [panX, panY]

    /// How far each goes at 1: turned and tilted 30°, rolled 45°, twice as near.
    static let turn = Double.pi / 6
    static let roll = Double.pi / 4

    /// Where the picture's corners go (top left, top right, bottom right, bottom left), `size` its pixels, from its
    /// top left.
    public static func corners(_ values: [String: Double], size: CGSize) -> [CGPoint] {
        func v(_ p: HangarParameter) -> Double { min(max(values[p.id] ?? p.start, p.range.lowerBound), p.range.upperBound) }
        let w = Double(size.width), h = Double(size.height)
        let scale = pow(2, v(zoom))
        let yaw = v(horizontal) * turn, pitch = v(vertical) * turn, rollAngle = -v(straighten) * roll
        // The camera as far back as the picture's longer side and a little more: a phone's wide lens.
        let d = max(w, h) * 1.2
        return [(-w / 2, -h / 2), (w / 2, -h / 2), (w / 2, h / 2), (-w / 2, h / 2)].map { (x0, y0) -> CGPoint in
            // Scaled and rolled in its plane (y down).
            var x = x0 * scale, y = y0 * scale
            (x, y) = (x * cos(rollAngle) - y * sin(rollAngle), x * sin(rollAngle) + y * cos(rollAngle))
            var z = 0.0
            // Turned about the up axis (its right side coming nearer for more), then tilted about the across one
            // (its top going back).
            (x, z) = (x * cos(yaw) - z * sin(yaw), x * sin(yaw) + z * cos(yaw))
            (y, z) = (y * cos(pitch) - z * sin(pitch), y * sin(pitch) + z * cos(pitch))
            x += v(panX) * w
            y += v(panY) * h
            // Seen from the camera: nearer (z up) larger.
            let f = d / max(d - z, d * 0.05)
            return CGPoint(x: w / 2 + x * f, y: h / 2 + y * f)
        }
    }

    /// The picture seen from the new angle, its size, over itself blurred where the plane doesn't reach.
    public static func apply(_ image: CIImage, values: [String: Double]) -> CIImage {
        let e = image.extent
        let picture = image.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
        let size = e.size
        let c = corners(values, size: size)
        // Core Image's y goes up.
        func ci(_ p: CGPoint) -> CIVector { CIVector(x: p.x, y: size.height - p.y) }
        let moved = picture.applyingFilter("CIPerspectiveTransform", parameters: [
            "inputTopLeft": ci(c[0]), "inputTopRight": ci(c[1]), "inputBottomRight": ci(c[2]), "inputBottomLeft": ci(c[3]),
        ])
        let all = CGRect(origin: .zero, size: size)
        let backdrop = picture.clampedToExtent()
            .applyingGaussianBlur(sigma: max(size.width, size.height) * 0.03)
            .applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: -0.6])
            .cropped(to: all)
        return moved.composited(over: backdrop).cropped(to: all)
    }
}

/// A light on the picture (Flowith's relight): where it comes from, how bright the picture is, how warm the light,
/// how strong, and a rim of it round what's lit. What a tool shows as it's set, and what an app with no model of its
/// own can make of it: the picture lit from that side and dimmed away from it, warmer or cooler, its edges caught.
public enum HangarRelight {
    /// Where the light is, 0 to 1 each way from the picture's top left (dragged, not on a ruler).
    public static let x = HangarParameter(id: "x", name: "Across", range: 0...1, start: 0.25)
    public static let y = HangarParameter(id: "y", name: "Down", range: 0...1, start: 0.2)
    public static let brightness = HangarParameter(id: "brightness", name: "Brightness")
    public static let warmth = HangarParameter(id: "warmth", name: "Warmth")
    public static let intensity = HangarParameter(id: "intensity", name: "Intensity", range: 0...1, start: 0.5)
    public static let rim = HangarParameter(id: "rim", name: "Rim Light", range: 0...1, start: 0)
    public static let shown = [brightness, warmth, intensity, rim]
    public static let all = shown + [x, y]

    public static func apply(_ image: CIImage, values: [String: Double]) -> CIImage {
        func v(_ p: HangarParameter) -> Double { min(max(values[p.id] ?? p.start, p.range.lowerBound), p.range.upperBound) }
        let e = image.extent
        let longer = max(e.width, e.height)
        let strength = v(intensity)
        let warm = v(warmth)
        // The light's colour: warm toward amber, cool toward blue.
        let tint = warm >= 0 ? (1.0, 1 - 0.16 * warm, 1 - 0.4 * warm) : (1 + 0.3 * warm, 1 + 0.12 * warm, 1.0)
        let near = 1 + 0.9 * strength, far = 1 - 0.65 * strength
        let centre = CIVector(x: e.minX + v(x) * e.width, y: e.maxY - v(y) * e.height)
        // A gradient's colours stop at 1: drawn a `near`th as bright, then made that much brighter.
        let dim = far / near
        let light = CIFilter(name: "CIRadialGradient", parameters: [
            "inputCenter": centre, "inputRadius0": longer * 0.05, "inputRadius1": longer * 1.1,
            "inputColor0": CIColor(red: tint.0, green: tint.1, blue: tint.2),
            "inputColor1": CIColor(red: dim * (0.85 + 0.15 * tint.0), green: dim * (0.85 + 0.15 * tint.1), blue: dim * (0.85 + 0.15 * tint.2)),
        ])!.outputImage!.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: near, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: near, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: near, w: 0),
        ]).cropped(to: e)
        var out = image.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: light])
        let rimAmount = v(rim)
        if rimAmount > 0.001 {
            // The edges caught by the light, stronger nearer it.
            let edges = image.clampedToExtent().applyingGaussianBlur(sigma: longer * 0.002)
                .applyingFilter("CIEdges", parameters: [kCIInputIntensityKey: 6])
                .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0])
                .applyingGaussianBlur(sigma: longer * 0.004)
                .cropped(to: e)
            let glow = edges.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: light])
                .applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: rimAmount * 1.5, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: rimAmount * 1.5, z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 0, z: rimAmount * 1.5, w: 0),
                ])
            out = glow.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: out])
        }
        let ev = v(brightness)
        if abs(ev) > 0.001 { out = out.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: ev * 0.8]) }
        return out.cropped(to: e)
    }
}
