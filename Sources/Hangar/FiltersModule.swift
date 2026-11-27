import HangarCore
import UIKit

/// Photos' Filters: Original and the toolbox's looks as thumbnails of the picture on a wheel, the one in the middle on
/// it, its amount on a ruler (each filter keeps its own); the bars go while it's dragged.
@MainActor
public final class HangarFiltersModule: HangarModule {
    public let item = HangarModeItem(id: HangarMode.filters.id, name: "Filters", symbol: "camera.filters")

    private weak var host: (any HangarHost)?
    private let strip = Strip()
    private var thumbnails: [FilterThumbnail] = []
    private var loupe: FilterLoupe!
    private var ruler: Ruler!
    /// How much of each filter, as it was last set: a filter comes back as it was left (Photos'), whole the first time.
    private var amounts: [String: Double] = [:]
    /// The bars hidden while a filter's ruler is moved (Photos', to see the picture whole).
    private var barsHidden = false
    private var thumbnailsFor: HangarEdit?
    private var chosen = false

    public init() {}

    public var chrome: [UIView] {
        // Its ruler only while there's a filter to have an amount of.
        host?.edit.filter == nil ? [strip] : [strip, ruler]
    }

    /// Its name a little higher, over the thumbnails.
    public var nameRise: CGFloat { 159.7 }

    public func load(in host: any HangarHost) {
        self.host = host
        let style = host.style
        loupe = FilterLoupe(style: style, thumbnail: FilterThumbnail.side)
        ruler = Ruler(style: style)
        let edit = host.edit
        let none = FilterThumbnail(id: nil, name: "Original", style: style)
        thumbnails = [none] + host.toolbox.filters.map { FilterThumbnail(id: $0.id, name: $0.name, style: style) }
        thumbnails.first?.end.first = true
        thumbnails.last?.end.last = true
        if let id = edit.filter { amounts[id] = edit.filterAmount }
        strip.setItems(thumbnails, chosen: thumbnails.firstIndex { $0.id == edit.filter } ?? 0)
        strip.feel = .filters
        strip.overhang = 12
        strip.loupe = loupe
        strip.onChoose = { [weak self] i in self?.choose(i) }
        strip.onMove = { [weak self] in self?.ruler.setState(enabled: false, dimmed: true, animated: true) }
        strip.onRest = { [weak self] _ in self?.rested() }
        strip.accessibilityLabel = "Filters"
        strip.spokenValue = { [weak self] i in self?.thumbnails[i].name ?? "" }
        ruler.range = 0...1
        ruler.magnet = 1
        ruler.marked = 0.5
        ruler.onChange = { [weak self] value in self?.amountMoved(value) }
        ruler.onEnd = { [weak self] _ in self?.amountEnded() }
        ruler.alpha = edit.filter == nil ? 0 : 1
        host.add(strip, at: .controls)
        host.add(ruler, at: .controls)
    }

    public func layout(_ layout: HangarLayout) {
        if layout.sideways {
            // Photos' filters on an iPad: 51-point thumbnails 53 apart on a wide wheel (700), shown as far as the
            // tools, their middle 82 in from the right, nearer the ruler than the tools' (room for the dot on their left).
            strip.axis = .along
            setStrip(side: 51, wheel: 700, reach: 361)
            strip.frame = CGRect(x: layout.bounds.maxX - layout.safeArea.right - 82 - 75 / 2, y: layout.tools.minY,
                                 width: 75, height: layout.tools.height)
            ruler.axis = .along
        } else {
            // Photos' filters on a phone: 52-point thumbnails 54 apart on a wheel of 200, three and a half each way,
            // 125 over the mode bar (taller than the tools, their middles level).
            strip.axis = .across
            setStrip(side: FilterThumbnail.side, wheel: 200, reach: nil)
            strip.frame = CGRect(x: layout.tools.minX, y: layout.modeBar.minY - 125, width: layout.tools.width, height: 75)
            ruler.axis = .across
        }
        ruler.frame = layout.ruler
        for thumbnail in thumbnails { thumbnail.axis = layout.sideways ? .along : .across }
    }

    private func setStrip(side: CGFloat, wheel: CGFloat, reach: CGFloat?) {
        strip.pitch = side + 2
        strip.itemSize = side + 2
        strip.wheel = wheel
        strip.reach = reach
        strip.fadeClear = 14
        strip.fadeWhole = 40
        loupe.thumbnail = side
    }

    public func show(_ shown: Bool) {
        chosen = shown
        strip.isHidden = !shown
        ruler.isHidden = !shown
        ruler.alpha = host?.edit.filter == nil ? 0 : 1
        if shown { host?.showName(thumbnails[strip.chosen].name) }
    }

    public func entered() {
        makeThumbnails()
    }

    public func stop() {
        ruler.stop()
    }

    public func sync() {
        guard let edit = host?.edit else { return }
        let index = thumbnails.firstIndex { $0.id == edit.filter } ?? 0
        if index != strip.chosen {
            strip.choose(index, animated: true)
            if chosen { host?.showName(thumbnails[index].name) }
        }
        for thumbnail in thumbnails { thumbnail.applied = thumbnail.id == edit.filter }
        if let id = edit.filter { amounts[id] = edit.filterAmount }
        ruler.set(edit.filterAmount)
        ruler.setState(enabled: edit.filter != nil, dimmed: false, animated: host?.hasEntered ?? false)
        if chosen {
            let alpha: CGFloat = edit.filter == nil ? 0 : 1
            if host?.hasEntered ?? false, ruler.alpha != alpha {
                UIView.animate(withDuration: 0.25, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) { self.ruler.alpha = alpha }
            } else {
                ruler.alpha = alpha
            }
            makeThumbnails()
        }
    }

    public func pictureChanged() {
        thumbnailsFor = nil
        if chosen { makeThumbnails() }
    }

    /// A filter passing the middle of the strip, or tapped: on the picture at once (as much of it as it was left at),
    /// kept when the strip rests.
    private func choose(_ index: Int) {
        guard let host else { return }
        let id = thumbnails[index].id
        host.edit.filter = id
        host.edit.filterAmount = id.flatMap { amounts[$0] } ?? 1
        // Photos' ruler goes for Original, over a quarter of a second.
        UIView.animate(withDuration: 0.25, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
            self.ruler.alpha = id == nil ? 0 : 1
        }
        host.showName(thumbnails[index].name)
        // Dragging through the filters, Photos hides its bars as it does for a filter's ruler.
        if strip.isDragged { hideBars(true) }
        host.render()
    }

    private func rested() {
        guard let host else { return }
        hideBars(false)
        ruler.set(host.edit.filterAmount)
        ruler.accessibilityLabel = "Intensity Slider for \(thumbnails[strip.chosen].name)"
        ruler.setState(enabled: host.edit.filter != nil, dimmed: false, animated: true)
        for thumbnail in thumbnails { thumbnail.applied = thumbnail.id == host.edit.filter }
        host.commit()
    }

    private func amountMoved(_ value: Double) {
        guard let host else { return }
        host.edit.filterAmount = value
        if let id = host.edit.filter { amounts[id] = value }
        loupe.show(amount: value)
        hideBars(true)
        host.render()
    }

    private func amountEnded() {
        loupe.show(amount: nil)
        hideBars(false)
        host?.commit()
    }

    /// Photos hides its bars while a filter's ruler is moved, and brings them back a quarter of a second after it's
    /// let go.
    private func hideBars(_ hide: Bool) {
        guard hide != barsHidden else { return }
        barsHidden = hide
        host?.showBars(!hide, duration: 0.3, delay: hide ? 0 : 0.25)
    }

    /// Each filter on the picture as it's adjusted, small: made when Filters opens, again if the adjustments changed.
    private func makeThumbnails() {
        guard let host, let (preview, previewContext) = host.shaped else { return }
        var adjusted = host.edit
        adjusted.filter = nil
        guard thumbnailsFor != adjusted else { return }
        thumbnailsFor = adjusted
        let side = min(preview.extent.width, preview.extent.height)
        let pixels: CGFloat = 150
        let scale = pixels / side
        let square = CGRect(x: preview.extent.midX - side / 2, y: preview.extent.midY - side / 2, width: side, height: side)
        let small = preview.cropped(to: square)
            .transformed(by: CGAffineTransform(translationX: -square.minX, y: -square.minY))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let context = HangarRenderContext(source: small, scale: previewContext.scale * Double(scale))
        let renderer = host.renderer
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
                guard let self, self.thumbnailsFor == adjusted else { return }
                for (thumbnail, picture) in zip(self.thumbnails, made) {
                    thumbnail.image = picture.map { UIImage(cgImage: $0) }
                }
            }
        }
    }
}
