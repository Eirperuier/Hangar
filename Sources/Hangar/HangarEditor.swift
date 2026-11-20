import Flight
import HangarCore
import UIKit

/// Where the picture was before the editor opened, to fly out of it and back into it: a view, the picture's frame
/// in it (all of it if nil), and its corners. Asked again as the editor closes, so a source that moved meanwhile is
/// landed on where it is.
public struct HangarSource {
    public var view: UIView
    public var frame: CGRect?
    public var cornerRadius: CGFloat

    public init(view: UIView, frame: CGRect? = nil, cornerRadius: CGFloat = 0) {
        self.view = view
        self.frame = frame
        self.cornerRadius = cornerRadius
    }
}

/// What the editor gives back when it's done: the edit, the picture edited at the editor's size (about the screen's,
/// at once), and the full picture edited when asked (`render()`, off the main thread).
public struct HangarResult: Sendable {
    public let edit: HangarEdit
    public let preview: UIImage
    let original: UIImage
    let toolbox: HangarToolbox

    /// The whole picture with the edit, its own size and colours.
    public func render() async -> UIImage? {
        let (original, edit, toolbox) = (original, edit, toolbox)
        return await Task.detached(priority: .userInitiated) {
            guard let picture = original.cgImage ?? Self.drawn(original) else { return nil }
            let orientation = CGImagePropertyOrientation(original.imageOrientation)
            guard let out = HangarRenderer(toolbox: toolbox).render(edit, to: picture, orientation: orientation) else { return nil }
            return UIImage(cgImage: out, scale: original.scale, orientation: .up)
        }.value
    }

    private static func drawn(_ image: UIImage) -> CGImage? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        return UIGraphicsImageRenderer(size: image.size, format: format).image { _ in image.draw(at: .zero) }.cgImage
    }
}

/// One of the editor's modes: Adjust and Filters (Crop and Video to come).
public struct HangarMode: Hashable, Sendable {
    public let id: String

    public init(_ id: String) {
        self.id = id
    }

    public static let adjust = HangarMode("adjust")
    public static let filters = HangarMode("filters")
}

/// Photos' editor for a picture: Adjust (Auto and fifteen adjustments, each on its ruler) and Filters (nine looks,
/// each as much as its ruler says), undo and redo a step at a time, the original under a finger held on the picture.
/// It flies out of the picture it was opened from and back into it (Flight). Its tools are the toolbox's
/// (`HangarToolbox`) and its look the style's (`HangarStyle`).
///
/// ```swift
/// let editor = HangarEditor(image: photo.original, edit: photo.edit)
/// editor.onDone = { result in photo.edit = result.edit; photo.shown = result.preview }
/// editor.present(from: self, source: HangarSource(view: cell.imageView, cornerRadius: 8))
/// ```
@MainActor
public final class HangarEditor: UIViewController {
    /// Done: the edit and the picture with it. Called before the editor flies home, so the source can show it.
    public var onDone: ((HangarResult) -> Void)?
    /// Closed without keeping anything.
    public var onCancel: (() -> Void)?

    private let original: UIImage
    private let toolbox: HangarToolbox
    private let style: HangarStyle
    private let renderer: HangarRenderer
    private let initialEdit: HangarEdit
    private var edit: HangarEdit
    private var history: [HangarEdit]
    private var historyIndex = 0
    /// The mode it's in, Adjust when it opens unless set before.
    public var mode = HangarMode.adjust {
        didSet { if isViewLoaded, mode != oldValue { setMode(mode) } }
    }
    /// The tool in the middle of the strip, and the one the ruler is set to: the same but while the strip moves,
    /// when the ruler is off (as Photos' is), so a ruler still sliding never changes the tool coming to the middle.
    private var tool: String
    private var rulerTool: String

    private var preview: CIImage?
    private var previewContext: HangarRenderContext?
    private var previewSize = CGSize(width: 1, height: 1)
    /// The preview at the canvas's size in pixels, kept on the GPU: what the canvas draws each change from, so a frame
    /// is the tools' work on the pixels shown and no more (as Photos draws for its view's size).
    private var shown: (image: CIImage, context: HangarRenderContext)?
    private var shownSize = CGSize.zero
    private var filterThumbnailsFor: HangarEdit?

    private let backdrop = UIView()
    private let canvas = CanvasView()
    private let closeButton: UIButton
    private let historyBar: UIVisualEffectView
    /// On an iPad, Photos' toggle between the original and the edit, first on the history capsule.
    private let originalButton: UIButton
    private let undoButton: UIButton
    private let redoButton: UIButton
    private let moreButton: UIButton
    private var doneButton: UIButton
    private let titleLabel = UILabel()
    private let nameLabel = UILabel()
    private let tools = Strip()
    private var toolButtons: [ToolButton] = []
    private let ruler: Ruler
    private let filters = Strip()
    private var thumbnails: [FilterThumbnail] = []
    private let loupe: FilterLoupe
    private let filterRuler: Ruler
    /// How much of each filter, as it was last set: a filter comes back as it was left (Photos'), whole the first time.
    private var filterAmounts: [String: Double] = [:]
    private let modeBar: ModeBar
    /// The bars hidden while a filter's ruler is moved (Photos', to see the picture whole).
    private var barsHidden = false

    private var source: HangarSource?
    private var flight: FlightGroup?
    private var flyer: UIImageView?
    private var entered = false
    private var leaving = false
    private var comparing = false
    private var sideways = false

    public init(image: UIImage, edit: HangarEdit = HangarEdit(), toolbox: HangarToolbox = .standard, style: HangarStyle = .system) {
        original = image
        self.toolbox = toolbox
        self.style = style
        renderer = HangarRenderer(toolbox: toolbox)
        initialEdit = edit
        self.edit = edit
        history = [edit]
        tool = toolbox.adjustments.first?.id ?? ""
        rulerTool = tool
        closeButton = Chrome.button("xmark", label: "Cancel", style: style)
        historyBar = Chrome.capsule(style)
        originalButton = Chrome.plainButton("square.and.line.vertical.and.square.filled", label: "Show Original", style: style)
        undoButton = Chrome.plainButton("arrow.uturn.backward", label: "Undo", style: style)
        redoButton = Chrome.plainButton("arrow.uturn.forward", label: "Redo", style: style)
        moreButton = Chrome.button("ellipsis", label: "More", style: style)
        doneButton = Chrome.button("checkmark", label: "Done", style: style)
        ruler = Ruler(style: style)
        filterRuler = Ruler(style: style)
        loupe = FilterLoupe(style: style, thumbnail: FilterThumbnail.side)
        modeBar = ModeBar(modes: [
            .init(id: HangarMode.adjust.id, name: "Adjust", symbol: "dial.low", chosenSymbol: "dial.low.fill"),
            .init(id: HangarMode.filters.id, name: "Filters", symbol: "camera.filters", chosenSymbol: "camera.filters"),
        ], chosen: HangarMode.adjust.id, style: style)
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
        modalPresentationCapturesStatusBarAppearance = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Opens over `presenter`, flying out of `source` (fading in without one).
    public func present(from presenter: UIViewController, source: HangarSource? = nil) {
        self.source = source
        presenter.present(self, animated: false)
    }

    /// Photos hides the status bar on a phone, not on an iPad.
    public override var prefersStatusBarHidden: Bool { traitCollection.userInterfaceIdiom == .phone }
    /// Photos' editor hides the home indicator too.
    public override var prefersHomeIndicatorAutoHidden: Bool { true }

    // MARK: Building

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        backdrop.backgroundColor = style.background
        view.addSubview(backdrop)
        view.addSubview(canvas)

        closeButton.addAction(UIAction { [weak self] _ in self?.closeTapped() }, for: .touchUpInside)
        undoButton.addAction(UIAction { [weak self] _ in self?.step(-1) }, for: .touchUpInside)
        redoButton.addAction(UIAction { [weak self] _ in self?.step(1) }, for: .touchUpInside)
        originalButton.addAction(UIAction { [weak self] _ in self?.toggleOriginal() }, for: .touchUpInside)
        historyBar.contentView.addSubview(originalButton)
        historyBar.contentView.addSubview(undoButton)
        historyBar.contentView.addSubview(redoButton)
        doneButton.addAction(UIAction { [weak self] _ in self?.doneTapped() }, for: .touchUpInside)
        moreButton.showsMenuAsPrimaryAction = true
        moreButton.menu = UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] completion in
            completion(self?.moreActions() ?? [])
        }])
        titleLabel.textAlignment = .center
        titleLabel.font = style.titleFont
        titleLabel.textColor = style.title
        nameLabel.font = style.nameFont
        nameLabel.textColor = style.secondary
        for chrome in [closeButton, historyBar, moreButton, doneButton, titleLabel, nameLabel, tools, ruler, filters, filterRuler, modeBar] as [UIView] {
            view.addSubview(chrome)
        }

        toolButtons = toolbox.adjustments.map { ToolButton($0, style: style) }
        tools.setItems(toolButtons, chosen: 0)
        tools.feel = .tools
        tools.pitch = ToolButton.size + 20
        tools.itemSize = ToolButton.size
        // Photos' tools strip: its ends fade from clear 14 points in to whole 40 in.
        tools.fadeClear = 14
        tools.fadeWhole = 40
        tools.onChoose = { [weak self] i in self?.passTool(i) }
        // The ruler off and dimmed while the strip moves (Photos'), set for the tool it rests on.
        tools.onMove = { [weak self] in self?.ruler.setState(enabled: false, dimmed: true, animated: true) }
        tools.onRest = { [weak self] i in self?.chooseTool(i) }
        tools.onTapChosen = { [weak self] i in self?.toggleTool(i) }
        tools.accessibilityLabel = "Enhancements"
        tools.spokenValue = { [weak self] i in self?.spokenTool(i) ?? "" }
        ruler.onTouch = { [weak self] in self?.rulerTouched() }
        ruler.onChange = { [weak self] value in self?.rulerMoved(value) }
        ruler.onEnd = { [weak self] _ in self?.rulerEnded() }

        let none = FilterThumbnail(id: nil, name: "Original", style: style)
        thumbnails = [none] + toolbox.filters.map { FilterThumbnail(id: $0.id, name: $0.name, style: style) }
        thumbnails.first?.end.first = true
        thumbnails.last?.end.last = true
        if let id = edit.filter { filterAmounts[id] = edit.filterAmount }
        filters.setItems(thumbnails, chosen: thumbnails.firstIndex { $0.id == edit.filter } ?? 0)
        filters.feel = .filters
        filters.overhang = 12
        filters.loupe = loupe
        filters.onChoose = { [weak self] i in self?.chooseFilter(i) }
        filters.onMove = { [weak self] in self?.filterRuler.setState(enabled: false, dimmed: true, animated: true) }
        filters.onRest = { [weak self] _ in self?.filtersRested() }
        filters.accessibilityLabel = "Filters"
        filters.spokenValue = { [weak self] i in self?.thumbnails[i].name ?? "" }
        filterRuler.range = 0...1
        filterRuler.magnet = 1
        filterRuler.marked = 0.5
        filterRuler.onTouch = { [weak self] in self?.filterRulerTouched() }
        filterRuler.onChange = { [weak self] value in self?.filterAmountMoved(value) }
        filterRuler.onEnd = { [weak self] _ in self?.filterAmountEnded() }

        modeBar.onChoose = { [weak self] id in self?.mode = HangarMode(id) }

        let hold = UILongPressGestureRecognizer(target: self, action: #selector(held(_:)))
        hold.minimumPressDuration = 0.15
        canvas.addGestureRecognizer(hold)

        preparePreview()
        chooseTool(0)
        setMode(mode)
        sync()
        // Hidden until it has flown in (or faded in).
        backdrop.alpha = 0
        canvas.alpha = 0
        for chrome in chromeViews { Chrome.show(chrome, false) }
    }

    private var chromeViews: [UIView] {
        [closeButton, historyBar, moreButton, doneButton, titleLabel, nameLabel, tools, ruler, filters, filterRuler, modeBar]
    }

    /// The picture at about the screen's size, kept on the GPU: what every change is drawn from.
    private func preparePreview() {
        let screen = view.window?.windowScene?.screen ?? UIScreen.main
        let longest = max(screen.bounds.width, screen.bounds.height) * screen.scale
        let pixels = CGSize(width: original.size.width * original.scale, height: original.size.height * original.scale)
        let fit = min(1, longest / max(pixels.width, pixels.height))
        let size = CGSize(width: (pixels.width * fit).rounded(), height: (pixels.height * fit).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.preferredRange = .standard
        let drawn = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            original.draw(in: CGRect(origin: .zero, size: size))
        }
        guard let picture = drawn.cgImage else { return }
        let source = CIImage(cgImage: picture).insertingIntermediate(cache: true)
        preview = source
        previewSize = size
        previewContext = HangarRenderContext(source: source, scale: Double(fit))
    }

    // MARK: Layout

    public override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let bounds = view.bounds
        let safe = view.safeAreaInsets
        sideways = traitCollection.horizontalSizeClass == .regular || bounds.width > bounds.height
        backdrop.frame = bounds

        // Photos' top bar: 44-point buttons 12 apart, in from the sides (16 on a phone, 10 on an iPad), from the top of
        // the safe area (8 below it on an iPad, under its status bar); undo and redo (and on an iPad the original
        // first) on one capsule, 52 apart; the mode's name in the middle on an iPad.
        let button: CGFloat = 44
        let side: CGFloat = sideways ? 10 : 16
        let top = safe.top
        closeButton.frame = CGRect(x: safe.left + side, y: top, width: button, height: button)
        let onCapsule: [UIButton] = sideways ? [originalButton, undoButton, redoButton] : [undoButton, redoButton]
        originalButton.isHidden = !sideways
        historyBar.frame = CGRect(x: closeButton.frame.maxX + 12, y: top, width: button + 52 * CGFloat(onCapsule.count - 1), height: button)
        Chrome.round(historyBar)
        for (i, item) in onCapsule.enumerated() { item.frame = CGRect(x: 52 * CGFloat(i), y: 0, width: button, height: button) }
        doneButton.frame = CGRect(x: bounds.maxX - safe.right - side - button, y: top, width: button, height: button)
        moreButton.frame = CGRect(x: doneButton.frame.minX - 12 - button, y: top, width: button, height: button)
        titleLabel.frame = CGRect(x: bounds.midX - 150, y: top, width: 300, height: button)
        titleLabel.isHidden = !sideways
        let below = closeButton.frame.maxY + 12

        let region: CGRect
        if sideways {
            // Photos' iPad layout: the modes down the left side, their middle the screen's; the ruler 75 in from the
            // right, 43 from the top and bottom; the tools 117 in, 86 from them; the name's right 36 before the tools.
            let along = modeBar.fittingSize(for: .along)
            modeBar.axis = .along
            modeBar.frame = CGRect(x: safe.left + 26.5, y: bounds.midY - along.height / 2, width: along.width, height: along.height)
            let right = bounds.maxX - safe.right
            ruler.axis = .along
            ruler.frame = CGRect(x: right - 75, y: 43, width: Ruler.thickness, height: bounds.height - 86)
            filterRuler.axis = .along
            filterRuler.frame = ruler.frame
            tools.axis = .along
            // Photos shows the tools 361 points each way from the middle, fading at the ends as on a phone.
            tools.reach = 361
            tools.frame = CGRect(x: right - 117, y: 86, width: ToolButton.size, height: bounds.height - 172)
            // Photos' filters on an iPad: 51-point thumbnails 53 apart on a wide wheel (700), shown as far as the tools.
            filters.axis = .along
            setFilterStrip(side: 51, wheel: 700, reach: 361)
            // Their middle 82 in from the right, nearer the ruler than the tools' (room for the dot on their left).
            filters.frame = CGRect(x: right - 82 - 75 / 2, y: tools.frame.minY, width: 75, height: tools.frame.height)
            nameLabel.textAlignment = .right
            let font = style.nameFont
            let width: CGFloat = 200
            nameLabel.frame = CGRect(x: tools.frame.minX - 36 - width, y: bounds.midY - (font.ascender - font.capHeight / 2),
                                     width: width, height: ceil(font.lineHeight))
            region = CGRect(x: modeBar.frame.maxX + 24, y: below, width: tools.frame.minX - 36 - 120 - modeBar.frame.maxX - 24,
                            height: bounds.maxY - max(safe.bottom, 16) - 12 - below)
        } else {
            // Photos' phone layout, up from the mode bar 16 points off the bottom: the ruler 71 above the bar's top,
            // the tools 113 (the filters 125, taller, their middles level with the tools'), the name's middle 152 (160).
            let across = modeBar.fittingSize(for: .across)
            modeBar.axis = .across
            tools.reach = nil
            modeBar.frame = CGRect(x: bounds.midX - across.width / 2, y: bounds.maxY - 16 - across.height,
                                   width: across.width, height: across.height)
            let base = modeBar.frame.minY
            let width = bounds.width - safe.left - safe.right
            ruler.axis = .across
            ruler.frame = CGRect(x: safe.left, y: base - 71, width: width, height: Ruler.thickness)
            filterRuler.axis = .across
            filterRuler.frame = ruler.frame
            tools.axis = .across
            tools.frame = CGRect(x: safe.left, y: base - 113, width: width, height: ToolButton.size)
            // Photos' filters on a phone: 52-point thumbnails 54 apart on a wheel of 200, three and a half each way.
            filters.axis = .across
            setFilterStrip(side: FilterThumbnail.side, wheel: 200, reach: nil)
            filters.frame = CGRect(x: safe.left, y: base - 125, width: width, height: 75)
            nameLabel.textAlignment = .center
            placeName(capMiddle: base - (mode == .filters ? 159.7 : 151.7), width: bounds.width)
            region = CGRect(x: safe.left, y: below, width: width, height: base - 151.7 - 24 - below)
        }
        for thumbnail in thumbnails { thumbnail.axis = sideways ? .along : .across }
        if !leaving {
            canvas.frame = Self.fit(previewSize, in: region, scale: view.window?.screen.scale ?? 2)
            fitShown()
        }
    }

    private func setFilterStrip(side: CGFloat, wheel: CGFloat, reach: CGFloat?) {
        filters.pitch = side + 2
        filters.itemSize = side + 2
        filters.wheel = wheel
        filters.reach = reach
        filters.fadeClear = 14
        filters.fadeWhole = 40
        loupe.thumbnail = side
    }

    /// The name across the middle, its capitals' middle at `capMiddle` (where Photos' is).
    private func placeName(capMiddle: CGFloat, width: CGFloat) {
        let font = style.nameFont
        let top = capMiddle - (font.ascender - font.capHeight / 2)
        nameLabel.frame = CGRect(x: 0, y: top, width: width, height: ceil(font.lineHeight))
    }

    private func fitShown() {
        guard let preview, let previewContext, canvas.bounds.width > 0, canvas.bounds.height > 0 else { return }
        let scale = view.window?.screen.scale ?? traitCollection.displayScale
        let pixels = CGSize(width: (canvas.bounds.width * scale).rounded(), height: (canvas.bounds.height * scale).rounded())
        guard pixels != shownSize else { return }
        shownSize = pixels
        let down = pixels.height / previewSize.height
        if pixels.width >= previewSize.width || pixels.height >= previewSize.height {
            shown = (preview, previewContext)
        } else {
            let fitted = preview.clampedToExtent()
                .applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: down,
                                                                        kCIInputAspectRatioKey: (pixels.width / previewSize.width) / down])
                .cropped(to: CGRect(origin: .zero, size: pixels))
                .insertingIntermediate(cache: true)
            shown = (fitted, previewContext.resized(to: fitted, scale: previewContext.scale * Double(down)))
        }
        render()
    }

    /// `size` as large as fits in `region`, in its middle, on whole pixels: where a viewer that fits a picture to the
    /// screen shows it, for a `HangarSource`.
    public static func fit(_ size: CGSize, in region: CGRect, scale: CGFloat) -> CGRect {
        guard size.width > 0, size.height > 0, region.width > 0, region.height > 0 else { return .zero }
        let s = min(region.width / size.width, region.height / size.height)
        let w = (size.width * s * scale).rounded() / scale, h = (size.height * s * scale).rounded() / scale
        let x = ((region.midX - w / 2) * scale).rounded() / scale, y = ((region.midY - h / 2) * scale).rounded() / scale
        return CGRect(x: x, y: y, width: w, height: h)
    }

    // MARK: Flying in and out

    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !entered else { return }
        entered = true
        enter()
    }

    private func enter() {
        render()
        let showChrome = {
            UIView.animate(withDuration: 0.3, delay: 0.05, options: [.curveEaseOut, .allowUserInteraction]) {
                for chrome in self.chromeViews { Chrome.show(chrome, true) }
                if self.edit.filter == nil { self.filterRuler.alpha = 0 }
            }
        }
        guard let source, let start = place(of: source) else {
            UIView.animate(withDuration: 0.25) {
                self.backdrop.alpha = 1
                self.canvas.alpha = 1
            }
            showChrome()
            return
        }
        let flyer = UIImageView(image: renderedPreview(edit))
        flyer.contentMode = .scaleAspectFill
        flyer.clipsToBounds = true
        flyer.layer.cornerCurve = .continuous
        view.insertSubview(flyer, aboveSubview: canvas)
        self.flyer = flyer
        let end = FlightPlace(frame: canvas.frame)
        let piece = FlightPiece(view: flyer, from: start, target: { [weak self] in self.map { FlightPlace(frame: $0.canvas.frame) } }) { [weak self] place in
            // The page under it covered as the picture leaves its place, well before it lands.
            self?.backdrop.alpha = min(1, Self.progress(place, from: start, to: end) * 3)
        }
        let group = FlightGroup(pieces: [piece])
        group.onLanded = { [weak self] in self?.landedIn() }
        flight = group
        group.start()
        showChrome()
    }

    private func landedIn() {
        backdrop.alpha = 1
        canvas.alpha = 1
        // The flying picture stays over the canvas until the canvas has drawn.
        canvas.onFirstDraw = { [weak self] in
            self?.flyer?.removeFromSuperview()
            self?.flyer = nil
        }
        render()
        #if DEBUG
        scrubIfAsked()
        #endif
    }

    #if DEBUG
    private func scrubIfAsked() {
        guard let id = Scrub.asked, let index = toolbox.adjustments.firstIndex(where: { $0.id == id }) else { return }
        if Scrub.all {
            for adjustment in toolbox.adjustments where adjustment.id != id {
                edit.set(adjustment.id, to: adjustment.range.upperBound / 3)
            }
            render()
            sync()
        }
        tools.choose(index, animated: false)
        chooseTool(index)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self else { return }
            Scrub(ruler: self.ruler, canvas: self.canvas, name: id + (Scrub.all ? "-all" : "")).run()
        }
    }
    #endif

    private func leave(showing picture: UIImage) {
        leaving = true
        flight?.stop()
        flyer?.removeFromSuperview()
        view.isUserInteractionEnabled = false
        UIView.animate(withDuration: 0.2, delay: 0, options: .curveEaseIn) {
            for chrome in self.chromeViews { Chrome.show(chrome, false) }
        }
        guard let source, place(of: source) != nil else {
            UIView.animate(withDuration: 0.25) {
                self.backdrop.alpha = 0
                self.canvas.alpha = 0
            } completion: { _ in self.dismiss(animated: false) }
            return
        }
        let flyer = UIImageView(image: picture)
        flyer.contentMode = .scaleAspectFill
        flyer.clipsToBounds = true
        flyer.layer.cornerCurve = .continuous
        flyer.frame = canvas.frame
        view.insertSubview(flyer, aboveSubview: canvas)
        canvas.alpha = 0
        let start = FlightPlace(frame: canvas.frame)
        let end = place(of: source) ?? start
        let piece = FlightPiece(view: flyer, from: start, target: { [weak self] in self.flatMap { $0.place(of: source) } }) { [weak self] place in
            // The page shows through only as the picture is about to land on it.
            self?.backdrop.alpha = 1 - pow(Self.progress(place, from: start, to: end), 3)
        }
        let group = FlightGroup(pieces: [piece])
        group.onLanded = { [weak self] in self?.dismiss(animated: false) }
        flight = group
        group.start()
    }

    private func place(of source: HangarSource) -> FlightPlace? {
        guard source.view.window != nil else { return nil }
        let frame = source.view.convert(source.frame ?? source.view.bounds, to: view)
        return FlightPlace(frame: frame, corner: source.cornerRadius)
    }

    /// How far a place is from `from` toward `to`, 0 to 1.
    private static func progress(_ place: FlightPlace, from: FlightPlace, to: FlightPlace) -> CGFloat {
        func distance(_ a: FlightPlace, _ b: FlightPlace) -> CGFloat {
            abs(a.center.x - b.center.x) + abs(a.center.y - b.center.y) + abs(a.size.width - b.size.width) + abs(a.size.height - b.size.height)
        }
        let whole = distance(from, to)
        guard whole > 1 else { return 1 }
        return min(max(1 - distance(place, to) / whole, 0), 1)
    }

    // MARK: Drawing

    /// The canvas shows the edit (the original while a finger's held on it), made off the main thread.
    private func render() {
        guard let shown else { return }
        let (renderer, edit, comparing) = (renderer, edit, comparing)
        canvas.show { comparing ? shown.image : renderer.apply(edit, to: shown.image, context: shown.context) }
    }

    /// The preview with an edit, as a picture: what flies, and what's given back at once.
    private func renderedPreview(_ edit: HangarEdit) -> UIImage {
        guard let preview, let previewContext else { return original }
        let out = renderer.apply(edit, to: preview, context: previewContext)
        guard let picture = HangarRenderer.context.createCGImage(out, from: preview.extent, format: .RGBA8,
                                                                 colorSpace: CGColorSpace(name: CGColorSpace.displayP3)) else { return original }
        return UIImage(cgImage: picture)
    }

    /// Photos' Show Original on an iPad: the original until it's tapped again.
    private func toggleOriginal() {
        comparing.toggle()
        var configuration = originalButton.configuration
        configuration?.image = UIImage(systemName: comparing ? "square.filled.and.line.vertical.and.square" : "square.and.line.vertical.and.square.filled",
                                       withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .medium))
        originalButton.configuration = configuration
        originalButton.accessibilityTraits = comparing ? [.button, .selected] : .button
        render()
    }

    @objc private func held(_ press: UILongPressGestureRecognizer) {
        switch press.state {
        case .began: comparing = true
        case .ended, .cancelled, .failed: comparing = false
        default: return
        }
        render()
    }

    // MARK: Modes

    private func setMode(_ new: HangarMode) {
        ruler.stop()
        filterRuler.stop()
        modeBar.choose(new.id)
        let adjusting = new == .adjust
        UIView.transition(with: view, duration: entered ? 0.2 : 0, options: [.transitionCrossDissolve, .allowUserInteraction]) {
            self.tools.isHidden = !adjusting
            self.ruler.isHidden = !adjusting
            self.filters.isHidden = adjusting
            self.filterRuler.isHidden = adjusting
            self.filterRuler.alpha = self.edit.filter == nil ? 0 : 1
        }
        titleLabel.text = (adjusting ? "Adjust" : "Filters").uppercased()
        if adjusting {
            if let i = toolbox.adjustments.firstIndex(where: { $0.id == tool }) { showName(toolbox.adjustments[i].name) }
        } else {
            showName(thumbnails[filters.chosen].name)
            makeThumbnails()
        }
        // The name sits a little higher over the filters.
        view.setNeedsLayout()
    }

    private func showName(_ name: String) {
        nameLabel.attributedText = NSAttributedString(string: name.uppercased(), attributes: [.font: style.nameFont,
                                                                                              .foregroundColor: style.secondary])
    }

    // MARK: Adjust

    private var autoID: String { HangarAdjustment.auto.id }

    /// A tool passing the middle of the strip as it moves: its name shown, the ruler (off meanwhile) left alone.
    private func passTool(_ index: Int) {
        guard toolbox.adjustments.indices.contains(index) else { return }
        tool = toolbox.adjustments[index].id
        showName(toolbox.adjustments[index].name)
    }

    /// The strip came to rest on a tool: the ruler set to it and on again (as its tool is: off for Auto off, dimmed
    /// for a tool switched off).
    private func chooseTool(_ index: Int) {
        guard toolbox.adjustments.indices.contains(index) else { return }
        let adjustment = toolbox.adjustments[index]
        tool = adjustment.id
        rulerTool = adjustment.id
        ruler.range = adjustment.range
        ruler.magnet = 0
        ruler.marked = 0
        ruler.set(shownValue(rulerTool))
        ruler.accessibilityLabel = "Intensity Slider for \(adjustment.name)"
        showName(adjustment.name)
        setRulerState(animated: true)
    }

    private func setRulerState(animated: Bool) {
        if rulerTool == autoID {
            let on = edit.applies(autoID)
            ruler.setState(enabled: on, dimmed: !on, animated: animated)
        } else {
            ruler.setState(enabled: true, dimmed: edit.switchedOff.contains(rulerTool), animated: animated)
        }
    }

    /// What a tool's ruler shows: its value, or its default while it's switched off (Photos').
    private func shownValue(_ id: String) -> Double {
        id != autoID && edit.switchedOff.contains(id) ? 0 : edit.value(of: id)
    }

    private func button(_ id: String) -> ToolButton? {
        toolButtons.first { $0.id == id }
    }

    /// The chosen tool tapped: switched off or on (its value kept; its number shown, on). Auto on for the first time
    /// is Photos' first guess.
    private func toggleTool(_ index: Int) {
        ruler.stop()
        let id = toolbox.adjustments[index].id
        let on: Bool
        if id == autoID {
            on = !edit.applies(id)
            if on, edit.value(of: id) == 0 { edit.set(id, to: Self.autoFirst) }
            if on { edit.switchedOff.remove(id) } else { edit.switchedOff.insert(id) }
        } else {
            on = edit.switchedOff.contains(id)
            if on { edit.switchedOff.remove(id) } else { edit.switchedOff.insert(id) }
        }
        ruler.set(shownValue(id), animated: true)
        button(id)?.show(value: edit.value(of: id), switchedOff: edit.switchedOff.contains(id), number: on)
        setRulerState(animated: true)
        render()
        commit()
    }

    /// A tool as VoiceOver reads it in the strip: its name and value (Photos'), or Auto on or off.
    private func spokenTool(_ index: Int) -> String {
        let adjustment = toolbox.adjustments[index]
        let id = adjustment.id
        if id == autoID { return "\(adjustment.name), \(edit.applies(id) ? "On" : "Off")" }
        if edit.switchedOff.contains(id) { return "\(adjustment.name), Off" }
        return "\(adjustment.name), \(Int((edit.value(of: id) * 100).rounded()))%"
    }

    /// How much Auto is when it's first switched on.
    private static let autoFirst = 0.42

    /// A finger on the ruler: the tool's number shows (Photos').
    private func rulerTouched() {
        button(rulerTool)?.show(value: edit.value(of: rulerTool), switchedOff: edit.switchedOff.contains(rulerTool), number: true)
    }

    private func rulerMoved(_ value: Double) {
        edit.set(rulerTool, to: value)
        // Moving a tool switched off switches it on.
        if edit.switchedOff.remove(rulerTool) != nil { setRulerState(animated: true) }
        button(rulerTool)?.show(value: value, switchedOff: false, number: true)
        render()
    }

    /// The number stays until another tool is chosen.
    private func rulerEnded() {
        commit()
    }

    // MARK: Filters

    /// A filter passing the middle of the strip, or tapped: on the picture at once (as much of it as it was left at),
    /// kept when the strip rests.
    private func chooseFilter(_ index: Int) {
        let id = thumbnails[index].id
        edit.filter = id
        edit.filterAmount = id.flatMap { filterAmounts[$0] } ?? 1
        // Photos' ruler goes for Original, over a quarter of a second.
        UIView.animate(withDuration: 0.25, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
            self.filterRuler.alpha = id == nil ? 0 : 1
        }
        showName(thumbnails[index].name)
        // Dragging through the filters, Photos hides its bars as it does for a filter's ruler.
        if filters.isDragged { hideBars(true) }
        render()
    }

    private func filtersRested() {
        hideBars(false)
        filterRuler.set(edit.filterAmount)
        filterRuler.accessibilityLabel = "Intensity Slider for \(thumbnails[filters.chosen].name)"
        filterRuler.setState(enabled: edit.filter != nil, dimmed: false, animated: true)
        for thumbnail in thumbnails { thumbnail.applied = thumbnail.id == edit.filter }
        commit()
    }

    private func filterRulerTouched() {}

    private func filterAmountMoved(_ value: Double) {
        edit.filterAmount = value
        if let id = edit.filter { filterAmounts[id] = value }
        loupe.show(amount: value)
        hideBars(true)
        render()
    }

    private func filterAmountEnded() {
        loupe.show(amount: nil)
        hideBars(false)
        commit()
    }

    /// Photos hides its bars while a filter's ruler is moved, and brings them back once it's let go.
    private func hideBars(_ hide: Bool) {
        guard hide != barsHidden else { return }
        barsHidden = hide
        // Back a quarter of a second after it's let go (a delay glass doesn't keep, so waited for here).
        DispatchQueue.main.asyncAfter(deadline: .now() + (hide ? 0 : 0.25)) { [weak self] in
            guard let self, self.barsHidden == hide else { return }
            UIView.animate(withDuration: 0.3, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
                for bar in [self.closeButton, self.historyBar, self.moreButton, self.doneButton, self.modeBar] as [UIView] {
                    Chrome.show(bar, !hide)
                }
            }
        }
    }

    /// Each filter on the picture as it's adjusted, small: made when Filters opens, again if the adjustments changed.
    private func makeThumbnails() {
        guard let preview, let previewContext else { return }
        var adjusted = edit
        adjusted.filter = nil
        guard filterThumbnailsFor != adjusted else { return }
        filterThumbnailsFor = adjusted
        let side = min(preview.extent.width, preview.extent.height)
        let pixels: CGFloat = 150
        let scale = pixels / side
        let square = CGRect(x: preview.extent.midX - side / 2, y: preview.extent.midY - side / 2, width: side, height: side)
        let small = preview.cropped(to: square)
            .transformed(by: CGAffineTransform(translationX: -square.minX, y: -square.minY))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let context = HangarRenderContext(source: small, scale: previewContext.scale * Double(scale))
        let renderer = renderer
        let ids = thumbnails.map(\.id)
        Task.detached(priority: .userInitiated) {
            let base = renderer.apply(adjusted, to: small, context: context)
            var pictures: [CGImage?] = []
            for id in ids {
                var withFilter = adjusted
                withFilter.filter = id
                withFilter.filterAmount = 1
                let out = id == nil ? base : renderer.apply(withFilter, to: small, context: context)
                pictures.append(HangarRenderer.context.createCGImage(out, from: small.extent, format: .RGBA8,
                                                                     colorSpace: CGColorSpace(name: CGColorSpace.sRGB)))
            }
            let made = pictures
            await MainActor.run { [weak self] in
                guard let self, self.filterThumbnailsFor == adjusted else { return }
                for (thumbnail, picture) in zip(self.thumbnails, made) {
                    thumbnail.image = picture.map { UIImage(cgImage: $0) }
                }
            }
        }
    }

    // MARK: History

    private func commit() {
        guard history[historyIndex] != edit else { return sync() }
        history.removeSubrange((historyIndex + 1)...)
        history.append(edit)
        historyIndex += 1
        sync()
    }

    private func step(_ by: Int) {
        ruler.stop()
        filterRuler.stop()
        let to = historyIndex + by
        guard history.indices.contains(to) else { return }
        historyIndex = to
        edit = history[to]
        render()
        sync()
    }

    /// Every control as the edit is.
    private func sync() {
        for button in toolButtons {
            button.show(value: edit.value(of: button.id), switchedOff: edit.switchedOff.contains(button.id),
                        number: button.showsNumber)
        }
        ruler.set(shownValue(rulerTool))
        setRulerState(animated: entered)
        let chosen = thumbnails.firstIndex { $0.id == edit.filter } ?? 0
        if chosen != filters.chosen {
            filters.choose(chosen, animated: true)
            if mode == .filters { showName(thumbnails[chosen].name) }
        }
        for thumbnail in thumbnails { thumbnail.applied = thumbnail.id == edit.filter }
        if let id = edit.filter { filterAmounts[id] = edit.filterAmount }
        filterRuler.set(edit.filterAmount)
        filterRuler.setState(enabled: edit.filter != nil, dimmed: false, animated: entered)
        if mode == .filters {
            filterRuler.alpha = edit.filter == nil ? 0 : 1
            makeThumbnails()
        }
        undoButton.isEnabled = historyIndex > 0
        redoButton.isEnabled = historyIndex < history.count - 1
        let changed = edit != initialEdit
        if changed != (doneButton.configuration?.baseBackgroundColor == style.accent) {
            let replacement = Chrome.button("checkmark", label: "Done", style: style, prominent: changed)
            replacement.frame = doneButton.frame
            replacement.alpha = doneButton.alpha
            replacement.addAction(UIAction { [weak self] _ in self?.doneTapped() }, for: .touchUpInside)
            view.insertSubview(replacement, aboveSubview: doneButton)
            doneButton.removeFromSuperview()
            doneButton = replacement
        }
        doneButton.isEnabled = changed
    }

    // MARK: Leaving

    private func doneTapped() {
        let picture = renderedPreview(edit)
        onDone?(HangarResult(edit: edit, preview: picture, original: original, toolbox: toolbox))
        leave(showing: picture)
    }

    private func closeTapped() {
        guard edit != initialEdit else { return cancel() }
        let sheet = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: "Discard Changes", style: .destructive) { [weak self] _ in self?.cancel() })
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        sheet.popoverPresentationController?.sourceView = closeButton
        present(sheet, animated: true)
    }

    private func cancel() {
        onCancel?()
        leave(showing: renderedPreview(initialEdit))
    }

    // MARK: More

    private static let pasteboardType = "dev.hangar.edit"

    private func moreActions() -> [UIMenuElement] {
        var actions: [UIMenuElement] = []
        actions.append(UIAction(title: "Copy Edits", image: UIImage(systemName: "doc.on.doc"),
                                attributes: edit.isOriginal ? .disabled : []) { [weak self] _ in
            guard let self, let data = try? JSONEncoder().encode(self.edit) else { return }
            UIPasteboard.general.setData(data, forPasteboardType: Self.pasteboardType)
        })
        let pasted = UIPasteboard.general.data(forPasteboardType: Self.pasteboardType).flatMap { try? JSONDecoder().decode(HangarEdit.self, from: $0) }
        actions.append(UIAction(title: "Paste Edits", image: UIImage(systemName: "doc.on.clipboard"),
                                attributes: pasted == nil ? .disabled : []) { [weak self] _ in
            guard let self, let pasted else { return }
            self.ruler.stop()
            self.filterRuler.stop()
            self.edit = pasted
            self.render()
            self.commit()
        })
        actions.append(UIMenu(options: .displayInline, children: [
            UIAction(title: "Revert to Original", image: UIImage(systemName: "arrow.uturn.backward.circle"),
                     attributes: edit.isOriginal ? .disabled : .destructive) { [weak self] _ in
                guard let self else { return }
                self.ruler.stop()
                self.filterRuler.stop()
                self.edit = HangarEdit()
                self.render()
                self.commit()
            },
        ]))
        return actions
    }
}

extension CGImagePropertyOrientation {
    init(_ orientation: UIImage.Orientation) {
        switch orientation {
        case .up: self = .up
        case .down: self = .down
        case .left: self = .left
        case .right: self = .right
        case .upMirrored: self = .upMirrored
        case .downMirrored: self = .downMirrored
        case .leftMirrored: self = .leftMirrored
        case .rightMirrored: self = .rightMirrored
        @unknown default: self = .up
        }
    }
}
