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
    let renderer: HangarRenderer

    /// The whole picture with the edit, its own size and colours.
    public func render() async -> UIImage? {
        let (original, edit, renderer) = (original, edit, renderer)
        return await Task.detached(priority: .userInitiated) {
            guard let picture = original.cgImage ?? HangarEditor.drawn(original) else { return nil }
            let orientation = CGImagePropertyOrientation(original.imageOrientation)
            guard let out = renderer.render(edit, to: picture, orientation: orientation) else { return nil }
            return UIImage(cgImage: out, scale: original.scale, orientation: .up)
        }.value
    }
}

/// One of the editor's modes, by its id: Adjust, Filters, Crop, or an app's own (`HangarModule`).
public struct HangarMode: Hashable, Sendable {
    public let id: String

    public init(_ id: String) {
        self.id = id
    }

    public static let adjust = HangarMode("adjust")
    public static let filters = HangarMode("filters")
    public static let crop = HangarMode("crop")
}

/// Photos' editor for a picture: Adjust (Auto and fifteen adjustments, each on its ruler), Filters (nine looks, each as
/// much as its ruler says) and Crop (the crop's box, Straighten, Vertical and Horizontal, Flip, Rotate, Aspect Ratio),
/// undo and redo a step at a time, the original under a finger held on the picture.
/// It flies out of the picture it was opened from and back into it (Flight). Its modes are its `modules` (an app's
/// own among them), its tools the toolbox's (`HangarToolbox`), its look the style's (`HangarStyle`); More offers the
/// app's `actions`, and what they make is kept in the app's `assets`.
///
/// ```swift
/// let editor = HangarEditor(image: photo.original, edit: photo.edit)
/// editor.onDone = { result in photo.edit = result.edit; photo.shown = result.preview }
/// editor.present(from: self, source: HangarSource(view: cell.imageView, cornerRadius: 8))
/// ```
@MainActor
public final class HangarEditor: UIViewController, HangarHost {
    /// Done: the edit and the picture with it. Called before the editor flies home, so the source can show it.
    public var onDone: ((HangarResult) -> Void)?
    /// Closed without keeping anything.
    public var onCancel: (() -> Void)?
    /// Jobs More offers, after Photos' own (Remove Background, Upscale): what they make becomes a step.
    public var actions: [HangarAction] = []

    private let original: UIImage
    public let toolbox: HangarToolbox
    public let style: HangarStyle
    public let renderer: HangarRenderer
    private let initialEdit: HangarEdit
    public var edit: HangarEdit
    private var history: [HangarEdit]
    private var historyIndex = 0
    /// The mode it's in, Adjust when it opens unless set before (the first module's if it has no Adjust).
    public var mode = HangarMode.adjust {
        didSet { if isViewLoaded, mode != oldValue { setMode(mode) } }
    }
    /// Its modes, in the mode bar's order.
    public let modules: [any HangarModule]
    private var current: (any HangarModule)?

    /// The picture the edit's drawn on: the original with the edit's steps, at about the screen's size, on the GPU.
    private var preview: CIImage?
    private var previewContext: HangarRenderContext?
    /// The steps it was made with (or is being made with).
    private var previewSteps: [HangarStep] = []
    /// The picture without them, the same size: shown while a finger's held on the picture (Photos shows what was
    /// there before Clean Up too).
    private var plainPreview: CIImage?
    private var previewToken = 0
    /// The preview shaped by the edit's geometry (cropped, turned, flipped), and its size: what the canvas shows.
    private var shapedImage: CIImage?
    private var shapedContext: HangarRenderContext?
    private var shapedGeometry: HangarGeometry?
    private var previewSize = CGSize(width: 1, height: 1)
    /// The preview at the canvas's size in pixels, kept on the GPU: what the canvas draws each change from, so a frame
    /// is the tools' work on the pixels shown and no more (as Photos draws for its view's size).
    private var shown: (image: CIImage, context: HangarRenderContext)?
    private var shownSize = CGSize.zero
    public var overlay: (@Sendable (CIImage, HangarRenderContext) -> CIImage)? {
        didSet { if isViewLoaded { render() } }
    }

    private let backdrop = UIView()
    private let canvas = CanvasView()
    private let shimmer = Shimmer()
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
    private let modeBar: ModeBar
    /// Shown or hidden last (`showBars`), for one coming late.
    private var barsShown = true

    private var source: HangarSource?
    private var flight: FlightGroup?
    private var flyer: UIImageView?
    private var entered = false
    private var leaving = false
    private var comparing = false
    private var sideways = false
    /// A job working, and what keeps fingers off everything but Cancel meanwhile.
    private var job: Task<Void, Never>?
    /// Which job it is: one cancelled and still finishing doesn't end the next.
    private var jobNumber = 0
    private let blocker = UIView()

    public init(image: UIImage, edit: HangarEdit = HangarEdit(), toolbox: HangarToolbox = .standard, style: HangarStyle = .system,
                modules: [any HangarModule]? = nil, assets: (any HangarAssets)? = HangarAssetFolder.caches) {
        original = image
        self.toolbox = toolbox
        self.style = style
        renderer = HangarRenderer(toolbox: toolbox, assets: assets)
        initialEdit = edit
        self.edit = edit
        history = [edit]
        self.modules = modules ?? [HangarAdjustModule(), HangarFiltersModule(), HangarCropModule()]
        closeButton = Chrome.button("xmark", label: "Cancel", style: style)
        historyBar = Chrome.capsule(style)
        originalButton = Chrome.plainButton("square.and.line.vertical.and.square.filled", label: "Show Original", style: style)
        undoButton = Chrome.plainButton("arrow.uturn.backward", label: "Undo", style: style)
        redoButton = Chrome.plainButton("arrow.uturn.forward", label: "Redo", style: style)
        moreButton = Chrome.button("ellipsis", label: "More", style: style)
        doneButton = Chrome.button("checkmark", label: "Done", style: style)
        modeBar = ModeBar(modes: self.modules.map { m in
            ModeBar.Mode(id: m.item.id, name: m.item.name, symbol: m.item.symbol, chosenSymbol: m.item.chosenSymbol, spoken: m.item.spoken)
        }, chosen: self.modules.first?.item.id ?? "", style: style)
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
        view.addSubview(shimmer)

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
            completion(self?.moreMenu() ?? [])
        }])
        titleLabel.textAlignment = .center
        titleLabel.font = style.titleFont
        titleLabel.textColor = style.title
        nameLabel.font = style.nameFont
        nameLabel.textColor = style.secondary
        for chrome in [closeButton, historyBar, moreButton, doneButton, titleLabel, nameLabel, modeBar] as [UIView] {
            view.addSubview(chrome)
        }
        modeBar.onChoose = { [weak self] id in self?.mode = HangarMode(id) }

        let hold = UILongPressGestureRecognizer(target: self, action: #selector(held(_:)))
        hold.minimumPressDuration = 0.15
        canvas.addGestureRecognizer(hold)

        preparePreview()
        for module in modules { module.load(in: self) }
        blocker.isHidden = true
        blocker.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(blockedTap(_:))))
        view.addSubview(blocker)
        setMode(mode)
        sync()
        // Hidden until it has flown in (or faded in).
        backdrop.alpha = 0
        canvas.alpha = 0
        for chrome in chromeViews { Chrome.show(chrome, false) }
    }

    private var chromeViews: [UIView] {
        [closeButton, historyBar, moreButton, doneButton, titleLabel, nameLabel, modeBar] + modules.flatMap(\.chrome)
    }

    private func module(_ mode: HangarMode) -> (any HangarModule)? {
        modules.first { $0.item.id == mode.id } ?? modules.first
    }

    // MARK: The picture

    /// The picture at about the screen's size, kept on the GPU: what every change is drawn from.
    private func preparePreview() {
        let longest = screenLongest
        previewSteps = edit.steps
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
        let plain = CIImage(cgImage: picture).insertingIntermediate(cache: true)
        plainPreview = plain
        if edit.steps.isEmpty || renderer.assets == nil {
            preview = plain
            previewContext = HangarRenderContext(source: plain, scale: Double(fit))
        } else if let picture = original.cgImage ?? Self.drawn(original),
                  let made = Self.makeBase(picture, CGImagePropertyOrientation(original.imageOrientation), renderer, edit, longest) {
            preview = made.image
            previewContext = HangarRenderContext(source: made.image, scale: made.scale)
        }
        shapedGeometry = nil
        shapePreview()
    }

    private var screenLongest: CGFloat {
        let screen = view.window?.windowScene?.screen ?? UIScreen.main
        return max(screen.bounds.width, screen.bounds.height) * screen.scale
    }

    /// What the edit's steps make of the picture, at most `longest` pixels on its longer side, on the GPU; and its
    /// pixels a pixel of what they make whole. Off the main thread for a large picture.
    nonisolated static func makeBase(_ picture: CGImage, _ orientation: CGImagePropertyOrientation, _ renderer: HangarRenderer,
                                     _ edit: HangarEdit, _ longest: CGFloat) -> (image: CIImage, scale: Double)? {
        let base = renderer.base(edit, CIImage(cgImage: picture).oriented(orientation))
        let whole = base.extent.size
        let fit = min(1, longest / max(whole.width, whole.height))
        let size = CGSize(width: (whole.width * fit).rounded(), height: (whole.height * fit).rounded())
        let scaled = fit < 1
            ? base.clampedToExtent()
                .applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: size.height / whole.height,
                                                                        kCIInputAspectRatioKey: (size.width / whole.width) / (size.height / whole.height)])
                .cropped(to: CGRect(origin: .zero, size: size))
            : base
        guard let out = HangarRenderer.context.createCGImage(scaled, from: CGRect(origin: .zero, size: size), format: .RGBA8,
                                                             colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) else { return nil }
        return (CIImage(cgImage: out).insertingIntermediate(cache: true), Double(fit))
    }

    /// The preview made again if the edit's steps aren't the ones it was made with (undone, pasted, a step made),
    /// off the main thread; then `done`.
    private func refreshPreview(then done: (@MainActor () -> Void)? = nil) {
        guard edit.steps != previewSteps else { done?(); return }
        previewSteps = edit.steps
        previewToken += 1
        let token = previewToken
        let (original, renderer, edit, longest) = (original, renderer, edit, screenLongest)
        Task { [weak self] in
            let made = await Task.detached(priority: .userInitiated) {
                let picture = original.cgImage ?? Self.drawn(original)
                return picture.flatMap { Self.makeBase($0, CGImagePropertyOrientation(original.imageOrientation), renderer, edit, longest) }
            }.value
            guard let self, self.previewToken == token else { return }
            if let made {
                self.preview = made.image
                self.previewContext = HangarRenderContext(source: made.image, scale: made.scale)
                self.shapedGeometry = nil
                self.shapePreview()
                self.view.layoutIfNeeded()
                self.render()
                for module in self.modules { module.pictureChanged() }
            }
            done?()
        }
    }

    /// The preview shaped by the edit's geometry, again if it's changed: the canvas laid out for its size.
    private func shapePreview() {
        guard let preview, let previewContext else { return }
        let g = edit.appliedGeometry
        guard g != shapedGeometry else { return }
        shapedGeometry = g
        let out = renderer.shape(edit, preview).insertingIntermediate(cache: true)
        shapedImage = out
        shapedContext = previewContext.resized(to: out, scale: previewContext.scale)
        previewSize = out.extent.size
        shownSize = .zero
        view.setNeedsLayout()
    }

    nonisolated static func drawn(_ image: UIImage) -> CGImage? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        return UIGraphicsImageRenderer(size: image.size, format: format).image { _ in image.draw(at: .zero) }.cgImage
    }

    // MARK: Layout

    public override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let bounds = view.bounds
        let safe = view.safeAreaInsets
        sideways = traitCollection.horizontalSizeClass == .regular || bounds.width > bounds.height
        backdrop.frame = bounds
        blocker.frame = bounds
        shimmer.frame = bounds

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
        titleLabel.isHidden = !sideways || !(current?.showsTitle ?? true)
        let below = closeButton.frame.maxY + 12

        let region: CGRect, tools: CGRect, ruler: CGRect
        if sideways {
            // Photos' iPad layout: the modes down the left side, their middle the screen's; the ruler 75 in from the
            // right, 43 from the top and bottom; the tools 117 in, 86 from them; the name's right 36 before the tools.
            let along = modeBar.fittingSize(for: .along)
            modeBar.axis = .along
            modeBar.frame = CGRect(x: safe.left + 26.5, y: bounds.midY - along.height / 2, width: along.width, height: along.height)
            let right = bounds.maxX - safe.right
            ruler = CGRect(x: right - 75, y: 43, width: Ruler.thickness, height: bounds.height - 86)
            tools = CGRect(x: right - 117, y: 86, width: ToolButton.size, height: bounds.height - 172)
            nameLabel.textAlignment = .right
            let font = style.nameFont
            let width: CGFloat = 200
            nameLabel.frame = CGRect(x: tools.minX - 36 - width, y: bounds.midY - (font.ascender - font.capHeight / 2),
                                     width: width, height: ceil(font.lineHeight))
            region = CGRect(x: modeBar.frame.maxX + 24, y: below, width: tools.minX - 36 - 120 - modeBar.frame.maxX - 24,
                            height: bounds.maxY - max(safe.bottom, 16) - 12 - below)
        } else {
            // Photos' phone layout, up from the mode bar 16 points off the bottom: the ruler 71 above the bar's top,
            // the tools 113, the name's middle 152 (a mode's own: Filters' 160).
            let across = modeBar.fittingSize(for: .across)
            modeBar.axis = .across
            modeBar.frame = CGRect(x: bounds.midX - across.width / 2, y: bounds.maxY - 16 - across.height,
                                   width: across.width, height: across.height)
            let base = modeBar.frame.minY
            let width = bounds.width - safe.left - safe.right
            ruler = CGRect(x: safe.left, y: base - 71, width: width, height: Ruler.thickness)
            tools = CGRect(x: safe.left, y: base - 113, width: width, height: ToolButton.size)
            nameLabel.textAlignment = .center
            let font = style.nameFont
            let capMiddle = base - (current?.nameRise ?? 151.7)
            nameLabel.frame = CGRect(x: 0, y: capMiddle - (font.ascender - font.capHeight / 2), width: bounds.width, height: ceil(font.lineHeight))
            region = CGRect(x: safe.left, y: below, width: width, height: base - 151.7 - 24 - below)
        }
        let layout = HangarLayout(bounds: bounds, safeArea: safe, sideways: sideways, scale: view.window?.screen.scale ?? traitCollection.displayScale,
                                  cancel: closeButton.frame, history: historyBar.frame, more: moreButton.frame, done: doneButton.frame,
                                  title: titleLabel.frame, modeBar: modeBar.frame, tools: tools, ruler: ruler, region: region)
        for module in modules { module.layout(layout) }
        if !leaving {
            canvas.frame = Self.fit(previewSize, in: region, scale: view.window?.screen.scale ?? 2)
            fitShown()
        }
    }

    private func fitShown() {
        guard let preview = shapedImage, let previewContext = shapedContext, canvas.bounds.width > 0, canvas.bounds.height > 0 else { return }
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
        for case let adjust as HangarAdjustModule in modules { adjust.scrubIfAsked(canvas: canvas) }
        #endif
    }

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
        // From where the mode shows the picture (Crop's box, the picture round it gone at once).
        let from = current?.pictureFrame ?? canvas.frame
        flyer.frame = from
        view.insertSubview(flyer, aboveSubview: shimmer)
        canvas.alpha = 0
        for module in modules { module.closing() }
        let start = FlightPlace(frame: from)
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

    /// The canvas shows the edit (the original while a finger's held on it), made off the main thread; shaped again
    /// first if the geometry's changed.
    public func render() {
        shapePreview()
        guard let shown else { return }
        let (renderer, edit, comparing, overlay) = (renderer, edit, comparing, overlay)
        let plain = comparing ? plainShown() : nil
        canvas.show {
            guard !comparing else { return plain ?? shown.image }
            let out = renderer.apply(edit, to: shown.image, context: shown.context)
            return overlay.map { $0(out, shown.context) } ?? out
        }
    }

    /// The picture as it was before the edit's steps, shaped and sized as the canvas shows the edit: while a finger's
    /// held on it. Nil if there are none, or one's made the picture another size.
    private func plainShown() -> CIImage? {
        guard !edit.steps.isEmpty, edit.steps.allSatisfy({ $0.reach == HangarStep.whole }), let plainPreview, let shown else { return nil }
        let shaped = renderer.shape(edit, plainPreview)
        let target = shown.image.extent.size
        let down = target.height / shaped.extent.height
        return shaped.clampedToExtent()
            .applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: down,
                                                                    kCIInputAspectRatioKey: (target.width / shaped.extent.width) / down])
            .cropped(to: CGRect(origin: .zero, size: target))
    }

    /// The preview with an edit, as a picture: what flies, and what's given back at once.
    private func renderedPreview(_ edit: HangarEdit) -> UIImage {
        var base = preview.flatMap { p in previewContext.map { (p, $0) } }
        // An edit with other steps (Cancel after a step was made): its own picture under it.
        if edit.steps != previewSteps, let picture = original.cgImage ?? Self.drawn(original),
           let made = Self.makeBase(picture, CGImagePropertyOrientation(original.imageOrientation), renderer, edit, screenLongest) {
            base = (made.image, HangarRenderContext(source: made.image, scale: made.scale))
        }
        guard let (preview, previewContext) = base else { return original }
        let shapedPreview = renderer.shape(edit, preview)
        let out = renderer.apply(edit, to: shapedPreview, context: previewContext.resized(to: shapedPreview, scale: previewContext.scale))
        guard let picture = HangarRenderer.context.createCGImage(out, from: shapedPreview.extent, format: .RGBA8,
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
        current?.showOriginal(comparing)
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

    // MARK: The host's

    public var hasEntered: Bool { entered }
    public var base: (image: CIImage, context: HangarRenderContext)? { preview.flatMap { p in previewContext.map { (p, $0) } } }
    public var shaped: (image: CIImage, context: HangarRenderContext)? { shapedImage.flatMap { p in shapedContext.map { (p, $0) } } }
    public var canvasFrame: CGRect { canvas.frame }
    public var plain: CIImage? {
        guard edit.steps.allSatisfy({ $0.reach == HangarStep.whole }) else { return nil }
        return plainPreview.flatMap { p in preview.map { $0.extent.size == p.extent.size ? p : Self.resized(p, to: $0.extent.size) } }
    }

    private static func resized(_ image: CIImage, to size: CGSize) -> CIImage {
        let e = image.extent
        return image.clampedToExtent()
            .transformed(by: CGAffineTransform(scaleX: size.width / e.width, y: size.height / e.height))
            .cropped(to: CGRect(origin: .zero, size: size))
    }

    public func add(_ child: UIView, at level: HangarLevel) {
        switch level {
        case .picture: view.insertSubview(child, belowSubview: shimmer)
        case .controls:
            // Over the editor's bars, under what keeps fingers off while a job works.
            if blocker.superview == nil { view.addSubview(child) } else { view.insertSubview(child, belowSubview: blocker) }
        }
    }

    public func showName(_ name: String?) {
        nameLabel.isHidden = name == nil
        guard let name else { return }
        nameLabel.attributedText = NSAttributedString(string: name.uppercased(), attributes: [.font: style.nameFont,
                                                                                              .foregroundColor: style.secondary])
    }

    public func showBars(_ shown: Bool, duration: TimeInterval, delay: TimeInterval) {
        barsShown = shown
        let change = { [weak self] in
            guard let self, self.barsShown == shown else { return }
            var bars: [UIView] = [self.closeButton, self.doneButton, self.modeBar]
            if !(self.current?.ownsTopBar ?? false) { bars += [self.historyBar, self.moreButton] }
            UIView.animate(withDuration: duration, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
                for bar in bars { Chrome.show(bar, shown) }
            }
        }
        // Glass doesn't keep an animation's delay: waited for here.
        if delay > 0 { DispatchQueue.main.asyncAfter(deadline: .now() + delay) { change() } } else { change() }
    }

    public func showCanvas(_ shown: Bool) {
        canvas.alpha = shown ? 1 : 0
    }

    public func layoutNow() {
        view.layoutIfNeeded()
    }

    // MARK: Modes

    private func setMode(_ new: HangarMode) {
        guard let next = module(new) else { return }
        for module in modules { module.stop() }
        modeBar.choose(next.item.id)
        let old = current
        current = next
        UIView.transition(with: view, duration: entered ? 0.2 : 0, options: [.transitionCrossDissolve, .allowUserInteraction]) {
            for module in self.modules where module !== next { module.show(false) }
            next.show(true)
            self.historyBar.isHidden = next.ownsTopBar
            self.moreButton.isHidden = next.ownsTopBar
            self.titleLabel.isHidden = !self.sideways || !next.showsTitle
        }
        titleLabel.text = next.item.name.uppercased()
        if let old, old !== next { old.left() }
        next.entered()
        // The name sits a mode's own height (Filters' a little higher).
        view.setNeedsLayout()
    }

    // MARK: History

    public func commit() {
        guard history[historyIndex] != edit else { return sync() }
        history.removeSubrange((historyIndex + 1)...)
        history.append(edit)
        historyIndex += 1
        sync()
    }

    private func step(_ by: Int) {
        for module in modules { module.stop() }
        let to = historyIndex + by
        guard history.indices.contains(to) else { return }
        historyIndex = to
        edit = history[to]
        render()
        sync()
        refreshPreview()
    }

    /// An edit from elsewhere (pasted, reverted): drawn, kept as a step, every control with it.
    private func replace(with new: HangarEdit) {
        for module in modules { module.stop() }
        edit = new
        render()
        commit()
        refreshPreview()
    }

    /// Every control as the edit is.
    private func sync() {
        for module in modules { module.sync() }
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

    // MARK: Jobs

    public func run(_ job: HangarJob, done: (@MainActor (Bool) -> Void)?) {
        guard self.job == nil, let assets = renderer.assets else { done?(false); return }
        for module in modules { module.stop() }
        blocker.isHidden = false
        shimmer.run(over: shimmerRegion(job.region))
        UIAccessibility.post(notification: .announcement, argument: job.name)
        let (original, renderer, edit, limit) = (original, renderer, edit, job.longestSide)
        jobNumber += 1
        let number = jobNumber
        self.job = Task { [weak self] in
            do {
                // The picture under the edit, as its steps make it, at most as large as the job takes.
                let picture: CGImage = try await Task.detached(priority: .userInitiated) {
                    guard let source = original.cgImage ?? HangarEditor.drawn(original),
                          let made = HangarEditor.makeBase(source, CGImagePropertyOrientation(original.imageOrientation), renderer, edit, limit ?? .greatestFiniteMagnitude),
                          let out = HangarRenderer.context.createCGImage(made.image, from: made.image.extent)
                    else { throw CocoaError(.fileReadCorruptFile) }
                    return out
                }.value
                let made = try await job.make(picture)
                try Task.checkCancellation()
                guard !made.takes.isEmpty else { throw CancellationError() }
                let step = try await Task.detached(priority: .userInitiated) {
                    HangarStep(tool: job.tool, takes: try made.takes.map { try assets.keep($0) }, frame: made.frame,
                               mask: try made.mask.map { try assets.keep($0) }, parameters: job.parameters)
                }.value
                try Task.checkCancellation()
                guard let self else { return }
                self.edit.add(step)
                self.refreshPreview { [weak self] in
                    self?.endJob(number)
                    self?.commit()
                    done?(true)
                }
            } catch {
                guard let self else { return }
                self.endJob(number)
                if !(error is CancellationError) { self.tell(error) }
                done?(false)
            }
        }
    }

    /// Where the picture shimmers: the job's part of it as the picture's shown (its corners where the edit's geometry
    /// takes them).
    private func shimmerRegion(_ region: CGRect?) -> CGRect {
        let frame = current?.pictureFrame ?? canvas.frame
        guard let region, let size = preview?.extent.size, size.width > 0, size.height > 0 else { return frame }
        let g = edit.appliedGeometry
        let shown = g.isIdentity ? size : g.shownSize(for: size)
        let corners = [CGPoint(x: region.minX, y: region.minY), CGPoint(x: region.maxX, y: region.minY),
                       CGPoint(x: region.maxX, y: region.maxY), CGPoint(x: region.minX, y: region.maxY)]
            .map { g.shownPoint(CGPoint(x: $0.x * size.width, y: $0.y * size.height), size: size) }
            .map { CGPoint(x: frame.minX + $0.x / shown.width * frame.width, y: frame.minY + $0.y / shown.height * frame.height) }
        let xs = corners.map(\.x), ys = corners.map(\.y)
        let part = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!).intersection(frame)
        return part.isNull || part.isEmpty ? frame : part
    }

    private func endJob(_ number: Int? = nil) {
        guard number == nil || number == jobNumber else { return }
        job = nil
        blocker.isHidden = true
        shimmer.stop()
    }

    /// While a job works, a tap on Cancel stops it; nothing else is touched.
    @objc private func blockedTap(_ tap: UITapGestureRecognizer) {
        guard closeButton.frame.insetBy(dx: -8, dy: -8).contains(tap.location(in: view)) else { return }
        job?.cancel()
        endJob()
    }

    private func tell(_ error: any Error) {
        let alert = UIAlertController(title: nil, message: error.localizedDescription, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    // MARK: Leaving

    private func doneTapped() {
        let picture = renderedPreview(edit)
        onDone?(HangarResult(edit: edit, preview: picture, original: original, renderer: renderer))
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

    public func moreMenu() -> [UIMenuElement] {
        var items: [UIMenuElement] = current?.menu() ?? []
        items.append(UIAction(title: "Copy Edits", image: UIImage(systemName: "doc.on.doc"),
                              attributes: edit.isOriginal ? .disabled : []) { [weak self] _ in
            guard let self, let data = try? JSONEncoder().encode(self.edit) else { return }
            UIPasteboard.general.setData(data, forPasteboardType: Self.pasteboardType)
        })
        let pasted = UIPasteboard.general.data(forPasteboardType: Self.pasteboardType).flatMap { try? JSONDecoder().decode(HangarEdit.self, from: $0) }
        items.append(UIAction(title: "Paste Edits", image: UIImage(systemName: "doc.on.clipboard"),
                              attributes: pasted == nil ? .disabled : []) { [weak self] _ in
            guard let self, let pasted else { return }
            self.replace(with: pasted)
        })
        if !actions.isEmpty, renderer.assets != nil {
            items.append(UIMenu(options: .displayInline, children: actions.map { action in
                UIAction(title: action.title, image: UIImage(systemName: action.symbol)) { [weak self] _ in self?.run(action.job) }
            }))
        }
        items.append(UIMenu(options: .displayInline, children: [
            UIAction(title: "Revert to Original", image: UIImage(systemName: "arrow.uturn.backward.circle"),
                     attributes: edit.isOriginal ? .disabled : .destructive) { [weak self] _ in
                self?.replace(with: HangarEdit())
            },
        ]))
        return items
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
