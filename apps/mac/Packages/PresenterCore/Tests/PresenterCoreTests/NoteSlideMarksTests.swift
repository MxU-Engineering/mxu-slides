import Foundation
import Testing
@testable import PresenterCore

private func run(_ text: String, group: String? = nil, type: String? = nil, slideId: String? = nil) -> NoteRun {
    NoteRun(text: text, slideGroup: group, slideType: type, slideId: slideId)
}

@Test func groupsFollowTheRunsAcrossBlocksInOrder() {
    let body = NoteBody(blocks: [
        NoteBlock(type: .heading, level: 2, runs: [run("Point one", group: "a", type: "title")]),
        NoteBlock(type: .paragraph, runs: [run("Plain "), run("For God so loved ", group: "b"), run("the world", group: "b", slideId: "s1")]),
        NoteBlock(type: .list, ordered: false, items: [
            NoteListItem(runs: [run("First", group: "c", type: "points")]),
            NoteListItem(runs: [run("Second", group: "c")], blocks: [NoteBlock(type: .paragraph, runs: [run("  nested  ", group: "c")])]),
        ]),
        NoteBlock(type: .quote, blocks: [NoteBlock(type: .paragraph, runs: [run("John 3:16", group: "b")])]),
        NoteBlock(type: .rule),
    ], plainText: "")

    let groups = NoteSlideMarks.groups(in: body)
    #expect(groups.map(\.id) == ["a", "b", "c"])
    #expect(groups[0] == NoteSlideMarks.Group(id: "a", type: "title", slideId: nil, blockIndexes: [0], text: "Point one", shape: .heading))

    #expect(groups[1].text == "For God so loved the world\n\nJohn 3:16")
    #expect(groups[1].blockIndexes == [1, 3] && groups[1].slideId == "s1" && groups[1].type == nil)

    #expect(groups[2].text == "First\nSecond\nnested" && groups[2].blockIndexes == [2] && groups[2].type == "points")
    #expect(NoteSlideMarks.blockIndex(ofGroup: "b", in: body) == 1)
    #expect(NoteSlideMarks.blockIndex(ofGroup: "zz", in: body) == nil)
}

@Test func madeSlidesLandAfterTheirPassagesAndStampTheRuns() {
    let body = NoteBody(blocks: [
        NoteBlock(type: .paragraph, runs: [run("Intro")]),
        NoteBlock(type: .paragraph, runs: [run("First ", group: "a"), run("passage", group: "a")]),
        NoteBlock(type: .paragraph, runs: [run("Between")]),
        NoteBlock(type: .list, ordered: false, items: [NoteListItem(runs: [run("Point", group: "b", type: "points")])]),
    ], plainText: "")
    let ref = { (id: String) in NoteSlideRef(presentationId: "p", slideId: id, slideIndex: 0, slideText: id) }
    let placed = NoteSlideMarks.placingMadeSlides([
        (groupId: "a", refs: [ref("s1"), ref("s2")]),
        (groupId: "b", refs: [ref("s3")]),
        (groupId: "zz", refs: [ref("s9")]),
    ], in: body)

    #expect(placed.blocks.map(\.type) == [.paragraph, .paragraph, .slideRef, .slideRef, .paragraph, .list, .slideRef])
    #expect(placed.blocks[2].slide?.slideId == "s1" && placed.blocks[3].slide?.slideId == "s2" && placed.blocks[6].slide?.slideId == "s3")

    #expect(placed.blocks[1].runs?.map(\.slideId) == ["s1", "s1"])
    #expect(placed.blocks[5].items?[0].runs[0].slideId == "s3" && placed.blocks[5].items?[0].runs[0].slideType == "points")
    #expect(placed.blocks[0].runs?[0].slideId == nil)
    #expect(placed.plainText == "Intro\nFirst passage\ns1\ns2\nBetween\nPoint\ns3")
    #expect(NoteSlideMarks.groups(in: placed).map(\.slideId) == ["s1", "s3"])
}

@Test func markByStructureTakesEveryContentBlockOnceAndLyricsAsOne() {
    let body = NoteBody(blocks: [
        NoteBlock(type: .heading, level: 2, runs: [run("Point one")]),
        NoteBlock(type: .paragraph, runs: [run("Body text")]),
        NoteBlock(type: .rule),
        NoteBlock(type: .list, ordered: false, items: [NoteListItem(runs: [run("First")]), NoteListItem(runs: [run("Second")])]),
        NoteBlock(type: .paragraph, runs: [run("already", group: "keep")]),
        NoteBlock(type: .paragraph, runs: [run("   ")]),
        NoteBlock(type: .slideRef, slide: NoteSlideRef(presentationId: "p", slideId: "s")),
    ], plainText: "")
    let marked = NoteSlideMarks.markingByStructure(body)
    let groups = NoteSlideMarks.groups(in: marked)
    #expect(groups.count == 4)
    #expect(groups.map(\.text) == ["Point one", "Body text", "First\nSecond", "already"])
    #expect(groups.map(\.shape) == [.heading, .paragraph, .list, .paragraph])
    #expect(groups[3].id == "keep", "an existing mark stays as it was")
    #expect(marked.blocks[5].runs?[0].slideGroup == nil, "a blank paragraph is no passage")

    let lyrics = NoteBody(blocks: [
        NoteBlock(type: .paragraph, runs: [run("Verse 1")]),
        NoteBlock(type: .paragraph, runs: [run("Amazing grace")]),
        NoteBlock(type: .paragraph, runs: [run("Chorus")]),
        NoteBlock(type: .paragraph, runs: [run("My chains are gone")]),
    ], plainText: "")
    let song = NoteSlideMarks.groups(in: NoteSlideMarks.markingByStructure(lyrics))
    #expect(song.count == 1 && song[0].text == "Verse 1\nAmazing grace\nChorus\nMy chains are gone")

    let unmarked = NoteSlideMarks.unmarking(group: groups[2].id, in: marked)
    #expect(NoteSlideMarks.groups(in: unmarked).map(\.text) == ["Point one", "Body text", "already"])
}

@Test func slideMarkersMakePassagesAndTheirCardsTakeTheMarkersPlace() {
    let marker = NoteBlock(type: .paragraph, runs: [run("[slide]")])
    let body = NoteBody(blocks: [
        NoteBlock(type: .paragraph, runs: [run("Hey everyone, this is the list for Sunday.")]),
        marker,
        NoteBlock(type: .paragraph, runs: [run("What passage impacted you most?")]),
        marker,
        NoteBlock(type: .paragraph, runs: [run("1. Many voices")]),
        NoteBlock(type: .paragraph, runs: [run("")]),
        NoteBlock(type: .paragraph, runs: [run("2. Not a given")]),
        marker,
        NoteBlock(type: .paragraph, runs: [run("Psalm 1:1-6")]),
    ], plainText: "")

    let marked = NoteSlideMarks.markingByStructure(body)
    let groups = NoteSlideMarks.groups(in: marked)
    #expect(groups.map(\.text) == ["What passage impacted you most?", "1. Many voices\n\n2. Not a given", "Psalm 1:1-6"])
    #expect(marked.blocks[0].runs?[0].slideGroup == nil, "the greeting never reaches a slide")
    #expect(marked.blocks[1].runs?[0].slideGroup == nil, "markers stay markers")

    let ref = { (id: String) in NoteSlideRef(presentationId: "p", slideId: id, slideText: id) }
    let placed = NoteSlideMarks.placingMadeSlides([
        (groupId: groups[0].id, refs: [ref("s1")]),
        (groupId: groups[1].id, refs: [ref("s2"), ref("s3")]),
    ], in: marked)

    #expect(placed.blocks.map(\.type) == [.paragraph, .slideRef, .paragraph, .slideRef, .slideRef, .paragraph, .paragraph, .paragraph, .paragraph, .paragraph])
    #expect(placed.blocks[1].slide?.slideId == "s1" && placed.blocks[3].slide?.slideId == "s2" && placed.blocks[4].slide?.slideId == "s3")
    #expect(NoteSlideMarks.groups(in: placed).map(\.slideId) == ["s1", "s2", nil])
    #expect(NoteSlides.isMarker(placed.blocks[8], marker: "[slide]"))
}

@Test func aCardTakesItsMarkersPlacePastAnAside() {
    let body = NoteBody(blocks: [
        NoteBlock(type: .paragraph, runs: [run("Slide 2:")]),
        NoteBlock(type: .paragraph, runs: [run("(Snoop Dogg video - attached)")]),
        NoteBlock(type: .paragraph, runs: [run("Snoop.mp4", group: "v")]),
    ], plainText: "")
    let placed = NoteSlideMarks.placingMadeSlides([(groupId: "v", refs: [NoteSlideRef(presentationId: "p", slideId: "s1")])], in: body)
    #expect(placed.blocks.map(\.type) == [.paragraph, .slideRef, .paragraph])
    #expect(NoteReading.text(of: placed.blocks[0]) == "(Snoop Dogg video - attached)")
}

@Test func aPassageRewrittenFromTheSheetLandsInItsFirstBlockAndDropsTheRest() {
    let body = NoteBody(blocks: [
        NoteBlock(type: .paragraph, runs: [run("Keep "), run("old first", group: "a", type: "points", slideId: "s1"), run(" tail")]),
        NoteBlock(type: .paragraph, runs: [run("old second", group: "a")]),
        NoteBlock(type: .list, ordered: false, items: [
            NoteListItem(runs: [run("old item", group: "a")]),
            NoteListItem(runs: [run("other item", group: "b")]),
        ]),
        NoteBlock(type: .paragraph, runs: [run("After")]),
    ], plainText: "")
    let edited = NoteSlideMarks.replacingText(ofGroup: "a", with: "New line one\nNew line two", in: body)
    #expect(edited.blocks.count == 3, "the emptied paragraph is gone; the list keeps its other item")
    #expect(edited.blocks[0].runs == [run("Keep "), run("New line one\nNew line two", group: "a", type: "points", slideId: "s1"), run(" tail")])
    #expect(edited.blocks[1].items?.map { $0.runs[0].text } == ["other item"])
    #expect(NoteSlideMarks.groups(in: edited).map(\.text) == ["New line one\nNew line two", "other item"])
    #expect(NoteSlideMarks.replacingText(ofGroup: "zz", with: "x", in: body) == body)
}

@Test func declinedReadsAsUnmarkedAndSuggestionsCountBesideMarks() {
    func state(_ text: String, _ group: String, _ state: String?) -> NoteRun {
        NoteRun(text: text, slideGroup: group, slideState: state)
    }
    var body = NoteBody(blocks: [
        NoteBlock(type: .paragraph, runs: [state("Welcome", "d", NoteSlideMarks.declined)]),
        NoteBlock(type: .paragraph, runs: [state("Grace is a gift", "s1", NoteSlideMarks.suggested)]),
        NoteBlock(type: .paragraph, runs: [state("Romans 5:8", "s2", NoteSlideMarks.suggested)]),
        NoteBlock(type: .paragraph, runs: [run("Closing")]),
    ], plainText: "")

    #expect(NoteSlideMarks.groups(in: body).map(\.id) == ["s1", "s2"])
    #expect(NoteSlideMarks.groups(in: body).allSatisfy { $0.state == NoteSlideMarks.suggested })

    let structured = NoteSlideMarks.markingByStructure(body)
    #expect(structured.blocks[0].runs?[0] == body.blocks[0].runs?[0])
    #expect(structured.blocks[3].runs?[0].slideGroup != nil)

    body.blocks[3].runs = [run("Closing", group: "m")]
    #expect(NoteSlideMarks.groups(in: body).map(\.id) == ["s1", "s2", "m"])
    #expect(NoteSlideMarks.groups(in: body).map(\.state) == [NoteSlideMarks.suggested, NoteSlideMarks.suggested, nil])
    #expect(NoteSlideBuilder.groups(in: body).map(\.id) == ["s1", "s2", "m"])

    let accepted = NoteSlideMarks.acceptingSuggestions(in: body)
    #expect(accepted.blocks.compactMap { $0.runs?[0].slideState } == [NoteSlideMarks.declined])
    #expect(NoteSlideMarks.groups(in: accepted).map(\.id) == ["s1", "s2", "m"])
    let stamped = NoteSlideMarks.stamping(slideId: "x", onGroup: "s1", in: body)
    #expect(stamped.blocks[1].runs?[0].slideState == nil && stamped.blocks[1].runs?[0].slideId == "x")
    let unmarked = NoteSlideMarks.unmarking(group: "d", in: body)
    #expect(unmarked.blocks[0].runs?[0] == run("Welcome"))
    let rematched = NoteSlideMarks.marking(blockIndexes: [2], group: "n", slideId: nil, in: body)
    #expect(rematched.blocks[2].runs?[0] == run("Romans 5:8", group: "n"))
}

@Test func unmarkedBodiesHaveNoGroupsAndIdsMintShort() {
    let body = NoteBody(blocks: [NoteBlock(type: .paragraph, runs: [run("hi"), run("", group: "")])], plainText: "hi")
    #expect(NoteSlideMarks.groups(in: body).isEmpty)
    let id = NoteSlideMarks.mintGroupID()
    #expect(id.count == 6 && id.allSatisfy { $0.isLetter || $0.isNumber })
    #expect(NoteSlideMarks.mintGroupID() != id || NoteSlideMarks.mintGroupID() != id)
    #expect(NoteSlideMarks.SlideType.scripture.label == "Scripture")
}

@Test func aGroupKeepsItsUnderlinedWordsOncePerRunInOrder() {
    var under = NoteRun(text: "reverence", underline: true, slideGroup: "a")
    let space = NoteRun(text: " ", underline: true, slideGroup: "a")
    let body = NoteBody(blocks: [
        NoteBlock(type: .paragraph, runs: [
            run("So we worship with ", group: "a"), under, space,
            NoteRun(text: "and awe", underline: true, slideGroup: "a"), run(" and ", group: "a"),
            NoteRun(text: "joy", underline: true, slideGroup: "a"),
            NoteRun(text: "outside", underline: true),
        ]),
    ], plainText: "")
    #expect(NoteSlideMarks.groups(in: body).first?.underlines == ["reverence and awe", "joy"])
    under.underline = nil
    #expect(NoteSlideMarks.groups(in: NoteBody(blocks: [NoteBlock(type: .paragraph, runs: [under])], plainText: "")).first?.underlines == [])
}
