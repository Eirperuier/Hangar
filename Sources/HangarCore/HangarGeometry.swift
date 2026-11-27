import CoreGraphics
import CoreImage
import Foundation

/// A shape a crop keeps, as wide as `width` is to `height`.
public struct HangarRatio: Hashable, Sendable, Codable {
    public var width: Double
    public var height: Double

    public init(_ width: Double, _ height: Double) {
        self.width = width
        self.height = height
    }

    /// Width over height.
    public var value: Double { width / height }

    /// The same shape turned a quarter: 3:2 is 2:3.
    public var turned: HangarRatio { HangarRatio(height, width) }

    public static let square = HangarRatio(1, 1)
}

/// What Crop does to a picture, as values, as Photos keeps it: the picture tilted (Vertical and Horizontal) and
/// straightened, the part of it kept (the crop, held to a shape or not), then turned a quarter at a time and flipped.
/// Everything but the turns and the flip is in the picture's own frame, as it was taken, so turning or flipping it
/// changes nothing else; the editor shows each as it looks after them.
public struct HangarGeometry: Hashable, Sendable, Codable {
    /// Straighten: how far it's turned, in radians, counter-clockwise for more (Photos'); 45° each way.
    public var straighten: Double
    /// Vertical: how far it's tilted about its middle across, in radians, its top going back (narrower) for more
    /// (Photos'); 30° each way.
    public var vertical: Double
    /// Horizontal: how far it's tilted about its middle up and down, in radians, its right side coming nearer
    /// (taller) for more (Photos'); 30° each way.
    public var horizontal: Double
    /// The part kept, in the picture's own frame as a unit square (0, 0 its top left, 1, 1 its bottom right) once
    /// tilted and straightened; nil is as much as there is (`fittedCrop`).
    public var crop: CGRect?
    /// The shape the crop is held to, in the picture's own frame; nil is any (Photos' Freeform).
    public var aspect: HangarRatio?
    /// Quarter turns to the left (Photos' Rotate), 0 to 3, after the crop.
    public var turns: Int
    /// Mirrored left to right as it's shown (Photos' Flip), after the turns.
    public var flipped: Bool

    public init(straighten: Double = 0, vertical: Double = 0, horizontal: Double = 0, crop: CGRect? = nil,
                aspect: HangarRatio? = nil, turns: Int = 0, flipped: Bool = false) {
        self.straighten = straighten
        self.vertical = vertical
        self.horizontal = horizontal
        self.crop = crop
        self.aspect = aspect
        self.turns = turns
        self.flipped = flipped
    }

    public static let identity = HangarGeometry()

    /// Photos' Straighten goes 45° each way.
    public static let straightenLimit = Double.pi / 4
    /// Vertical and Horizontal go as far each way.
    public static let tiltLimit = Double.pi / 6

    /// Crop's three tools, on its ruler: their ids (an edit's `switchedOff` takes them as it does adjustments').
    public static let straightenID = "straighten"
    public static let verticalID = "vertical"
    public static let horizontalID = "horizontal"
    public static let toolIDs = [straightenID, verticalID, horizontalID]

    /// A tool's value as its ruler shows it, -1 to 1 of its reach.
    public func value(of id: String) -> Double {
        switch id {
        case Self.straightenID: straighten / Self.straightenLimit
        case Self.verticalID: vertical / Self.tiltLimit
        case Self.horizontalID: horizontal / Self.tiltLimit
        default: 0
        }
    }

    public mutating func set(_ id: String, to value: Double) {
        let v = min(max(value, -1), 1)
        switch id {
        case Self.straightenID: straighten = v * Self.straightenLimit
        case Self.verticalID: vertical = v * Self.tiltLimit
        case Self.horizontalID: horizontal = v * Self.tiltLimit
        default: break
        }
    }

    /// It with the tools `off` (switched off) at 0, as it's drawn.
    public func without(_ off: Set<String>) -> HangarGeometry {
        var g = self
        for id in Self.toolIDs where off.contains(id) { g.set(id, to: 0) }
        return g
    }

    /// Whether it leaves the picture as it was.
    public var isIdentity: Bool {
        self == .identity || (straighten == 0 && vertical == 0 && horizontal == 0 && turns % 4 == 0 && !flipped
                              && aspect == nil && (crop == nil || crop == CGRect(x: 0, y: 0, width: 1, height: 1)))
    }

    /// Whether it's turned on its side: the picture shown is as wide as it was high.
    public var isSideways: Bool { turns % 2 != 0 }

    // MARK: Where things go

    /// The lens a tilt is seen through, for a picture of `size`: Photos' (a 28 mm lens on a 35 mm frame, measured
    /// across its diagonal), so a tilt looks as the same tilt of the camera would have.
    public static func focalLength(for size: CGSize) -> Double {
        28 / hypot(36, 24) * Double(hypot(size.width, size.height))
    }

    /// The tilt and straightening of a picture of `size`, on points from its middle (y down), in its pixels.
    public func warp(for size: CGSize) -> HangarWarp {
        var warp = HangarWarp.identity
        if vertical != 0 || horizontal != 0 {
            let f = Self.focalLength(for: size)
            // Here v > 0 brings the top (y < 0) nearer; Photos' Vertical takes it back.
            let (cv, sv, ch, sh) = (cos(-vertical), sin(-vertical), cos(horizontal), sin(horizontal))
            // The picture a plane f in front of the eye, turned by Horizontal about its upright and by Vertical about
            // its level, and seen again from where it was: (x, y, f) turned, then brought back to the plane.
            // R = Ry(h) · Rx(v), with the top (y < 0) coming nearer for v > 0 and the right for h > 0.
            let r = [ch, sh * sv, sh * cv,
                     0, cv, -sv,
                     -sh, ch * sv, ch * cv]
            // K R K⁻¹, K = diag(f, f, 1).
            var tilt = HangarWarp(m: [r[0], r[1], r[2] * f,
                                      r[3], r[4], r[5] * f,
                                      r[6] / f, r[7] / f, r[8]])
            // Its middle kept where it was.
            let middle = tilt.apply(.zero)
            tilt = HangarWarp.translation(-middle.x, -middle.y) * tilt
            warp = tilt
        }
        if straighten != 0 {
            // Counter-clockwise on the screen.
            warp = HangarWarp.rotation(-straighten) * warp
        }
        return warp
    }

    /// The picture's corners once tilted and straightened, from its middle (y down): top left, top right, bottom
    /// right, bottom left.
    public func outline(for size: CGSize) -> [CGPoint] {
        let warp = warp(for: size)
        let (w, h) = (size.width / 2, size.height / 2)
        return [CGPoint(x: -w, y: -h), CGPoint(x: w, y: -h), CGPoint(x: w, y: h), CGPoint(x: -w, y: h)].map(warp.apply)
    }

    /// The crop in the picture's pixels, from its middle (y down).
    public func cropRect(for size: CGSize) -> CGRect {
        guard let crop else { return fittedCrop(for: size) }
        return Self.pixels(crop, size)
    }

    /// As much of the picture as there is once tilted and straightened, in the shape kept (the picture's own if
    /// there's none), about its middle.
    public func fittedCrop(for size: CGSize) -> CGRect {
        let ratio = aspect?.value ?? Double(size.width / size.height)
        let whole = Self.shaped(CGRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height), ratio)
        return HangarFit.scaled(whole, into: outline(for: size), allowGrowing: true)
    }

    /// A crop in pixels from the middle (y down) as a unit square's part, and back.
    public static func unit(_ rect: CGRect, _ size: CGSize) -> CGRect {
        CGRect(x: rect.minX / size.width + 0.5, y: rect.minY / size.height + 0.5, width: rect.width / size.width, height: rect.height / size.height)
    }

    public static func pixels(_ unit: CGRect, _ size: CGSize) -> CGRect {
        CGRect(x: (unit.minX - 0.5) * size.width, y: (unit.minY - 0.5) * size.height, width: unit.width * size.width, height: unit.height * size.height)
    }

    /// The largest of `ratio`'s shape in `rect`, about its middle.
    static func shaped(_ rect: CGRect, _ ratio: Double) -> CGRect {
        var size = rect.size
        if size.width / size.height > ratio { size.width = size.height * ratio } else { size.height = size.width / ratio }
        return CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height)
    }

    /// The size of what's kept as it's shown (turned), for a picture of `size`.
    public func shownSize(for size: CGSize) -> CGSize {
        let crop = cropRect(for: size)
        let w = max(1, crop.width.rounded()), h = max(1, crop.height.rounded())
        return isSideways ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
    }

    /// The turns and the flip, on points from the middle (y down): what the editor's shown picture is from the
    /// picture's own frame.
    public var orientation: CGAffineTransform {
        // A quarter to the left on the screen (y down) takes (x, y) to (y, -x).
        var t = CGAffineTransform.identity
        for _ in 0..<((turns % 4 + 4) % 4) { t = t.concatenating(CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: 0)) }
        if flipped { t = t.concatenating(CGAffineTransform(scaleX: -1, y: 1)) }
        return t
    }

    /// Where a point of a picture of `size` (its pixels from its top left, y down) is in the picture as it's shown
    /// (`apply`: tilted, straightened, cropped, turned and flipped; from its top left, y down).
    public func shownPoint(_ point: CGPoint, size: CGSize) -> CGPoint {
        let middle = CGPoint(x: point.x - size.width / 2, y: point.y - size.height / 2)
        let warped = warp(for: size).apply(middle)
        let (corner, kept) = keptCorner(for: size)
        let inKept = CGPoint(x: warped.x - corner.x - kept.width / 2, y: warped.y - corner.y - kept.height / 2)
        let turned = isSideways ? CGSize(width: kept.height, height: kept.width) : kept
        let out = inKept.applying(orientation)
        return CGPoint(x: out.x + turned.width / 2, y: out.y + turned.height / 2)
    }

    /// Where a point of the picture as it's shown (from its top left, y down) is in the picture of `size` itself
    /// (its pixels from its top left, y down): what a finger on the shown picture touches of it.
    public func picturePoint(_ shown: CGPoint, size: CGSize) -> CGPoint {
        let (corner, kept) = keptCorner(for: size)
        let turned = isSideways ? CGSize(width: kept.height, height: kept.width) : kept
        let inKept = CGPoint(x: shown.x - turned.width / 2, y: shown.y - turned.height / 2).applying(orientation.inverted())
        let warped = CGPoint(x: inKept.x + corner.x + kept.width / 2, y: inKept.y + corner.y + kept.height / 2)
        let middle = warp(for: size).inverted.apply(warped)
        return CGPoint(x: middle.x + size.width / 2, y: middle.y + size.height / 2)
    }

    /// The kept part's top left from the middle (y down) once tilted and straightened, and its size, as `apply` keeps it.
    private func keptCorner(for size: CGSize) -> (CGPoint, CGSize) {
        guard !isIdentity else { return (CGPoint(x: -size.width / 2, y: -size.height / 2), size) }
        let crop = cropRect(for: size)
        let kept = CGSize(width: max(1, crop.width.rounded()), height: max(1, crop.height.rounded()))
        return (CGPoint(x: crop.midX - kept.width / 2, y: crop.midY - kept.height / 2), kept)
    }

    // MARK: Drawing

    /// The picture tilted, straightened, cropped, turned and flipped, its corner at the origin. `image` is the
    /// picture whole (any size: a preview is cropped as the full one is).
    public func apply(to image: CIImage) -> CIImage {
        guard !isIdentity else { return image }
        let extent = image.extent
        let size = extent.size
        // From the middle, y down, to Core Image's (y up).
        let middle = CGPoint(x: extent.midX, y: extent.midY)
        func ci(_ p: CGPoint) -> CGPoint { CGPoint(x: middle.x + p.x, y: middle.y - p.y) }
        var out = image
        if straighten != 0 || vertical != 0 || horizontal != 0 {
            let corners = outline(for: size).map(ci)
            // The edge carried on outward, so the crop's edges (on or just inside the outline) are never part clear.
            out = image.clampedToExtent().applyingFilter("CIPerspectiveTransformWithExtent", parameters: [
                "inputExtent": CIVector(cgRect: extent),
                "inputTopLeft": CIVector(cgPoint: corners[0]),
                "inputTopRight": CIVector(cgPoint: corners[1]),
                "inputBottomRight": CIVector(cgPoint: corners[2]),
                "inputBottomLeft": CIVector(cgPoint: corners[3]),
            ])
        }
        let crop = cropRect(for: size)
        let shown = CGSize(width: max(1, crop.width.rounded()), height: max(1, crop.height.rounded()))
        let corner = ci(CGPoint(x: crop.midX - shown.width / 2, y: crop.midY + shown.height / 2))
        let kept = CGRect(origin: corner, size: shown)
        out = out.cropped(to: kept).transformed(by: CGAffineTransform(translationX: -kept.minX, y: -kept.minY))
        // Turned a quarter to the left at a time, and flipped, about the kept part's middle (y up: to the left is
        // counter-clockwise here too).
        let quarters = (turns % 4 + 4) % 4
        if quarters != 0 || flipped {
            var t = CGAffineTransform(translationX: -shown.width / 2, y: -shown.height / 2)
            t = t.concatenating(CGAffineTransform(rotationAngle: CGFloat(quarters) * .pi / 2))
            if flipped { t = t.concatenating(CGAffineTransform(scaleX: -1, y: 1)) }
            let turned = quarters % 2 == 0 ? shown : CGSize(width: shown.height, height: shown.width)
            t = t.concatenating(CGAffineTransform(translationX: turned.width / 2, y: turned.height / 2))
            out = out.transformed(by: t)
            out = out.cropped(to: CGRect(origin: .zero, size: turned))
        }
        return out
    }

    // An edit kept by an older version opens in a newer one.
    private enum CodingKeys: String, CodingKey {
        case straighten, vertical, horizontal, crop, aspect, turns, flipped
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        straighten = try c.decodeIfPresent(Double.self, forKey: .straighten) ?? 0
        vertical = try c.decodeIfPresent(Double.self, forKey: .vertical) ?? 0
        horizontal = try c.decodeIfPresent(Double.self, forKey: .horizontal) ?? 0
        crop = try c.decodeIfPresent(CGRect.self, forKey: .crop)
        aspect = try c.decodeIfPresent(HangarRatio.self, forKey: .aspect)
        turns = try c.decodeIfPresent(Int.self, forKey: .turns) ?? 0
        flipped = try c.decodeIfPresent(Bool.self, forKey: .flipped) ?? false
    }
}

/// A plane's projective map (a homography), on points (x, y): row by row, acting on (x, y, 1).
public struct HangarWarp: Hashable, Sendable {
    public var m: [Double]

    public init(m: [Double]) {
        self.m = m
    }

    public static let identity = HangarWarp(m: [1, 0, 0, 0, 1, 0, 0, 0, 1])

    public static func translation(_ x: Double, _ y: Double) -> HangarWarp {
        HangarWarp(m: [1, 0, x, 0, 1, y, 0, 0, 1])
    }

    /// Clockwise on the screen (y down).
    public static func rotation(_ angle: Double) -> HangarWarp {
        let (c, s) = (cos(angle), sin(angle))
        return HangarWarp(m: [c, -s, 0, s, c, 0, 0, 0, 1])
    }

    public static func scale(_ s: Double) -> HangarWarp {
        HangarWarp(m: [s, 0, 0, 0, s, 0, 0, 0, 1])
    }

    public init(_ t: CGAffineTransform) {
        m = [t.a, t.c, t.tx, t.b, t.d, t.ty, 0, 0, 1].map { Double($0) }
    }

    public func apply(_ p: CGPoint) -> CGPoint {
        let x = Double(p.x), y = Double(p.y)
        let w = m[6] * x + m[7] * y + m[8]
        return CGPoint(x: (m[0] * x + m[1] * y + m[2]) / w, y: (m[3] * x + m[4] * y + m[5]) / w)
    }

    /// `a` after `b`.
    public static func * (a: HangarWarp, b: HangarWarp) -> HangarWarp {
        var out = [Double](repeating: 0, count: 9)
        for r in 0..<3 {
            for c in 0..<3 {
                out[r * 3 + c] = a.m[r * 3] * b.m[c] + a.m[r * 3 + 1] * b.m[3 + c] + a.m[r * 3 + 2] * b.m[6 + c]
            }
        }
        return HangarWarp(m: out)
    }

    public var inverted: HangarWarp {
        let a = m
        let c0 = a[4] * a[8] - a[5] * a[7], c1 = a[5] * a[6] - a[3] * a[8], c2 = a[3] * a[7] - a[4] * a[6]
        let det = a[0] * c0 + a[1] * c1 + a[2] * c2
        guard abs(det) > 1e-12 else { return .identity }
        let inv = [c0, a[2] * a[7] - a[1] * a[8], a[1] * a[5] - a[2] * a[4],
                   c1, a[0] * a[8] - a[2] * a[6], a[2] * a[3] - a[0] * a[5],
                   c2, a[1] * a[6] - a[0] * a[7], a[0] * a[4] - a[1] * a[3]]
        return HangarWarp(m: inv.map { $0 / det })
    }
}

/// Keeping a crop inside the picture's outline (a convex quadrilateral, its corners in order).
public enum HangarFit {
    /// Whether `rect` is inside `outline` (to within `slack`).
    public static func contains(_ outline: [CGPoint], _ rect: CGRect, slack: CGFloat = 0.01) -> Bool {
        corners(rect).allSatisfy { inside(outline, $0, slack: slack) }
    }

    public static func inside(_ outline: [CGPoint], _ p: CGPoint, slack: CGFloat = 0.01) -> Bool {
        let sign = orientation(outline)
        for i in outline.indices {
            let a = outline[i], b = outline[(i + 1) % outline.count]
            let cross = (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x)
            let length = hypot(b.x - a.x, b.y - a.y)
            if sign * cross / max(length, 1e-9) < -slack { return false }
        }
        return true
    }

    /// `rect` scaled about its middle to be as large as fits in `outline` (no larger than it is unless
    /// `allowGrowing`); if its middle isn't in it, about the outline's middle instead.
    public static func scaled(_ rect: CGRect, into outline: [CGPoint], allowGrowing: Bool = false) -> CGRect {
        var middle = CGPoint(x: rect.midX, y: rect.midY)
        if !inside(outline, middle, slack: 0) { middle = centroid(outline) }
        let s = largestScale(half: CGSize(width: rect.width / 2, height: rect.height / 2), at: middle, in: outline)
        let k = allowGrowing ? s : min(1, s)
        return CGRect(x: middle.x - rect.width / 2 * k, y: middle.y - rect.height / 2 * k, width: rect.width * k, height: rect.height * k)
    }

    /// `rect` moved as little as it takes to be inside `outline`, its size kept (made smaller only if it can't fit
    /// anywhere as it is).
    public static func moved(_ rect: CGRect, into outline: [CGPoint]) -> CGRect {
        guard !contains(outline, rect) else { return rect }
        var r = rect
        // Too large to fit even in the middle: as large as it fits there, about its own middle.
        let middle = centroid(outline)
        let k = min(1, largestScale(half: CGSize(width: r.width / 2, height: r.height / 2), at: middle, in: outline))
        if k < 1 {
            r = CGRect(x: r.midX - r.width * k / 2, y: r.midY - r.height * k / 2, width: r.width * k, height: r.height * k)
        }
        // Pushed in off each edge it crosses, over and over: settles inside, near where it was.
        let sign = orientation(outline)
        for _ in 0..<200 {
            var moved = false
            for i in outline.indices {
                let a = outline[i], b = outline[(i + 1) % outline.count]
                let length = hypot(b.x - a.x, b.y - a.y)
                guard length > 1e-9 else { continue }
                // Inward normal.
                let n = CGPoint(x: -(b.y - a.y) / length * sign, y: (b.x - a.x) / length * sign)
                let worst = corners(r).map { ($0.x - a.x) * n.x + ($0.y - a.y) * n.y }.min() ?? 0
                if worst < -0.001 {
                    r = r.offsetBy(dx: -worst * n.x, dy: -worst * n.y)
                    moved = true
                }
            }
            if !moved { break }
        }
        if !contains(outline, r) { return scaled(r, into: outline) }
        return r
    }

    /// How many times `half` (a rect's half width and height) about `middle` fits in `outline`.
    static func largestScale(half: CGSize, at middle: CGPoint, in outline: [CGPoint]) -> CGFloat {
        let sign = orientation(outline)
        var best = CGFloat.greatestFiniteMagnitude
        for i in outline.indices {
            let a = outline[i], b = outline[(i + 1) % outline.count]
            let length = hypot(b.x - a.x, b.y - a.y)
            guard length > 1e-9 else { continue }
            let n = CGPoint(x: -(b.y - a.y) / length * sign, y: (b.x - a.x) / length * sign)
            // Distance from the edge to the middle, inward.
            let room = (middle.x - a.x) * n.x + (middle.y - a.y) * n.y
            // The corner reaching furthest outward.
            let reach = abs(half.width * n.x) + abs(half.height * n.y)
            guard reach > 1e-9 else { continue }
            best = min(best, max(0, room) / reach)
        }
        return best == .greatestFiniteMagnitude ? 1 : best
    }

    static func corners(_ r: CGRect) -> [CGPoint] {
        [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)]
    }

    static func centroid(_ points: [CGPoint]) -> CGPoint {
        let n = CGFloat(max(points.count, 1))
        return CGPoint(x: points.reduce(0) { $0 + $1.x } / n, y: points.reduce(0) { $0 + $1.y } / n)
    }

    /// 1 for corners going clockwise on the screen (y down), -1 the other way.
    static func orientation(_ outline: [CGPoint]) -> CGFloat {
        var area: CGFloat = 0
        for i in outline.indices {
            let a = outline[i], b = outline[(i + 1) % outline.count]
            area += a.x * b.y - b.x * a.y
        }
        return area >= 0 ? 1 : -1
    }
}
