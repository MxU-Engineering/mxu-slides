import Foundation
import Testing
@testable import PresenterCore

private let folder = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().appendingPathComponent("packages/make-slides-fixtures")

private struct Fixture: Decodable {
    struct Suggestion: Codable, Equatable {
        var type: String?
        var text: String
        var media: [String]?
    }

    struct Underline: Codable, Equatable {
        var line: Int
        var column: Int
        var length: Int
    }

    struct Made: Codable, Equatable {
        var kind: String
        var text: String
        var notes: String?
        var reveal: [Int]?
        var underlines: [Underline]?
        var media: String?
        var scale: String?
    }

    var name: String
    var mode: String?
    var options: SlideOptions?
    var blanks: BlankPlacement?
    var suggestions: [Suggestion]
    var slides: [Made]

    var liveAdds: [Suggestion]?
}

func fixtureNoteBody(_ json: [String: Any]) throws -> NoteBody {
    try JSONDecoder().decode(NoteBody.self, from: JSONSerialization.data(withJSONObject: try #require(json["body"])))
}

private func fixtureFiles() -> [URL] {
    ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
        .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
}

@Test func theFixturesFolderHoldsTheUnshakableNote() {
    #expect(fixtureFiles().map(\.lastPathComponent).contains("unshakable.json"))
}

@Test(arguments: fixtureFiles())
func fixtureGivesItsSuggestionsAndSlides(_ file: URL) throws {
    let data = try Data(contentsOf: file)
    let fixture = try JSONDecoder().decode(Fixture.self, from: data)
    let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    let body = try fixtureNoteBody(json)
    let options = fixture.options ?? SlideOptions()

    let suggested = NoteSlideMarks.suggesting(
        body, mode: fixture.mode.flatMap(NoteSlideMarks.SuggestMode.init) ?? .pickForMe, ownTypes: options.ownTypes.map(\.name))
    let groups = NoteSlideMarks.groups(in: suggested)
    #expect(groups.allSatisfy { $0.state == NoteSlideMarks.suggested }, "\(fixture.name)")
    let suggestions = groups.map { Fixture.Suggestion(type: $0.type, text: $0.text, media: $0.media.isEmpty ? nil : $0.media) }
    let gotSuggestions = String(decoding: try JSONEncoder().encode(suggestions), as: UTF8.self)
    #expect(suggestions == fixture.suggestions, "\(fixture.name) suggestions: \(gotSuggestions)")

    let marked = NoteSlideBuilder.groups(in: NoteSlideMarks.acceptingSuggestions(in: suggested))
    let rows = DeterministicSlidePlanner(options: options).plan(marked, theme: nil, overrides: [:]).rows
    let blanks = Dictionary(uniqueKeysWithValues: marked.map { ($0.id, fixture.blanks ?? .none) })
    let built = NoteSlideBuilder.build(SlidePlan(rows: rows), blanks: blanks, blank: .init(), options: options)
    let kinds = Dictionary(uniqueKeysWithValues: rows.map { ($0.groupId, $0.kind.rawValue) })
    let made = built.slides.map { slide in
        let main = slide.objects.first
        return Fixture.Made(
            kind: built.groupBySlideId[slide.id].flatMap { kinds[$0] } ?? SlideKind.blank.rawValue,
            text: slide.objects.map(\.text).joined(separator: "\n"),
            notes: slide.notes,
            reveal: main?.animationSteps.map { $0.compactMap { $0.ranges?.first?.line } },
            underlines: main?.styleRuns.map { $0.map { Fixture.Underline(line: $0.line, column: $0.column, length: $0.length) } },
            media: slide.background.map { NoteMedia.key(ofPendingId: $0.mediaId) ?? $0.mediaId },
            scale: slide.background?.scaleMode?.rawValue)
    }
    let got = String(decoding: try JSONEncoder().encode(made), as: UTF8.self)
    #expect(made == fixture.slides, "\(fixture.name) slides: \(got)")
}

@Test(arguments: fixtureFiles().filter { (try? String(contentsOf: $0, encoding: .utf8))?.contains("\"liveAdds\"") == true })
func aLiveNoteOffersItsAdds(_ file: URL) throws {
    let data = try Data(contentsOf: file)
    let fixture = try JSONDecoder().decode(Fixture.self, from: data)
    let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    let body = try fixtureNoteBody(json)
    let made = NoteSlides.make(body: body, themeId: "", designMap: SlideDesignMap(), theme: { _ in nil })
    let adds = NoteLiveUpdates.candidates(in: made.body, mode: NoteLiveUpdates.buildMode(of: body)).map { candidate in
        Fixture.Suggestion(type: candidate.type, text: candidate.blocks.map { NoteReading.text(of: made.body.blocks[$0]) }.joined(separator: "\n"))
    }
    let got = String(decoding: try JSONEncoder().encode(adds), as: UTF8.self)
    #expect(adds == fixture.liveAdds, "\(fixture.name) live adds: \(got)")
}

@Test func makingFromTheNoteMakesTheDeckTheSheetMakes() throws {
    let data = try Data(contentsOf: folder.appendingPathComponent("slide-markers.json"))
    let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    let body = try fixtureNoteBody(json)
    func look(_ slides: [Slide]) -> [String] {
        slides.map { slide in
            [slide.objects.map(\.text).joined(separator: "\n"), slide.notes ?? "", slide.background.map { NoteMedia.key(ofPendingId: $0.mediaId) ?? $0.mediaId } ?? ""]
                .joined(separator: " | ")
        }
    }

    let made = NoteSlides.make(body: body, themeId: "", designMap: SlideDesignMap(), theme: { _ in nil })
    let marked = NoteSlideBuilder.groups(in: NoteSlideMarks.acceptingSuggestions(in: NoteSlideMarks.AutoMark.pickForMe.marking(body)))
    let sheet = NoteSlideBuilder.build(DeterministicSlidePlanner().plan(marked, theme: nil, overrides: [:]))
    #expect(look(made.newSlides) == look(sheet.slides))
    #expect(NoteSlideMarks.groups(in: made.body).map(\.type) == marked.map(\.type))
    #expect(marked.map(\.type) == ["points", "video", nil, "points", "picture", nil])
}

@Test(arguments: StarterPack.allCases)
func threeWarningsAreOnePointsSlide(_ pack: StarterPack) throws {
    let data = try Data(contentsOf: folder.appendingPathComponent("slide-markers.json"))
    let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    var body = try fixtureNoteBody(json)
    body.blocks += [
        NoteBlock(type: .paragraph, runs: [NoteRun(text: "Slide 8:")]),
        NoteBlock(type: .paragraph, runs: [NoteRun(text: "Three Warnings:")]),
        NoteBlock(type: .list, ordered: false, items: [
            NoteListItem(runs: [NoteRun(text: "\"Don't forget Me when you experience prosperity\" (vs. 12)")]),
            NoteListItem(runs: [NoteRun(text: "Don't fall for the surrounding culture's idols (vs. 14)")]),
            NoteListItem(runs: [NoteRun(text: "Don't test God when hardship comes (vs. 16)")]),
        ]),
    ]
    let marked = NoteSlideBuilder.groups(in: NoteSlideMarks.acceptingSuggestions(in: NoteSlideMarks.AutoMark.pickForMe.marking(body)))
    let warnings = try #require(marked.last)
    #expect(warnings.type == "points")
    let theme = pack.makeTheme()
    let built = NoteSlideBuilder.build(DeterministicSlidePlanner().plan(marked, theme: theme, overrides: [:]))
    let slides = built.slides.filter { built.groupBySlideId[$0.id] == warnings.id }
    #expect(slides.count == 1, "\(pack.title): \(slides.map { $0.objects.map(\.text) })")
    #expect(slides.first?.themeSlideName == "Points")
}

@Test func theRepairGivesThePointsBoxItsFloor() {
    let pack = StarterPack.boldBlocks
    let fresh = pack.makeTheme().slides ?? []
    let stale = fresh.map { slide -> Slide in
        var s = slide
        for i in s.objects.indices where s.objects[i].id == "\(pack.themeID).points.text" {
            s.objects[i].textStyle?.autoShrink = nil
            s.objects[i].textStyle?.minFontSize = nil
        }
        return s
    }
    #expect(stale != fresh)
    #expect(pack.shrinkingPoints(stale) == fresh)
    let chosen = stale.map { slide -> Slide in
        var s = slide
        for i in s.objects.indices where s.objects[i].id == "\(pack.themeID).points.text" { s.objects[i].textStyle?.autoShrink = false }
        return s
    }
    #expect(pack.shrinkingPoints(chosen) == chosen)
}

@Test(arguments: StarterPack.allCases)
func longPointsKeepTheirSizeAndSplit(_ pack: StarterPack) throws {
    let rules = "Backyard Ultra - Rules:\nComplete 4.167 miles, every hour, on the hour.\n"
        + "Warnings given 3, 2, and 1 minute prior to each loop. All competitors must be in the starting corral before the starting whistle.\n"
        + "You win by being the last person standing and must complete an additional loop in order to win outright."
    let theme = pack.makeTheme()
    let built = NoteSlideBuilder.build(DeterministicSlidePlanner().plan([MarkedGroup(id: "r", type: "points", text: rules)], theme: theme, overrides: [:]))
    #expect(built.slides.count >= 2, "\(pack.title): \(built.slides.map { $0.objects.map(\.text) })")
    let box = try #require(theme.slides?.first { $0.name == "Points" }?.objects.first { $0.id == "\(pack.themeID).points.text" })
    var fullSize = box
    fullSize.textStyle?.autoShrink = nil
    for slide in built.slides {
        let words = try #require(slide.objects.first { $0.text.contains("\n") || $0.text.count > 30 }?.text)
        #expect(NoteSlideBuilder.fits(words, in: fullSize, theme: theme), "\(pack.title): fits at 80 pt: \(words)")
    }
}
