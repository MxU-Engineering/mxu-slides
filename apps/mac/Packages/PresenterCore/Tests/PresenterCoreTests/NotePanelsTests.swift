import Foundation
import Testing
@testable import PresenterCore

private func marked(_ text: String, group: String, slideId: String? = nil, type: String? = nil) -> NoteBlock {
    NoteBlock(type: .paragraph, runs: [NoteRun(text: text, slideGroup: group, slideType: type, slideId: slideId)])
}

private func card(_ slideId: String, index: Int, byHand: Bool = false) -> NoteBlock {
    NoteBlock(type: .slideRef, slide: NoteSlideRef(presentationId: "deck", slideId: slideId, slideIndex: index, placedByHand: byHand ? true : nil))
}

private func body(_ blocks: [NoteBlock]) -> NoteBody { NoteBody(blocks: blocks, plainText: "") }

@Test func panelsPairEachPassageWithTheCardsAfterIt() {
    let note = body([
        NoteBlock(type: .paragraph, runs: [NoteRun(text: "Intro")]),
        marked("For God so loved", group: "g1", slideId: "s1"),
        card("s1", index: 0), card("s2", index: 1),
        NoteBlock(type: .paragraph, runs: [NoteRun(text: "Between")]),
        marked("Point one", group: "g2", type: "points"),
    ])
    let panels = NotePanels.panels(in: note)
    #expect(panels.count == 2)
    #expect(panels[0] == NotePanels.Panel(id: "g1", groupId: "g1", made: true, words: 1 ... 1, cards: [2, 3], lines: 1))
    #expect(panels[1] == NotePanels.Panel(id: "g2", groupId: "g2", type: "points", made: false, words: 5 ... 5, cards: [], lines: 1))
}

@Test func handPlacedCardsStandAloneAndNeverJoinAPassage() {
    let note = body([
        marked("Words", group: "g1", slideId: "s1"),
        card("s1", index: 0),
        card("s9", index: 8, byHand: true),
        NoteBlock(type: .paragraph, runs: [NoteRun(text: "Prose")]),
        card("s5", index: 4),
    ])
    let panels = NotePanels.panels(in: note)
    #expect(panels.map(\.id) == ["g1", "card:s9", "card:s5"])
    #expect(panels[0].cards == [1])
    #expect(panels[1].placedByHand && panels[1].words == nil && panels[1].cards == [2])
    #expect(panels[2].cards == [4])
}

@Test func cardsUnderAMarkerBelongToThePassageBelowThemAndNeverTwice() {
    let note = body([
        marked("First passage", group: "g1", slideId: "s1"),
        card("s1", index: 0),
        card("s2", index: 1),
        marked("Second passage", group: "g2", slideId: "s2"),
    ])
    let panels = NotePanels.panels(in: note)
    #expect(panels[0].cards == [1])
    #expect(panels[1].cards == [2])
    #expect(panels[1].firstBlock == 2 && panels[1].lastBlock == 3)
}

@Test func panelLinesCountEveryMarkedLine() {
    let note = body([
        NoteBlock(type: .list, ordered: true, items: [
            NoteListItem(runs: [NoteRun(text: "One", slideGroup: "g")]),
            NoteListItem(runs: [NoteRun(text: "Two", slideGroup: "g")]),
            NoteListItem(runs: [NoteRun(text: "Three", slideGroup: "g")]),
        ]),
    ])
    #expect(NotePanels.panels(in: note).first?.lines == 3)
    #expect(NotePanels.foldedTitle(lines: 3) == "3 lines")
    #expect(NotePanels.foldedTitle(lines: 1) == "1 line")
}

@Test func panelTitlesReadAsRangesWhenTheNumbersRun() {
    #expect(NotePanels.title(slideNumbers: []) == nil)
    #expect(NotePanels.title(slideNumbers: [3]) == "Slide 3")
    #expect(NotePanels.title(slideNumbers: [5, 3, 4]) == "Slides 3 to 5")
    #expect(NotePanels.title(slideNumbers: [3, 7]) == "Slides 3, 7")
}
