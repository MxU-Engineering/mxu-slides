# Output Configuration — one picture per output (M4.3c)

| | |
|---|---|
| **Status** | Built on labs-output-config (2026-10-29), awaiting Cody's review. Mockups: https://claude.ai/artifact/5U2ggA46RcRCNziFmsVTiD — E/F/G (the On menu, first wave) plus H and J (round 2, decisions 8–9). |
| **Builds on** | docs/output-placement.md (M4.3b: `OutputPlacement`, packed carries, `Add Alongside`), docs/masks-edge-blend.md (M4.3: slices) |
| **Why** | Cody 2026-10-28: "my biggest frustration is not having the one final screen output to see and move all of the screens around on. There's no way to know what LED Wall does." The model already packs several screens into one wire; the UI never drew the wire. |

## 1. Decisions (Cody, 2026-10-28)

1. **Three words in the app: Screen, Output, Slice.** Screen = what the room sees, what presets route to (unchanged). Output = a signal leaving the Mac: a display, a DeckLink port, an NDI sender. Slice = one piece of a screen (Grouped: 3 slices). "Frame" is not a UI word. The old "Outputs N" / "Add Output" (a screen's tiles) and the "OUTPUT" card row both said Output for different things.
2. **No outputs list in the sidebar.** Outputs are found, never created. They appear in one place: each slice's **On** menu, which replaces the card row. The "System Displays — Direct" section and the display detail leave Screen Configuration (the Engine rig keeps direct-live).
3. **On menu**: Displays / DeckLink / Network / No output, each row naming the output's size and who is on it ("free", "Main is on it"). Picking a free output fills it, today's behaviour. Picking one in use offers **Share it** (both land in the same frame, you place them — the LED wall case) or **Take it over** (today's claim-steal).
4. **The output's picture appears inside the screen, only when it matters**: when the slice's output is shared, or the slice is placed 1:1 instead of filling. The live tile is replaced by the output at wire pixels with every slice on it drawn live, the selected one draggable with 8 px snap, X/Y/W/H fields beneath. Click a sibling to edit it there too. A simple rig never sees it.
5. **LED Wall type retired.** Placement is orthogonal to the type row (Single / Mirror / Grouped / Edge Blend / Custom). A one-wall rig = one screen at wall pixels, On: the processor's SDI, "Place 1:1" from the badge next to the On menu.
6. **Frame size lives on the output**, read when a placement is seeded (display pixel size, DeckLink mode, NDI = first placement's frame or the screen size). Screens never carry Frame fields again; `OutputPlacement.frameWidth/Height` stay as the persisted record of what the placement was authored against.
7. **One routing system.** Presets route layers to screens; where a slice lands never changes with a preset. Layer→slice routing is answered by placements on the Screen Map (docs/screen-map.md), never a second path.
8. **A shared output is a row in the Screens list** (Cody 2026-10-29, mockup H, after the first build read as "boring, black, no way to add a screen"). Two screens on one output tuck under a row for it; the row opens the output's own page: the picture with rulers and a checkerboard for unused pixels, Content (live canvases) or Grid (a named test card per screen, never black), Snap, **Add Screen** (move an existing screen here, or a new one), the selected screen's At/Size fields with Top-left 1:1 / Center 1:1 / Fill, Open <screen> →, Take off this output. A screen alone on its output stays a plain row, so a simple rig never sees a group. Outputs are still never listed on their own.
9. **New LED Wall…** under the Screens + (mockup J): pick the output the processor is on, list the screens with sizes, Create — they land stacked 1:1 and the output's page opens to place them. The sheet does not place; the page does (one editor, not two).

## 2. Model changes (small)

- `OutputLayoutKind.ledWall` removed; `OutputLayout.classify` ignores placements (a placed single slice is `.single`; placed extras are what their regions say).
- `OutputManager.seedPlacement(forSlice:frameWidth:frameHeight:)` — the 1:1 top-left seed that `applyLayout(.ledWall)` did, callable from Share it / Place 1:1. A joiner lands below the incumbent when it fits, else at 0,0 (ponytail: first free row only).
- `RenderContext.restorePlaceholderScreens` assigns display claims with `exclusive: false` when the display already holds a restored slice — packed displays survive relaunch (bug found 2026-10-28; DeckLink restore already joins).
- Persistence shape unchanged (`outputs.placeholderScreens` in UserDefaults; `placement` per slice).

## 3. UI changes

| Where | Today | After |
|---|---|---|
| Sidebar | Screens · System Displays — Direct · Output Presets | Screens (shared outputs as group rows with their screens under them, "+ Add a screen to this output") · Output Presets; + menu gains New LED Wall… |
| Output page | — | `OutputEditor`: title + size, Identify, Alignment Grid (every screen), Content/Grid, Snap 8 px, Add Screen ▾, `OutputPicture`, placement row, Open screen →, Take off this output |
| Type row | Single Mirror Grouped Edge Blend LED Wall (Custom) | Single Mirror Grouped Edge Blend (Custom) |
| Count | "Outputs 3", "Add Output" | "Slices 3", "Add Slice" |
| Per slice | OUTPUT card grid (Placeholder, each display, NDI, DeckLink…, Syphon), right-click Add Alongside | **On** menu + badge ("fills it · live" / "at 0,0 · 1:1 · shares with Ribbon"); Share it / Take it over inside the menu |
| Picture | live tile(s) of the screen's canvas; LED Wall: 110 pt frame map | live tile(s); when shared or placed: the output's picture — pixel rulers, checkerboard = unused pixels, each slice live (Content) or a tinted test card with its name (Grid), draggable, siblings click-to-select |
| Placement fields | Frame W H · Position · Size | X Y W H (frame shown in the picture's header, read-only) |
| Header | Sync Test twice | once (identity bar) |
| DeckLink | ALPHA KEY / FORMAT rows under the cards | same rows under the On menu |

## 4. Phases

| Phase | What | Tests |
|---|---|---|
| **1 model** | drop `.ledWall`, `seedPlacement`, restore joins | `OutputLayoutTests` updated; `OutputSliceTests`: joiner lands below incumbent; restore test for two slices on one display |
| **2 UI** | On menu replaces cards; Share it / Take it over; Place 1:1 badge; output picture with drag + handles + fields; sidebar/display section removed; wording; Add Alongside removed | PresenterCore sweep green; on-screen QA |
| **3 QA** | sandboxed build, screenshots of simple rig + shared output + On menu; UX self-review | — |
| **4 round 2** | group rows, `OutputEditor`, `AddScreenMenu`, `NewWallSheet`, test cards/rulers/checkerboard, `OutputCarry.join/release` as the one share path, `OutputManager.identify`; canvas wake owned by `ScreenConfigurationView` (per-page onAppear/onDisappear raced) | model unchanged (116 OutputEngine tests); sandbox QA 2026-10-29: sheet → group → Content+grid → Add Screen → take-off → relaunch |

## 5. Not in this wave
- A third screen that fits neither below nor beside the others lands at 0,0 and the footer says "overlapping" (ponytail: first free row only).
- Dragging a sibling's handles from the output page: click it first (one selected screen at a time).
- Mirror of a screen from Add Screen (mockup H listed it); Mirror stays a layout type on the screen page.

- Multi-select / align / distribute in the picture (PVP). Snap to siblings' edges is in.
- Rotation in the picture (fields keep it).
- Stage overview of every output at once (mockup B) — revisit if two-processor rooms ask.
