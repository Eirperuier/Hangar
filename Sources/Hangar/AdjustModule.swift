import HangarCore
import UIKit

/// Photos' Adjust: the toolbox's adjustments on a strip (Auto first), the one in the middle on the ruler under it, its
/// value as an arc round it; tapping the chosen one switches it off and on.
@MainActor
public final class HangarAdjustModule: HangarModule {
    public let item = HangarModeItem(id: HangarMode.adjust.id, name: "Adjust", symbol: "dial.low", chosenSymbol: "dial.low.fill")

    private weak var host: (any HangarHost)?
    private var toolbox: HangarToolbox { host?.toolbox ?? .standard }
    let tools = Strip()
    private var buttons: [ToolButton] = []
    private(set) var ruler: Ruler!
    /// The tool in the middle of the strip, and the one the ruler is set to: the same but while the strip moves,
    /// when the ruler is off (as Photos' is), so a ruler still sliding never changes the tool coming to the middle.
    private var tool = ""
    private var rulerTool = ""
    private var chosen = false

    public init() {}

    public var chrome: [UIView] { [tools, ruler] }

    public func load(in host: any HangarHost) {
        self.host = host
        let style = host.style
        ruler = Ruler(style: style)
        buttons = host.toolbox.adjustments.map { ToolButton($0, style: style) }
        tools.setItems(buttons, chosen: 0)
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
        ruler.onEnd = { [weak self] _ in self?.host?.commit() }
        host.add(tools, at: .controls)
        host.add(ruler, at: .controls)
        tool = toolbox.adjustments.first?.id ?? ""
        rulerTool = tool
        chooseTool(0)
    }

    public func layout(_ layout: HangarLayout) {
        // Photos' iPad: the ruler 75 in from the right, the tools 117 in, shown 361 points each way from the middle;
        // its phone: the ruler 71 over the mode bar, the tools 113.
        let axis: Ruler.Axis = layout.sideways ? .along : .across
        ruler.axis = axis
        ruler.frame = layout.ruler
        tools.axis = axis
        tools.reach = layout.sideways ? 361 : nil
        tools.frame = layout.tools
    }

    public func show(_ shown: Bool) {
        chosen = shown
        tools.isHidden = !shown
        ruler.isHidden = !shown
        if shown, let adjustment = toolbox.adjustment(tool) { host?.showName(adjustment.name) }
    }

    public func stop() {
        ruler.stop()
    }

    public func sync() {
        guard let edit = host?.edit else { return }
        for button in buttons {
            button.show(value: edit.value(of: button.id), switchedOff: edit.switchedOff.contains(button.id), number: button.showsNumber)
        }
        ruler.set(shownValue(rulerTool))
        setRulerState(animated: host?.hasEntered ?? false)
    }

    private var autoID: String { HangarAdjustment.auto.id }

    /// A tool passing the middle of the strip as it moves: its name shown, the ruler (off meanwhile) left alone.
    private func passTool(_ index: Int) {
        guard toolbox.adjustments.indices.contains(index) else { return }
        tool = toolbox.adjustments[index].id
        host?.showName(toolbox.adjustments[index].name)
    }

    /// The strip came to rest on a tool: the ruler set to it and on again (as its tool is: off for Auto off, dimmed
    /// for a tool switched off).
    func chooseTool(_ index: Int) {
        guard toolbox.adjustments.indices.contains(index) else { return }
        let adjustment = toolbox.adjustments[index]
        tool = adjustment.id
        rulerTool = adjustment.id
        ruler.range = adjustment.range
        ruler.magnet = 0
        ruler.marked = 0
        ruler.set(shownValue(rulerTool))
        ruler.accessibilityLabel = "Intensity Slider for \(adjustment.name)"
        if chosen { host?.showName(adjustment.name) }
        setRulerState(animated: true)
    }

    private func setRulerState(animated: Bool) {
        guard let edit = host?.edit else { return }
        if rulerTool == autoID {
            let on = edit.applies(autoID)
            ruler.setState(enabled: on, dimmed: !on, animated: animated)
        } else {
            ruler.setState(enabled: true, dimmed: edit.switchedOff.contains(rulerTool), animated: animated)
        }
    }

    /// What a tool's ruler shows: its value, or its default while it's switched off (Photos').
    private func shownValue(_ id: String) -> Double {
        guard let edit = host?.edit else { return 0 }
        return id != autoID && edit.switchedOff.contains(id) ? 0 : edit.value(of: id)
    }

    private func button(_ id: String) -> ToolButton? {
        buttons.first { $0.id == id }
    }

    /// The chosen tool tapped: switched off or on (its value kept; its number shown, on). Auto on for the first time
    /// is Photos' first guess.
    private func toggleTool(_ index: Int) {
        guard let host else { return }
        ruler.stop()
        let id = toolbox.adjustments[index].id
        let on: Bool
        if id == autoID {
            on = !host.edit.applies(id)
            if on, host.edit.value(of: id) == 0 { host.edit.set(id, to: Self.autoFirst) }
            if on { host.edit.switchedOff.remove(id) } else { host.edit.switchedOff.insert(id) }
        } else {
            on = host.edit.switchedOff.contains(id)
            if on { host.edit.switchedOff.remove(id) } else { host.edit.switchedOff.insert(id) }
        }
        ruler.set(shownValue(id), animated: true)
        button(id)?.show(value: host.edit.value(of: id), switchedOff: host.edit.switchedOff.contains(id), number: on)
        setRulerState(animated: true)
        host.render()
        host.commit()
    }

    /// A tool as VoiceOver reads it in the strip: its name and value (Photos'), or Auto on or off.
    private func spokenTool(_ index: Int) -> String {
        guard let edit = host?.edit else { return "" }
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
        guard let edit = host?.edit else { return }
        button(rulerTool)?.show(value: edit.value(of: rulerTool), switchedOff: edit.switchedOff.contains(rulerTool), number: true)
    }

    private func rulerMoved(_ value: Double) {
        guard let host else { return }
        host.edit.set(rulerTool, to: value)
        // Moving a tool switched off switches it on.
        if host.edit.switchedOff.remove(rulerTool) != nil { setRulerState(animated: true) }
        button(rulerTool)?.show(value: value, switchedOff: false, number: true)
        host.render()
    }

    #if DEBUG
    /// `HANGAR_SCRUB`: the asked tool's ruler swept, its frames timed (`Scrub`).
    func scrubIfAsked(canvas: CanvasView) {
        guard let id = Scrub.asked, let index = toolbox.adjustments.firstIndex(where: { $0.id == id }), let host else { return }
        if Scrub.all {
            for adjustment in toolbox.adjustments where adjustment.id != id {
                host.edit.set(adjustment.id, to: adjustment.range.upperBound / 3)
            }
            host.render()
            sync()
        }
        tools.choose(index, animated: false)
        chooseTool(index)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self else { return }
            Scrub(ruler: self.ruler, canvas: canvas, name: id + (Scrub.all ? "-all" : "")).run()
        }
    }
    #endif
}
