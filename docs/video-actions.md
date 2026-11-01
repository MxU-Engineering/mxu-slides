# Video Actions — plan (PRD §7.8, M4.4)

| | |
|---|---|
| **Status** | BUILT 2026-10-30, on labs (Cody reviewed and said commit). Cody took every proposed pick the same day ("Yes, build picks", review page https://claude.ai/artifact/7G8YGshNGV4vgExvM3bQJV), so VA4–VA11 are his. |
| **Ask** | Cody 2026-10-30: "use our NLE timeline type thing inside the video editor to be able to place app actions that play based on when the video hits that mark in the timeline of that video. We'll need the ability to have timers that countdown/up to the next video action or a specific video action (to show only while a video is playing) and if there are no actions remaining in the timeline count up or count to next can show the end of the video. The timer title option would allow us to show the name of the upcoming action as the text fill. Being able to name the video actions would be great, and see them on the timeline but also in a list view in the inspector for that video." |

## 1. What exists (audited on labs 6fa5ededd7)

- `MediaItem.actions` (v87, M1.38) fire once, when the media fires. No time inside the video.
- The presentation timeline's Actions lane: `TimelineCue.actions` (`[SlideAction]`), point cues, fired by `PresentationTimelines.crossing` → `.runActions` → `controls.actionRouter.execute`. Never on a jump (`landing`, T16). Placed through `ActionPlacementSheet`, edited through `SlideActionsSheet` — the slides' own vocabulary and editors.
- Shared timeline UI: `Sources/TimelineControls.swift` (ruler, scrub strip, `PlayheadLayerView` playhead, zoom, block/pin gestures, snapping) over PresenterCore `TimelineGeometry`.
- The media editor (`Sources/MediaEditorView.swift`): preview with a floating `TransportPill` (play + `ScrubBar` with trim handles) over its own `MediaPreviewPlayer`; Form inspector on the right (Name, Behavior, Trim, Effects, Organization, File). No timeline.
- Room playback clock: `MediaTransportController` rows (`MediaTransportState`, `position(at:)` wraps when looping), a 4 Hz poll that writes only on change, and per-layer `ConfidenceInfo.videoCountdowns` (anchored `VideoCountdown`: name, duration, position, anchoredAt, isPlaying) that render-side boxes project with no main-thread traffic.
- Linked text `.videoCountdown` (`SlideScene/LinkedText.swift`): remaining time of a layer's playing video, Format/Custom pattern, warning ink, Show Video Name, Video From (layer). Renders empty when nothing plays on that layer — "only while a video is playing" already holds.
- Service Tracking `Video` / `Timeline` Remaining+Elapsed timers (`ServiceTrackingTimers`, read from the anchors) — the Timers panel / Local API face of the same clocks.

## 2. Decisions

| # | Decision | Whose |
|---|---|---|
| VA1 | A video's actions are **named marks** on that video's own timeline, stored on the media item (`MediaItem.marks`), so the video carries them into every service, slide and presentation timeline that fires it. | Cody (the ask) |
| VA2 | A mark holds any action a slide can (`[SlideAction]`, Clear included), placed and edited with the slides' own Add Action menu and Actions editor. | Cody (the ask: "app actions") |
| VA3 | Marks show on the editor timeline and as a list in the video's inspector. | Cody |
| VA4 | Mark times are **seconds into the file**, not into the trim window, so re-trimming never moves a mark off its frame. A mark outside the trim window shows dimmed and never fires. | Cody 2026-10-30 |
| VA5 | **Crossing fires, landing doesn't** (timeline T16): a mark fires when playback runs across it. A scrub, Go To Time, or a fire that starts mid-video (resume) skips every mark it jumps over. | Cody 2026-10-30 (Q2) |
| VA6 | **Loops re-fire**: each pass of a looping video fires its marks again. | Cody 2026-10-30 (Q1) |
| VA7 | **Same on every layer**: a video fires its marks whether it plays as a background, foreground, on a slide, or from a presentation timeline block. Two layers playing the same video fire once each. | Cody 2026-10-30 (Q3) |
| VA8 | Where the timeline lives: a **timeline card under the preview** in the media editor (ruler, a Video Actions lane with named pins, playhead, zoom), the transport pill stays on the picture. | Cody 2026-10-30 (Q4, option A) |
| VA9 | Timers: the existing **Video Countdown** linked text gains **Counts To** (End of Video · Next Video Action · Video Action Named…) and **Direction** (Down · Up). Up counts from the previous mark (or the start). With no mark left, Next counts to the end. "Named" matches a mark name case-insensitively, like From Object does, so one layout works for every bumper that names a mark "Walk On". | Cody 2026-10-30 (Q5) |
| VA10 | Title fill: a new linked-text source **Video Action Name** shows the upcoming mark's name (Next or Named, same picker), empty when none is left. | Cody 2026-10-30 (Q5) |
| VA11 | Precision: marks fire from a one-shot timer aimed at the mark's wall-clock time from the anchored transport, re-aimed on play / pause / seek / rate change — never a per-tick poll. Target: within one frame (M4.4's acceptance). | Cody 2026-10-30 (with the plan) |

## 3. Shape

- **Schema v161** (`packages/schema/documents.json` + codegen): `VideoMark { id, name, at, actions: [SlideAction] }`, `MediaItem.marks: [VideoMark]?`; `TextLink.videoTarget` (`end` · `nextMark` · `namedMark`), `TextLink.videoMarkName`, `TextLink.countsUp`; `TextSourceKind.videoMarkName`. Media fields aren't in `DeckField.all` (that's presentations); check the media field list the same way.
- **PresenterCore** `Timeline/VideoMarks.swift`: pure rules — `crossing(marks, from:, to:, looping:, duration:)` (wrap-aware), `next(after:)`, `previous(before:)`, file↔window time. Tests beside `PresentationTimelineTests`.
- **App** `VideoActionsController`: watches `MediaTransportController.rowsVersion`, keeps each playing video's last fired position, aims one timer at the next mark, fires through `controls.actionRouter.execute` with a `video.mark` breadcrumb.
- **SlideScene**: `VideoCountdown.marks` (window-time `(name, at)`), `LinkedText` reads them; Inspector rows in `SlideObjectInspector.textContentSection`.
- **Editor**: `MediaEditorView` timeline card from `TimelineControls` (ruler, `PlayheadLayerView`, pins with the presentation timeline's `pinFace`), Add Video Action at the playhead, drag to move, nudge a frame, double-click edits actions; the inspector's **Video Actions** section lists marks (time · name · actions summary), rename in place, delete.

## 4. Phases

1. Schema + PresenterCore rules + tests.
2. Firing (`VideoActionsController`) + tests; sandbox: a real video fires an alert at its mark.
3. Editor timeline + inspector list.
4. Linked text: Counts To / Direction / Video Action Name + inspector rows + tests.
5. Sandboxed QA with a real video: screenshots of timeline, list, a firing action, timer + title counting live; UX read.

## 5. Answered 2026-10-30

Q1 every pass · Q2 skip (T16) · Q3 same on every layer · Q4 timeline card under the preview · Q5 extend the Video Countdown box (Service Tracking timers not added).

## 6. Built (2026-10-30, on labs)

- **Schema v161**: `VideoMark`, `MediaItem.marks`, `VideoCountdownTarget`, `TextLink.videoTarget/videoMarkName/countsUp`, `TextSourceKind.videoMarkName`.
- **Rules**: PresenterCore `Timeline/VideoMarks.swift`, covering window points (VA4), crossing with jumps, loops, the start grace and a restart from the top (VA5/VA6), targets, the up-count start, the next mark's distance, and edits. Tests in `VideoMarksTests` (11).
- **Room**: `MediaTransportController.fireVideoActions`, run on every transport read (4 Hz poll, play, pause, seek) plus a one-shot timer aimed at the next mark. Actions go through `ActionRouter.execute` and leave a `video.mark` breadcrumb. Reads are saved before actions run, because an action that changes the show re-enters `refresh()` (the first sandbox pass fired one mark 133 times). `VideoCountdown.marks` feeds the boxes.
- **Linked text**: `VideoCountdown.seconds(at:to:name:countsUp:)` and `target(at:_:name:)`. The `videoCountdown` source reads Counts To and Direction. The new `videoMarkName` source ("Video Action Name"). Counting up never reads amber. Editor samples carry a "Band Walk-On" mark. Tests in `LinkedTextTests` (4).
- **Editor**: `Sources/VideoActionsTimeline.swift` (the card: ruler and playhead from `TimelineControls`, a filmstrip decoded off main, marks with names in two rows that shorten when crowded, trim shading, drag to move, a context menu with Edit Actions, Rename, Go Here, Nudge 1 Frame and Remove; the inspector's Video Actions section). `MediaEditorView` hosts the add/edit/rename sheets. Every mark edit is on the app's ⌘Z journal (`MoveUndoJournal`). Typed action edits coalesce.
- **Inspector**: Counts To (End of Video · Next Video Action · Video Action Named…), Action Name, Direction (Down · Up); Video Action Name boxes get Action + Video From.
- **Main thread**: the card's body reads no ticking state. The playhead is drawn by `PlayheadLayerView` leaves, and the "Next: …" readout is one registered leaf (`VideoActionsNextReadout`, 8 Hz while the preview plays). The room's crossing check runs per transport read (4 Hz while a video plays), plus one timer fire per mark.

- **StarterPack stack fix**: `StarterPack.namePlate` had a 404 KB Debug stack frame on labs (four styles inline), and the three new `TextLink` fields tipped it past a swift-testing thread's 512 KB stack (SIGBUS in `StarterPackThemeTests`). Each style is now its own function; the largest StarterPack frame is now 156 KB. Behavior unchanged.
- **Tests**: PresenterCore 1955 + 71 XCTest, SlideScene 388, LocalAPI 33, sweeps included. All pass.

Sandbox QA (QA 31, "Ways to Give" 5:00, Local API driven): every mark fired once, 1–3 ms after its time; a jump from 1:40 to 3:20 over a mark fired nothing; a loop re-fired a 0:01 mark on each of two wraps; a re-fire from the top fired the 0:01 mark; the timer and title counted live in the Output Preview and moved on at the mark; add (Alert at the playhead), drag-move, rename, Edit Actions, Remove and ⌘Z all worked in the real UI.

## 7. UX pass (Cody 2026-10-30, "Build my picks")

- An action mark is named after its target (`VideoMarks.defaultName(forActionLabel:)`): "Fire Alert: Band on Stage" becomes "Band on Stage".
- The card header drops the zoom slider and keeps − / + / Fit (pinch still zooms), so "Next: …" fits a narrow window.
- Present's transport strip shows yellow ticks for the video's marks (`ScrubBar.markFractions`, from `MediaTransportController.Row.marks`) and "· Next: <name> 0:07" beside the video's name.
- Fix for a bug already on labs: Present's elapsed readout (`GoToTimeReadout`) froze while playing. It read `Date()` in its own body, and SwiftUI skipped that body because its inputs never changed. It now takes the strip clock's position as an input.

## 8. Color per action + readout check (Cody 2026-10-30)

- `VideoMark.colorHex` (still v161, not shipped yet; absent = yellow). The list's row has the Settings › Groups color well. The editor's marks, Present's ticks and Present's "Next:" line take the color. A well drag repaints at once and saves once, 0.3 s after the drag rests (one coalesced ⌘Z step).
- Present readout check: the freeze came from 7405217ba1 (main-thread phase 1), which stopped the 4 Hz row rewrite that had also been redrawing the readout. The readout now reads the strip's existing 30 Hz clock; no new clock. Sandbox A/B, Debug build, 30 s of Present playback: labs strip 11.0 / 10.9 CPU-s, this branch 11.7 / 10.5 CPU-s, 0 hitches either way.
