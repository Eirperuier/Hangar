import HangarCore
import UIKit

/// Photos' Crop (iOS 27): Flip and Rotate where Undo and Redo were, Aspect Ratio beside More, RESET once anything's
/// changed; Straighten, Vertical and Horizontal on a strip and ruler of their own (their numbers in degrees); the
/// picture whole on a stage of its own (`CropStage`), its box fitted to the canvas Photos keeps for it.
@MainActor
public final class HangarCropModule: HangarModule {
    public let item = HangarModeItem(id: HangarMode.crop.id, name: "Crop", symbol: "crop.rotate", spoken: "Crop and Rotate")

    private weak var host: (any HangarHost)?
    private var h: any HangarHost { host! }
    private var edit: HangarEdit {
        get { h.edit }
        set { h.edit = newValue }
    }
    private var style: HangarStyle { h.style }

    private var stage: CropStage!
    private let geometryTools = Strip()
    private var geometryButtons: [ToolButton] = []
    private var geometryRuler: Ruler!
    private var aspectPicker: AspectPicker!
    /// Flip and Rotate, where undo and redo are in the other modes.
    private var geometryBar: UIVisualEffectView!
    private var flipButton: UIButton!
    private var rotateButton: UIButton!
    /// Aspect Ratio and More on one capsule.
    private var cropBar: UIVisualEffectView!
    private var aspectButton: UIButton!
    private var cropMoreButton: UIButton!
    private let resetButton = UIButton(type: .custom)
    private let badge = BadgeLabel()
    private let lockedToast = BadgeLabel()
    private var geometryTool = HangarGeometry.straightenID
    private var aspectOpen = false
    /// The tone-edited picture the stage shows, and the edit it was made for.
    private var stagePictureFor: HangarEdit?
    private var badgeTimer: Timer?
    private var toastTimer: Timer?
    /// Where the stage shows the picture (the canvas Photos keeps for Crop).
    private var cropRegion = CGRect.zero
    private var sideways = false
    private var isChosen = false

    public init() {}

    public var ownsTopBar: Bool { true }
    /// Photos' iPad shows no mode's name in Crop's top bar (RESET is there).
    public var showsTitle: Bool { false }
    public var pictureFrame: CGRect? { isChosen && !stage.isHidden && stage.alpha > 0 ? stage.box : nil }
    public var chrome: [UIView] { cropChrome }

    /// Straighten, Vertical and Horizontal: their ids, names, symbols and degrees at the ends of their rulers.
    static let geometryTools: [(id: String, name: String, symbol: String, degrees: Double)] = [
        (HangarGeometry.straightenID, "Straighten", "circle.and.line.horizontal.fill", 45),
        (HangarGeometry.verticalID, "Vertical", "trapezoid.and.line.vertical.fill", 30),
        (HangarGeometry.horizontalID, "Horizontal", "trapezoid.and.line.horizontal.fill", 30),
    ]

    /// Crop's bars and controls (its badge and notice come and go on their own).
    private var cropChrome: [UIView] {
        [geometryBar, cropBar, resetButton, geometryTools, geometryRuler, aspectPicker]
    }

    // MARK: Building

    public func load(in host: any HangarHost) {
        self.host = host
        let style = host.style
        stage = CropStage(style: style)
        geometryRuler = Ruler(style: style)
        aspectPicker = AspectPicker(style: style)
        geometryBar = Chrome.capsule(style)
        flipButton = Chrome.plainButton("arrow.left.and.right.righttriangle.left.righttriangle.right", label: "Flip", style: style)
        rotateButton = Chrome.plainButton("rotate.left", label: "Rotate", style: style)
        cropBar = Chrome.capsule(style)
        aspectButton = Chrome.plainButton("aspectratio", label: "Aspect Ratio", style: style)
        cropMoreButton = Chrome.plainButton("ellipsis", label: "More", style: style)
        geometryButtons = Self.geometryTools.map { tool in
            let adjustment = HangarAdjustment(id: tool.id, name: tool.name, symbol: tool.symbol, range: -1...1) { image, _, _ in image }
            let button = ToolButton(adjustment, style: style)
            button.numberScale = tool.degrees
            return button
        }
        geometryTools.setItems(geometryButtons, chosen: 0)
        geometryTools.feel = .tools
        geometryTools.pitch = ToolButton.size + 20
        geometryTools.itemSize = ToolButton.size
        geometryTools.fadeClear = 14
        geometryTools.fadeWhole = 40
        geometryTools.onChoose = { [weak self] i in self?.passGeometryTool(i) }
        geometryTools.onMove = { [weak self] in self?.geometryRuler.setState(enabled: false, dimmed: true, animated: true) }
        geometryTools.onRest = { [weak self] i in self?.chooseGeometryTool(i) }
        geometryTools.onTapChosen = { [weak self] i in self?.toggleGeometryTool(i) }
        geometryTools.accessibilityLabel = "Enhancements, Geometry"
        geometryTools.spokenValue = { [weak self] i in self?.spokenGeometryTool(i) ?? "" }
        geometryRuler.range = -1...1
        geometryRuler.magnet = 0
        geometryRuler.marked = 0
        geometryRuler.onTouch = { [weak self] in self?.geometryRulerTouched() }
        geometryRuler.onChange = { [weak self] value in self?.geometryRulerMoved(value) }
        geometryRuler.onEnd = { [weak self] _ in self?.stage.endTool() }

        stage.onChange = { [weak self] g in self?.stageChanged(g) }
        stage.onEnd = { [weak self] g in
            guard let self else { return }
            self.stageChanged(g)
            Chrome.fade(self.resetButton, self.cropChanged, animated: true)
            self.h.commit()
        }
        stage.onTouch = { [weak self] in self?.hideBadge() }
        stage.onGesture = { [weak self] moving in self?.hideCropBars(moving) }
        stage.isHidden = true

        flipButton.addAction(UIAction { [weak self] _ in self?.stage.flip() }, for: .touchUpInside)
        rotateButton.addAction(UIAction { [weak self] _ in self?.stage.rotate() }, for: .touchUpInside)
        geometryBar.contentView.addSubview(flipButton)
        geometryBar.contentView.addSubview(rotateButton)
        aspectButton.addAction(UIAction { [weak self] _ in self?.toggleAspect() }, for: .touchUpInside)
        cropMoreButton.showsMenuAsPrimaryAction = true
        cropMoreButton.menu = UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] completion in
            completion(self?.host?.moreMenu() ?? [])
        }])
        cropBar.contentView.addSubview(aspectButton)
        cropBar.contentView.addSubview(cropMoreButton)

        // Photos' RESET: 15-point capitals on the accent, 5 in each way, a little rounded.
        resetButton.setTitle("RESET", for: .normal)
        resetButton.titleLabel?.font = .systemFont(ofSize: 15)
        resetButton.setTitleColor(UIColor.black.withAlphaComponent(0.85), for: .normal)
        resetButton.backgroundColor = style.accent
        resetButton.layer.cornerRadius = 5
        resetButton.layer.cornerCurve = .continuous
        resetButton.accessibilityLabel = "Reset"
        resetButton.accessibilityIdentifier = "resetButton"
        resetButton.addAction(UIAction { [weak self] _ in self?.resetCrop() }, for: .touchUpInside)

        badge.font = style.nameFont
        badge.textColor = style.secondary
        badge.fill = style.foreground.withAlphaComponent(0.035)
        badge.insets = UIEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        badge.layer.cornerRadius = 8
        lockedToast.font = .systemFont(ofSize: 12)
        lockedToast.textColor = style.foreground
        lockedToast.fill = style.background
        lockedToast.insets = UIEdgeInsets(top: 0, left: 6, bottom: 0, right: 6)
        lockedToast.layer.cornerRadius = 3
        lockedToast.text = "ASPECT RATIO LOCKED"

        aspectPicker.onChoose = { [weak self] choice in self?.chooseAspect(choice) }
        aspectPicker.onUpright = { [weak self] _ in self.map { $0.chooseAspect($0.aspectPicker.chosen) } }

        host.add(stage, at: .picture)
        for chrome in cropChrome + [badge, lockedToast] { host.add(chrome, at: .controls) }
        for chrome in cropChrome + [badge, lockedToast] { chrome.isHidden = true }
    }

    // MARK: Layout

    public func layout(_ layout: HangarLayout) {
        let bounds = layout.bounds, safe = layout.safeArea
        sideways = layout.sideways
        stage.frame = bounds
        geometryBar.frame = CGRect(x: layout.history.minX, y: layout.history.minY, width: 96, height: 44)
        flipButton.frame = CGRect(x: 0, y: 0, width: 44, height: 44)
        rotateButton.frame = CGRect(x: 52, y: 0, width: 44, height: 44)
        cropBar.frame = CGRect(x: layout.more.maxX - 96, y: layout.more.minY, width: 96, height: 44)
        aspectButton.frame = CGRect(x: 0, y: 0, width: 44, height: 44)
        cropMoreButton.frame = CGRect(x: 52, y: 0, width: 44, height: 44)
        Chrome.round(geometryBar)
        Chrome.round(cropBar)
        // Photos' crop canvas starts 20 under the top bar.
        let top = layout.cancel.maxY + 20
        if sideways {
            // Photos' iPad: the tools and ruler 9 further right than Adjust's (108 and 66 in), the canvas 141 in from
            // each side (its side bars' width) and 125 off the bottom; the picker one row along the bottom, the tools
            // left where they are.
            let right = bounds.maxX - safe.right
            geometryTools.axis = .along
            geometryTools.reach = 361
            geometryTools.frame = CGRect(x: right - 108, y: layout.tools.minY, width: ToolButton.size, height: layout.tools.height)
            geometryRuler.axis = .along
            geometryRuler.frame = CGRect(x: right - Ruler.thickness, y: layout.ruler.minY, width: Ruler.thickness, height: layout.ruler.height)
            cropRegion = CGRect(x: safe.left + 141, y: top, width: bounds.width - safe.left - safe.right - 282, height: bounds.maxY - 125 - top)
            aspectPicker.inline = true
            aspectPicker.frame = CGRect(x: safe.left, y: bounds.maxY - 49 - 20, width: bounds.width - safe.left - safe.right, height: 40)
            aspectPicker.buttonsMiddle = 20
            aspectPicker.rowMiddle = 20
            // The name as Adjust's is, its right 36 before the tools.
            badge.sizeToFit()
            badge.center = CGPoint(x: geometryTools.frame.minX - 36 - badge.bounds.width / 2, y: bounds.midY)
        } else {
            aspectPicker.inline = false
            let base = layout.modeBar.minY
            geometryTools.axis = .across
            geometryTools.reach = nil
            geometryTools.frame = layout.tools
            geometryRuler.axis = .across
            geometryRuler.frame = layout.ruler
            cropRegion = CGRect(x: safe.left + 10, y: top, width: bounds.width - safe.left - safe.right - 20, height: base - 141 - top)
            // Photos' picker: its buttons' middles 90.5 over the mode bar, its row's 32.
            aspectPicker.frame = CGRect(x: safe.left, y: base - 141, width: bounds.width - safe.left - safe.right, height: 141)
            aspectPicker.buttonsMiddle = 141 - 90.5
            aspectPicker.rowMiddle = 141 - 32
            // The tool's name on its capsule, 160 over the mode bar.
            badge.sizeToFit()
            badge.center = CGPoint(x: bounds.midX, y: base - 160.3)
        }
        badge.sizeToFit()
        badge.frame = CGRect(x: (badge.center.x - badge.bounds.width / 2).rounded(), y: badge.center.y - 13, width: badge.bounds.width, height: 26)
        resetButton.sizeToFit()
        let resetWidth = ceil(("RESET" as NSString).size(withAttributes: [.font: UIFont.systemFont(ofSize: 15)]).width) + 10
        // Under the top bar on a phone; on an iPad in it, in the middle (where the title is in the other modes).
        resetButton.frame = sideways
            ? CGRect(x: (bounds.midX - resetWidth / 2).rounded(), y: layout.cancel.midY - 13, width: resetWidth, height: 26)
            : CGRect(x: (cropRegion.midX - resetWidth / 2).rounded(), y: cropRegion.minY + 2, width: resetWidth, height: 26)
        lockedToast.sizeToFit()
        lockedToast.frame = CGRect(x: (resetButton.frame.midX - lockedToast.bounds.width / 2).rounded(), y: resetButton.frame.maxY + 1,
                                   width: lockedToast.bounds.width, height: 15)
        stage.region = cropRegion
    }

    // MARK: Coming and going

    /// Crop's chrome shown or hidden (in a cross-dissolve).
    public func show(_ cropping: Bool) {
        isChosen = cropping
        if cropping { h.showName(nil) }
        geometryBar.isHidden = !cropping
        cropBar.isHidden = !cropping
        geometryTools.isHidden = !cropping || (aspectOpen && !sideways)
        geometryRuler.isHidden = !cropping || (aspectOpen && !sideways)
        aspectPicker.isHidden = !cropping || !aspectOpen
        badge.isHidden = !cropping
        lockedToast.isHidden = !cropping
        Chrome.fade(resetButton, cropping && cropChanged, animated: false)
    }

    public func stop() {
        geometryRuler.stop()
    }

    public func menu() -> [UIMenuElement] {
        [lockAction()]
    }

    public func closing() {
        stage.alpha = 0
    }

    /// Into Crop: the picture whole on the stage, flying from where the canvas shows the crop to the box.
    public func entered() {
        guard let preview = h.base?.image else { return }
        h.layoutNow()
        aspectOpen = false
        setAspectButton(open: false)
        show(true)
        let index = Self.geometryTools.firstIndex { $0.id == geometryTool } ?? 0
        geometryTools.choose(index, animated: false)
        chooseGeometryTool(index)
        showBadge(Self.geometryTools[index].name)
        stage.region = cropRegion
        stage.load(nil, size: preview.extent.size, geometry: edit.geometry, off: edit.switchedOff)
        stage.isHidden = false
        stage.alpha = 0
        stage.showOverlay(false, animated: false)
        makeStagePicture { [weak self] picture in
            guard let self, self.isChosen else { return }
            self.stage.show(picture)
            self.stage.alpha = 1
            self.h.showCanvas(false)
            if self.h.hasEntered {
                self.stage.fly(from: self.h.canvasFrame)
                self.stage.showOverlay(true, animated: true)
            } else {
                self.stage.showOverlay(true, animated: false)
            }
        }
        sync()
    }

    /// Out of Crop: the box flies to where the canvas will show the crop, then the canvas takes over.
    public func left() {
        guard !stage.isHidden else { return }
        geometryRuler.stop()
        stage.cancelPending()
        edit.geometry = stage.current
        hideBadge()
        lockedToast.alpha = 0
        h.render()
        h.layoutNow()
        stage.showOverlay(false, animated: true)
        stage.fly(to: h.canvasFrame) { [weak self] in
            guard let self, !self.isChosen else { return }
            self.h.showCanvas(true)
            self.stage.isHidden = true
        }
    }

    /// The picture with its adjustments and filter, not its geometry: what the stage shows, made off the main
    /// thread (once for the edit's tones).
    private func makeStagePicture(_ done: @escaping @MainActor (CGImage) -> Void) {
        guard let (preview, previewContext) = h.base else { return }
        var tones = edit
        tones.geometry = .identity
        tones.switchedOff.subtract(HangarGeometry.toolIDs)
        if stagePictureFor == tones, let image = stage.image { return done(image) }
        let renderer = h.renderer
        Task.detached(priority: .userInitiated) {
            let out = renderer.apply(tones, to: preview, context: previewContext)
            guard let picture = HangarRenderer.context.createCGImage(out, from: preview.extent, format: .RGBA8,
                                                                     colorSpace: CGColorSpace(name: CGColorSpace.displayP3)) else { return }
            await MainActor.run { [weak self] in
                self?.stagePictureFor = tones
                done(picture)
            }
        }
    }

    /// The stage shown afresh for the edit (pasted, reverted, a step made).
    private func reloadStage() {
        guard isChosen, let preview = h.base?.image else { return }
        stage.load(nil, size: preview.extent.size, geometry: edit.geometry, off: edit.switchedOff)
        makeStagePicture { [weak self] picture in self?.stage.show(picture) }
    }

    public func pictureChanged() {
        stagePictureFor = nil
        reloadStage()
    }

    // MARK: The tools

    /// A tool's value as its ruler shows it: Photos shows Straighten and Horizontal the other way once flipped,
    /// and a tool switched off at 0.
    private func shownGeometryValue(_ id: String) -> Double {
        guard !edit.switchedOff.contains(id) else { return 0 }
        return geometrySign(id) * edit.geometry.value(of: id)
    }

    private func geometrySign(_ id: String) -> Double {
        edit.geometry.flipped && id != HangarGeometry.verticalID ? -1 : 1
    }

    private func passGeometryTool(_ index: Int) {
        geometryTool = Self.geometryTools[index].id
        showBadge(Self.geometryTools[index].name)
    }

    private func chooseGeometryTool(_ index: Int) {
        let tool = Self.geometryTools[index]
        geometryTool = tool.id
        geometryRuler.set(shownGeometryValue(tool.id))
        geometryRuler.accessibilityLabel = "Intensity Slider for \(tool.name)"
        setGeometryRulerState(animated: true)
        showBadge(tool.name)
    }

    private func setGeometryRulerState(animated: Bool) {
        geometryRuler.setState(enabled: true, dimmed: edit.switchedOff.contains(geometryTool), animated: animated)
    }

    private func geometryButton(_ id: String) -> ToolButton? {
        geometryButtons.first { $0.id == id }
    }

    private func geometryRulerTouched() {
        stage.beginTool()
        geometryButton(geometryTool)?.show(value: shownGeometryValue(geometryTool), switchedOff: edit.switchedOff.contains(geometryTool), number: true)
        showBadge(Self.geometryTools.first { $0.id == geometryTool }?.name ?? "")
    }

    private func geometryRulerMoved(_ shown: Double) {
        let id = geometryTool
        // Moving a tool switched off switches it on.
        if edit.switchedOff.remove(id) != nil { setGeometryRulerState(animated: true) }
        stage.setTool(id, value: geometrySign(id) * shown, off: edit.switchedOff)
        geometryButton(id)?.show(value: shown, switchedOff: false, number: true)
    }

    /// The chosen tool tapped: switched off or on, the picture without it or with it again.
    private func toggleGeometryTool(_ index: Int) {
        geometryRuler.stop()
        let id = Self.geometryTools[index].id
        let on = edit.switchedOff.contains(id)
        if on { edit.switchedOff.remove(id) } else { edit.switchedOff.insert(id) }
        stage.setOff(edit.switchedOff)
        geometryRuler.set(shownGeometryValue(id), animated: true)
        geometryButton(id)?.show(value: geometrySign(id) * edit.geometry.value(of: id), switchedOff: !on, number: on)
        setGeometryRulerState(animated: true)
    }

    private func spokenGeometryTool(_ index: Int) -> String {
        let tool = Self.geometryTools[index]
        if edit.switchedOff.contains(tool.id) { return "\(tool.name), Off" }
        return "\(tool.name), \(Int((shownGeometryValue(tool.id) * 100).rounded()))%"
    }

    /// The stage changed the geometry: kept in the edit, the controls with it.
    /// The stage moved: the edit with it, RESET and Done left as they are until it's kept (Photos': as the box comes
    /// back).
    private func stageChanged(_ g: HangarGeometry) {
        edit.geometry = g
        if aspectOpen { aspectPicker.set(chosen: currentChoice(), upright: currentUpright()) }
    }

    /// Crop's controls as the edit is; the stage too, if the edit's changed under it (pasted, reverted).
    public func sync() {
        if isChosen, !stage.isHidden {
            let off = edit.switchedOff.intersection(HangarGeometry.toolIDs)
            if stage.current != edit.geometry || stage.off != off {
                reloadStage()
            } else {
                var tones = edit
                tones.geometry = .identity
                tones.switchedOff.subtract(HangarGeometry.toolIDs)
                if stagePictureFor != nil, stagePictureFor != tones { makeStagePicture { [weak self] picture in self?.stage.show(picture) } }
            }
        }
        for button in geometryButtons {
            button.show(value: geometrySign(button.id) * edit.geometry.value(of: button.id), switchedOff: edit.switchedOff.contains(button.id),
                        number: button.showsNumber)
        }
        geometryRuler.set(shownGeometryValue(geometryTool))
        setGeometryRulerState(animated: h.hasEntered)
        if isChosen {
            Chrome.fade(resetButton, cropChanged, animated: h.hasEntered)
            aspectButton.accessibilityValue = currentChoice().name
        }
    }

    /// Whether there's anything for RESET to undo: Photos' leaves the turns and the flip.
    private var cropChanged: Bool {
        let g = edit.geometry
        if g.straighten != 0 || g.vertical != 0 || g.horizontal != 0 || g.aspect != nil { return true }
        guard let crop = g.crop else { return false }
        return abs(crop.minX) > 0.001 || abs(crop.minY) > 0.001 || abs(crop.width - 1) > 0.001 || abs(crop.height - 1) > 0.001
    }

    private func resetCrop() {
        geometryRuler.stop()
        edit.switchedOff.subtract(HangarGeometry.toolIDs)
        stage.reset(off: edit.switchedOff)
        for button in geometryButtons { button.show(value: 0, switchedOff: false, number: false) }
        geometryRuler.set(0, animated: true)
        setGeometryRulerState(animated: true)
        if aspectOpen { aspectPicker.set(chosen: .freeform, upright: currentUpright()) }
        UIView.animate(withDuration: 0.2) { self.lock(false) }
    }

    /// Photos' bars go while a handle, the picture or a pinch moves, and come back as it's let go.
    private func hideCropBars(_ hidden: Bool) {
        let bars: [UIView] = [geometryBar, cropBar, resetButton, geometryTools, geometryRuler, aspectPicker]
        if hidden { hideBadge() }
        h.showBars(!hidden, duration: hidden ? 0.25 : 0.2, delay: 0)
        UIView.animate(withDuration: hidden ? 0.25 : 0.2, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
            for bar in bars { Chrome.show(bar, !hidden) }
            if hidden { self.lockedToast.alpha = 0 }
        }
    }

    // MARK: The badge

    /// The tool's name on its capsule, for a second and a half after it last changed (Photos').
    private func showBadge(_ name: String) {
        badge.text = name.uppercased()
        h.view.setNeedsLayout()
        badgeTimer?.invalidate()
        UIView.animate(withDuration: 0.2, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) { self.badge.alpha = 1 }
        badgeTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.hideBadge() }
        }
    }

    private func hideBadge() {
        badgeTimer?.invalidate()
        UIView.animate(withDuration: 0.25, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) { self.badge.alpha = 0 }
    }

    // MARK: Aspect Ratio

    private func setAspectButton(open: Bool) {
        var configuration = aspectButton.configuration
        configuration?.image = UIImage(systemName: open ? "aspectratio.fill" : "aspectratio",
                                       withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .medium))
        aspectButton.configuration = configuration
        aspectButton.accessibilityTraits = open ? [.button, .selected] : .button
    }

    /// The picker in place of the tools, or the tools back.
    private func toggleAspect() {
        geometryRuler.stop()
        aspectOpen.toggle()
        setAspectButton(open: aspectOpen)
        if aspectOpen {
            aspectPicker.set(chosen: currentChoice(), upright: currentUpright())
            aspectPicker.alpha = 0
            aspectPicker.isHidden = false
            aspectPicker.scrollToStart()
            hideBadge()
        } else {
            geometryTools.isHidden = false
            geometryRuler.isHidden = false
        }
        // On a phone the picker takes the tools' place; on an iPad it's along the bottom, the tools left.
        let replaces = !sideways
        UIView.animate(withDuration: 0.25, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
            self.aspectPicker.alpha = self.aspectOpen ? 1 : 0
            if replaces {
                self.geometryTools.alpha = self.aspectOpen ? 0 : 1
                self.geometryRuler.alpha = self.aspectOpen ? 0 : 1
            }
        } completion: { _ in
            self.aspectPicker.isHidden = !self.aspectOpen
            self.geometryTools.isHidden = replaces && self.aspectOpen
            self.geometryRuler.isHidden = replaces && self.aspectOpen
        }
    }

    /// The picture's shape as it's shown (turned with it).
    private var originalRatio: Double {
        guard let preview = h.base?.image else { return 1 }
        let r = Double(preview.extent.width / preview.extent.height)
        return edit.geometry.isSideways ? 1 / r : r
    }

    private var wallpaperRatio: Double {
        let size = h.view.window?.windowScene?.screen.bounds.size ?? h.view.bounds.size
        return Double(max(size.width, size.height) / min(size.width, size.height))
    }

    /// The shape held, as it's shown; nil for any.
    private var shownRatio: Double? {
        guard let aspect = edit.geometry.aspect else { return nil }
        return edit.geometry.isSideways ? aspect.turned.value : aspect.value
    }

    private func currentUpright() -> Bool {
        let crop = stage.displayCrop
        let r = shownRatio ?? Double(crop.width / max(crop.height, 1))
        // A square is neither: Photos leaves the picker as it was (Square chosen from 9:16 still offers 9:16).
        if abs(r - 1) < 0.002 { return aspectPicker.upright }
        return r < 1
    }

    private func currentChoice() -> AspectPicker.Choice {
        guard let r = shownRatio else { return .freeform }
        func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 0.002 * max(a, b) }
        let level = max(r, 1 / r)
        if near(r, 1) { return .square }
        if near(r, originalRatio) || near(r, 1 / originalRatio) { return .original }
        if near(level, wallpaperRatio) { return .wallpaper }
        for choice in AspectPicker.choices {
            if case .ratio(let a, let b) = choice, near(level, a / b) { return choice }
        }
        return .freeform
    }

    /// A shape chosen (or turned upright or level): the crop to it, locked.
    private func chooseAspect(_ choice: AspectPicker.Choice) {
        let upright = aspectPicker.upright
        let shown: Double?
        switch choice {
        case .freeform: shown = nil
        case .square: shown = 1
        case .original:
            // Upright or level as asked, the picture's own way if the picker hasn't been turned.
            shown = upright == (originalRatio < 1) ? originalRatio : 1 / originalRatio
        case .wallpaper: shown = upright ? 1 / wallpaperRatio : wallpaperRatio
        case .ratio(let a, let b): shown = upright ? b / a : a / b
        }
        let aspect = shown.map { r in
            let ratio = HangarRatio(r, 1)
            return edit.geometry.isSideways ? ratio.turned : ratio
        }
        stage.setAspect(aspect)
        aspectButton.accessibilityValue = choice.name
        UIView.animate(withDuration: 0.2) { self.lock(aspect != nil) }
        if aspect != nil { showLockedToast() }
    }

    private func lock(_ locked: Bool) {
        stage.showLock(locked)
    }

    private func showLockedToast() {
        toastTimer?.invalidate()
        lockedToast.isHidden = false
        lockedToast.alpha = 1
        toastTimer = Timer.scheduledTimer(withTimeInterval: 1.2, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                UIView.animate(withDuration: 0.3) { self.lockedToast.alpha = 0 }
            }
        }
    }

    /// More's Lock Aspect Ratio (Photos'): held to the crop's shape as it is, or let go.
    private func lockAction() -> UIAction {
        let locked = edit.geometry.aspect != nil
        return UIAction(title: locked ? "Unlock Aspect Ratio" : "Lock Aspect Ratio",
                        image: UIImage(systemName: locked ? "lock.open" : "lock")) { [weak self] _ in
            guard let self else { return }
            if locked {
                self.stage.setAspect(nil)
                self.lock(false)
            } else {
                let crop = self.stage.current.cropRect(for: self.h.base?.image.extent.size ?? .zero)
                self.stage.setAspect(HangarRatio(Double(crop.width), Double(crop.height)))
                self.lock(true)
                self.showLockedToast()
            }
        }
    }
}

/// A label on a capsule of its own (Crop's tool name, its lock's notice).
@MainActor
final class BadgeLabel: UILabel {
    var insets = UIEdgeInsets.zero
    var fill: UIColor = .clear { didSet { backgroundColor = fill } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        textAlignment = .center
        layer.cornerCurve = .continuous
        clipsToBounds = true
        alpha = 0
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var intrinsicContentSize: CGSize {
        let size = super.intrinsicContentSize
        return CGSize(width: size.width + insets.left + insets.right, height: size.height + insets.top + insets.bottom)
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let fit = super.sizeThatFits(size)
        return CGSize(width: fit.width + insets.left + insets.right, height: fit.height + insets.top + insets.bottom)
    }

    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.inset(by: insets))
    }
}
