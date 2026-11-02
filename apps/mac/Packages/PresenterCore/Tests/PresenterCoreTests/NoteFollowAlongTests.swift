import Foundation
import Testing
@testable import PresenterCore

private func prose(_ text: String) -> NoteBlock { NoteBlock(type: .paragraph, runs: [NoteRun(text: text)]) }

private func marked(_ text: String, group: String, slideId: String? = nil, type: String? = nil) -> NoteBlock {
    NoteBlock(type: .paragraph, runs: [NoteRun(text: text, slideGroup: group, slideType: type, slideId: slideId)])
}

private func card(_ slideId: String, byHand: Bool = false) -> NoteBlock {
    NoteBlock(type: .slideRef, slide: NoteSlideRef(presentationId: "deck", slideId: slideId, placedByHand: byHand ? true : nil))
}

private func slide(_ id: String, _ texts: String...) -> Slide {
    Slide(id: id, name: "", objects: texts.enumerated().map { SlideObject(id: "\(id)-\($0.offset)", objectKind: .text, name: "Box \($0.offset)", text: $0.element) })
}

private func deck(_ slides: [Slide]) -> Presentation {
    Presentation(id: "deck", name: "Unshakable", presentationKind: .deck, themeId: "t", slides: slides)
}

private func items(_ blocks: [NoteBlock], deck: Presentation?, memory: [NoteMadePassage] = [], parts: [String: [String]] = [:]) -> [NoteFollowAlong.Item] {
    NoteFollowAlong.items(
        body: NoteBody(blocks: blocks, plainText: ""), deck: deck, memory: memory,
        slide: { slot in deck?.slides.first { $0.id == slot.slideId } },
        replan: { group, _ in
            let texts = parts[group.id] ?? [group.text]
            return SlideRow(groupId: group.id, kind: .scripture, linesPerSlide: 4, parts: texts.map { [SlideBox(name: "Box 0", text: $0)] })
        })
}

private func rows(_ item: NoteFollowAlong.Item) -> [NoteFollowAlong.Row] {
    if case .passage(_, _, _, let rows) = item { return rows }
    return []
}

@Test func followAlongReadsProseAndPassagesInNoteOrder() {
    let made = deck([slide("s1", "For God so loved the world")])
    let result = items([
        prose("Intro"), prose("Story"),
        marked("For God so loved the world", group: "g1", slideId: "s1", type: "scripture"),
        card("s1"),
        prose("Close"),
    ], deck: made)
    #expect(result.map(\.id) == ["prose:0", "passage:g1", "prose:4"])
    #expect(result[0].blocks == [0, 1])
    guard case .passage(let groupId, let kind, let blocks, let passageRows) = result[1] else { Issue.record("no passage"); return }
    #expect(groupId == "g1" && kind == "scripture" && blocks == 2 ... 2)

    #expect(passageRows == [NoteFollowAlong.Row(id: "s1", kind: "scripture", words: "For God so loved the world", slides: [.init(presentationId: "deck", slideId: "s1")])])
}

@Test func followAlongPutsEachSlideOnThePartItShowsAndBlanksOnTheirOwnRows() {
    let made = deck([slide("v28", "28 Therefore"), slide("v27", "27 This phrase"), slide("blank"), slide("x", "Edited by hand")])
    let result = items([
        marked("27 This phrase 28 Therefore", group: "g", slideId: "v28"),
        card("v28"), card("v27"), card("blank"), card("x"),
    ], deck: made, parts: ["g": ["27 This phrase", "28 Therefore", "29 For our God"]])
    let passage = rows(result[0])
    #expect(passage.map(\.words) == ["27 This phrase", "28 Therefore", nil, "29 For our God"])
    #expect(passage.map { $0.slides.map(\.slideId) } == [["v27"], ["v28"], ["blank"], ["x"]])
    #expect(passage.map(\.kind) == ["scripture", "scripture", "blank", "scripture"])
    #expect(passage.map(\.id) == ["v27", "v28", "blank", "x"])
}

@Test func followAlongPutsASlideMatchingNoFreePartUnderTheFirstRow() {
    let made = deck([slide("a", "One"), slide("b", "Two"), slide("c", "Three")])
    let result = items([marked("One Two", group: "g", slideId: "a"), card("a"), card("b"), card("c")],
                       deck: made, parts: ["g": ["One", "Two"]])
    #expect(rows(result[0]).map { $0.slides.map(\.slideId) } == [["a", "c"], ["b"]])
}

@Test func followAlongPlacesSlidesTheNoteNeverMadeWhereTheyFallInTheDeck() {
    let made = deck([slide("welcome"), slide("s1", "Title"), slide("between"), slide("s2", "Point"), slide("hand"), slide("end")])
    let result = items([
        prose("Opening"),
        marked("Title", group: "g1", slideId: "s1"), card("s1"),
        prose("Middle"),
        marked("Point", group: "g2", slideId: "s2"), card("s2"),
        card("hand", byHand: true),
    ], deck: made)
    #expect(result.map(\.id) == ["prose:0", "slide:welcome", "passage:g1", "slide:between", "prose:3", "passage:g2", "slide:hand", "slide:end"])
    #expect(result[1] == .slide(.init(presentationId: "deck", slideId: "welcome"), inNote: false))
    #expect(result[6] == .slide(.init(presentationId: "deck", slideId: "hand"), inNote: true))
}

@Test func followAlongPutsEveryDeckSlideAtTheEndOfANoteHoldingNone() {
    let result = items([prose("Just words")], deck: deck([slide("a"), slide("b")]))
    #expect(result.map(\.id) == ["prose:0", "slide:a", "slide:b"])
    #expect(items([prose("Just words")], deck: nil).map(\.id) == ["prose:0"])
}

@Test func followAlongReadsThePassagesMemoryWhenItsCardsAreGone() {
    let made = deck([slide("s1", "Remembered")])
    let memory = [NoteMadePassage(groupId: "g", text: "Remembered", slides: [NoteMadeSlide(slideId: "s1", boxes: [])])]
    let result = items([marked("Remembered", group: "g")], deck: made, memory: memory)
    #expect(result.map(\.id) == ["passage:g"])
    #expect(rows(result[0]).first?.slides.map(\.slideId) == ["s1"])
}

@Test func followAlongReadsPassagesWithNoLivingSlideAsProseAndShowsACardOnce() {
    let made = deck([slide("s1", "Kept")])
    let result = items([
        marked("Not made yet", group: "g0"),
        marked("Gone", group: "g1", slideId: "dead"), card("dead"),
        marked("Kept", group: "g2", slideId: "s1"), card("s1"), card("s1"),
    ], deck: made)
    #expect(result.map(\.id) == ["prose:0", "passage:g2"])
    #expect(result[0].blocks == [0, 1])
    #expect(rows(result[1]).flatMap(\.slides).map(\.slideId) == ["s1"])
}

@Test func followAlongRowsFollowTheRealPlannersVerseSplit() {
    var options = SlideOptions()
    options.scriptureSplit = .oneVerse
    let group = MarkedGroup(id: "g", type: "scripture", text: "Hebrews 12:27–28\n27 This phrase signifies the removing. 28 Therefore, receiving a Kingdom.")
    let row = DeterministicSlidePlanner(options: options).plan([group], theme: nil, overrides: [:]).rows[0]
    let made = row.parts.enumerated().map { index, boxes in
        Slide(id: "v\(index)", name: "", objects: boxes.map { SlideObject(id: UUID().uuidString, objectKind: .text, name: $0.name, text: $0.text) })
    }
    #expect(made.count == 2)
    let result = NoteFollowAlong.items(
        body: NoteBody(blocks: [
            NoteBlock(type: .paragraph, runs: [NoteRun(text: group.text, slideGroup: "g", slideType: "scripture", slideId: "v0")]),
            card("v1"), card("v0"),
        ], plainText: ""),
        deck: deck(made), slide: { slot in made.first { $0.id == slot.slideId } },
        replan: { group, slides in NoteSlideUpdate.replan(group, like: slides, theme: nil, options: options) })
    let passage = rows(result[0])
    #expect(passage.map { $0.slides.map(\.slideId) } == [["v0"], ["v1"]])
    #expect(passage[0].words?.hasPrefix("27 This phrase") == true)
    #expect(passage[1].words?.hasPrefix("28 Therefore") == true)
}

@Test func followAlongLaneNarrowsWithThePanelAndStopsAtItsLimits() {
    #expect(NoteFollowAlong.laneWidth(view: 0) == 160)
    #expect(NoteFollowAlong.laneWidth(view: 200) == 80)
    #expect(NoteFollowAlong.laneWidth(view: 420) == 130)
    #expect(NoteFollowAlong.laneWidth(view: 1400) == 220)
}

@Test func followAlongLinesFlattenPassagesIntoOutlinedRowsAndIndexThem() {
    let made = deck([slide("welcome"), slide("a", "One"), slide("b", "Two")])
    let result = items([prose("Intro"), marked("One Two", group: "g", slideId: "a"), card("a"), card("b")],
                       deck: made, parts: ["g": ["One", "Two"]])
    let lines = NoteFollowAlong.lines(result)
    #expect(lines.map(\.id) == ["prose:0", "slide:welcome", "row:a", "row:b"])
    guard case .row(let kind, _, let first, let last) = lines[2].content, case .row(_, _, let secondFirst, let secondLast) = lines[3].content else {
        Issue.record("no rows"); return
    }

    #expect(kind == "slide" && first && !last && !secondFirst && secondLast)
    let index = NoteFollowAlong.lineIndex(result)
    #expect(index.bySlide == ["welcome": "slide:welcome", "a": "row:a", "b": "row:b"])
    #expect(index.byBlock == [0: "prose:0", 1: "row:a"])
}

@Test func followAlongCallsOnlyEmptyTextSlidesBlank() {
    #expect(NoteFollowAlong.isBlank(slide("b")))
    #expect(NoteFollowAlong.isBlank(slide("b", " ")))
    #expect(!NoteFollowAlong.isBlank(slide("t", "Welcome")))
    var video = slide("v")
    video.objects.append(SlideObject(id: "m", objectKind: .media, name: "Video", text: ""))
    #expect(!NoteFollowAlong.isBlank(video))
}
