import Foundation
import Testing
@testable import PresenterCore

private let stacked = NoteBody(blocks: [
    NoteBlock(type: .slideRef, slide: NoteSlideRef(presentationId: "p", slideId: "s1")),
    NoteBlock(type: .paragraph, runs: [NoteRun(text: "First", slideGroup: "a", slideId: "s1")]),
    NoteBlock(type: .slideRef, slide: NoteSlideRef(presentationId: "p", slideId: "s2")),
    NoteBlock(type: .paragraph, runs: [NoteRun(text: "Second", slideGroup: "b", slideId: "s2")]),
    NoteBlock(type: .paragraph, runs: [NoteRun(text: "Third", slideGroup: "c")]),
    NoteBlock(type: .slideRef, slide: NoteSlideRef(presentationId: "p", slideId: "s3")),
    NoteBlock(type: .slideRef, slide: NoteSlideRef(presentationId: "p", slideId: "h1", placedByHand: true)),
], plainText: "")

@Test func passagesMatchThePerGroupReads() {
    let passages = NotePassages(body: stacked)
    #expect(passages.groups == NoteSlideBuilder.groups(in: stacked))
    for group in passages.groups {
        #expect(passages.cards[group.id] == NoteSlideUpdate.cards(afterGroup: group.id, in: stacked), "\(group.id)")
    }
    #expect(passages.cards["c"]?.map(\.slideId) == ["s3"], "a hand-placed card is not the passage's")
}

@Test func aCardFindsItsPassage() {
    let passages = NotePassages(body: stacked)
    #expect(passages.passage(containingSlide: "s2")?.group.id == "b")
    #expect(passages.passage(containingSlide: "s3")?.cards.map(\.slideId) == ["s3"])
    #expect(passages.passage(containingSlide: "h1") == nil)
    #expect(passages.passage(containingSlide: "gone") == nil)
}

@MainActor @Test func theMemoParsesOncePerBody() {
    let memo = NotePassagesMemo()
    for _ in 0 ..< 20 { _ = memo.passages(for: stacked) }
    #expect(memo.parses == 1)

    let reloaded = NoteBody(blocks: stacked.blocks.map { $0 }, plainText: String(stacked.plainText))
    _ = memo.passages(for: reloaded)
    #expect(memo.parses == 1)

    var edited = stacked
    edited.blocks[4].runs = [NoteRun(text: "Third, edited", slideGroup: "c")]
    #expect(memo.passages(for: edited).groups.last?.text == "Third, edited")
    #expect(memo.parses == 2)
}

@Test func panelsReadEachPassagesCardsFromTheOneParse() {
    let panels = NotePanels.panels(in: stacked)
    #expect(panels.first { $0.groupId == "a" }?.cards == [0])
    #expect(panels.first { $0.groupId == "b" }?.cards == [2])
    #expect(panels.first { $0.groupId == "c" }?.cards == [5])
}
