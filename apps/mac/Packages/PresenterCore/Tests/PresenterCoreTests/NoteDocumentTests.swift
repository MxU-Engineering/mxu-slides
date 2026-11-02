import Foundation
import Testing
@testable import PresenterCore

private let readingBody = NoteBody(blocks: [
    NoteBlock(type: .heading, level: 1, runs: [NoteRun(text: "Grace")]),
    NoteBlock(type: .paragraph, runs: [NoteRun(text: "Grace upon "), NoteRun(text: "grace", bold: true)]),
    NoteBlock(type: .heading, level: 2, runs: [NoteRun(text: "  ")]),
    NoteBlock(type: .list, ordered: false, items: [
        NoteListItem(runs: [NoteRun(text: "Gráce here")], blocks: [NoteBlock(type: .paragraph, runs: [NoteRun(text: "and grace")])]),
    ]),
    NoteBlock(type: .heading, level: 3, runs: [NoteRun(text: "Close")]),
], plainText: "")

@Test func outlineListsNonEmptyHeadings() {
    #expect(NoteReading.outline(readingBody) == [
        NoteReading.OutlineEntry(blockIndex: 0, level: 1, title: "Grace"),
        NoteReading.OutlineEntry(blockIndex: 4, level: 3, title: "Close"),
    ])
}

@Test func findMatchesEveryOccurrenceInsensitively() {
    let hits = NoteReading.matches(in: readingBody, query: "grace")
    #expect(hits == [
        NoteReading.Match(blockIndex: 0, offset: 0),
        NoteReading.Match(blockIndex: 1, offset: 0),
        NoteReading.Match(blockIndex: 1, offset: 11),
        NoteReading.Match(blockIndex: 3, offset: 0),
        NoteReading.Match(blockIndex: 3, offset: 15),
    ])
    #expect(NoteReading.matches(in: readingBody, query: "  ").isEmpty)
}

@LibraryActor @Test func notesIndexByFolderAndPlainTextAndSurviveARebuild() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let library = try Library(rootURL: root)
    defer { try? FileManager.default.removeItem(at: root) }

    let body = NoteBody(blocks: [], plainText: "Amazing grace how sweet")
    var note = LocalNotes.note(name: "Sunday Message", body: body, id: "n1")
    note.folder = "Messages/Sept"
    try library.create(note)

    #expect(try library.index.entries(of: .note).map(\.subkind) == ["Messages/Sept"])
    #expect(try library.index.search("sweet").map(\.id) == ["n1"])

    try library.rebuildIndex()
    #expect(try library.index.entries(of: .note).map(\.name) == ["Sunday Message"])
}

private func deck() -> Presentation {
    Presentation(id: "p1", name: "Sermon", presentationKind: .deck, themeId: "", slides: [
        Slide(id: "s1", name: "One", objects: []),
        Slide(id: "s2", name: "Two", objects: []),
    ])
}

@Test func slideRefsResolveByIdThenIndexAndNameWhatIsMissing() {
    let lookup: (String) -> Presentation? = { $0 == "p1" ? deck() : nil }
    var ref = NoteSlideRef(presentationId: "p1", slideId: "s2", slideIndex: 0)
    #expect(NoteSlides.resolve(ref, presentation: lookup) == .slide(presentation: deck(), slide: deck().slides[1], index: 1))

    ref.slideId = "gone"
    #expect(NoteSlides.resolve(ref, presentation: lookup) == .slide(presentation: deck(), slide: deck().slides[0], index: 0))
    ref.slideIndex = 9
    #expect(NoteSlides.resolve(ref, presentation: lookup) == .missingSlide(presentation: deck()))
    ref.presentationId = "nope"
    #expect(NoteSlides.resolve(ref, presentation: lookup) == .missingPresentation)
    #expect(NoteSlides.resolve(NoteSlideRef(ppIntegrationHexId: "i1"), presentation: lookup) == .notPresenter)
}

@Test func liveSlideFindsItsBlock() {
    let body = NoteBody(blocks: [
        NoteBlock(type: .paragraph, runs: [NoteRun(text: "Read")]),
        NoteBlock(type: .slideRef, slide: NoteSlideRef(presentationId: "p1", slideId: "s1")),
        NoteBlock(type: .slideRef, slide: NoteSlideRef(presentationId: "p1", slideId: "s2")),
    ], plainText: "")
    #expect(NoteSlides.blockIndex(ofLiveSlide: "s2", in: body) == 2)
    #expect(NoteSlides.blockIndex(ofLiveSlide: "s9", in: body) == nil)
}

@Test func aDroppedTileBecomesAFullRef() {
    var presentation = deck()
    presentation.slides[1].objects = [SlideObject(id: "o", objectKind: .text, name: "", text: "Grace upon grace")]
    let ref = NoteSlides.dropRef(presentationId: "p1", slideId: "s2") { $0 == "p1" ? presentation : nil }
    #expect(ref?.slideIndex == 1 && ref?.presentationName == "Sermon" && ref?.slideLabel == "Two")
    #expect(ref?.slideText == "Grace upon grace" && ref?.showThumbnail == true && ref?.showNumber == true)
    #expect(NoteSlides.dropRef(presentationId: "p1", slideId: "nope") { _ in presentation } == nil)
}

@Test func slideMarkersBecomeTheDeckSlidesInOrder() {
    let body = NoteBody(blocks: [
        NoteBlock(type: .paragraph, runs: [NoteRun(text: " [Slide] ")]),
        NoteBlock(type: .paragraph, runs: [NoteRun(text: "Luke 11:27")]),
        NoteBlock(type: .paragraph, runs: [NoteRun(text: "[slide]")]),
        NoteBlock(type: .paragraph, runs: [NoteRun(text: "[slide]")]),
        NoteBlock(type: .heading, level: 2, runs: [NoteRun(text: "[slide]")]),
    ], plainText: "")
    #expect(NoteSlides.markerBlockIndexes(in: body) == [0, 2, 3])

    let placed = NoteSlides.placeSlides(in: body, from: deck())
    #expect(placed.blocks[0].type == .slideRef && placed.blocks[0].slide?.slideId == "s1")
    #expect(placed.blocks[1].runs == [NoteRun(text: "Luke 11:27")])
    #expect(placed.blocks[2].slide?.slideId == "s2" && placed.blocks[2].slide?.slideIndex == 1)
    #expect(placed.blocks[3].type == .paragraph, "more markers than slides: the marker stays")
    #expect(placed.blocks[4].type == .heading, "a heading is never a marker")
    #expect(placed.plainText == "Sermon\nLuke 11:27\nSermon\n[slide]\n[slide]", "placed cards join the search text by their deck name")
}
