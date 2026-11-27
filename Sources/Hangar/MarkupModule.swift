import HangarCore
import UIKit

public extension HangarMode {
    static let markup = HangarMode("markup")
}

/// Drawing on the picture (`HangarDrawing`): a pen, a shape dragged out (a line, an arrow, a rectangle, an ellipse,
/// a triangle, a diamond, a star, a heart) or the eraser taking out what's drawn, in a colour and a width. Each mark is
/// a step to undo to. The marks are kept on the picture under its geometry (a crop later keeps them on what they're
/// on), drawn over it as it's shown; while it's chosen it draws them itself, over the canvas, the bars going while
/// a finger draws.
@MainActor
public final class HangarMarkupModule: HangarModule {
    public let item = HangarModeItem(id: HangarMode.markup.id, name: "Markup", symbol: "pencil.tip.crop.circle",
                                     chosenSymbol: "pencil.tip.crop.circle.fill")

    /// The colours offered, as they're kept; any other from the colour well.
    public var colors = ["#FFFFFF", "#000000", "#8E8E93", "#FF3B30", "#FF9500", "#FFCC00", "#34C759", "#007AFF", "#AF52DE"]
    /// How wide a mark's drawn, in points on the screen as the picture's shown then.
    public var widths: ClosedRange<CGFloat> = 2...40
    /// How wide the pen and shapes are at first, and the eraser (each keeps its own).
    public var firstWidth: CGFloat = 8
    public var firstEraserWidth: CGFloat = 24

    private weak var host: (any HangarHost)?
    private let stage = MarkupStage()
    private var tools: MarkupTools!
    private var palette: MarkupPalette!
    private var ruler: Ruler!
    private var chosen = false
    private var kind: HangarMark.Kind = .pen
    private var shape: HangarMark.Kind = .arrow
    private var color = "#FFFFFF"
    private var drawWidth: CGFloat = 8
    private var eraserWidth: CGFloat = 24
    /// The chosen tool's width.
    private var width: CGFloat {
        get { kind == .eraser ? eraserWidth : drawWidth }
        set { if kind == .eraser { eraserWidth = newValue } else { drawWidth = newValue } }
    }

    public init() {}

    public var chrome: [UIView] { [tools, palette, ruler] }

    public func load(in host: any HangarHost) {
        self.host = host
        let style = host.style
        tools = MarkupTools(style: style)
        tools.onChoose = { [weak self] kind in self?.choose(kind) }
        palette = MarkupPalette(style: style, colors: colors)
        palette.onChoose = { [weak self] color in self?.color = color }
        ruler = Ruler(style: style)
        drawWidth = firstWidth
        eraserWidth = firstEraserWidth
        ruler.range = 0...1
        ruler.magnet = nil
        ruler.accessibilityLabel = "Width"
        ruler.onChange = { [weak self] value in
            guard let self else { return }
            self.width = self.widths.lowerBound + CGFloat(value) * (self.widths.upperBound - self.widths.lowerBound)
        }
        setRuler()
        stage.onBegin = { [weak self] in self?.drawing(true) }
        stage.onEnd = { [weak self] mark in self?.drawn(mark) }
        stage.make = { [weak self] points in self?.mark(points) }
        stage.isHidden = true
        tools.choose(kind, shape: shape)
        palette.choose(color)
        host.add(stage, at: .picture)
        host.add(tools, at: .controls)
        host.add(palette, at: .controls)
        host.add(ruler, at: .controls)
    }

    public func layout(_ layout: HangarLayout) {
        tools.axis = layout.sideways ? .vertical : .horizontal
        palette.axis = tools.axis
        ruler.axis = layout.sideways ? .along : .across
        ruler.frame = layout.ruler
        let toolsSize = tools.fittingSize
        let paletteSize = palette.fittingSize
        if layout.sideways {
            // Down the right as the tools are on an iPad, the colours in a column beside them.
            tools.frame = CGRect(x: layout.tools.midX - toolsSize.width / 2, y: layout.tools.midY - toolsSize.height / 2,
                                 width: toolsSize.width, height: toolsSize.height)
            palette.frame = CGRect(x: tools.frame.minX - 16 - paletteSize.width, y: layout.tools.midY - paletteSize.height / 2,
                                   width: paletteSize.width, height: paletteSize.height)
        } else {
            // Where Adjust's tools are, the colours where its name is (it shows none), the width on the ruler.
            tools.frame = CGRect(x: layout.tools.midX - toolsSize.width / 2, y: layout.tools.midY - toolsSize.height / 2,
                                 width: toolsSize.width, height: toolsSize.height)
            let across = min(paletteSize.width, layout.tools.width)
            palette.frame = CGRect(x: layout.tools.midX - across / 2, y: layout.modeBar.minY - 151.7 - paletteSize.height / 2,
                                   width: across, height: paletteSize.height)
        }
        placeStage()
    }

    public func show(_ shown: Bool) {
        chosen = shown
        tools.isHidden = !shown
        palette.isHidden = !shown
        ruler.isHidden = !shown
        // It draws the marks itself while it's chosen (its eraser taking out what's under it), the canvas not.
        host?.showsDrawing = !shown
        if shown {
            syncStage()
            stage.isHidden = false
        } else {
            stage.isHidden = true
        }
        // The colours where the name would be (on an iPad, beside the tools); its name's in the top bar there.
        if shown { host?.showName(nil) }
    }

    /// The ruler at the chosen tool's width, its first width marked.
    private func setRuler() {
        let span = widths.upperBound - widths.lowerBound
        ruler.marked = Double(((kind == .eraser ? firstEraserWidth : firstWidth) - widths.lowerBound) / span)
        ruler.set(Double((width - widths.lowerBound) / span))
    }

    public func entered() {
        placeStage()
    }

    public func sync() {
        syncStage()
    }

    public func pictureChanged() {
        syncStage()
    }

    public func stop() {
        ruler.stop()
        stage.cancel()
    }

    public func closing() {
        stage.isHidden = true
    }

    /// The original as it was, with nothing drawn on it.
    public func showOriginal(_ shown: Bool) {
        stage.isHidden = shown || !chosen
    }

    // MARK: Drawing

    private func choose(_ kind: HangarMark.Kind) {
        if kind.isShape { shape = kind }
        let erasing = self.kind == .eraser
        self.kind = kind
        tools.choose(kind, shape: shape)
        if erasing != (kind == .eraser) { setRuler() }
    }

    private func placeStage() {
        guard let host else { return }
        stage.frame = host.canvasFrame
        syncStage()
    }

    private func syncStage() {
        guard let host else { return }
        stage.drawing = host.edit.drawing
        stage.geometry = host.edit.appliedGeometry
        stage.base = host.base?.image.extent.size ?? .zero
        stage.setNeedsDisplay()
    }

    /// The mark the finger's making, from where it's touched the picture as it's shown (its points in the stage's).
    private func mark(_ points: [CGPoint]) -> HangarMark? {
        guard let first = points.first, let last = points.last, stage.base.width > 0, stage.base.height > 0 else { return nil }
        let geometry = stage.geometry
        let upright = geometry.straighten == 0 && geometry.vertical == 0 && geometry.horizontal == 0 && geometry.turns % 4 == 0 && !geometry.flipped
        let marked: [CGPoint]
        if kind.isShape && !kind.isLine && !upright {
            // The box upright as it's shown: its top left, top right and bottom left on the picture under it.
            let (minX, maxX, minY, maxY) = (min(first.x, last.x), max(first.x, last.x), min(first.y, last.y), max(first.y, last.y))
            marked = [CGPoint(x: minX, y: minY), CGPoint(x: maxX, y: minY), CGPoint(x: minX, y: maxY)].map(stage.picturePoint)
        } else if kind.isShape {
            marked = [first, last].map(stage.picturePoint)
        } else {
            marked = points.map(stage.picturePoint)
        }
        // As wide on the picture as it's drawn on the screen.
        let across = width / max(stage.pointsPerPixel * min(stage.base.width, stage.base.height), 0.0001)
        return HangarMark(kind, points: marked, width: across, color: kind == .eraser ? nil : color)
    }

    /// The bars go while a finger draws, and the mode's own controls dim (to see the picture).
    private func drawing(_ now: Bool) {
        host?.showBars(!now, duration: 0.25, delay: now ? 0 : 0.2)
        UIView.animate(withDuration: 0.25, delay: now ? 0 : 0.2, options: [.beginFromCurrentState, .allowUserInteraction]) {
            for view in [self.tools, self.palette, self.ruler] as [UIView] { view.alpha = now ? 0.25 : 1 }
        }
    }

    private func drawn(_ mark: HangarMark?) {
        drawing(false)
        // A shape with no size, or an eraser over nothing drawn: no step.
        guard let host, let mark, !mark.outline(size: stage.base).isEmpty, mark.kind != .eraser || !host.edit.drawing.isEmpty else {
            syncStage()
            return
        }
        host.edit.drawing.marks.append(mark)
        host.commit()
    }
}

// MARK: - The stage

/// Over the canvas while Markup's chosen: the marks as the picture's shown, and the one a finger's making, drawn
/// again as it moves (the eraser taking out what's under it).
@MainActor
final class MarkupStage: UIView {
    var drawing = HangarDrawing()
    var geometry = HangarGeometry.identity
    /// The picture under the geometry (the steps'), in pixels: what the marks' points are 0 to 1 of.
    var base = CGSize.zero
    var onBegin: (() -> Void)?
    var onEnd: ((HangarMark?) -> Void)?
    /// The mark from the points touched so far.
    var make: (([CGPoint]) -> HangarMark?)?
    private var touched: [CGPoint] = []
    private var current: HangarMark?
    private var touch: UITouch?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        contentMode = .redraw
        isMultipleTouchEnabled = false
        accessibilityLabel = "Drawing"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The picture as it's shown, in pixels.
    private var shownSize: CGSize {
        guard base.width > 0, base.height > 0 else { return bounds.size }
        return geometry.isIdentity ? base : geometry.shownSize(for: base)
    }

    /// The screen's points for each of the picture's pixels, as it's shown.
    var pointsPerPixel: CGFloat {
        bounds.width / max(shownSize.width, 1)
    }

    /// Where a point of the stage is on the picture under the geometry, 0 to 1 each way.
    func picturePoint(_ point: CGPoint) -> CGPoint {
        let shown = shownSize
        let s = CGPoint(x: point.x / max(bounds.width, 1) * shown.width, y: point.y / max(bounds.height, 1) * shown.height)
        let p = geometry.isIdentity ? s : geometry.picturePoint(s, size: base)
        return CGPoint(x: p.x / base.width, y: p.y / base.height)
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext(), base.width > 0 else { return }
        var all = drawing
        if let current { all.marks.append(current) }
        all.drawShown(in: context, base: base, geometry: geometry, into: bounds)
    }

    func cancel() {
        guard touch != nil else { return }
        touch = nil
        touched = []
        current = nil
        setNeedsDisplay()
        onEnd?(nil)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard touch == nil, let first = touches.first else { return }
        touch = first
        touched = [first.location(in: self)]
        current = make?(touched)
        setNeedsDisplay()
        onBegin?()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch, touches.contains(touch) else { return }
        // Every point the screen took between frames, for a smooth line.
        for sample in event?.coalescedTouches(for: touch) ?? [touch] {
            let point = sample.location(in: self)
            if let last = touched.last, hypot(point.x - last.x, point.y - last.y) < 0.75 { continue }
            touched.append(point)
        }
        current = make?(touched)
        setNeedsDisplay()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch, touches.contains(touch) else { return }
        self.touch = nil
        touched.append(touch.location(in: self))
        let mark = make?(touched)
        touched = []
        current = nil
        // Drawn with the rest until the edit has it.
        if let mark { drawing.marks.append(mark) }
        setNeedsDisplay()
        onEnd?(mark)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch, touches.contains(touch) else { return }
        cancel()
    }
}

extension HangarDrawing {
    /// Draws the marks into `context` (y down) as the picture under `geometry` (`base` in pixels) is shown in `frame`:
    /// each point where the geometry takes it, each line as much wider as the picture's shown larger.
    func drawShown(in context: CGContext, base: CGSize, geometry: HangarGeometry, into frame: CGRect) {
        let shown = geometry.isIdentity ? base : geometry.shownSize(for: base)
        let fx = frame.width / max(shown.width, 1), fy = frame.height / max(shown.height, 1)
        draw(in: context, size: base, scale: (fx + fy) / 2) { p in
            let s = geometry.isIdentity ? p : geometry.shownPoint(p, size: base)
            return CGPoint(x: frame.minX + s.x * fx, y: frame.minY + s.y * fy)
        }
    }

    /// The marks as the picture under `geometry` (`base` in pixels) is shown at `size` pixels, on a clear picture.
    func shownImage(base: CGSize, geometry: HangarGeometry, size: CGSize) -> CGImage? {
        let width = Int(size.width.rounded()), height = Int(size.height.rounded())
        guard !isEmpty, width > 0, height > 0, base.width > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        drawShown(in: context, base: base, geometry: geometry, into: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}

// MARK: - The controls

/// The pen, the shape (the last one chosen; tapped again, the others) and the eraser, on a capsule.
@MainActor
final class MarkupTools: UIView {
    var onChoose: ((HangarMark.Kind) -> Void)?
    var axis: NSLayoutConstraint.Axis = .horizontal {
        didSet { setNeedsLayout() }
    }

    private let capsule: UIVisualEffectView
    private let pen: UIButton
    private let shape: UIButton
    private let eraser: UIButton
    private let style: HangarStyle
    static let cell: CGFloat = 44

    static func symbol(_ kind: HangarMark.Kind) -> String {
        switch kind {
        case .pen: "scribble.variable"
        case .line: "line.diagonal"
        case .arrow: "arrow.up.right"
        case .rectangle: "rectangle"
        case .ellipse: "circle"
        case .triangle: "triangle"
        case .diamond: "diamond"
        case .star: "star"
        case .heart: "heart"
        case .eraser: "eraser"
        }
    }

    static func name(_ kind: HangarMark.Kind) -> String {
        switch kind {
        case .pen: "Pen"
        case .line: "Line"
        case .arrow: "Arrow"
        case .rectangle: "Rectangle"
        case .ellipse: "Ellipse"
        case .triangle: "Triangle"
        case .diamond: "Diamond"
        case .star: "Star"
        case .heart: "Heart"
        case .eraser: "Eraser"
        }
    }

    init(style: HangarStyle) {
        self.style = style
        capsule = Chrome.capsule(style)
        pen = Chrome.plainButton(Self.symbol(.pen), label: Self.name(.pen), style: style)
        shape = Chrome.plainButton(Self.symbol(.arrow), label: "Shape", style: style)
        eraser = Chrome.plainButton(Self.symbol(.eraser), label: Self.name(.eraser), style: style)
        super.init(frame: .zero)
        addSubview(capsule)
        for button in [pen, shape, eraser] { capsule.contentView.addSubview(button) }
        pen.addAction(UIAction { [weak self] _ in self?.onChoose?(.pen) }, for: .primaryActionTriggered)
        eraser.addAction(UIAction { [weak self] _ in self?.onChoose?(.eraser) }, for: .primaryActionTriggered)
        shape.addAction(UIAction { [weak self] _ in self?.onChoose?(self?.shownShape ?? .arrow) }, for: .primaryActionTriggered)
        // The shapes in two rows of four, as icons.
        let row = { (kinds: [HangarMark.Kind]) in
            let menu = UIMenu(options: .displayInline, children: kinds.map { kind in
                UIAction(title: Self.name(kind), image: UIImage(systemName: Self.symbol(kind))) { [weak self] _ in self?.onChoose?(kind) }
            })
            menu.preferredElementSize = .small
            return menu
        }
        shape.menu = UIMenu(children: [row([.line, .arrow, .rectangle, .ellipse]), row([.triangle, .diamond, .star, .heart])])
        // The rows as they are, opening up or down.
        shape.preferredMenuElementOrder = .fixed
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private var shownShape: HangarMark.Kind = .arrow

    var fittingSize: CGSize {
        let long = Self.cell * 3 + 8, short = Self.cell + 8
        return axis == .horizontal ? CGSize(width: long, height: short) : CGSize(width: short, height: long)
    }

    /// The tool chosen marked; the shape button showing the shape it draws (and, chosen, opening the others).
    func choose(_ kind: HangarMark.Kind, shape kindOfShape: HangarMark.Kind) {
        shownShape = kindOfShape
        shape.configuration?.image = UIImage(systemName: Self.symbol(kindOfShape),
                                             withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .medium))
        shape.accessibilityValue = Self.name(kindOfShape)
        // Tapped while it's the tool: the shapes to choose from.
        shape.showsMenuAsPrimaryAction = kind.isShape
        for (button, on) in [(pen, kind == .pen), (shape, kind.isShape), (eraser, kind == .eraser)] {
            button.configuration?.background.backgroundColor = on ? style.foreground.withAlphaComponent(0.12) : .clear
            button.configuration?.background.cornerRadius = Self.cell / 2
            button.accessibilityTraits = on ? [.button, .selected] : .button
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        capsule.frame = bounds
        Chrome.round(capsule)
        for (i, button) in [pen, shape, eraser].enumerated() {
            let at = 4 + Self.cell * CGFloat(i)
            button.frame = axis == .horizontal ? CGRect(x: at, y: 4, width: Self.cell, height: Self.cell)
                : CGRect(x: 4, y: at, width: Self.cell, height: Self.cell)
        }
    }
}

/// The colours to draw in, the chosen one ringed, and a well for any other.
@MainActor
final class MarkupPalette: UIView {
    var onChoose: ((String) -> Void)?
    var axis: NSLayoutConstraint.Axis = .horizontal {
        didSet { setNeedsLayout() }
    }

    private let style: HangarStyle
    private let colors: [String]
    private var swatches: [UIButton] = []
    private let well = UIColorWell()
    private var chosen = ""
    static let side: CGFloat = 28
    static let gap: CGFloat = 8

    init(style: HangarStyle, colors: [String]) {
        self.style = style
        self.colors = colors
        super.init(frame: .zero)
        well.supportsAlpha = false
        well.title = "Colour"
        well.addAction(UIAction { [weak self] _ in
            guard let self, let color = self.well.selectedColor else { return }
            let hex = HangarMark.hex(color.cgColor)
            self.choose(hex)
            self.onChoose?(hex)
        }, for: .valueChanged)
        addSubview(well)
        swatches = colors.map { hex in
            let button = UIButton(type: .custom)
            button.backgroundColor = HangarMark.color(hex).map { UIColor(cgColor: $0) }
            button.layer.cornerRadius = Self.side / 2
            button.layer.borderColor = UIColor.separator.cgColor
            button.layer.borderWidth = 0.5
            button.accessibilityLabel = Self.spoken(hex)
            button.addAction(UIAction { [weak self] _ in
                self?.choose(hex)
                self?.onChoose?(hex)
            }, for: .touchUpInside)
            addSubview(button)
            return button
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private static func spoken(_ hex: String) -> String {
        ["#FFFFFF": "White", "#000000": "Black", "#8E8E93": "Grey", "#FF3B30": "Red", "#FF9500": "Orange", "#FFCC00": "Yellow",
         "#34C759": "Green", "#007AFF": "Blue", "#AF52DE": "Purple"][hex.uppercased()] ?? hex
    }

    var fittingSize: CGSize {
        let count = CGFloat(colors.count + 1)
        let long = count * Self.side + (count - 1) * Self.gap + 8, short = Self.side + 8
        return axis == .horizontal ? CGSize(width: long, height: short) : CGSize(width: short, height: long)
    }

    /// The chosen colour ringed: one of its swatches, or the well's.
    func choose(_ hex: String) {
        chosen = hex.uppercased()
        let mine = colors.contains { $0.uppercased() == chosen }
        for (button, color) in zip(swatches, colors) {
            let on = color.uppercased() == chosen
            button.layer.borderColor = on ? style.foreground.cgColor : UIColor.separator.cgColor
            button.layer.borderWidth = on ? 2.5 : 0.5
            button.transform = on ? CGAffineTransform(scaleX: 1.12, y: 1.12) : .identity
            button.accessibilityTraits = on ? [.button, .selected] : .button
        }
        if !mine, let color = HangarMark.color(hex) { well.selectedColor = UIColor(cgColor: color) }
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        choose(chosen)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        for (i, view) in ([well] + swatches as [UIView]).enumerated() {
            let at = 4 + CGFloat(i) * (Self.side + Self.gap)
            let frame = axis == .horizontal ? CGRect(x: at, y: 4, width: Self.side, height: Self.side)
                : CGRect(x: 4, y: at, width: Self.side, height: Self.side)
            // Transformed while chosen: placed by its middle.
            view.bounds = CGRect(origin: .zero, size: frame.size)
            view.center = CGPoint(x: frame.midX, y: frame.midY)
        }
    }
}
