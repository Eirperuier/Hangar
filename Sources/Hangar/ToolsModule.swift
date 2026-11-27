import HangarCore
import UIKit

/// Photos' Tools (iOS 27: "Choose a new camera angle, expand the edges of your photo, and remove objects… in the new
/// Tools pane"): tools that ask something of the picture shown over the editor (painted, tapped, a frame pulled out, a
/// camera moved, a light placed), then have it made again by something else and laid back as one step to undo. The
/// tools are the app's (`HangarTool`): what makes their pictures is a model or something on the device, Hangar has
/// none of its own. Several on a strip; a brush's size or a value on the ruler under them; words in a bar where their
/// name is; a button over the picture's foot for those that wait to be asked; and once one's made, its takes over the
/// picture's top: another asked for, the one used chosen, how it's laid.
@MainActor
public final class HangarToolsModule: HangarModule {
    public let item = HangarModeItem(id: HangarMode.tools.id, name: "Tools", symbol: "wand.and.sparkles", spoken: "Tools")
    public let tools: [HangarTool]

    private weak var host: (any HangarHost)?
    private var h: any HangarHost { host! }
    private var stage: ToolStage!
    private let strip = Strip()
    private var ruler: Ruler!
    private let hint = BadgeLabel()
    private var bar: WordsBar!
    private var chips: Chips!
    private var action: UIButton!
    private var pill: ResultPill!
    private let references = ReferenceRow()
    private let pad = TouchPad()
    private let dot = LightDot()
    private let frameBox = FrameBox()
    private let kept = UIImageView()
    private var tool: HangarTool
    private var isChosen = false
    private var working = false
    private var layout: HangarLayout?
    private var keyboard = CGRect.null
    private var hintTimer: Timer?
    private var keyboardWatch: (any NSObjectProtocol)?

    /// The edit the stage's picture was made for, and that picture.
    private var stagedFor: HangarEdit?
    private var stagedToken = 0
    private var stagePicture: CGImage?

    // What each tool's been asked so far.
    /// The brush's width on the screen, in points, held to the chosen tool's (the web canvas's).
    private var brushWidth = HangarMarking.firstBrushWidth
    private var picked: [HangarReference] = []
    private var found: [Found] = []
    private var foundFor: CGImage?
    private var finding = false
    private var extendFrame = HangarStep.whole
    private var shape = 1
    private var closeBox = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
    private var values: [String: Double] = [:]
    private var parameter = 0
    private var previewSource: CIImage?
    private var previewBusy = false
    private var previewAgain = false

    /// The step just made, by its first take (its takes shown over the picture while it's the edit's last), the job
    /// that made it (to ask again), and whether what it keeps is shown.
    private var result: String?
    private var lastJob: HangarJob?
    /// Where the last job was shown working (asked again, its strokes gone: their bounds).
    private var lastArea = HangarArea.whole
    private var showingKept = false

    /// Text found on the picture: where (0 to 1 of the picture shown), what it says, what it's to say instead.
    private struct Found {
        var box: CGRect
        var text: String
        var to: String?
        var view: UIView
    }

    /// Extend's shapes: the picture's own, any, then fixed ones.
    static let shapes: [(name: String, ratio: CGFloat?)] = [("Original", nil), ("Freeform", nil), ("Square", 1), ("4:3", 4 / 3), ("3:4", 3 / 4),
                                                             ("16:9", 16 / 9), ("9:16", 9 / 16)]
    /// The most takes a step keeps.
    static let mostTakes = 8

    public init(tools: [HangarTool]) {
        precondition(!tools.isEmpty, "Tools needs a tool")
        self.tools = tools
        tool = tools[0]
    }

    public var chrome: [UIView] { [strip, ruler, hint, bar, chips, action, pill, references] }
    public var pictureFrame: CGRect? { isChosen && stage.hasPicture ? stage.pictureFrame(in: h.view) : nil }

    // MARK: Building

    public func load(in host: any HangarHost) {
        self.host = host
        GlowKit.prepare()
        let style = host.style
        stage = ToolStage(style: style)
        stage.isHidden = true
        stage.onBegin = { [weak self] in self?.begun() }
        stage.onStroke = { [weak self] _ in self?.stroked() }
        stage.marks.addSubview(kept)
        kept.alpha = 0
        ruler = Ruler(style: style)
        ruler.onChange = { [weak self] value in self?.ruled(value) }
        ruler.onEnd = { [weak self] value in
            self?.ruled(value)
            self?.stage.hideCursor()
        }
        stage.brushWidth = brushWidth

        let buttons = tools.map { tool in
            ToolButton(HangarAdjustment(id: tool.id, name: tool.name, symbol: tool.symbol, range: 0...1) { image, _, _ in image }, style: style)
        }
        strip.setItems(buttons, chosen: 0)
        strip.feel = .tools
        strip.pitch = ToolButton.size + 20
        strip.itemSize = ToolButton.size
        strip.fadeClear = 14
        strip.fadeWhole = 40
        strip.onRest = { [weak self] i in self?.choose(i) }
        // A tool passing the middle: its name, where the chosen one's words or values aren't.
        strip.onChoose = { [weak self] i in
            guard let self, self.tools.indices.contains(i), !self.takesName(self.tool) else { return }
            self.h.showName(self.title(for: self.tools[i]))
        }
        strip.accessibilityLabel = "Tools"
        strip.spokenValue = { [weak self] i in self?.tools[i].name ?? "" }

        hint.font = style.hintFont
        hint.textColor = style.foreground
        hint.fill = style.background.withAlphaComponent(0.72)
        hint.numberOfLines = 0
        hint.insets = UIEdgeInsets(top: 7, left: 12, bottom: 7, right: 12)
        hint.layer.cornerRadius = 14
        hint.accessibilityTraits = .staticText

        bar = WordsBar(style: style)
        bar.onSend = { [weak self] _ in self?.work() }
        bar.onClear = { [weak self] in self?.clearStrokes() }
        bar.onChange = { [weak self] in self?.updateControls() }
        bar.onAttach = { [weak self] in self?.pickReference() }
        references.onRemove = { [weak self] i in
            guard let self, self.picked.indices.contains(i) else { return }
            self.picked.remove(at: i)
            self.references.show(self.picked.map(\.picture))
            self.arrange()
        }

        chips = Chips(style: style)
        chips.onChoose = { [weak self] i in self?.chipChosen(i) }

        action = UIButton(configuration: .plain())
        action.addAction(UIAction { [weak self] _ in self?.work() }, for: .touchUpInside)
        action.accessibilityIdentifier = "toolAction"

        pill = ResultPill(style: style)
        pill.isHidden = true
        pill.onTake = { [weak self] i in self?.useTake(i) }
        pill.onAgain = { [weak self] in self?.again() }
        pill.onMasked = { [weak self] masked in self?.setMasked(masked) }
        pill.onShowKept = { [weak self] shown in self?.showKept(shown) }

        pad.addSubview(dot)
        pad.onOne = { [weak self] at, moved, state in self?.oneFinger(at, moved, state) }
        pad.onTwo = { [weak self] moved, scale, turned, state in self?.twoFingers(moved, scale, turned, state) }
        frameBox.onChange = { [weak self] rect in self?.framed(rect) }
        frameBox.onEnd = { [weak self] rect in
            self?.framed(rect)
            self?.arrange(animated: true)
        }

        // A finger anywhere but on the words puts the keyboard away (as it is, a menu over the bars gives it back as
        // it closes).
        let watch = TouchWatch()
        watch.onTouch = { [weak self] touch in
            guard let self, let view = touch.view, !view.isDescendant(of: self.bar), !view.isDescendant(of: self.references) else { return }
            self.bar.endEditing(true)
        }
        host.view.addGestureRecognizer(watch)
        host.add(stage, at: .picture)
        for view in [pad, frameBox] as [UIView] {
            host.add(view, at: .picture)
            view.isHidden = true
        }
        for view in [strip, ruler, references, bar, chips, action, hint, pill] as [UIView] {
            host.add(view, at: .controls)
            view.isHidden = true
        }
        keyboardWatch = NotificationCenter.default.addObserver(forName: UIResponder.keyboardWillChangeFrameNotification, object: nil, queue: .main) { [weak self] note in
            let frame = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
            let duration = note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? 0.25
            MainActor.assumeIsolated { self?.keyboardMoved(to: frame, duration: duration) }
        }
        setTool(tools[0])
    }

    // MARK: Layout

    public func layout(_ layout: HangarLayout) {
        self.layout = layout
        stage.frame = layout.bounds
        frameBox.frame = layout.bounds
        let axis: Ruler.Axis = layout.sideways ? .along : .across
        ruler.axis = axis
        ruler.frame = layout.ruler
        strip.axis = axis
        strip.reach = layout.sideways ? 361 : nil
        strip.frame = layout.tools
        arrange()
    }

    /// The tool's name; its price after it if nothing else shows it (its price is on what sets it working: its
    /// button, or its words' Send).
    private func title(for tool: HangarTool) -> String {
        guard tool.action == nil, tool.words == nil, let price = tool.price else { return tool.name }
        return "\(tool.name) · \(price)"
    }

    private var isExtend: Bool { if case .extend = tool.kind { true } else { false } }
    private var isCloseUp: Bool { if case .closeUp = tool.kind { true } else { false } }

    /// Everything placed for the tool chosen and what it's been asked: what shows where (a phone's name row taken
    /// by the words or the values; an iPad's along the picture's foot), where the picture goes (above what's along
    /// its foot; Extend's smaller, inside its frame).
    private func arrange(animated: Bool = false) {
        guard let layout else { return }
        let sideways = layout.sideways
        let region = layout.region
        let words = tool.words != nil
        let values = !tool.parameters.isEmpty
        let hasChips = values || isExtend
        let hasAction = tool.action != nil
        let nameTaken = takesName(tool)
        // What was showing, and where: moved there from where it was, if it's animated.
        let was = [bar, chips, action, references].map { (view: $0 as UIView, shown: !$0.isHidden, frame: $0.frame) }

        // Shown or not.
        if isChosen {
            strip.isHidden = tools.count < 2
            ruler.isHidden = !(tool.paints || values)
            bar.isHidden = !words
            chips.isHidden = !hasChips
            action.isHidden = !hasAction
            references.isHidden = picked.isEmpty || !words
            pad.isHidden = !values
            frameBox.isHidden = !(isExtend || isCloseUp) || !stage.hasPicture
            h.showName(nameTaken ? nil : title(for: tool))
        }
        dot.isHidden = { if case .light = tool.kind { false } else { true } }()
        pad.takesTwo = { if case .reframe = tool.kind { true } else { false } }()

        // Along the picture's foot, from the bottom: on an iPad the words, the values and the button; on a phone the
        // button. The pictures to go by over the words, room kept for them.
        let gap: CGFloat = 10
        var foot = region.maxY
        var along: [UIView] = []
        let across = layout.bounds.width - layout.safeArea.left - layout.safeArea.right - 32
        if words {
            if sideways {
                let width = min(region.width - 32, 520)
                bar.frame = CGRect(x: region.midX - width / 2, y: foot - 48 - 8, width: width, height: 48)
                foot = bar.frame.minY - gap
                along.append(bar)
            } else {
                bar.frame = CGRect(x: layout.safeArea.left + 16, y: layout.modeBar.minY - 151.7 - 24, width: across, height: 48)
            }
            references.frame = CGRect(x: bar.frame.minX + 4, y: bar.frame.minY - ReferenceRow.side - 10, width: bar.frame.width, height: ReferenceRow.side)
            if !references.isHidden {
                foot = min(foot, references.frame.minY - gap)
                if sideways { along.append(references) }
            }
        }
        if hasChips {
            if sideways {
                chips.frame = CGRect(x: region.minX + 16, y: foot - Chips.height - (words ? 0 : 8), width: region.width - 32, height: Chips.height)
                foot = chips.frame.minY - gap
                along.append(chips)
            } else if isExtend {
                // A phone's Extend has no ruler: its shapes where it would be.
                chips.frame = CGRect(x: layout.safeArea.left + 16, y: layout.ruler.midY - Chips.height / 2, width: across, height: Chips.height)
            } else {
                chips.frame = CGRect(x: layout.safeArea.left + 16, y: layout.modeBar.minY - 151.7 - Chips.height / 2, width: across, height: Chips.height)
            }
        }
        if hasAction {
            styleAction(price: tool.price)
            let size = action.sizeThatFits(CGSize(width: region.width - 32, height: 60))
            let height = max(44, ceil(size.height))
            action.frame = CGRect(x: (region.midX - size.width / 2).rounded(), y: foot - height - 8, width: ceil(size.width), height: height)
            foot = action.frame.minY - gap
            along.append(action)
        }

        // Where the picture goes: where it is for every tool, what's along its foot just under it, if there's room
        // for it there; over it if not. (Extend's over it: the room round its frame is where it's pulled out to.)
        var work = CGRect(x: region.minX, y: region.minY, width: region.width, height: max(80, foot - region.minY))
        var place = work
        if isChosen, isExtend, stage.hasPicture {
            place = extendPlace(in: work)
        } else if isChosen, stage.hasPicture, !along.isEmpty {
            let shown = HangarEditor.fit(stage.pixelSize, in: region, scale: layout.scale)
            let top = foot + gap, under: CGFloat = 16
            if shown.maxY + under <= top {
                for view in along { view.frame.origin.y -= top - (shown.maxY + under) }
                place = region
                work.size.height = shown.maxY + under - region.minY
            }
        }
        placeBarOverKeyboard()
        let change = {
            self.stage.region = place
            self.stage.layoutIfNeeded()
        }
        if animated, isChosen { UIView.animate(withDuration: 0.3, delay: 0, options: [.beginFromCurrentState], animations: change) } else { change() }
        if animated, isChosen {
            for (view, shown, frame) in was where shown && !view.isHidden && view.frame != frame {
                let to = view.frame
                view.frame = frame
                UIView.animate(withDuration: 0.3, delay: 0, options: [.beginFromCurrentState]) { view.frame = to }
            }
        }
        pad.frame = work
        // The frame goes where the picture's going, with it.
        let wasFramed = frameBox.onScreen
        frameBox.kind = isExtend ? .around : .inside
        frameBox.limit = work.insetBy(dx: 8, dy: 8)
        frameBox.picture = isExtend ? place : stage.pictureFrame(in: h.view)
        frameBox.rect = isExtend ? extendFrame : closeBox
        frameBox.ratio = isExtend ? shapeRatio : nil
        if animated, isChosen, isExtend, !frameBox.isHidden { frameBox.glide(from: wasFramed) }
        placeDot()
        if !found.isEmpty { drawFound() }
        kept.frame = stage.marks.bounds
        updateControls()
    }

    /// Whether a tool's words or values are where its name goes (a phone's name row).
    private func takesName(_ tool: HangarTool) -> Bool {
        !(layout?.sideways ?? false) && (tool.words != nil || !tool.parameters.isEmpty)
    }

    /// Where the picture goes for Extend: its frame fitted to `work`, the picture inside it where the frame says.
    private func extendPlace(in work: CGRect) -> CGRect {
        let pixels = stage.pixelSize
        let f = extendFrame
        // The frame fitted under the hint (and a step's takes over it), a little smaller than it could be: room round
        // it to pull it out further (it's fitted again as it's let go).
        let top = 56 + (takesStep == nil ? 0 : ResultPill.height + 8)
        let room = work.inset(by: UIEdgeInsets(top: top, left: 16, bottom: 16, right: 16))
        let fitted = HangarEditor.fit(CGSize(width: f.width * pixels.width, height: f.height * pixels.height),
                                      in: room.insetBy(dx: room.width * 0.09, dy: room.height * 0.09), scale: layout?.scale ?? 2)
        return CGRect(x: fitted.minX - f.minX / f.width * fitted.width, y: fitted.minY - f.minY / f.height * fitted.height,
                      width: fitted.width / f.width, height: fitted.height / f.height)
    }

    /// The button over the picture's foot: the tool's action in capitals, its price under it where the name's not
    /// showing it.
    private func styleAction(price: String?) {
        guard let title = tool.action else { return }
        var configuration: UIButton.Configuration
        if h.style.glass, #available(iOS 26.0, *) {
            configuration = .prominentGlass()
        } else {
            configuration = .filled()
        }
        configuration.cornerStyle = .capsule
        configuration.baseBackgroundColor = h.style.accent
        configuration.baseForegroundColor = .black
        configuration.attributedTitle = AttributedString(title.uppercased(), attributes: AttributeContainer([.font: UIFont.systemFont(ofSize: 15, weight: .semibold)]))
        configuration.attributedSubtitle = price.map { AttributedString($0, attributes: AttributeContainer([.font: UIFont.systemFont(ofSize: 11, weight: .medium)])) }
        configuration.titleAlignment = .center
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 20, bottom: 6, trailing: 20)
        action.configuration = configuration
        action.accessibilityLabel = title
        action.accessibilityValue = price
    }

    /// What's said, in a platter over the picture's top (Photos puts its Clean Up messages in a platter of glass);
    /// under a step's takes while they show.
    private func placeHint() {
        guard let layout else { return }
        let region = layout.region
        var top = region.minY + 4
        if !pill.isHidden {
            let width = min(pill.fittingWidth, region.width - 32)
            pill.frame = CGRect(x: (region.midX - width / 2).rounded(), y: top, width: width, height: ResultPill.height)
            top = pill.frame.maxY + 8
        }
        let width = min(region.width - 32, 360)
        let fits = hint.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        let size = CGSize(width: min(width, ceil(fits.width)), height: ceil(fits.height))
        hint.frame = CGRect(x: (region.midX - size.width / 2).rounded(), y: top, width: size.width, height: size.height)
    }

    /// The words over the keyboard while it's up.
    private func placeBarOverKeyboard() {
        guard !keyboard.isNull, !bar.isHidden, let layout else { return }
        let top = h.view.convert(keyboard, from: nil).minY
        guard top < layout.bounds.maxY else { return }
        bar.frame.origin.y = min(bar.frame.minY, top - bar.frame.height - 10)
        references.frame.origin.y = bar.frame.minY - ReferenceRow.side - 10
    }

    private func keyboardMoved(to frame: CGRect?, duration: Double) {
        keyboard = frame ?? .null
        guard isChosen else { return }
        if duration > 0 {
            UIView.animate(withDuration: duration, delay: 0, options: [.beginFromCurrentState]) { self.arrange() }
        } else {
            arrange()
        }
    }

    /// Each control as what's been asked is: what can be sent, the button, the takes.
    private func updateControls() {
        if let words = tool.words {
            let isEdit = { if case .edit = tool.kind { true } else { false } }()
            bar.configure(words, painted: !stage.lines.isEmpty, working: working, sends: tool.action == nil,
                          needsPaint: false, attaches: isEdit && tool.pickReference != nil && picked.count < 3,
                          price: tool.price)
        }
        action.isEnabled = !working && canWork
        updatePill()
        placeHint()
    }

    /// Whether the tool has what it needs to work.
    private var canWork: Bool {
        switch tool.kind {
        case .cleanUp: !stage.lines.isEmpty
        case .edit: !bar.words.isEmpty
        case .text: found.contains { $0.to != nil }
        case .extend: extendFrame != HangarStep.whole
        case .reframe: HangarReframe.all.contains { abs((values[$0.id] ?? $0.start) - $0.start) > 0.001 }
        case .light, .closeUp: true
        }
    }

    // MARK: Coming and going

    public func show(_ shown: Bool) {
        isChosen = shown
        if !shown {
            for view in [strip, ruler, hint, bar, chips, action, pill, references, pad, frameBox] as [UIView] { view.isHidden = true }
            return
        }
        hint.isHidden = false
        arrange()
    }

    /// Into Tools: the stage over the canvas, in its place, showing the edit.
    public func entered() {
        h.layoutNow()
        stage.unzoom(animated: false)
        stage.isHidden = false
        stage.alpha = 1
        // From where the canvas shows the picture (what's flown there from another mode) to the tool's place.
        if let layout {
            stage.region = layout.region
            stage.layoutIfNeeded()
        }
        settling = h.hasEntered
        say(tool.hint)
        makeStagePicture { [weak self] in self?.toolShown() }
    }

    /// Whether the stage's picture moves to its place once it's there (just into Tools).
    private var settling = false

    /// The stage shows the picture: the canvas hidden, everything placed.
    private func stageShown() {
        guard isChosen else { return }
        h.showCanvas(false)
        arrange(animated: settling)
        settling = false
    }

    public func left() {
        bar.endEditing(true)
        stage.clear(fading: false)
        stage.unzoom(animated: false)
        stage.preview(nil)
        collapseResult()
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
        makeStagePicture { [weak self] in self?.toolShown() }
        updateControls()
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
        if stagedFor == edit, stage.hasPicture {
            stageShown()
            done?()
            return
        }
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
            self.stagePicture = made.0
            self.previewSource = nil
            self.stage.show(made.0, original: made.1)
            // The stage shows the picture now, wherever it was asked for first.
            self.stageShown()
            done?()
        }
    }

    // MARK: Tools

    private func choose(_ index: Int) {
        guard tools.indices.contains(index), tools[index].id != tool.id else {
            // Back on the one chosen: its name again, if others' showed as they passed.
            if isChosen { h.showName(takesName(tool) ? nil : title(for: tool)) }
            return
        }
        setTool(tools[index])
        arrange(animated: true)
        toolShown()
    }

    /// A tool chosen: what was asked of another let go, the stage made ready for it.
    private func setTool(_ new: HangarTool) {
        tool = new
        stage.clear(fading: false)
        stage.preview(nil)
        stage.paints = new.paints
        stage.zooms = { switch new.kind { case .cleanUp, .edit, .text: true; default: false } }()
        if case .text = new.kind { stage.onTap = { [weak self] p in self?.tapped(p) } } else { stage.onTap = nil }
        bar.clearWords()
        bar.endEditing(true)
        picked = []
        references.show([])
        clearFound()
        extendFrame = HangarStep.whole
        shape = 1
        chips.set(new.parameters.isEmpty ? Self.shapes.map(\.name) : new.parameters.map(\.name), chosen: new.parameters.isEmpty ? shape : 0)
        values = [:]
        parameter = 0
        collapseResult()
        setRuler()
        say(new.hint)
    }

    /// What's shown once the tool's chosen and the picture's there: text looked for, a preview made.
    private func toolShown() {
        guard isChosen else { return }
        switch tool.kind {
        case .text: findText()
        case .reframe, .light: renderPreview()
        default: break
        }
        arrange()
    }

    /// The ruler for the brush's size, or the value chosen.
    private func setRuler() {
        let parameters = tool.parameters
        if parameters.indices.contains(parameter) {
            let p = parameters[parameter]
            ruler.range = p.range
            ruler.magnet = p.start
            ruler.marked = p.start
            ruler.set(values[p.id] ?? p.start)
            ruler.accessibilityLabel = p.name
        } else {
            // Along the ruler, the tool's widths end to end.
            let widths = tool.marking.brushWidths, span = widths.upperBound - widths.lowerBound
            brushWidth = min(max(brushWidth, widths.lowerBound), widths.upperBound)
            stage.brushWidth = brushWidth
            ruler.range = 0...1
            ruler.magnet = nil
            ruler.marked = Double((HangarMarking.firstBrushWidth - widths.lowerBound) / span)
            ruler.set(Double((brushWidth - widths.lowerBound) / span))
            ruler.accessibilityLabel = "Brush Size"
        }
    }

    private func ruled(_ value: Double) {
        let parameters = tool.parameters
        if parameters.indices.contains(parameter) {
            values[parameters[parameter].id] = value
            collapseResult()
            renderPreview()
            updateControls()
        } else {
            let widths = tool.marking.brushWidths
            brushWidth = widths.lowerBound + CGFloat(value) * (widths.upperBound - widths.lowerBound)
            stage.brushWidth = brushWidth
            stage.showCursor()
        }
    }

    private func chipChosen(_ i: Int) {
        if !tool.parameters.isEmpty {
            parameter = i
            setRuler()
            return
        }
        // Extend's shape: the least frame of it round the picture.
        shape = i
        collapseResult()
        if let ratio = shapeRatio {
            let pixels = stage.pixelSize
            let aspect = pixels.width / max(pixels.height, 1)
            let w = max(1, ratio / aspect), h = max(1, aspect / ratio)
            extendFrame = CGRect(x: (1 - w) / 2, y: (1 - h) / 2, width: w, height: h)
        }
        arrange(animated: true)
    }

    /// The shape Extend's frame is held to, as it's shown (nil for any).
    private var shapeRatio: CGFloat? {
        guard shape != 1 else { return nil }
        let pixels = stage.pixelSize
        return Self.shapes[shape].ratio ?? pixels.width / max(pixels.height, 1)
    }

    // MARK: Painting

    /// A finger down on the picture: the last step's takes put away.
    private func begun() {
        bar.endEditing(true)
        collapseResult()
    }

    /// A stroke lifted: Clean Up works on it at once; a tool asking for words waits for them.
    private func stroked() {
        if case .cleanUp = tool.kind { work() } else { updateControls() }
    }

    private func clearStrokes() {
        stage.clear(fading: true)
        updateControls()
    }

    private func pickReference() {
        guard let pick = tool.pickReference, let controller else { return }
        bar.endEditing(true)
        Task { [weak self] in
            guard let reference = await pick(controller), let self else { return }
            self.picked.append(reference)
            self.references.show(self.picked.map(\.picture))
            self.arrange()
        }
    }

    /// What presents over the editor: the editor (its view's controller), or what it's presenting.
    private var controller: UIViewController? {
        var top = h.view.next as? UIViewController
        while let next = top?.presentedViewController { top = next }
        return top
    }

    // MARK: Text

    private func clearFound() {
        found.forEach { $0.view.removeFromSuperview() }
        found = []
        foundFor = nil
    }

    /// The text on the picture shown, found once for it: a box over each piece.
    private func findText() {
        guard case .text(let find) = tool.kind, let picture = stagePicture, foundFor !== picture, !finding else { return }
        clearFound()
        foundFor = picture
        finding = true
        // Just after a step, what it did stays said.
        let quiet = result != nil
        if !quiet { say("Finding text…", for: nil) }
        Task { [weak self] in
            let texts = (try? await find(picture)) ?? []
            guard let self else { return }
            self.finding = false
            guard self.foundFor === picture, case .text = self.tool.kind else { return }
            self.found = texts.map { text in
                let view = UIView()
                view.isUserInteractionEnabled = false
                self.stage.marks.addSubview(view)
                return Found(box: text.box, text: text.text, to: nil, view: view)
            }
            self.drawFound()
            if !quiet || texts.isEmpty { self.say(texts.isEmpty ? "No text was found in this photo." : self.tool.hint) }
            self.updateControls()
        }
    }

    /// Each piece's box on the picture: outlined; filled with its new words once it has them.
    private func drawFound() {
        let size = stage.marks.bounds.size
        let accent = h.style.accent
        for piece in found {
            let view = piece.view
            view.frame = CGRect(x: piece.box.minX * size.width, y: piece.box.minY * size.height,
                                width: piece.box.width * size.width, height: piece.box.height * size.height).insetBy(dx: -3, dy: -3)
            view.layer.cornerRadius = 4
            view.layer.borderWidth = piece.to == nil ? 1.5 : 2
            view.layer.borderColor = (piece.to == nil ? UIColor.white : accent).cgColor
            view.backgroundColor = piece.to == nil ? UIColor.black.withAlphaComponent(0.12) : accent
            view.layer.shadowColor = UIColor.black.cgColor
            view.layer.shadowOpacity = 0.3
            view.layer.shadowRadius = 2
            view.layer.shadowOffset = .zero
            view.subviews.forEach { $0.removeFromSuperview() }
            if let to = piece.to {
                let label = UILabel(frame: view.bounds.insetBy(dx: 3, dy: 1))
                label.text = to.isEmpty ? "—" : to
                label.textColor = .black
                label.font = .systemFont(ofSize: max(8, view.bounds.height * 0.62), weight: .semibold)
                label.adjustsFontSizeToFitWidth = true
                label.minimumScaleFactor = 0.3
                label.textAlignment = .center
                view.addSubview(label)
            }
        }
    }

    /// A tap on the picture: the piece of text under it, to say something else.
    private func tapped(_ pixel: CGPoint) {
        collapseResult()
        let size = stage.pixelSize
        let at = CGPoint(x: pixel.x / max(size.width, 1), y: pixel.y / max(size.height, 1))
        let slack = 8 / max(stage.marks.bounds.width, 1)
        guard let i = found.firstIndex(where: { $0.box.insetBy(dx: -slack, dy: -slack).contains(at) }) else { return }
        let piece = found[i]
        let alert = UIAlertController(title: "Change Text", message: "“\(piece.text)”", preferredStyle: .alert)
        alert.addTextField { field in
            field.text = piece.to ?? piece.text
            field.clearButtonMode = .whileEditing
            field.accessibilityIdentifier = "newText"
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        if piece.to != nil {
            alert.addAction(UIAlertAction(title: "Keep Original", style: .default) { [weak self] _ in self?.setText(i, nil) })
        }
        alert.addAction(UIAlertAction(title: "Done", style: .default) { [weak self, weak alert] _ in
            let text = alert?.textFields?.first?.text ?? ""
            self?.setText(i, text == piece.text ? nil : text)
        })
        controller?.present(alert, animated: true)
    }

    private func setText(_ i: Int, _ to: String?) {
        guard found.indices.contains(i) else { return }
        found[i].to = to
        drawFound()
        updateControls()
    }

    // MARK: Moving the picture

    /// One finger: Reframe's camera turned and tilted; Light's light placed.
    private func oneFinger(_ at: CGPoint, _ moved: CGPoint, _ state: UIGestureRecognizer.State) {
        collapseResult()
        let frame = stage.pictureFrame(in: pad)
        switch tool.kind {
        case .reframe:
            nudge(HangarReframe.horizontal, by: Double(moved.x / max(frame.width, 1)) * 1.6)
            nudge(HangarReframe.vertical, by: Double(-moved.y / max(frame.height, 1)) * 1.6)
        case .light:
            values[HangarRelight.x.id] = Double(min(max((at.x - frame.minX) / max(frame.width, 1), 0), 1))
            values[HangarRelight.y.id] = Double(min(max((at.y - frame.minY) / max(frame.height, 1), 0), 1))
            placeDot()
        default: return
        }
        changedValues()
    }

    /// Two: Reframe's camera moved, nearer and rolled.
    private func twoFingers(_ moved: CGPoint, _ scale: CGFloat, _ turned: CGFloat, _ state: UIGestureRecognizer.State) {
        guard case .reframe = tool.kind else { return }
        collapseResult()
        let frame = stage.pictureFrame(in: pad)
        nudge(HangarReframe.panX, by: Double(moved.x / max(frame.width, 1)))
        nudge(HangarReframe.panY, by: Double(moved.y / max(frame.height, 1)))
        nudge(HangarReframe.zoom, by: Double(log2(max(scale, 0.01))))
        nudge(HangarReframe.straighten, by: Double(-turned) / (Double.pi / 4))
        changedValues()
    }

    private func nudge(_ p: HangarParameter, by amount: Double) {
        guard amount != 0 else { return }
        values[p.id] = min(max((values[p.id] ?? p.start) + amount, p.range.lowerBound), p.range.upperBound)
    }

    private func changedValues() {
        let parameters = tool.parameters
        if parameters.indices.contains(parameter) { ruler.set(values[parameters[parameter].id] ?? parameters[parameter].start) }
        renderPreview()
        updateControls()
    }

    private func placeDot() {
        guard !dot.isHidden else { return }
        let frame = stage.pictureFrame(in: pad)
        let x = values[HangarRelight.x.id] ?? HangarRelight.x.start, y = values[HangarRelight.y.id] ?? HangarRelight.y.start
        dot.center = CGPoint(x: frame.minX + CGFloat(x) * frame.width, y: frame.minY + CGFloat(y) * frame.height)
    }

    /// The picture as Reframe or Light would make it, shown in its place as it's set: drawn small, one at a time,
    /// the latest asked for next.
    private func renderPreview() {
        guard let picture = stagePicture else { return }
        let kind = tool.kind
        let reframes: Bool
        switch kind {
        case .reframe: reframes = true
        case .light: reframes = false
        default: return
        }
        if previewBusy { previewAgain = true; return }
        let source = previewSource ?? {
            let image = CIImage(cgImage: picture)
            let fit = min(1, 900 / max(image.extent.width, image.extent.height))
            let small = fit < 1 ? image.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: fit, kCIInputAspectRatioKey: 1]) : image
            return small.insertingIntermediate(cache: true)
        }()
        previewSource = source
        previewBusy = true
        let values = values
        let tool = tool.id
        Task { [weak self] in
            let made = await Task.detached(priority: .userInitiated) { () -> CGImage? in
                let out = reframes ? HangarReframe.apply(source, values: values) : HangarRelight.apply(source, values: values)
                return HangarRenderer.context.createCGImage(out, from: out.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.displayP3))
            }.value
            guard let self else { return }
            self.previewBusy = false
            if self.tool.id == tool, !self.working, let made { self.stage.preview(made) }
            if self.previewAgain {
                self.previewAgain = false
                self.renderPreview()
            }
        }
    }

    // MARK: Frames

    private func framed(_ rect: CGRect) {
        collapseResult()
        switch tool.kind {
        case .extend: extendFrame = rect
        case .closeUp: closeBox = rect
        default: break
        }
        updateControls()
    }

    // MARK: Working

    /// What the tool's been asked, back on the picture under the edit's geometry, made by the tool, laid back as
    /// one step.
    private func work() {
        guard let base = h.base?.image.extent.size, !working, canWork else { return }
        let geometry = h.edit.appliedGeometry
        let shown = stage.pixelSize
        let tool = tool
        // A point on the picture shown, 0 to 1 of the picture under the geometry; a box's corners there, round.
        func back(_ p: CGPoint) -> CGPoint {
            let q = geometry.picturePoint(p, size: base)
            return CGPoint(x: q.x / base.width, y: q.y / base.height)
        }
        func back(_ box: CGRect) -> CGRect {
            let corners = [CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY), CGPoint(x: box.maxX, y: box.maxY), CGPoint(x: box.minX, y: box.maxY)]
                .map { back(CGPoint(x: $0.x * shown.width, y: $0.y * shown.height)) }
            let xs = corners.map(\.x), ys = corners.map(\.y)
            return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
        }
        let words = tool.words != nil && !bar.words.isEmpty ? bar.words : nil
        let shownWidth = stage.shownWidth
        var asked = ToolAsked(tool: tool.id, words: words)
        var region: CGRect?
        var shaped: HangarGeometry?
        let make: @Sendable (CGImage) async throws -> HangarMade
        switch tool.kind {
        case .cleanUp, .edit:
            let shorter = min(base.width, base.height)
            let strokes = stage.lines.map { line in HangarStroke(points: line.points.map(back), width: line.width / shorter) }
            let references = picked
            asked.strokes = strokes
            asked.references = references.map(\.id)
            region = strokes.isEmpty ? nil : strokes.reduce(CGRect.null) { $0.union($1.bounds(aspect: base.width / base.height)) }.intersection(HangarStep.whole)
            make = { picture in
                let request = try HangarToolRequest.painted(picture, strokes: strokes, words: words, references: references,
                                                            marking: tool.marking, shownWidth: shownWidth)
                let takes = try await tool.make(request)
                guard request.mask != nil else {
                    return HangarMade(takes: try HangarRetouch.shaped(takes, like: CGSize(width: picture.width, height: picture.height)))
                }
                let made = try HangarRetouch.made(takes, for: request, matchingTones: tool.matchesTones)
                return HangarMade(takes: made.takes, mask: made.mask, wholes: made.wholes)
            }
        case .text:
            let changes = found.compactMap { piece in piece.to.map { HangarTextChange(box: back(piece.box), from: piece.text, to: $0) } }
            asked.texts = changes
            region = changes.reduce(CGRect.null) { $0.union($1.box) }
            make = { picture in
                let request = try HangarToolRequest.text(picture, changes: changes)
                let made = try HangarRetouch.made(try await tool.make(request), for: request, matchingTones: tool.matchesTones)
                return HangarMade(takes: made.takes, mask: made.mask, wholes: made.wholes)
            }
        case .extend where geometry.crop == nil && geometry.straighten == 0 && geometry.vertical == 0 && geometry.horizontal == 0:
            // The frame round the picture shown, round the picture (only turned or flipped: a rect still).
            let frame = back(extendFrame).union(HangarStep.whole)
            asked.frame = frame
            make = { picture in
                let request = try HangarToolRequest.extend(picture, to: frame, words: words)
                let made = try HangarRetouch.extended(try await tool.make(request), for: request, matchingTones: tool.matchesTones)
                return HangarMade(takes: made.takes, frame: frame, mask: made.mask, wholes: made.wholes)
            }
        case .extend:
            // Cropped, straightened or tilted: what's extended is the picture as it's shown (its turns and flip
            // undone), and what's made is the picture from then on, the crop and the rest of it in it.
            let turned = HangarGeometry(turns: geometry.turns, flipped: geometry.flipped)
            let f = extendFrame
            let corners = [CGPoint(x: f.minX, y: f.minY), CGPoint(x: f.maxX, y: f.maxY)]
                .map { turned.picturePoint($0, size: CGSize(width: 1, height: 1)) }
            let frame = CGRect(x: min(corners[0].x, corners[1].x), y: min(corners[0].y, corners[1].y),
                               width: abs(corners[1].x - corners[0].x), height: abs(corners[1].y - corners[0].y)).union(HangarStep.whole)
            asked.frame = frame
            shaped = geometry
            make = { picture in
                let request = try HangarToolRequest.extend(picture, to: frame, words: words)
                let made = try HangarRetouch.extendedWhole(try await tool.make(request), for: request, matchingTones: tool.matchesTones)
                return HangarMade(takes: made.takes, wholes: made.wholes, replaces: true)
            }
        case .reframe, .light:
            let values = values
            asked.values = values
            make = { picture in
                let takes = try await tool.make(.values(picture, values, words: words))
                return HangarMade(takes: try HangarRetouch.shaped(takes, like: CGSize(width: picture.width, height: picture.height)))
            }
        case .closeUp:
            let part = back(closeBox).intersection(HangarStep.whole)
            asked.region = part
            region = part
            make = { picture in
                let request = try HangarToolRequest.part(picture, region: part, words: words)
                let size = request.part.map { CGSize(width: $0.width, height: $0.height) } ?? CGSize(width: 1, height: 1)
                return HangarMade(takes: try HangarRetouch.shaped(try await tool.make(request), like: size), replaces: true)
            }
        }
        var job = HangarJob(tool: tool.id, name: tool.working, region: region.flatMap { $0.isNull ? nil : $0 }, longestSide: tool.longestSide,
                            parameters: try? HangarValue(asked), shaped: shaped, make: make)
        job.shownByMode = true
        lastJob = job
        // Shown working where it works, on the picture as it's shown.
        let area: HangarArea = switch tool.kind {
        case .cleanUp, .edit: stage.lines.isEmpty ? .whole : .painted
        case .text: .boxes(found.compactMap { $0.to == nil ? nil : $0.box })
        case .extend: .around(extendFrame)
        case .reframe, .light: .whole
        case .closeUp: .boxes([closeBox])
        }
        lastArea = area == .painted ? .boxes([paintedBounds]) : area
        run(job, over: area)
    }

    /// Where it's painted, in the shown picture's units.
    private var paintedBounds: CGRect {
        let pixels = stage.pixelSize
        return stage.lines.reduce(CGRect.null) { box, line in
            line.points.reduce(box) { $0.union(CGRect(x: $1.x - line.width / 2, y: $1.y - line.width / 2, width: line.width, height: line.width)) }
        }.applying(CGAffineTransform(scaleX: 1 / max(pixels.width, 1), y: 1 / max(pixels.height, 1))).intersection(HangarStep.whole)
    }

    /// The last step's tool asked again the same way: another take of it.
    private func again() {
        guard var job = lastJob, let step = h.edit.steps.last, step.takes.first == result, step.takes.count < Self.mostTakes else { return }
        job.addsTakes = true
        run(job, over: lastArea)
    }

    private func run(_ job: HangarJob, over area: HangarArea) {
        let ran = tool.id
        working = true
        stage.glow.work(area)
        stage.paints = false
        collapseResult(keepingResult: true)
        bar.endEditing(true)
        say(tool.working, for: nil)
        arrange()
        h.run(job) { [weak self] done in
            guard let self else { return }
            self.working = false
            self.stage.glow.work(nil)
            self.stage.paints = self.tool.paints
            guard self.tool.id == ran else { return self.arrange() }
            if done {
                // What was asked goes (the takes show what it made); the result's takes over the picture.
                self.stage.clear(fading: true)
                if !job.addsTakes {
                    self.bar.clearWords()
                    self.picked = []
                    self.references.show([])
                    self.clearFound()
                    self.extendFrame = HangarStep.whole
                    self.closeBox = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
                    self.values = [:]
                    self.setRuler()
                    self.stage.preview(nil)
                }
                self.result = self.h.edit.steps.last?.takes.first
                self.say(self.tool.done ?? self.tool.hint, for: 4)
                if let done = self.tool.done { UIAccessibility.post(notification: .announcement, argument: done) }
            } else {
                // Cancelled or failed: what was asked stays, to be sent again.
                self.say(self.tool.hint)
            }
            self.arrange()
        }
    }

    // MARK: The step's takes

    /// The takes of the step just made, over the picture while it's the edit's last and nothing else has begun.
    private var takesStep: HangarStep? {
        guard isChosen, !working, let result, let step = h.edit.steps.last, step.takes.first == result else { return nil }
        return step
    }

    private func updatePill() {
        guard let step = takesStep else {
            if !pill.isHidden {
                pill.isHidden = true
                pill.alpha = 0
            }
            if showingKept { showKept(false) }
            return
        }
        pill.show(take: step.take, of: step.takes.count, masked: step.wholes.isEmpty && (step.mask == nil || step.replaces) ? nil : step.masked,
                  showingKept: showingKept, canAgain: step.takes.count < Self.mostTakes && lastJob != nil)
        if pill.isHidden {
            pill.isHidden = false
            UIView.animate(withDuration: 0.2) { self.pill.alpha = 1 }
        }
    }

    /// The takes put away: something else has begun.
    private func collapseResult(keepingResult: Bool = false) {
        if !keepingResult { result = nil }
        if showingKept { showKept(false) }
        pill.isHidden = true
        pill.alpha = 0
        placeHint()
    }

    private func useTake(_ i: Int) {
        guard let last = h.edit.steps.indices.last, h.edit.steps[last].takes.indices.contains(i) else { return }
        h.edit.steps[last].take = i
        h.commit()
    }

    private func setMasked(_ masked: Bool) {
        guard let last = h.edit.steps.indices.last, h.edit.steps[last].masked != masked else { return }
        if !masked { showKept(false) }
        h.edit.steps[last].masked = masked
        h.commit()
    }

    /// Where the step just made is kept, outlined on the picture in the accent.
    private func showKept(_ shown: Bool) {
        showingKept = shown
        guard shown, let step = h.edit.steps.last, let maskID = step.mask, let assets = h.renderer.assets,
              let base = h.base?.image.extent.size else {
            UIView.animate(withDuration: 0.2) { self.kept.alpha = 0 }
            if !pill.isHidden { updatePill() }
            return
        }
        let (edit, renderer, pixels) = (h.edit, h.renderer, stage.pixelSize)
        var r: CGFloat = 1, g: CGFloat = 1, b: CGFloat = 0, a: CGFloat = 1
        h.style.accent.resolvedColor(with: h.view.traitCollection).getRed(&r, green: &g, blue: &b, alpha: &a)
        let colour = CIColor(red: r, green: g, blue: b)
        Task { [weak self] in
            let made = await Task.detached(priority: .userInitiated) { () -> CGImage? in
                guard let mask = assets.picture(maskID) else { return nil }
                // The mask where the step lays it on the picture it makes (Core Image's y up), black round it; shaped
                // as the picture's shown.
                let reach = step.reach
                let place = CGRect(x: (step.frame.minX - reach.minX) / reach.width * base.width,
                                   y: (reach.maxY - step.frame.maxY) / reach.height * base.height,
                                   width: step.frame.width / reach.width * base.width, height: step.frame.height / reach.height * base.height)
                let m = CIImage(cgImage: mask)
                let all = CGRect(origin: .zero, size: base)
                let laid = m.transformed(by: CGAffineTransform(scaleX: place.width / m.extent.width, y: place.height / m.extent.height)
                    .concatenating(CGAffineTransform(translationX: place.minX, y: place.minY)))
                    .composited(over: CIImage(color: .black).cropped(to: all))
                    .cropped(to: all)
                let shaped = renderer.shape(edit, laid)
                let e = shaped.extent
                let size = CGRect(origin: .zero, size: pixels)
                let fitted = shaped.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY)
                    .concatenating(CGAffineTransform(scaleX: pixels.width / e.width, y: pixels.height / e.height)))
                let inside = fitted.applyingFilter("CIColorThreshold", parameters: ["inputThreshold": 0.5]).cropped(to: size)
                let edge = inside.applyingFilter("CIMorphologyGradient", parameters: [kCIInputRadiusKey: max(2, pixels.width / 300)])
                // The edge solid, inside faint: how much of the accent, in red.
                let amount = edge.applyingFilter("CIColorMatrix", parameters: ["inputRVector": CIVector(x: 0.85, y: 0, z: 0, w: 0)])
                    .applyingFilter("CIAdditionCompositing", parameters: [
                        kCIInputBackgroundImageKey: inside.applyingFilter("CIColorMatrix", parameters: ["inputRVector": CIVector(x: 0.18, y: 0, z: 0, w: 0)]),
                    ])
                let out = CIImage(color: colour).cropped(to: size)
                    .applyingFilter("CIBlendWithRedMask", parameters: [kCIInputBackgroundImageKey: CIImage.empty(), kCIInputMaskImageKey: amount])
                    .cropped(to: size)
                return HangarRenderer.context.createCGImage(out, from: size, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
            }.value
            guard let self, self.showingKept, let made else { return }
            self.kept.image = UIImage(cgImage: made)
            self.kept.frame = self.stage.marks.bounds
            UIView.animate(withDuration: 0.2) { self.kept.alpha = 1 }
            self.updatePill()
        }
    }

    // MARK: Saying

    /// Says `words` in the platter, for a while then back to the tool's hint (nil: until said otherwise).
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
                self.say(self.tool.hint)
            }
        }
    }
}

public extension HangarMode {
    static let tools = HangarMode("tools")
}
