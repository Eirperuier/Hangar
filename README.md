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
| Tools | the app's tools that have a picture made again: Clean Up (what's painted taken out), an edit in words (of a part painted, or all of it), the text changed, Extend (more round it), Reframe (a new camera angle), a light, a Close-Up; each step's takes over the picture, another asked for, the one used chosen |
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

Some changes are pixels, not values: an object erased, the background taken out, more of the scene drawn round it, the whole of it made larger, by a model on your server or by Vision on the device. Give the editor a `HangarJob` (from a mode, `host.run(job)`, or from More, as an `HangarAction`): it's given the picture as the edit has it so far, and what it makes becomes a step (`HangarStep`), one to undo, with the picture lit where it works meanwhile and Cancel stopping it.

```swift
editor.actions = [HangarAction(title: "Upscale", symbol: "arrow.up.left.and.arrow.down.right", job: HangarJob(tool: "upscale", name: "Upscaling") { picture in
    HangarMade(try await server.upscale(picture))      // twice as large: the whole picture is, from then on
})]
```

A step's pictures are kept by the app (`HangarAssets`: a folder by default, your storage or server if you like); the edit keeps only their ids. A step is laid over the picture before it where its frame says (more round it for a picture made larger) and as much as its mask says, and the crop, adjustments and filter are drawn on top, so they stay values: change Exposure after the background's gone, and the background stays gone. The example's Remove Background (Vision) is made this way.

## Tools

Photos' Tools (iOS 27) asks something of the picture and has it made again: paint over something and it's taken out, pull the frame past the edges and more of the scene is drawn, move the camera and it's seen from there. Hangar has the mode and each tool's handling, not what makes their pictures: that's your model, or something on the device. Give the editor a Tools mode with yours:

```swift
let cleanUp = HangarTool.cleanUp(price: "2 credits", longestSide: 2048) { request in
    // request.picture: the picture as the edit's steps make it; request.mask: white where it was painted;
    // request.marked: the picture with the paint on it, marked as Flowith's web eraser marks it (`HangarMarking.eraser`),
    // for a model that reads marks.
    [try await server.erase(request.marked, prompt: "Remove the area marked by the translucent blue brush strokes…")]
}
let edit = HangarTool.edit(price: "4 credits", pickReference: pickFromLibrary) { request in
    // request.words, request.references; request.mask nil if nothing was painted (the whole picture).
    [try await server.edit(request.picture, marked: request.marked, references: request.references.map(\.picture), prompt: request.words ?? "")]
}
let extend = HangarTool.extend { request in
    // request.canvas: the picture on a canvas out to request.frame, grey round it; request.mask: white what's to be drawn.
    [try await server.outpaint(request.canvas!, mask: request.mask!)]
}
let editor = HangarEditor(image: image, modules: [HangarAdjustModule(), HangarFiltersModule(), HangarCropModule(),
                                                  HangarToolsModule(tools: [cleanUp, edit, extend])])
```

| Tool | What's asked | What's laid back |
|---|---|---|
| `cleanUp` | painted; works as the finger lifts | only the painted part, its tones met to the picture's |
| `edit` | words, pictures to go by, a part painted or not | the painted part as Clean Up's; all of it if nothing was |
| `text` | the text Vision finds, each box tapped and said again | only the boxes, tones met |
| `extend` | a frame pulled out past the picture (or a shape chosen), words if it asks | the picture's own pixels kept, what's round it met to them; the picture larger |
| `reframe` | one finger turns and tilts the camera, two move, zoom and roll it; shown as it's set (`HangarReframe`) | all of it |
| `light` | a light dragged into place, its brightness, warmth, strength and rim; shown as it's set (`HangarRelight`) | all of it |
| `closeUp` | a box over a part | that part, the whole picture from then on (the crop let go) |

A model may redraw the whole picture: where only a part was asked, Hangar keeps that part (2% wider, its edge feathered), meets its tones to the picture's round it (so a model's cast over everything leaves no seam), and refuses one that came back another shape; a whole picture that comes back another shape is cut to the picture's. What was asked is kept with the step, as values on the picture under the crop, so the crop, adjustments and filter can still change after.

Once a step's made, its takes show over the picture: Again asks for another the same way (up to 8), the arrows choose the one used (each an undo step), and ⋯ lays it only where it was asked or whole, and shows what's kept. A tool's price, if the app gives one, shows after its name or on its button; an action's in More, under its title. An action can be a choice of jobs (`HangarAction(title:symbol:choices:)`, as Upscale's 2K, 4K and 8K).

A stroke (`HangarStroke`) is kept as Flowith's web canvas keeps one (`{"points": [{"x", "y"}], "widthRatio", "color"}`), and a tool marks its picture as the web marks it for the same model (`HangarMarking.drawArea`, `.eraser`), so a stroke goes either way and a model's prompt reads the same marks. The brush and the light over a working picture are a view of their own (`HangarGlowView`), for a picture shown anywhere else:

```swift
let glow = HangarGlowView()                      // over the picture's view, as large as what it may light
glow.show(picture)                               // the picture's CGImage: the frost and the lines it lights
glow.pictureFrame = imageView.frame              // where it is, again as it moves or zooms
glow.paint(stroke); glow.lift()                  // a stroke as a finger draws it (HangarStroke, the picture's units)
glow.work(.painted)                              // lit while something works there (.whole, .boxes, .around)
```

The example's tools are all made on the device (a fill from round the paint, colours named in the words, the text written over the colour round it, the same camera and light the tools show, a part enlarged), so every tool can be tried; a model does far better.

## Drawing

`HangarMarkupModule()` is a mode for drawing on the picture: a pen, a shape (line, arrow, rectangle, ellipse, triangle, diamond, star, heart; the shape button, tapped again, opens them), the eraser, nine colours and a well for any other, and a width on the ruler (the pen and shapes one, the eraser its own). Each mark is an undo step; the bars go while a finger draws.

What's drawn is part of the edit (`edit.drawing`, a `HangarDrawing`): values, like the rest of it. It's drawn over the picture as the edit shows it, after its adjustments and filter (a red arrow stays red under a filter), and it's on the picture under the crop: a crop, a turn or a flip later keeps each mark on what it was drawn on, and Crop shows it as it moves. The eraser takes out what's drawn, never the picture. A picture made larger (Extend) keeps the marks on the same part of it; a part made the whole picture (Close-Up) lets them go.

A drawing is kept as a list of marks, each a stroke as the web canvas keeps one with what it is beside it, so the same JSON draws the same thing anywhere:

```json
{"marks": [
  {"kind": "pen",       "points": [{"x": 0.20, "y": 0.35}, {"x": 0.31, "y": 0.42}, {"x": 0.45, "y": 0.44}], "widthRatio": 0.012, "color": "#FFFFFF"},
  {"kind": "arrow",     "points": [{"x": 0.22, "y": 0.80}, {"x": 0.70, "y": 0.30}], "widthRatio": 0.012, "color": "#FF3B30"},
  {"kind": "star",      "points": [{"x": 0.60, "y": 0.10}, {"x": 0.85, "y": 0.45}], "widthRatio": 0.008, "color": "#FFCC00"},
  {"kind": "rectangle", "points": [{"x": 0.10, "y": 0.90}, {"x": 0.10, "y": 0.60}, {"x": 0.40, "y": 0.90}], "widthRatio": 0.008, "color": "#34C759"},
  {"kind": "eraser",    "points": [{"x": 0.38, "y": 0.30}, {"x": 0.40, "y": 0.55}], "widthRatio": 0.036}
]}
```

- `points` are 0 to 1 each way from the picture's top left; `widthRatio` is the line's width as a share of the picture's shorter side; `color` is `#RRGGBB` (`#RGB` and `#RRGGBBAA` read too, either case; white if there's none). A mark with no `kind` is a pen's, so a stroke the web sends for a painted edit is a drawing's mark as it is; a `kind` it doesn't know is drawn as a pen's line through its points.
- `pen`, `eraser`: a line through the points in order (one point is a dot). `line`, `arrow`: its two ends; the arrow's head at the second, two lines 30° each side of the arrow, 4 widths long (no more than 45% of it).
- The shapes fill a box: two opposite corners (the box upright on the picture), or its top left, top right and bottom left (a box drawn upright on a picture shown turned or straightened: the shape stays upright as it was drawn). In the box, 0 to 1 each way: a rectangle its edges, an ellipse inside them, a triangle (½, 0) (1, 1) (0, 1), a diamond the edges' middles, a five-pointed star its points on the ellipse (the first at the top, the corners between them 0.382 of the way in), a heart as `HangarMark.heartCurves` go. A box with no size, or a line with no length, draws nothing.
- Lines have round ends and corners. Marks are drawn in order on a clear layer; the eraser clears that layer (a canvas's `destination-out`), and the layer goes over the picture.

`HangarMark.outline(size:)` is where each kind's lines are worked out, for a picture of a size; `HangarDrawing.image(size:)` draws the layer, `draw(in:size:scale:place:)` into a context of your own (each point placed where you show it), and `HangarRenderer.marks(_:size:)` gives it shaped by the edit's geometry, as `render` lays it.

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
