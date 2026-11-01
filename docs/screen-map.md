# Screen Map — placing layers across screens (PVP-style)

| | |
|---|---|
| **Status** | Approved 2026-10-29 (Cody: "the plan seems good now"). Phases 1, 3, 4 on labs; 2 (render) and 5 (layers, chips) in their own sessions. Mockups: https://claude.ai/artifact/5U2ggA46RcRCNziFmsVTiD artboards K, L, M. |
| **Builds on** | docs/output-configuration.md (M4.3c: On menu, output page for processor packing), Output Presets (PRD §7.1: `OutputPreset` / `OutputAssignment`), `LayerKind` (RenderEngine) |
| **Supersedes** | The 2026-10-28 layer→slice routing plan (dropped, never merged): its question — a layer on one piece of a screen — is answered here by placements. Preset-firing rules are shipped behavior in `ActionRouter.swift`: a header switch mid-service wins and is sticky, a slide-fired preset lands before its scene, a dangling preset id is a miss, never a reset. |
| **Why** | Cody 2026-10-29: "PVP and Resolume, not ProPresenter and slides" — one picture of every output, and presets that say whether a layer is the same on each screen, stretched across them, or sitting on part of one. Anthony Terry's customer fork (Slack, 10-14) proved the appetite: custom layers, a Layer menu per media item, a Span column. Ideas only, our own code. |

## 1. Decisions (Cody, 2026-10-29)

1. **The default never changes.** Most churches use Output Presets as they are: which layers on which screens, theme alternate looks deciding how a slide reads on each. The Screen Map is an advanced, opt-in function for LED walls and complex routing. A church that never opens it sees nothing new.
2. **Screen Map** is the name, and its own sidebar section, never a row among the screens. One per station: where every audience screen sits on one canvas, in map pixels. Not "Stage" (ProPresenter's word for confidence screens). Confidence screens are never on the map.
3. **A layer in a preset is a set of placements on the map.** A placement is a rectangle (x, y, w, h in map px) with Fit or Fill. The same layer may have several placements — a duplicate copy of lyrics on another screen is the point, not an edge case. A screen shows whatever part of a placement falls on it, so partial coverage needs no extra step.
4. **A filled dot is an implicit placement** that fills that screen. Today's presets are therefore already valid placements; nothing migrates. Drawing a placement for a layer on a preset replaces the dots' implicit placements for that layer on that preset; clearing them falls back to the dots.
5. **Starting points, not modes.** "One per screen" and "Across the chosen screens" are buttons that create placements; the operator drags, resizes and duplicates from there.
6. **Items pick layers, presets place layers, slides may fire presets.** A media item on a slide may be moved to another layer (right-click › Layer); custom layers are added under Output Presets (Add Layer). A slide never says where content goes. One routing system.
7. **Thumbnails show stored facts only.** A chip for an item on a non-default layer, a chip when the slide fires a preset. Where that lands under the active preset appears on hover, never in the grid — a thumbnail that changes when the operator jumps around is a thing to distrust during a service.
8. **Two drawings, kept apart (Cody 2026-10-29, the "room drawing and suitcase" explanation):** the Screen Map is where the pieces hang in the room and what part of a spanned layer each shows; the output page is how pieces are packed down one wire to a processor. Usually alike, so the bridge seeds the wire from the map; when the processor packs differently, only the wire changes.
9. **Processor packing stays separate.** Several screens into one SDI (the output page, docs/output-configuration.md decision 8) is the wire's business; the Screen Map is the room's.

## 2. Model

```
ScreenMap (per station, UserDefaults beside outputs.placeholderScreens)
  size: (w, h) px                       // grows to fit; default = bounding box of mapped screens
  screens: [screenID: MapRect]          // only audience screens; unmapped screens get dots only

Placement
  rect: MapRect                         // x, y, w, h in map px
  scale: fit | fill

OutputPreset (document, schema bump)
  assignments: [OutputAssignment]       // unchanged — the dots
  placements: [layerID: [Placement]]?   // absent = dots only (every existing preset)
  layers: [CustomLayer]?                // id, name, stacks above `slide` by default; absent = built-in only

Media item (slide document)
  layer: String?                        // LayerKind raw value or a custom layer id; absent = by classification
```

Resolution, per screen, per layer, for the active preset: if `placements[layer]` exists → every placement whose rect meets the screen's MapRect, cropped to the screen (the sourceRect machinery slices already use); else → the dot (fill the screen) or nothing. Fit/Fill of an explicit placement applies inside its rect; the per-screen Fit/Fill stays for dots.

## 3. Render

Today each screen composites its own scene. A placed layer renders once per frame at the placement's size and is blitted into each screen it meets, clipped. One extra pass per placement, not per screen; a spanned video across three screens decodes once. Masks and corner pin stay per output. Theme alternate looks apply to the slide layer per screen as now; a placed slide layer uses the look of the screen it mostly lands on (first wave; per-placement looks later if asked).

## 4. UI

| Where | What |
|---|---|
| Sidebar | **SCREEN MAP** is its own section between Screens and Output Presets (Cody 2026-10-29: as a row under Screens "it looks like it's just another screen"), present once a map exists; its + (and "Add Screen Map…" in the Screens + menu) creates one from the current screens laid side by side. The map has a name ("Main Room"). |
| Screen Map page | The canvas with rulers; each mapped screen a draggable rectangle with its name, size and output; snap 8 px; position/size fields; Identify; an "Off the map" list of unmapped audience screens with Add to map. Content/Grid view like the output page — Content is the live room: every piece shows its live canvas in place, so a spanned layer reads across the wall. **Send to one output…** on a multi-selection joins the chosen screens to one wire with their wire seats seeded from their map positions (the processor bridge; fix-ups happen on the output page). **Export Template…** writes the map at exact pixel size as SVG (one named layer per screen, labelled rectangles) and PNG, for designers: content authored at map size dropped into Slides spans 1:1 across the pieces under a preset that spans that layer with Fit. |
| Output Preview (Present) | The map is offered beside the single screens: pick "Main Room" and the preview is the room drawing with live content in its true shape, not a 16:9 box. |
| Preset page | The matrix as today. Below it, **Screen Map** disclosure (only when a map exists): the map with the selected layer's placements; Add placement · Duplicate · One per screen · Across chosen screens; per placement x y w h, Fit/Fill, Remove. Dots for a layer with drawn placements show as outlined-filled to say "placed on the map". |
| Layers | Add Layer under the presets section; custom layers appear as matrix rows and in the item's Layer menu; Remove Layer moves its items back to default. |
| Slide | Right-click a media item › Layer › Default (by classification) / built-in layers / custom layers. Thumbnail chips per decision 7; hover popover lists destinations under the active preset. |

## 5. Phases

| Phase | What | Tests |
|---|---|---|
| **1 model** ✓ | `ScreenMap` + `ScreenMapResolver` (OutputEngine/ScreenMap.swift), `OutputManager.screenMap` persisted at `outputs.screenMap`; schema v160: `LayerPlacement`, `CustomLayer`, `OutputPreset.placements/layers`, `CueMedia.layerId` | OutputEngine `ScreenMapTests` (dots-only, off-map, inside, spanned past the edge, duplicates, elsewhere, starting points, persistence hook); PresenterCore `ScreenMapSchemaTests` (pre-v160 decodes to dots, round trip, item layerId) |
| **2 render** | placed-layer pass + blits; Fit/Fill per placement | RenderEngine: a spanned layer across two screens samples the right halves |
| **3 Screen Map page** ✓ | `ScreenMapEditor` + `MapPicture` (Sources/ScreenMapEditor.swift), SCREEN MAP sidebar section, Add Screen Map… in the Screens +, Remove Screen Map in the row's menu; `PictureChrome`/`PixelField` shared with the output page | `ScreenMap.sideBySide/nextSeat` tests; sandbox QA 2026-10-29 (map, nudge, remove/add back, Content + grid) |
| **4 preset placements** ✓ | `PresetPlacementsEditor` under the matrix (only with a map): layer picker, One per screen / Across chosen, Add placement, Duplicate, Fit/Fill, x y w h, Remove; gold ring on a placed layer's dots; `OutputPresetsController.placements/hasPlacements/setPlacements` | `ScreenMapResolver` starting-point tests; sandbox QA (across chosen, add, duplicate → 3 placements, rings). Persistence of the map across relaunch not verified: the QA Mac's disk was full (defaults writes fail silently) |
| **5 layers + items** | Add Layer, item Layer menu, thumbnail chips + hover | PresenterCore: chips derive from stored fields only |
| **6 QA** | wall + ribbon + lobby rig in the sandbox; a church with no map sees no change | — |

## 6. Not in this wave

- Several Screen Maps per station (portable churches): stations cover most of it.
- Rotation of a placement; masks per placement (masks stay per output).
- Per-placement theme looks.
- Live-editing placements while a preset is active is allowed but not animated.
- **Layer effects (Cody 2026-10-29, later wave):** an effect chain per layer like a DAW's effect channels — blur, masks on a custom layer — with parameters a MIDI controller can ride (dim, tweak). Effects exist on media today and masks per output; this would move both onto layers and placements and expose continuous controls.
