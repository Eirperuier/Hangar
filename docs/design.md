# Design

## What it is read off

Photos' editor on iOS 27 and iPadOS 27, driven in the simulator by a UI test that opened a photo and a clip, entered Edit and stepped through each mode, keeping a screenshot and the element tree of each step (Photos' own names: `edit.tool.adjust`, `Enhancements`, `Intensity Slider for Auto`, `Aspect Ratio`).

- **A phone, upright.** At the top, on glass: Cancel (✕) alone, Undo and Redo on one capsule; More (···) and Done (✓, dim until there's something to keep) on the right. The picture fills the width between them and the tools. Under it, the chosen tool's or filter's name in grey capitals; the tools (Adjust) or filter thumbnails (Filters), the chosen one in the middle; a ruler; the modes on a capsule at the bottom, Adjust · Filters · Crop (Video first, for a clip), the chosen one darker, filled, a small yellow mark over it.
- **An iPad.** The modes down the left on a capsule, the mark beside the chosen one; the tools down the right with the ruler along the edge, the name to the left of the chosen tool; the mode's name in capitals at the top in the middle. On the top bar also a before-and-after switch, full screen and Markup.
- **Adjust.** Auto, Exposure, Brilliance, Highlights, Shadows, Contrast, Brightness, Black Point, Saturation, Vibrance, Warmth, Tint, Sharpness, Definition, Noise Reduction, Vignette: each a symbol in a ring, the chosen one filled grey. Its ruler: short marks, a longer one every fifth, under a fixed line; where 0 is marked yellow; a tool that only adds (Sharpness) has marks on one side only.
- **Filters.** Original and nine looks as small square thumbnails of the photo, the chosen one larger in a white frame with a dot over it.
- **Crop** (next). Flip, Rotate and Aspect Ratio on the top bar; corners and edge handles on the picture; Straighten, Vertical and Horizontal as three tools on one ruler.
- **A clip** (after). A Video mode first, with mute on the top bar and a trimmer: play, the clip's frames between two handles, the playhead; in the other modes a small player over the picture.
- **More (···).** Copy Edits, Paste Edits, Save as Duplicate, Appearance, Markup, Extensions, Undo, Redo.
- **Its colours follow the device.** White in light, black in dark: no longer the black it always was.

Hangar has those, Adjust and Filters first, laid out to the same measures. What's Photos' own and not public (its tools' maths, Clean Up, Extensions) it does its own way or not at all.

## An edit is values

`HangarEdit` holds a value for each adjustment, the ones switched off, a filter and how much of it: never pixels. The picture is drawn from it every time (`HangarRenderer.apply`), every adjustment that applies in the toolbox's order, then the filter mixed in by its amount. So an edit opens again where it was left, a step back is the edit before, Copy Edits copies values to another picture, and an app keeps the edit beside its original as Photos does. It decodes whatever it lacks as untouched, so an edit kept now opens in a later version.

## The tools

Each is a `HangarAdjustment` (an id, a name, a symbol, a range, and what a value does to a `CIImage`) or a `HangarFilter` (a look). Photos' are made of Core Image's filters, close to Photos' in what they do and how far they go at their ends; curves (contrast, brightness, black point, raising highlights) are done on the picture as it's seen (sRGB's curve) rather than as light adds up, so they look as they're drawn. Vignette is a soft radial ring multiplied in (darker) or screened in (lighter): Core Image's vignette, done in linear light, brightened the whole picture at -1. The tests check each one's direction (warmer is yellower, tint up is magenta, a vignette darkens the corners) and that each keeps the picture's size; `ContactSheet` draws every tool at both ends and every filter on a photo, to look at while tuning them.

An app's tools are the same kind of thing as Photos': the toolbox is a list it can add to, take from and reorder. A tool works at any size: `context.scale` is how many of the full picture's pixels a pixel being drawn is, for a tool working over a distance; Definition and Vignette measure by the picture instead.

## Drawing

The picture is drawn at about the screen's size into a Metal view the picture's shape (`CanvasView`), by Core Image, each time the edit changes: a ruler dragged redraws it every frame. Its source is drawn once to that size and kept on the GPU (`insertingIntermediate`), so a frame is only the tools' work. The full picture is drawn when it's asked for (`HangarResult.render`), off the main thread, in the picture's own colours.

## Moving things

The ruler and the strips are scroll views: they're dragged and flicked as everything else on iOS, and come to rest on a value or a tool. A strip chooses what passes its middle as it goes (a tap felt for each), and a tap on a tool brings it there; the ruler holds at 0 when it comes to rest within 2% of it, with a tap felt each time it crosses it.

The picture flies in and out on Flight (`FlightGroup`): from the source's frame to the canvas and back, its target read every frame. Flying in, the page under it is covered within the first third of the way, as the picture leaves its place; flying home, it shows through only as the picture is about to land (the cube of the way), so the picture never sits beside a copy of itself.

## Its look

`HangarStyle` is the editor's roles, not Photos' colours: the background, words and symbols, words set back, the accent (the chosen mode's mark, a value, 0), a tool's ring and fill, the ruler's marks, the fonts, glass or not. Photos' are the system's, following the device's light and dark; an app gives its design's tokens for the same roles.
