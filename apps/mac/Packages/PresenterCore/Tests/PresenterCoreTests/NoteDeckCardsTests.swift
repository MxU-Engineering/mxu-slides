import Foundation
import Testing
@testable import PresenterCore

private func slide(_ id: String, _ text: String = "") -> Slide {
    Slide(id: id, name: "", objects: text.isEmpty ? [] : [SlideObject(id: "\(id)-t", objectKind: .text, name: "Text", text: text)])
}

private func card(_ slideId: String, hand: Bool? = nil, deck: String = "p") -> NoteBlock {
    NoteBlock(type: .slideRef, slide: NoteSlideRef(presentationId: deck, slideId: slideId, placedByHand: hand))
}

private let deck = Presentation(
    id: "p", name: "Message", presentationKind: .deck, themeId: "t", slides: [slide("s1", "One"), slide("s2", "Two"), slide("s3", "Three")])

private let body = NoteBody(blocks: [
    NoteBlock(type: .paragraph, runs: [NoteRun(text: "Intro")]),
    NoteBlock(type: .paragraph, runs: [NoteRun(text: "Point one", slideGroup: "a", slideId: "s1")]),
    card("s1"),
    NoteBlock(type: .paragraph, runs: [NoteRun(text: "Point two", slideGroup: "b", slideId: "s3")]),
    card("s3"),
], plainText: "Intro\nPoint one\nOne\nPoint two\nThree")

@Test func aSlideAddedBetweenMadeSlidesGetsItsCardAfterTheEarlierOne() {
    let synced = NoteDeckCards.syncing(deck: deck, added: ["s2"], removed: [], in: body)
    #expect(synced.blocks.compactMap { $0.slide?.slideId } == ["s1", "s2", "s3"])
    let placed = synced.blocks[3].slide
    #expect(placed?.placedByHand == true && placed?.slideText == "Two" && placed?.slideIndex == 1)
    #expect(synced.plainText.contains("Two"))

    #expect(NoteSlideUpdate.cards(afterGroup: "a", in: synced).map(\.slideId) == ["s1"])
}

@Test func aSlideAheadOfEveryCardedSlideLandsBeforeTheDecksFirstCard() {
    var grown = deck
    grown.slides.insert(slide("s0", "Title"), at: 0)
    let synced = NoteDeckCards.syncing(deck: grown, added: ["s0"], removed: [], in: body)
    #expect(synced.blocks.compactMap { $0.slide?.slideId } == ["s0", "s1", "s3"])
    #expect(synced.blocks[2].slide?.slideId == "s0")
}

@Test func aNoteWithNoCardFromTheDeckTakesTheCardAtTheEnd() {
    let plain = NoteBody(blocks: [NoteBlock(type: .paragraph, runs: [NoteRun(text: "Just text")])], plainText: "Just text")
    let synced = NoteDeckCards.syncing(deck: deck, added: ["s2"], removed: [], in: plain)
    #expect(synced.blocks.count == 2 && synced.blocks.last?.slide?.slideId == "s2")

    let both = NoteDeckCards.syncing(deck: deck, added: ["s2", "s3"], removed: [], in: plain)
    #expect(both.blocks.compactMap { $0.slide?.slideId } == ["s2", "s3"])
}

@Test func aRemovedSlideTakesOnlyItsHandCardAndMadeCardsStay() {
    var withHand = body
    withHand.blocks.insert(card("s2", hand: true), at: 3)
    var shrunk = deck
    shrunk.slides.removeAll { $0.id == "s2" || $0.id == "s3" }
    let synced = NoteDeckCards.syncing(deck: shrunk, added: [], removed: ["s2", "s3"], in: withHand)
    #expect(synced.blocks.compactMap { $0.slide?.slideId } == ["s1", "s3"])

    var other = body
    other.blocks.append(card("s2", hand: true, deck: "q"))
    #expect(NoteDeckCards.syncing(deck: shrunk, added: [], removed: ["s2"], in: other) == other)
}

@Test func theShelfIsTheDecksSlidesWithNoCardInDeckOrder() {
    #expect(NoteDeckCards.unplaced(deck: deck, in: body).map(\.id) == ["s2"])

    var other = body
    other.blocks.append(card("s2", hand: true, deck: "q"))
    #expect(NoteDeckCards.unplaced(deck: deck, in: other).map(\.id) == ["s2"])
    let placed = NoteDeckCards.syncing(deck: deck, added: ["s2"], removed: [], in: body)
    #expect(NoteDeckCards.unplaced(deck: deck, in: placed).isEmpty)
}

@Test func nothingToPlaceReturnsTheBodyUntouched() {
    #expect(NoteDeckCards.syncing(deck: deck, added: ["s1", "zz"], removed: [], in: body) == body)
    #expect(NoteDeckCards.syncing(deck: deck, added: [], removed: ["zz"], in: body) == body)
}
