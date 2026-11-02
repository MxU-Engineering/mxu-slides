# Make Slides fixtures

Shared cases for the Make Slides suggester and the planner's split. PresenterCore
tests read every `*.json` here (`MakeSlidesFixturesTests`).

Each file:

| key | what |
|---|---|
| `name`, `about` | the case, in words |
| `mode` | Auto-Mark choice: `pickForMe` (default), `boldLines`, `structure` |
| `options` | `SlideDesignMap.options` (missing keys = defaults): `revealPoints`, `scriptureSplit` (`fitToBox` / `oneVerse`), `verseNumbers`, `blanksBetweenVerses`, `keepUnderlines`, `parenthesesToNotes`, `pictureScale` (`fill` / `fit` / `stretch` / `scaleAndBlur`), `videoEnd` (`next` / `stop` / `loop` / `fadeToBlack` / `fadeToClear`), `picturesTogether` (needs a theme), `ownTypes` (own slide types: `name`, `split` `fitToBox` / `paragraph` / `line`, `reveal`; a mark's `slideType` is the name) |
| `blanks` | blank placement for every passage: `none`, `afterPassage`, `afterSlide` |
| `body` | the note body (`NoteBody`) |
| `suggestions` | the suggested passages in order: `type` (the mark's `slideType`; absent = the planner decides) and `text` (lines joined with `\n`; empty for a picture or video file), `media` (a picture or video's note key: the image `url`, or `hex:` + the attachment's `hexId`) |
| `slides` | the deck made from the suggestions, accepted, with no theme: `kind`, `text` (every box, joined with `\n`), `notes`, `reveal` (lines that each come in on a click), `underlines` (`line`, `column`, `length` in characters), `media` (a picture or video slide's note key), `scale` (a picture's Scale when not Fill) |
| `liveAdds` | once the first deck is made from the suggestions, the new slide-like text the note offers as Adds (`NoteLiveUpdates.candidates`), `type` and `text` as in `suggestions` |

With no theme every slide has one text box, so a reference or attribution is the
last line of `text`, and a box holds 7 lines of 32 characters
(`NoteSlideBuilder.fit`: the renderer's default box, the middle 80% of the
canvas). The planner also measures each slide's words in the box's real font,
splits a part once more when it still doesn't fit and joins neighbours the box
holds together.

Columns and lengths count Swift `Character`s.
