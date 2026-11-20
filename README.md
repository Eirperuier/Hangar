# Hangar

The editor you know from Photos, for your app's pictures: Adjust, Filters and Crop, on iPhone and iPad, light and dark. Tap Edit and the picture flies out of where it was into the editor; drag a ruler and it changes under your finger; tap Done and it flies back, edited. Its tools, its modes and what More offers are yours to add to, and its look is yours to set, so it can speak your app's design rather than Apple's.

Hangar is built on [Flight](https://github.com/Eirperuier/Flight): the picture flies in and out on Flight's springs, and Flight's viewer (`ImagePreview`) is where it's most at home.

## What it feels like

- **It's Photos'.** The same bars, the same modes, the same tools in the same order, the same ruler: marks sliding under a line, 0 in yellow, a tap you feel as you cross it. On an iPhone the tools run along the bottom; on an iPad (or a phone on its side) the modes go down the left and the tools down the right.
- **It follows your finger.** The picture is drawn by Core Image straight into the screen, from a copy the screen's size kept on the GPU, every frame a ruler moves; off the main thread and always the latest, so the ruler never waits for it. A ruler only ever changes the tool it was set to: while the tools move it's off.
- **Nothing is lost.** An edit is values, never pixels (`HangarEdit`, Codable): keep it beside the original, open it again later, change Exposure without redoing the rest, or go back to the original. Undo and redo go a step at a time; a finger held on the picture shows the original.
- **It comes from where you tapped.** Give it the picture's place on screen (`HangarSource`) and it flies out of it and back into it, the page underneath covered and shown again as it goes.

| | |
|---|---|
| Adjust | Auto, Exposure, Brilliance, Highlights, Shadows, Contrast, Brightness, Black Point, Saturation, Vibrance, Warmth, Tint, Sharpness, Definition, Noise Reduction, Vignette |
| Filters | Vivid, Vivid Warm, Vivid Cool, Dramatic, Dramatic Warm, Dramatic Cool, Mono, Silvertone, Noir, each with how much |
| Crop | the box's corners and edges, the picture dragged and pinched under it; Straighten, Vertical, Horizontal; Flip, Rotate; Aspect Ratio (Original, Freeform, Square, Wallpaper, 16:9 to 3:2, upright or level, locked); Reset |
| ··· | Copy Edits, Paste Edits, Lock Aspect Ratio, Revert to Original |

Video (trimming, and every tool on a clip) comes next.

## Quick start

```swift
import Hangar

let editor = HangarEditor(image: photo.original, edit: photo.edit)
editor.onDone = { result in
    photo.edit = result.edit          // keep the edit, to open it again
    photo.shown = result.preview      // the edited picture at the editor's size, at once
    Task { photo.shown = await result.render() ?? photo.shown }   // full size, off the main thread
}
editor.present(from: self, source: HangarSource(view: cell.imageView, cornerRadius: 8))
```

`onDone` is called before the editor flies home, so the picture it lands on can already show the edit.

## With Flight's viewer

Photos opens its editor from its viewer, and so can you: put an Edit button on the viewer's toolbar and fly from the picture the viewer shows, which fits it to the screen. Give the viewer each photo as your own `PreviewContent` so it can show the edit the moment there is one (the example app does exactly this):

```swift
let edit = UIBarButtonItem(image: UIImage(systemName: "slider.horizontal.3"), primaryAction: UIAction { _ in
    let photo = photos[preview.index]
    let editor = HangarEditor(image: photo.original, edit: photo.edit)
    editor.onDone = { result in photo.keep(result) }   // and tell the viewer it changed
    let frame = HangarEditor.fit(photo.shown.size, in: preview.page.view.bounds, scale: view.window!.screen.scale)
    editor.present(from: preview.page, source: HangarSource(view: preview.page.view, frame: frame))
})
preview.page.toolbarItems = [.flexibleSpace(), edit, .flexibleSpace()]
```

## Your own tools

The editor's tools are a `HangarToolbox`, Photos' by default. An adjustment is a ruler and what its value does to the picture; a filter is a look. Add yours, take some out, or put them in another order:

```swift
var toolbox = HangarToolbox.standard
toolbox.adjustments.append(HangarAdjustment(id: "grain", name: "Grain", symbol: "circle.grid.3x3", range: 0...1) { image, value, _ in
    let noise = CIFilter(name: "CIRandomGenerator")!.outputImage!.cropped(to: image.extent)
    let grained = noise.applyingFilter("CISoftLightBlendMode", parameters: [kCIInputBackgroundImageKey: image])
    return image.mixed(toward: grained, value)
})
toolbox.filters.removeAll { $0.id == "noir" }
let editor = HangarEditor(image: image, toolbox: toolbox)
```

Each runs on any thread, on the picture at the size being drawn (`mixed(toward:_:)` and `perceptual(_:)` help): `context.scale` says how many of the full picture's pixels that is, so a tool working over a distance looks the same small and full size. `context.source` is the picture as it came.

## Your own modes

A mode is a `HangarModule`: its button on the mode bar, its controls, and what it does to the edit. Adjust, Filters and Crop are three (`HangarAdjustModule`, `HangarFiltersModule`, `HangarCropModule`); give the editor yours among them, in the order the mode bar shows them:

```swift
let editor = HangarEditor(image: image, modules: [HangarAdjustModule(), HangarFiltersModule(), HangarCropModule(), Markup()])
```

The editor keeps what they share (the top bar, the mode bar, the picture, the name over the tools, undo, flying in and out) and gives a mode its host (`HangarHost`): the edit to change, `render()` to see it as it goes, `commit()` for a step to undo to, where its controls go (`HangarLayout`, Photos' measures on a phone and an iPad), the picture as the canvas draws it, the bars to hide while the picture wants seeing whole. What a mode keeps goes in the edit, under its id (`edit.modules`), so it's undone, copied and kept with the rest.

## Pictures made elsewhere

Some changes are pixels, not values: an object erased, the background taken out, more of the scene drawn round it, the whole of it made larger, by a model on your server or by Vision on the device. Give the editor a `HangarJob` (from a mode, `host.run(job)`, or from More, as an `HangarAction`): it's given the picture as the edit has it so far, and what it makes becomes a step (`HangarStep`), one to undo, with the picture shimmering meanwhile and Cancel stopping it.

```swift
editor.actions = [HangarAction(title: "Upscale", symbol: "arrow.up.left.and.arrow.down.right", job: HangarJob(tool: "upscale", name: "Upscaling") { picture in
    HangarMade(try await server.upscale(picture))      // twice as large: the whole picture is, from then on
})]
```

A step's pictures are kept by the app (`HangarAssets`: a folder by default, your storage or server if you like); the edit keeps only their ids. A step is laid over the picture before it where its frame says (more round it for a picture made larger) and as much as its mask says, and the crop, adjustments and filter are drawn on top, so they stay values: change Exposure after the background's gone, and the background stays gone. The example's Remove Background (Vision) is made this way.

## Your own look

Everything the editor draws is from a `HangarStyle`: Photos' by default, following the device's light and dark. Give it your design's tokens for its roles:

```swift
var style = HangarStyle()
style.accent = Tokens.signal           // the chosen mode's mark, the ruler's mark at its value
style.raised = Tokens.signalStrong     // a tool's ring and number above its default
style.background = Tokens.background
style.toolFill = Tokens.secondaryFill  // a tool's face
style.nameFont = Tokens.caption        // the tool's or filter's name over the strip
style.glass = false                    // plain bars rather than glass
let editor = HangarEditor(image: image, style: style)
```

## HangarCore

What an edit is and how a picture is drawn from it, without the editor: `HangarRenderer(toolbox:assets:).render(edit, to: cgImage)` for a thumbnail, a share, or a server, and `apply(_:to:context:)` to do it to a `CIImage` of your own.

## Installation

Swift Package Manager:

```swift
.package(url: "https://github.com/Eirperuier/Hangar.git", branch: "main")
```

and add the `Hangar` product (or `HangarCore` alone). Requires iOS 17 or Mac Catalyst 17. On an iPhone with ProMotion, set `CADisableMinimumFrameDurationOnPhone` in your app's Info.plist so the picture follows a ruler at 120 Hz rather than 60.

## Example

`Example/` is a gallery: photos in a grid, opened in Flight's viewer, edited in Hangar from its toolbar. Run `Example/scripts/fetch-pictures.sh` for photos to edit (or pick your own with +), then `xcodegen generate` in `Example/` and open `HangarExample.xcodeproj`.

## License

MIT
