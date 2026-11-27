import HangarCore
import UIKit

/// Photos' Tools (iOS 27: "remove objects with natural infill in the new Tools pane"): brushes painted over the
/// picture, what's painted made again by something else and only that part kept, a step to undo. Clean Up works as
/// the finger lifts; a brush that asks for words (an edit of a part of the picture) gathers strokes until they're
/// sent with them. The brushes are the app's (`HangarBrush`): what makes their pictures is a model or something on
/// the device, Hangar has none of its own. Their size on a ruler; several on a strip over it.
@MainActor
public final class HangarToolsModule: HangarModule {
    public let item = HangarModeItem(id: HangarMode.tools.id, name: "Tools", symbol: "wand.and.sparkles", spoken: "Tools")
    public let brushes: [HangarBrush]

    private weak var host: (any HangarHost)?
    private var h: any HangarHost { host! }
    private var stage: BrushStage!
    private let strip = Strip()
    private var buttons: [ToolButton] = []
    private var ruler: Ruler!
    private let hint = BadgeLabel()
    private var bar: WordsBar!
    private var brush: HangarBrush
    private var isChosen = false
    private var working = false
    /// The edit the stage's picture was made for.
    private var stagedFor: HangarEdit?
    private var stagedToken = 0
    private var layout: HangarLayout?
    private var keyboard = CGRect.null
    private var hintTimer: Timer?
    private var keyboardWatch: (any NSObjectProtocol)?

    /// The brush's width on the screen at the ruler's ends, and at first (Flowith's 36).
    static let widths: ClosedRange<CGFloat> = 8...80
    static let firstWidth: CGFloat = 36

    public init(brushes: [HangarBrush]) {
        precondition(!brushes.isEmpty, "Tools needs a brush")
        self.brushes = brushes
        brush = brushes[0]
    }

    public var chrome: [UIView] { [strip, ruler, hint, bar] }
    public var pictureFrame: CGRect? { isChosen && stage.hasPicture ? stage.pictureFrame(in: h.view) : nil }

    // MARK: Building

    public func load(in host: any HangarHost) {
        self.host = host
        let style = host.style
        stage = BrushStage(style: style)
        stage.isHidden = true
        stage.onBegin = { [weak self] in self?.bar.endEditing(true) }
        stage.onStroke = { [weak self] _ in self?.stroked() }
        ruler = Ruler(style: style)
        ruler.range = 0...1
        ruler.magnet = nil
        let first = Double((Self.firstWidth - Self.widths.lowerBound) / (Self.widths.upperBound - Self.widths.lowerBound))
        ruler.marked = first
        ruler.set(first)
        ruler.accessibilityLabel = "Brush Size"
        ruler.onChange = { [weak self] value in self?.sized(value) }
        ruler.onEnd = { [weak self] value in
            self?.sized(value)
            self?.stage.hideCursor()
        }
        stage.brushWidth = Self.firstWidth

        buttons = brushes.map { brush in
            ToolButton(HangarAdjustment(id: brush.id, name: brush.name, symbol: brush.symbol, range: 0...1) { image, _, _ in image }, style: style)
        }
        strip.setItems(buttons, chosen: 0)
        strip.feel = .tools
        strip.pitch = ToolButton.size + 20
        strip.itemSize = ToolButton.size
        strip.fadeClear = 14
        strip.fadeWhole = 40
        strip.onRest = { [weak self] i in self?.choose(i) }
        strip.onChoose = { [weak self] i in self.map { $0.h.showName($0.brushes[i].name) } }
        strip.accessibilityLabel = "Tools"
        strip.spokenValue = { [weak self] i in self?.brushes[i].name ?? "" }

        hint.font = style.hintFont
        hint.textColor = style.foreground
        hint.fill = style.background.withAlphaComponent(0.72)
        hint.numberOfLines = 0
        hint.insets = UIEdgeInsets(top: 7, left: 12, bottom: 7, right: 12)
        hint.layer.cornerRadius = 14
        hint.accessibilityTraits = .staticText

        bar = WordsBar(style: style)
        bar.onSend = { [weak self] words in self?.send(words) }
        bar.onClear = { [weak self] in self?.clearStrokes() }
        bar.onChange = { [weak self] in self?.updateBar() }

        host.add(stage, at: .picture)
        for view in [strip, ruler, hint, bar] as [UIView] {
            host.add(view, at: .controls)
            view.isHidden = true
        }
        keyboardWatch = NotificationCenter.default.addObserver(forName: UIResponder.keyboardWillChangeFrameNotification, object: nil, queue: .main) { [weak self] note in
            let frame = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
            let duration = note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? 0.25
            MainActor.assumeIsolated { self?.keyboardMoved(to: frame, duration: duration) }
        }
    }

    // MARK: Layout

    public func layout(_ layout: HangarLayout) {
        self.layout = layout
        stage.frame = layout.bounds
        stage.region = layout.region
        let axis: Ruler.Axis = layout.sideways ? .along : .across
        ruler.axis = axis
        ruler.frame = layout.ruler
        strip.axis = axis
        strip.reach = layout.sideways ? 361 : nil
        strip.frame = layout.tools
        placeHint()
        placeBar(animated: false)
    }

    /// What's said, in a platter over the picture's top (Photos puts its Clean Up messages in a platter of glass).
    private func placeHint() {
        guard let layout else { return }
        let width = min(layout.region.width - 32, 360)
        let fits = hint.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        let size = CGSize(width: min(width, ceil(fits.width)), height: ceil(fits.height))
        hint.frame = CGRect(x: (layout.region.midX - size.width / 2).rounded(), y: layout.region.minY + 4, width: size.width, height: size.height)
    }

    /// The words' bar: where the name is on a phone (between the picture and the tools), along the picture's foot
    /// on an iPad; over the keyboard while it's up.
    private func placeBar(animated: Bool) {
        guard let layout else { return }
        let height: CGFloat = 48
        var frame: CGRect
        if layout.sideways {
            let width = min(layout.region.width - 32, 520)
            frame = CGRect(x: layout.region.midX - width / 2, y: layout.region.maxY - height - 8, width: width, height: height)
        } else {
            let width = layout.bounds.width - layout.safeArea.left - layout.safeArea.right - 32
            frame = CGRect(x: layout.safeArea.left + 16, y: layout.modeBar.minY - 151.7 - height / 2, width: width, height: height)
        }
        if !keyboard.isNull {
            let top = h.view.convert(keyboard, from: nil).minY
            if top < layout.bounds.maxY { frame.origin.y = min(frame.minY, top - height - 10) }
        }
        let change = { self.bar.frame = frame.integral }
        if animated { UIView.animate(withDuration: 0.25, delay: 0, options: [.beginFromCurrentState], animations: change) } else { change() }
    }

    private func keyboardMoved(to frame: CGRect?, duration: Double) {
        keyboard = frame ?? .null
        guard isChosen else { return }
        placeBar(animated: duration > 0)
    }

    // MARK: Coming and going

    public func show(_ shown: Bool) {
        isChosen = shown
        strip.isHidden = !shown || brushes.count < 2
        ruler.isHidden = !shown
        hint.isHidden = !shown
        if shown { h.showName(brush.name) }
        updateBar()
    }

    /// Into Tools: the stage over the canvas, in its place, showing the edit.
    public func entered() {
        h.layoutNow()
        stage.unzoom(animated: false)
        stage.isHidden = false
        stage.alpha = 1
        say(brush.hint)
        makeStagePicture { [weak self] in self?.h.showCanvas(false) }
    }

    public func left() {
        bar.endEditing(true)
        stage.clear(fading: false)
        stage.unzoom(animated: false)
        h.showCanvas(true)
        stage.isHidden = true
        hintTimer?.invalidate()
    }

    public func closing() {
        stage.alpha = 0
        bar.endEditing(true)
        keyboardWatch.map(NotificationCenter.default.removeObserver)
        keyboardWatch = nil
    }

    public func stop() {
        ruler.stop()
    }

    public func showOriginal(_ shown: Bool) {
        stage.showOriginal(shown)
    }

    public func sync() {
        guard isChosen else { return }
        makeStagePicture()
    }

    public func pictureChanged() {
        stagedFor = nil
        sync()
    }

    /// The edit drawn whole at the canvas's pixels, and the picture before its steps (for a finger held), off the
    /// main thread; shown on the stage.
    private func makeStagePicture(_ done: (@MainActor () -> Void)? = nil) {
        guard let (shaped, context) = h.shaped else { return }
        let edit = h.edit
        if stagedFor == edit, stage.hasPicture { done?(); return }
        stagedFor = edit
        stagedToken += 1
        let token = stagedToken
        let (renderer, plain) = (h.renderer, h.plain)
        Task { [weak self] in
            let made = await Task.detached(priority: .userInitiated) { () -> (CGImage, CGImage?)? in
                let space = CGColorSpace(name: CGColorSpace.displayP3)!
                let out = renderer.apply(edit, to: shaped, context: context)
                guard let picture = HangarRenderer.context.createCGImage(out, from: shaped.extent, format: .RGBA8, colorSpace: space) else { return nil }
                let original = plain.flatMap { plain -> CGImage? in
                    let shapedPlain = renderer.shape(edit, plain)
                    return HangarRenderer.context.createCGImage(shapedPlain, from: shapedPlain.extent, format: .RGBA8, colorSpace: space)
                }
                return (picture, original)
            }.value
            guard let self, self.stagedToken == token, let made else { return }
            self.stage.show(made.0, original: made.1)
            done?()
        }
    }

    // MARK: Brushes

    private func choose(_ index: Int) {
        guard brushes.indices.contains(index), brushes[index].id != brush.id else { return }
        brush = brushes[index]
        stage.clear(fading: false)
        say(brush.hint)
        updateBar()
    }

    private func sized(_ value: Double) {
        let width = Self.widths.lowerBound + CGFloat(value) * (Self.widths.upperBound - Self.widths.lowerBound)
        stage.brushWidth = width
        stage.showCursor()
    }

    /// A stroke lifted: Clean Up works on it at once; a brush asking for words waits for them.
    private func stroked() {
        if brush.words == nil {
            work(words: nil)
        } else {
            updateBar()
        }
    }

    private func clearStrokes() {
        stage.clear(fading: true)
        updateBar()
    }

    private func send(_ words: String) {
        guard !stage.lines.isEmpty else { return say(HangarRetouchError.unpainted.errorDescription ?? "", for: 3) }
        bar.endEditing(true)
        work(words: words)
    }

    private func updateBar() {
        guard isChosen, let words = brush.words else {
            bar.isHidden = true
            if isChosen { h.showName(brush.name) }
            return
        }
        bar.isHidden = false
        // On a phone the words go where the name is.
        h.showName(layout?.sideways == true ? brush.name : nil)
        bar.configure(words, painted: !stage.lines.isEmpty, working: working)
    }

    /// The strokes shown, back on the picture under the edit's geometry, made again by the brush; only their part
    /// kept, as one step.
    private func work(words: String?) {
        guard let base = h.base?.image.extent.size, !working else { return }
        let geometry = h.edit.appliedGeometry
        let shorter = min(base.width, base.height)
        let strokes = stage.lines.map { line in
            HangarStroke(points: line.points.map { p in
                let q = geometry.picturePoint(p, size: base)
                return CGPoint(x: q.x / base.width, y: q.y / base.height)
            }, width: line.width / shorter)
        }
        guard !strokes.isEmpty else { return }
        let brush = brush
        let region = strokes.reduce(CGRect.null) { $0.union($1.bounds(aspect: base.width / base.height)) }.intersection(HangarStep.whole)
        let asked = try? HangarValue(BrushAsked(brush: brush.id, strokes: strokes, words: words))
        let job = HangarJob(tool: brush.id, name: brush.working, region: region.isNull ? nil : region, longestSide: brush.longestSide,
                            parameters: asked) { picture in
            let request = try HangarBrushRequest(picture: picture, strokes: strokes, words: words, mark: brush.mark)
            let takes = try await brush.make(request)
            let made = try HangarRetouch.made(takes, for: request, matchingTones: brush.matchesTones)
            return HangarMade(takes: made.takes, mask: made.mask)
        }
        working = true
        stage.paints = false
        updateBar()
        say(brush.working, for: nil)
        h.run(job) { [weak self] done in
            guard let self else { return }
            self.working = false
            self.stage.paints = true
            if done {
                self.stage.clear(fading: true)
                self.bar.clearWords()
                self.say(brush.id == "cleanUp" ? "Objects in your scene have been removed. Tap and hold to see the original." : brush.hint, for: 4)
            } else {
                // Cancelled or failed: Clean Up's stroke goes; words wait to be sent again.
                if brush.words == nil { self.stage.clear(fading: true) }
                self.say(brush.hint)
            }
            self.updateBar()
        }
    }

    /// Says `words` in the platter, for a while then back to the brush's hint (nil: until said otherwise).
    private func say(_ words: String, for seconds: TimeInterval? = nil) {
        hintTimer?.invalidate()
        hint.text = words
        hint.accessibilityLabel = words
        placeHint()
        UIView.animate(withDuration: 0.2) { self.hint.alpha = words.isEmpty ? 0 : 1 }
        guard let seconds else { return }
        hintTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.working else { return }
                self.say(self.brush.hint)
            }
        }
    }
}

public extension HangarMode {
    static let tools = HangarMode("tools")
}

/// The words a brush asks for, on a capsule: a field, words to start from, the strokes cleared, and sent.
@MainActor
final class WordsBar: UIView, UITextFieldDelegate {
    var onSend: ((String) -> Void)?
    var onClear: (() -> Void)?
    var onChange: (() -> Void)?

    private let capsule: UIVisualEffectView
    private let field = UITextField()
    private let suggest: UIButton
    private let clear: UIButton
    private let send: UIButton
    private let style: HangarStyle
    private var painted = false
    private var working = false

    init(style: HangarStyle) {
        self.style = style
        capsule = Chrome.capsule(style)
        suggest = Chrome.plainButton("sparkles", label: "Suggestions", style: style)
        clear = Chrome.plainButton("xmark.circle.fill", label: "Clear Brush Strokes", style: style)
        send = Chrome.button("arrow.up", label: "Send", style: style, prominent: true)
        super.init(frame: .zero)
        addSubview(capsule)
        field.font = style.wordsFont
        field.textColor = style.foreground
        field.returnKeyType = .send
        field.enablesReturnKeyAutomatically = true
        field.delegate = self
        field.accessibilityIdentifier = "brushWords"
        field.addAction(UIAction { [weak self] _ in self?.changed() }, for: .editingChanged)
        suggest.showsMenuAsPrimaryAction = true
        clear.tintColor = style.secondary
        clear.addAction(UIAction { [weak self] _ in self?.onClear?() }, for: .touchUpInside)
        send.addAction(UIAction { [weak self] _ in self?.sendTapped() }, for: .touchUpInside)
        for view in [suggest, field, clear] as [UIView] { capsule.contentView.addSubview(view) }
        addSubview(send)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(_ words: HangarWords, painted: Bool, working: Bool) {
        self.painted = painted
        self.working = working
        field.attributedPlaceholder = NSAttributedString(string: words.placeholder, attributes: [.foregroundColor: style.secondary])
        suggest.isHidden = words.suggestions.isEmpty
        suggest.menu = UIMenu(children: words.suggestions.map { suggestion in
            UIAction(title: suggestion.title, image: suggestion.symbol.flatMap { UIImage(systemName: $0) }) { [weak self] _ in
                self?.append(suggestion.words)
            }
        })
        field.isEnabled = !working
        update()
        setNeedsLayout()
    }

    func clearWords() {
        field.text = nil
        update()
    }

    private func append(_ words: String) {
        let now = field.text ?? ""
        field.text = now.isEmpty ? words : now + (now.hasSuffix(" ") ? "" : " ") + words
        changed()
        field.becomeFirstResponder()
    }

    private func changed() {
        update()
        onChange?()
    }

    private func update() {
        let hasWords = !(field.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        send.isEnabled = hasWords && painted && !working
        clear.isHidden = !painted || working
    }

    private func sendTapped() {
        guard let words = field.text?.trimmingCharacters(in: .whitespacesAndNewlines), !words.isEmpty else { return }
        onSend?(words)
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        sendTapped()
        return false
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let h = bounds.height
        send.frame = CGRect(x: bounds.width - h, y: 0, width: h, height: h)
        capsule.frame = CGRect(x: 0, y: 0, width: bounds.width - h - 8, height: h)
        Chrome.round(capsule)
        var x: CGFloat = 6
        if !suggest.isHidden {
            suggest.frame = CGRect(x: x, y: 0, width: 36, height: h)
            x += 36
        } else {
            x = 18
        }
        let right = capsule.bounds.width - (clear.isHidden ? 16 : 40)
        clear.frame = CGRect(x: capsule.bounds.width - 40, y: 0, width: 36, height: h)
        field.frame = CGRect(x: x, y: 0, width: max(0, right - x), height: h)
    }
}
