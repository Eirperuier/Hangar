import HangarCore
import UIKit

/// One of the editor's modes: its button on the mode bar, its controls, and what it does to the edit. Adjust, Filters
/// and Crop are three (`HangarAdjustModule`, `HangarFiltersModule`, `HangarCropModule`); an app adds its own the same
/// way, and gives the editor them in the order the mode bar shows them.
///
/// The editor keeps what they share: the top bar (Cancel, Undo and Redo, More, Done), the mode bar, the picture
/// (drawn from the edit every change), the name over the tools, undo, and flying in and out. A mode makes its views
/// once (`load`), places them in each layout (`layout`), shows them while it's chosen (`show`), and changes the edit
/// through its host (`HangarHost`): `edit`, then `render()` as it goes and `commit()` for a step to undo to.
@MainActor
public protocol HangarModule: AnyObject {
    /// Its button on the mode bar; its id is the mode's (`HangarMode`).
    var item: HangarModeItem { get }
    /// Makes its views and adds them to the host's (`host.add`). Once, before anything else.
    func load(in host: any HangarHost)
    /// Places its views (all its views, chosen or not: a layout may come while another mode is chosen).
    func layout(_ layout: HangarLayout)
    /// Its views shown or hidden as it's chosen or left, in the editor's cross-dissolve between modes.
    func show(_ shown: Bool)
    /// It's been chosen and shown.
    func entered()
    /// Another mode's been chosen and it's hidden.
    func left()
    /// The edit's changed other than by it (undo, redo, Paste Edits, Revert, a step made), or after it kept a step:
    /// its controls as the edit is.
    func sync()
    /// The picture under the edit's changed (a step made or undone): anything made from it made again.
    func pictureChanged()
    /// Whatever it has moving stops where it is (before a mode changes, an undo, the editor closing).
    func stop()
    /// Its own items for More, first, while it's chosen.
    func menu() -> [UIMenuElement]
    /// Its views that come and go with the editor, faded in as it opens and out as it closes.
    var chrome: [UIView] { get }
    /// Whether it puts controls of its own where Undo, Redo and More are (Crop: Flip and Rotate, Aspect Ratio): the
    /// editor's go while it's chosen.
    var ownsTopBar: Bool { get }
    /// Whether the mode's name shows in the top bar on an iPad (Crop's has RESET there instead).
    var showsTitle: Bool { get }
    /// Where the name over the tools sits on a phone: its capitals' middle this far over the mode bar.
    var nameRise: CGFloat { get }
    /// Where the picture is while it shows the picture itself (Crop's stage), nil while the canvas does: the editor
    /// flies home from there.
    var pictureFrame: CGRect? { get }
    /// The editor's closing: anything of the picture's it shows goes at once (the editor flies a copy home).
    func closing()
    /// The original shown or not (an iPad's Show Original), for a mode that shows the picture itself.
    func showOriginal(_ shown: Bool)
}

public extension HangarModule {
    func entered() {}
    func left() {}
    func sync() {}
    func pictureChanged() {}
    func stop() {}
    func menu() -> [UIMenuElement] { [] }
    var ownsTopBar: Bool { false }
    var showsTitle: Bool { true }
    var nameRise: CGFloat { 151.7 }
    var pictureFrame: CGRect? { nil }
    func closing() {}
    func showOriginal(_ shown: Bool) {}
}

/// A mode's button on the mode bar: Photos' are a symbol over a name, the symbol filled while it's chosen.
public struct HangarModeItem: Sendable {
    public var id: String
    public var name: String
    public var symbol: String
    public var chosenSymbol: String
    /// What VoiceOver reads (its name if nil).
    public var spoken: String?

    public init(id: String, name: String, symbol: String, chosenSymbol: String? = nil, spoken: String? = nil) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.chosenSymbol = chosenSymbol ?? symbol
        self.spoken = spoken
    }
}

/// Where the editor has put what it keeps, and where a mode's controls go, in its view's coordinates: Photos'
/// measures on a phone (the tools along the bottom) and an iPad (down the right).
public struct HangarLayout {
    /// The editor's view.
    public var bounds: CGRect
    public var safeArea: UIEdgeInsets
    /// An iPad's (or a phone on its side): the modes down the left, the tools down the right.
    public var sideways: Bool
    /// The screen's pixels a point.
    public var scale: CGFloat
    /// The top bar's buttons: Cancel, the capsule Undo and Redo are on (Show Original first on an iPad), More, Done,
    /// and the mode's name between them on an iPad.
    public var cancel: CGRect
    public var history: CGRect
    public var more: CGRect
    public var done: CGRect
    public var title: CGRect
    public var modeBar: CGRect
    /// Adjust's tools strip and its ruler: where a mode's own go.
    public var tools: CGRect
    public var ruler: CGRect
    /// Where the picture's shown, fitted (`HangarEditor.fit`).
    public var region: CGRect
}

/// Where a mode's view goes among the editor's.
public enum HangarLevel: Sendable {
    /// Over the picture, under the bars (a stage of its own, what it draws on the picture).
    case picture
    /// With the bars and the tools.
    case controls
}

/// What a mode has of the editor it's in.
@MainActor
public protocol HangarHost: AnyObject {
    /// The edit as it is now: a mode changes it, then `render()` to see it and `commit()` to keep it as a step.
    var edit: HangarEdit { get set }
    var style: HangarStyle { get }
    var toolbox: HangarToolbox { get }
    var renderer: HangarRenderer { get }
    /// The editor's view, for its window and traits (a mode's views go in through `add`).
    var view: UIView! { get }
    /// Whether the editor's flown in: what happens before is set without animating.
    var hasEntered: Bool { get }
    /// The picture the edit is drawn on (its steps' pictures, at about the screen's size), and its context.
    var base: (image: CIImage, context: HangarRenderContext)? { get }
    /// The same, shaped by the edit's geometry: what the canvas draws the adjustments and filter on.
    var shaped: (image: CIImage, context: HangarRenderContext)? { get }
    /// Where the canvas shows the picture.
    var canvasFrame: CGRect { get }

    func add(_ view: UIView, at level: HangarLevel)
    /// The canvas drawn again with the edit (shaped again first if its geometry changed).
    func render()
    /// The edit kept as a step to undo to; every mode's controls synced to it.
    func commit()
    /// The name over the tools, in capitals; nil hides it.
    func showName(_ name: String?)
    /// The top bar and the mode bar hidden (while the picture wants seeing whole) or back.
    func showBars(_ shown: Bool, duration: TimeInterval, delay: TimeInterval)
    /// The canvas shown or not (a mode showing the picture itself hides it).
    func showCanvas(_ shown: Bool)
    /// Lays the editor out now (a mode about to fly to where the canvas will be).
    func layoutNow()
    /// What More shows (a mode with its own More button shows this).
    func moreMenu() -> [UIMenuElement]
    /// Something drawn over the edit on the canvas while a mode wants it (a preview of what it's about to do); nil
    /// for nothing. Any thread.
    var overlay: (@Sendable (CIImage, HangarRenderContext) -> CIImage)? { get set }
    /// Whether the canvas draws what's drawn on the picture (`HangarEdit.drawing`): not while a mode draws it itself
    /// (Markup, its eraser taking out what's under it).
    var showsDrawing: Bool { get set }
    /// The picture before the edit's steps, the same size as `base`: what a finger held on the picture shows (nil
    /// if a step made the picture another size).
    var plain: CIImage? { get }
    /// Pixels made elsewhere (`HangarJob`): the picture shimmers while it works, and what it makes becomes a step;
    /// then `done`, with whether it did (not if it failed or was cancelled).
    func run(_ job: HangarJob, done: (@MainActor (Bool) -> Void)?)
}

public extension HangarHost {
    func run(_ job: HangarJob) {
        run(job, done: nil)
    }
}
