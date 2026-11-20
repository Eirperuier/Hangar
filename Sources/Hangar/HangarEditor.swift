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
    private let filterRuler: Ruler
    private let modeBar: ModeBar

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
        undoButton = Chrome.plainButton("arrow.uturn.backward", label: "Undo", style: style)
        redoButton = Chrome.plainButton("arrow.uturn.forward", label: "Redo", style: style)
        moreButton = Chrome.button("ellipsis", label: "More", style: style)
        doneButton = Chrome.button("checkmark", label: "Done", style: style)
        ruler = Ruler(style: style)
        filterRuler = Ruler(style: style)
        modeBar = ModeBar(modes: [
            .init(id: HangarMode.adjust.id, name: "Adjust", symbol: "dial.medium", chosenSymbol: "dial.medium.fill"),
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

    public override var prefersStatusBarHidden: Bool { true }

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
        historyBar.contentView.addSubview(undoButton)
        historyBar.contentView.addSubview(redoButton)
        doneButton.addAction(UIAction { [weak self] _ in self?.doneTapped() }, for: .touchUpInside)
        moreButton.showsMenuAsPrimaryAction = true
        moreButton.menu = UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] completion in
            completion(self?.moreActions() ?? [])
        }])
        titleLabel.textAlignment = .center
        titleLabel.font = style.nameFont.withSize(13)
        titleLabel.textColor = style.secondary
        nameLabel.font = style.nameFont
        nameLabel.textColor = style.secondary
        for chrome in [closeButton, historyBar, moreButton, doneButton, titleLabel, nameLabel, tools, ruler, filters, filterRuler, modeBar] as [UIView] {
            view.addSubview(chrome)
        }

        toolButtons = toolbox.adjustments.map { ToolButton($0, style: style) }
        tools.setItems(toolButtons, chosen: 0)
        tools.onChoose = { [weak self] i in self?.passTool(i) }
        tools.onMove = { [weak self] dragged in self?.ruler.setEnabled(false, dimmed: dragged, animated: true) }
        tools.onRest = { [weak self] i in self?.chooseTool(i) }
        tools.onTapChosen = { [weak self] i in self?.toggleTool(i) }
        ruler.onBegin = { [weak self] in self?.rulerBegan() }
        ruler.onChange = { [weak self] value in self?.rulerMoved(value) }
        ruler.onEnd = { [weak self] _ in self?.rulerEnded() }

        let none = FilterThumbnail(id: nil, name: "Original", style: style)
        thumbnails = [none] + toolbox.filters.map { FilterThumbnail(id: $0.id, name: $0.name, style: style) }
        filters.setItems(thumbnails, chosen: thumbnails.firstIndex { $0.id == edit.filter } ?? 0)
        filters.onChoose = { [weak self] i in self?.chooseFilter(i) }
        filters.onMove = { [weak self] dragged in self?.filterRuler.setEnabled(false, dimmed: dragged, animated: true) }
        filters.onRest = { [weak self] _ in self?.filtersRested() }
        filterRuler.range = 0...1
        filterRuler.onChange = { [weak self] value in self?.filterAmountMoved(value) }
        filterRuler.onEnd = { [weak self] _ in self?.commit() }

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
        for chrome in chromeViews { chrome.alpha = 0 }
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

        let top = safe.top + 4
        closeButton.frame = CGRect(x: safe.left + 16, y: top, width: 44, height: 44)
        historyBar.frame = CGRect(x: closeButton.frame.maxX + 8, y: top, width: 92, height: 44)
        Chrome.round(historyBar)
        undoButton.frame = CGRect(x: 2, y: 0, width: 44, height: 44)
        redoButton.frame = CGRect(x: 46, y: 0, width: 44, height: 44)
        doneButton.frame = CGRect(x: bounds.maxX - safe.right - 16 - 44, y: top, width: 44, height: 44)
        moreButton.frame = CGRect(x: doneButton.frame.minX - 12 - 44, y: top, width: 44, height: 44)
        titleLabel.frame = CGRect(x: historyBar.frame.maxX + 8, y: top, width: moreButton.frame.minX - historyBar.frame.maxX - 16, height: 44)
        titleLabel.isHidden = !sideways
        let below = closeButton.frame.maxY + 12

        let region: CGRect
        if sideways {
            let along = modeBar.fittingSize(for: .along)
            modeBar.axis = .along
            modeBar.frame = CGRect(x: safe.left + 16, y: bounds.midY - along.height / 2, width: along.width, height: along.height)
            let rulerHeight = min(320, bounds.height * 0.45)
            ruler.axis = .along
            ruler.frame = CGRect(x: bounds.maxX - safe.right - 10 - 36, y: bounds.midY - rulerHeight / 2, width: 36, height: rulerHeight)
            filterRuler.axis = .along
            filterRuler.frame = ruler.frame
            let stripHeight = min(bounds.height - below - safe.bottom - 32, 520)
            for strip in [tools, filters] {
                strip.axis = .along
                strip.frame = CGRect(x: ruler.frame.minX - 6 - 56, y: bounds.midY - stripHeight / 2, width: 56, height: stripHeight)
            }
            tools.itemSize = 34
            tools.pitch = 46
            filters.itemSize = 36
            filters.pitch = 41
            nameLabel.textAlignment = .right
            nameLabel.frame = CGRect(x: tools.frame.minX - 8 - 150, y: bounds.midY - 10, width: 150, height: 20)
            region = CGRect(x: modeBar.frame.maxX + 24, y: below, width: nameLabel.frame.minX - 12 - modeBar.frame.maxX - 24,
                            height: bounds.maxY - max(safe.bottom, 16) - 12 - below)
        } else {
            let across = modeBar.fittingSize(for: .across)
            modeBar.axis = .across
            modeBar.frame = CGRect(x: bounds.midX - across.width / 2, y: bounds.maxY - max(safe.bottom - 6, 10) - across.height,
                                   width: across.width, height: across.height)
            ruler.axis = .across
            ruler.frame = CGRect(x: safe.left, y: modeBar.frame.minY - 14 - 36, width: bounds.width - safe.left - safe.right, height: 36)
            filterRuler.axis = .across
            filterRuler.frame = ruler.frame
            for strip in [tools, filters] {
                strip.axis = .across
                strip.frame = CGRect(x: safe.left, y: ruler.frame.minY - 8 - 60, width: ruler.frame.width, height: 60)
            }
            tools.itemSize = 48
            tools.pitch = 72
            filters.itemSize = 46
            filters.pitch = 52
            nameLabel.textAlignment = .center
            nameLabel.frame = CGRect(x: 0, y: tools.frame.minY - 12 - 20, width: bounds.width, height: 20)
            region = CGRect(x: safe.left, y: below, width: bounds.width - safe.left - safe.right, height: nameLabel.frame.minY - 16 - below)
        }
        for thumbnail in thumbnails { thumbnail.axis = sideways ? .along : .across }
        if !leaving {
            canvas.frame = Self.fit(previewSize, in: region, scale: view.window?.screen.scale ?? 2)
            fitShown()
        }
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
                for chrome in self.chromeViews { chrome.alpha = 1 }
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
            for chrome in self.chromeViews { chrome.alpha = 0 }
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
            self.filterRuler.isHidden = adjusting || self.edit.filter == nil
        }
        titleLabel.text = (adjusting ? "Adjust" : "Filters").uppercased()
        if adjusting {
            if let i = toolbox.adjustments.firstIndex(where: { $0.id == tool }) { showName(toolbox.adjustments[i].name) }
        } else {
            showName(thumbnails[filters.chosen].name)
            makeThumbnails()
        }
    }

    private func showName(_ name: String) {
        nameLabel.attributedText = NSAttributedString(string: name.uppercased(), attributes: [.kern: 0.6, .font: style.nameFont,
                                                                                              .foregroundColor: style.secondary])
    }

    // MARK: Adjust

    /// A tool passing the middle of the strip as it moves: its name shown, the ruler (off meanwhile) left alone.
    private func passTool(_ index: Int) {
        guard toolbox.adjustments.indices.contains(index) else { return }
        tool = toolbox.adjustments[index].id
        showName(toolbox.adjustments[index].name)
    }

    /// The strip came to rest on a tool: the ruler set to it and on again.
    private func chooseTool(_ index: Int) {
        guard toolbox.adjustments.indices.contains(index) else { return }
        let adjustment = toolbox.adjustments[index]
        tool = adjustment.id
        rulerTool = adjustment.id
        ruler.range = adjustment.range
        ruler.set(edit.value(of: rulerTool))
        showName(adjustment.name)
        ruler.setEnabled(true, animated: true)
    }

    /// The chosen tool tapped: Auto on or off; any other with a value, switched off or on (its value kept).
    private func toggleTool(_ index: Int) {
        ruler.stop()
        let adjustment = toolbox.adjustments[index]
        if edit.value(of: adjustment.id) == 0 {
            guard adjustment.id == HangarAdjustment.auto.id else { return }
            edit.set(adjustment.id, to: 0.6)
            edit.switchedOff.remove(adjustment.id)
            ruler.set(0.6, animated: true)
        } else if edit.switchedOff.contains(adjustment.id) {
            edit.switchedOff.remove(adjustment.id)
        } else {
            edit.switchedOff.insert(adjustment.id)
        }
        render()
        commit()
    }

    private func rulerBegan() {
        toolButtons.first { $0.id == rulerTool }?.show(value: edit.value(of: rulerTool), switchedOff: false, number: true)
    }

    private func rulerMoved(_ value: Double) {
        edit.set(rulerTool, to: value)
        // Moving a tool switched off switches it on.
        edit.switchedOff.remove(rulerTool)
        toolButtons.first { $0.id == rulerTool }?.show(value: value, switchedOff: false, number: true)
        render()
    }

    private func rulerEnded() {
        commit()
        toolButtons.first { $0.id == rulerTool }?.show(value: edit.value(of: rulerTool), switchedOff: false, number: false)
    }

    // MARK: Filters

    /// A filter passing the middle of the strip, or tapped: on the picture at once, kept when the strip rests.
    private func chooseFilter(_ index: Int) {
        let id = thumbnails[index].id
        edit.filter = id
        if id != nil, edit.filterAmount == 0 { edit.filterAmount = 1 }
        UIView.animate(withDuration: 0.2) { self.filterRuler.isHidden = id == nil }
        showName(thumbnails[index].name)
        render()
    }

    private func filtersRested() {
        filterRuler.set(edit.filterAmount)
        filterRuler.setEnabled(true, animated: true)
        commit()
    }

    private func filterAmountMoved(_ value: Double) {
        edit.filterAmount = value
        render()
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
            button.show(value: edit.value(of: button.id), switchedOff: edit.switchedOff.contains(button.id), number: false)
        }
        ruler.set(edit.value(of: rulerTool))
        let chosen = thumbnails.firstIndex { $0.id == edit.filter } ?? 0
        if chosen != filters.chosen {
            filters.choose(chosen, animated: true)
            if mode == .filters { showName(thumbnails[chosen].name) }
        }
        filterRuler.set(edit.filterAmount)
        if mode == .filters {
            filterRuler.isHidden = edit.filter == nil
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
