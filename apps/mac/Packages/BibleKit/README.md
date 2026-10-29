# Bible tool

Choose **Bible** beside Present, Edit, and Scheduler in the main workspace switcher,
or choose **View → Bible** (⇧⌘B). The built-in World English Bible is available offline.
Lookup, formatting, and slide selection remain in place when switching workspaces.

Enter a passage (`John 3:16–18`, `Psalm 23`, `1 John 4:7`, or `John 3:36–4:2`),
browse by book and chapter, or choose **Search Words**. Offline keyword search requires all
entered words and shows the first 200 results. API.Bible search shows up to 100
results and reports the total available. Select a search result to preview it.
The previous/next verse controls cross chapter and book boundaries. They change the
preview only. Lookup and formatting controls are grouped in the same soft-grey
panel style as the other workspaces, above the generated slide grid. The shared
Output Preview and Service Controls remain on the right (unless explicitly hidden).
Click a card to select it. **Presentation Mode** at the bottom puts the selected
slide live and arms live clicks; while it is on, subsequent card clicks go live.
Turn it off to return to selection-only preparation. Leaving Bible disarms it;
neither action clears existing output. A red outline and LIVE label identify the
slide on air. Looking up or formatting a passage never changes output automatically.

Choose one verse per slide or combine verses. Long passages split at word boundaries.
**Theme** and **Design** always appear. Theme **Built-in** offers Full Screen Dark,
Full Screen Light, and Lower Third designs. A library theme lists designs containing
at least two text blocks. The button beside Design opens **Bible Text Blocks**:

- Assign any theme text block to **Verse**, **Reference**, or **Copyright**.
- Automatic uses matching names (Verse/Reference/Copyright), then unused text
  blocks for Verse/Reference. Copyright never steals another role's block.
- Choose **Small footer at bottom** to bypass the theme's Copyright block.
  This is also the automatic fallback when no Copyright block exists.
- Mapping uses stable block IDs and is remembered separately for each theme/design.
  With unique names, mapped objects inherit geometry and typography from the theme;
  duplicate names snapshot the chosen block's appearance for reliable selection.
- **Short copyright notice** is on by default. NIV/NLT/MSG use a compact notice with
  the actual copyright years and known rights holder from the fetched metadata.
  Unrecognized notices remain unchanged. Full notices remain in Copyright & source
  and saved slide notes. Turn off Short copyright to display the full notice.

For offline translations, Copyright, Translation, and Verse Numbers can be shown or
hidden independently. Online translations keep source attribution. Lookup help stays
visible for every source; a separate caption identifies offline/online access.
Saved and appended slides are ordinary editable MxU presentations. **Save as New Presentation**
and **Add Slides** are the only operations that persist generated Scripture; live
presentation is an in-memory draft held by the show state. Saving without changing
the preview reuses the saved presentation.

## Implementation handoff

- `AppShell.swift` mounts `BibleBrowser` once and hides it outside Bible mode so
  the lookup state survives mode changes. Inactive controls cannot receive input.
- `VolunteerModeLogic` supplies the same workspace choices to the top switcher.
- `BibleRepository` is an actor: decoding/search run away from the UI actor; only
  translation imports write files. Lookup request IDs reject stale async results.
- `BibleSlides` owns word-preserving pagination and slide construction. Rebuilds
  get new draft/slide identities; existing live output is unaffected until clicked.
- `BiblePresentationState` separates selection from explicit live requests. Keep
  this state local to the current session; never persist live-click arming.
- `BibleBrowser.presentSlide` calls `ServiceControls.fire` with a transient full
  presentation and occurrence index for confidence output. It must not call a
  library create/append method. Explicit Save and Add actions own persistence.

## Direct ESV API

Open **Settings → Bible → ESV · Crossway API**. Create your own application at
https://api.esv.org/, enter its application key and choose **Save Key & Connect**.
A small John 11:35 request validates the key before saving it to a separate Keychain
item (`com.example.mxuslides.esv`). ESV from Crossway then appears in the Translation
menu, separately from any ESV edition available through API.Bible. No developer key
or ESV text corpus is bundled. Each Mac needs its own permitted configuration.

Reference, chapter and keyword search use Crossway's current v3 endpoints. The client
uses an ephemeral session, header authentication, rejects redirects, does not log
responses or secrets, and applies the documented minute/hour/day request limits to
its current client session. Crossway also enforces account limits across sessions.
HTML verse markers provide exact verse boundaries; arbitrary digits in text are
never parsed as verse numbers. Formatting/mapping changes use current in-memory
verses and make no HTTP requests.

ESV slides can be saved/appended for weekly preparation. A provenance line in each
slide's notes (`ESV-API-VERSES:`) records the included verse IDs, independent of
pagination and duplicate insertion. Before accepting an ESV lookup or save, the app
checks unique IDs in existing library presentations plus the pending verses against
the 500-verse total and a conservative half-book allowance. The book thresholds are
49% of the bundled 66-book index (capped at 500) to allow for numbering differences;
they are deliberately a little below the stated half-book allowance. Exceeding a
limit shows an explanation; nothing is deleted automatically. Remove older library
presentations manually when they are no longer needed.

This check covers app-tagged library slides, not external exports, backups, edited
notes, or manually pasted Scripture. Users remain responsible for their copies and
Crossway's non-commercial, attribution, redistribution and other conditions:
https://api.esv.org/ and https://www.crossway.org/permissions/.
Full ESV copyright information is visible in Settings and the Bible source disclosure;
ESV identification and the ESV.org link remain available in the workspace.

`ESVClient`, `ESVStorage`, and `ESVSettings` isolate transport, tracked storage and
Keychain/UI responsibilities. Fixtures exercise fabricated text without a live key.
Live credentials and publisher responses must be verified after connecting.

## API.Bible translations

1. Create an application in the [API.Bible dashboard](https://api.bible/dashboard).
   Enable the desired translations for that application and obtain its API key.
   Available editions depend on the account's plan and publisher permissions.
2. Open **Settings → Bible** (also available from **Bible → Translations →
   Online Bible Settings…**). Enter the API key, then **Save Key & Load Bibles**.
   Do not use your account password. No credentials are included in the source.
3. Filter by name, abbreviation, or language and check the Bibles to include.
   Return to Bible and choose one in the existing Translation menu. Online entries
   are marked **API.Bible**. Use the usual reference, chapter, or word search.

The key is validated before replacing a working saved key. It is stored only in
this Mac's Keychain, separately from the app's Local API token. The secret is read
only when an online request is needed, not at app startup. A locally signed rebuild
may cause macOS to ask permission to access that Keychain item. Keys do not travel
with the `.app`; configure each Mac separately. **Remove API Key** deletes it.

Formatting changes (pagination, verse numbers, theme, design and style) rebuild
slides from the current passage held in the Bible view's memory. They make no HTTP
requests and do not write a Scripture cache. A new lookup, translation change or
previous/next navigation fetches text; an expired metadata cache can add metadata
requests. Only explicit Save/Add actions persist the resulting library slides.

Online Bibles require internet. Passages are fetched on demand and are not written
to a disk cache or downloaded as a complete translation. API.Bible's 200-verse
passage limit is enforced; use smaller ranges when needed. References currently use
English book names/aliases and the 66 standard book IDs even for other languages.
Grouped verse labels (for example, 16–18) and partial verse labels (16a) are
preserved. One verse per slide means one source text unit; grouped text is never
invented as separate individual verses. If a same-chapter single/range lookup
returns missing or empty content, the tool requests that chapter and keeps the
complete units overlapping the requested range. Unknown/malformed IDs still fail
explicitly rather than silently mislabeling text.
Short publisher translation/copyright attribution stays on API.Bible slides; the existing
visibility toggles continue to work for offline translations. Locking both visibility controls
is this tool's conservative default, not a claim that the full copyright paragraph
must appear on every slide in all circumstances. API.Bible's Terms §7 require source
identification in context and full linked copyright information in the app; Appendix A
allows shortened notices when space is limited. Publisher-specific agreements may
have additional requirements. Any future attribution layout must preserve those
requirements across both previews and outputs. Saving/appending
slides explicitly creates normal library documents, subject to your edition's license.
API.Bible receives anonymous preview reports via its documented FUMS endpoint:
response token plus random device/session IDs, without an API key or user identity.

`BibleAPIClient` is an actor with an injectable HTTP transport for fixture tests.
It uses `https://rest.api.bible/v1`, header authentication, an ephemeral URLSession,
and refuses redirects. Structured JSON text nodes preserve nested verse text and
boundaries while omitting titles, verse number markers, and footnotes. HTTP errors
are translated into safe messages without logging the response body or key.
`BibleAPISettings` handles Keychain, metadata-only preferences and selected IDs;
`BibleBrowser` rejects stale async results and combines offline/online sources.
Changing settings or fetching text never fires a slide or saves a presentation.

Tests use fabricated responses and no credentials. Live account access, the Bibles
returned by your application, and publisher-specific responses must be checked
with your own key after setup.

Official references: [Bibles](https://docs.api.bible/guides/bibles/),
[Content formats](https://docs.api.bible/resources/content-output-formats/),
[Fair Use](https://docs.api.bible/resources/fair-use/).

## Additional offline translations

Use **Translations → Import Bible JSON…**. You must have permission for the text's
storage and use. Installing a file does not obtain a publisher license. No NIV,
NLT, or ESV texts or credentials are bundled. Proprietary
ProPresenter Bible packages are not supported.

Use **Export Import Example…** for a readable sample, or follow this structure:

```json
{
  "formatVersion": 1,
  "id": "MY-BIBLE",
  "name": "My Bible Translation",
  "language": "en",
  "copyright": "The publisher's required copyright notice",
  "source": "Optional source or publisher URL",
  "verses": [
    { "book": "GEN", "chapter": 1, "verse": 1, "text": "In the beginning, God created the heavens and the earth." }
  ]
}
```

`book` uses the standard three-character USFM identifier: `GEN`, `EXO`, `PSA`,
`MAT`, `MRK`, `LUK`, `JHN`, `1JN`, etc. See `BibleBook.all` for all 66 accepted IDs.
Partial translations are supported. Empty/duplicate verses, unknown books,
unsupported format versions, unsafe IDs, and oversized files are rejected.
IDs can contain letters, numbers, `-`, and `_`. Use `NIV`, `NLT`, or `ESV` when
importing an authorized edition with that abbreviation. An existing translation
cannot be overwritten; use a distinct ID for another edition.

Imported files are stored on this Mac at
`~/Library/Application Support/MxU Slides/Bibles/`. Transfer them separately to
another Mac as permitted by the translation's license. The bundled WEB Bible travels
with the app. Imported translations are not automatically uploaded or synced.

## Bundled WEB source

Publisher: https://ebible.org/Scriptures/details.php?id=engwebp

Source download: https://ebible.org/Scriptures/engwebp_vpl.zip

Edition: World English Bible Updated, American English, 66 books (without the
Deuterocanon/Apocrypha). The source contains 31,098 nonempty verses. Five empty
verse slots in the source are omitted; no replacement verse wording is invented.
Verse text is retained verbatim in the bundled JSON. Book IDs are normalized from
the publisher's BibleWorks codes to USFM codes. Pagination normalizes whitespace
for display while preserving words and punctuation.

The World English Bible text is public domain. The name World English Bible is a
trademark and identifies the unaltered publisher's text.

Original `engwebp_vpl.txt` SHA-256:
`8e37aaeba2f2c9fef4dad826bfe355f967c20288f4e0650f742cc6d7bfb775db`

Regenerate from the downloaded archive with:

```sh
python3 apps/mac/scripts/prepare-web-bible.py /path/to/engwebp_vpl.zip
```

Run lookup, import, pagination, attribution, and layout tests with:

```sh
swift test --package-path apps/mac/Packages/BibleKit
```
