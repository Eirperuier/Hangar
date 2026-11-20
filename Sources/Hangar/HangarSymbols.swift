import UIKit

/// Tools' symbols: SF Symbols by name, and the two Photos draws that no SF Symbol is, drawn here: Saturation's
/// rainbow disc and Vibrance's rainbow of upright strokes (`hangar.saturation`, `hangar.vibrance`).
@MainActor
enum HangarSymbols {
    static func image(_ name: String) -> UIImage? {
        switch name {
        case "hangar.saturation": rainbow(striped: false)
        case "hangar.vibrance": rainbow(striped: true)
        default: UIImage(systemName: name) ?? UIImage(systemName: "circle")
        }
    }

    /// Photos' rainbows: 19 points across, violet on the left to red on the right; Vibrance's in strokes a point
    /// wide, 1.75 apart.
    private static func rainbow(striped: Bool) -> UIImage {
        let side: CGFloat = 19
        let image = UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { context in
            let c = context.cgContext
            c.addEllipse(in: CGRect(x: 0, y: 0, width: side, height: side))
            c.clip()
            func hue(_ t: CGFloat) -> UIColor { UIColor(hue: 0.8 * (1 - t), saturation: 0.9, brightness: 1, alpha: 1) }
            if striped {
                var x: CGFloat = 0.6
                while x < side {
                    hue(x / side).setFill()
                    c.fill(CGRect(x: x, y: 0, width: 1, height: side))
                    x += 1.75
                }
            } else {
                let stops = stride(from: 0, through: 1, by: 0.1).map { CGFloat($0) }
                let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: stops.map { hue($0).cgColor } as CFArray,
                                          locations: stops)!
                c.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: side, y: 0), options: [])
            }
        }
        return image.withRenderingMode(.alwaysOriginal)
    }
}
