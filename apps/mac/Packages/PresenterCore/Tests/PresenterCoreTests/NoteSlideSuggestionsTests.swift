import Foundation
import Testing
@testable import PresenterCore

private func para(_ text: String, bold: Bool? = nil, group: String? = nil, state: String? = nil) -> NoteBlock {
    NoteBlock(type: .paragraph, runs: [NoteRun(text: text, bold: bold, slideGroup: group, slideState: state)])
}

private func suggested(_ blocks: [NoteBlock], mode: NoteSlideMarks.SuggestMode = .pickForMe) -> [NoteSlideMarks.Group] {
    NoteSlideMarks.groups(in: NoteSlideMarks.suggesting(NoteBody(blocks: blocks, plainText: ""), mode: mode))
}

@Test func runSheetAndMediaLinesAreNotSuggested() {
    for line in ["Intro: the earthquake", "Introduction", "Illustration – the bridge", "Offering", "Closing prayer, band up",
                 "Opening Prayer", "Video: Sarah (2:40)", "Pictures of the build", "Photos of camp", "Announcements"] {
        #expect(NoteSlideMarks.isRunSheet(line), Comment(rawValue: line))
    }
    for line in ["Prayer is our lifeline", "Introspection matters", "Videos teach us"] {
        #expect(!NoteSlideMarks.isRunSheet(line), Comment(rawValue: line))
    }
    #expect(suggested([para("Video: Sarah"), para("(Stand for the reading)"), para("https://example.com/clip")]).isEmpty)
}

@Test func suggestionsAreSuggestedWithTheirKindAndNeverTouchAMarkedBlock() {
    let groups = suggested([
        para("“Be still.” — Psalm 46"),
        para("A thought", group: "x", state: NoteSlideMarks.declined),
        para("God is faithful."),
    ])
    #expect(groups.map(\.text) == ["“Be still.” — Psalm 46", "God is faithful."])
    #expect(groups.map(\.type) == ["quote", nil] && groups.allSatisfy { $0.state == NoteSlideMarks.suggested })

    let once = NoteSlideMarks.suggesting(NoteBody(blocks: [para("God is faithful.")], plainText: ""))
    #expect(NoteSlideMarks.suggesting(once) == once)
}

@Test func boldLinesOnlyWhenTheNoteMixesThemUnlessTheModeSays() {
    let mixed = [para("Here is the plan."), para("One", bold: true), para("talk"), para("Two", bold: true),
                 para("John 3:16 – For God so loved"), para("more talk")]
    #expect(suggested(mixed).map(\.text) == ["One", "Two", "John 3:16 – For God so loved"])
    #expect(suggested(mixed, mode: .structure).count == 6)

    let oneBold = [para("Here is the plan."), para("One", bold: true), para("talk"), para("more talk")]
    #expect(suggested(oneBold).count == 4)
    #expect(suggested(oneBold, mode: .boldLines).map(\.text) == ["One"])
}

@Test func boldLinesOnlyKeepsTheTitleWithItsPlainSubtitle() {
    let groups = suggested([
        NoteBlock(type: .heading, level: 1, runs: [NoteRun(text: "Unshakable", bold: true)]),
        para("Hebrews 12:25–29 · Kingdom Come, week 4"),
        para("Intro: the earthquake"),
        para("Everything that can be shaken will be shaken", bold: true),
        para("Talk about 2020"),
        para("What God builds can’t be shaken", bold: true),
    ])
    #expect(groups.first?.type == "title")
    #expect(groups.first?.text == "Unshakable\nHebrews 12:25–29 · Kingdom Come, week 4")
    #expect(groups.dropFirst().map(\.text) == ["Everything that can be shaken will be shaken", "What God builds can’t be shaken"])
}

@Test func aReferenceJoinsItsVerseAndATitleItsShortLine() {
    let groups = suggested([
        NoteBlock(type: .heading, level: 1, runs: [NoteRun(text: "Rooted")]),
        para("Colossians 2 · week 3"),
        para("For God so loved the world"),
        para("John 3:16"),
        para("Romans 8:28"),
    ])
    #expect(groups.map(\.text) == ["Rooted\nColossians 2 · week 3", "For God so loved the world\nJohn 3:16", "Romans 8:28"])
    #expect(groups.map(\.type) == ["title", "scripture", "scripture"])
}

@Test func slideMarkersMakeTheSuggestions() {
    let groups = suggested([
        para("Hi team, here are Sunday's slides"),
        para("[slide]"), para("Grace is enough"), para("It always was"),
        para("[slide]"), para("John 3:16 – For God so loved"),
    ])
    #expect(groups.map(\.text) == ["Grace is enough\nIt always was", "John 3:16 – For God so loved"])
    #expect(groups.map(\.type) == [nil, "scripture"])
}

@Test func slideLabelLinesAreMarkers() {
    let markers = ["Slide", "Slide:", "Slide 1", "slide 3:", "SLIDE 4", "Slide #5 -", "Slides:", "Slide 10: (photo attached)", "[slide]"]
    #expect(markers.allSatisfy { NoteSlides.isMarker(para($0), marker: NoteSlides.defaultMarker) })
    #expect(!["Slide 1: Welcome", "Slides are ready", "Slideshow"].contains { NoteSlides.isMarker(para($0), marker: NoteSlides.defaultMarker) })
    #expect(!NoteSlideMarks.isVideoFileLink(para("Snoop.mp4")))
    #expect(suggested([para("Slide 2:"), para("Snoop.mp4")]).map(\.type) == [nil])
}

@Test func oneLineMarkersMakeSlidesOfTheirWords() {
    #expect(NoteSlides.inlineMarkerLabelLength(para("Slide 1: Welcome to Grace Church")) == 9)
    #expect(NoteSlides.inlineMarkerLabelLength(para("SLIDE: God is good")) == 7)
    let words = ["Slide into home plate", "the slide 3 we saw", "Slide 1 Welcome", "Slide 10: (photo attached)", "Slide 2:"]
    #expect(words.allSatisfy { NoteSlides.inlineMarkerLabelLength(para($0)) == nil })

    let marked = NoteSlideMarks.suggesting(NoteBody(blocks: [
        para("Hi team"), NoteBlock(type: .paragraph, runs: [NoteRun(text: "Slide 1: "), NoteRun(text: "Welcome", bold: true), NoteRun(text: " to Grace Church")]),
        para("Slide 2: Grace is enough"),
    ], plainText: ""))
    #expect(NoteSlideMarks.groups(in: marked).map(\.text) == ["Welcome to Grace Church", "Grace is enough"])
    #expect(marked.blocks[1].runs?.first?.slideGroup == nil, "the label stays the speaker's")
    #expect(marked.blocks[2].runs?.map(\.text) == ["Slide 2: ", "Grace is enough"])
}

@Test func pastedNotesGetTheirTitleAndTheirNumberedPoints() {
    let groups = suggested([
        para("Unshakable"),
        para("Hebrews 12 · week 4"),
        para("1. Everything that can be shaken will be"),
        para("2. What God builds can’t be shaken"),
        para("God is faithful."),
    ])
    #expect(groups.map(\.text) == [
        "Unshakable\nHebrews 12 · week 4",
        "1. Everything that can be shaken will be\n2. What God builds can’t be shaken",
        "God is faithful.",
    ])
    #expect(groups.map(\.type) == ["title", "points", nil])

    #expect(suggested([para("Today we begin a new series.")]).map(\.type) == [nil])
}

@Test func theSelectionBarGuessesByTheSuggestersLadder() {
    #expect(NoteSlideMarks.guessedType(of: "Psalm 46:1 – God is our refuge and strength", shape: .paragraph) == "scripture")
    #expect(NoteSlideMarks.guessedType(of: "“Faith is trusting God.” — Corrie ten Boom", shape: .paragraph) == "quote")
    #expect(NoteSlideMarks.guessedType(of: "Unshakable", shape: .heading) == "title")
    #expect(NoteSlideMarks.guessedType(of: "God is our refuge\nGod is our strength", shape: .list) == "points")
    #expect(NoteSlideMarks.guessedType(of: "We were living in Santa Cruz, and the first thing I remember is the sound of the sea.", shape: .paragraph) == nil)
    #expect(NoteSlideMarks.guessedType(of: "https://example.com/clip", shape: .paragraph) == "media")
}

@Test func theSelectionBarPutsTheGuessFirstAndNeverTwice() {
    let scripture = NoteSlideMarks.selectionBarKinds(guess: "scripture")
    #expect(scripture.shown == ["scripture", "points", "quote", "title"])
    #expect(scripture.more == ["lyrics", "body", "media"])
    let slide = NoteSlideMarks.selectionBarKinds(guess: nil)
    #expect(slide.shown == [nil, "points", "scripture", "quote", "title"])
    #expect(slide.more == ["lyrics", "body", "media"])
    #expect(NoteSlideMarks.selectionBarKinds(guess: "media").more == ["lyrics", "body"])
    #expect([nil, "points", "scripture", "body"].map(NoteSlideMarks.selectionBarLabel) == ["Slide", "Point", "Scripture", "Statement"])

    #expect(NoteSlideMarks.SlideType.body.label == "Statement" && NoteSlideMarks.SlideType.textKinds.first == .body)
    #expect(DeterministicSlidePlanner.kind(ofDesignNamed: "Statement") == .body)
}

@Test func autoMarkWritesItsModesSuggestionsOrNothing() {
    let body = NoteBody(blocks: [para("Here is the plan."), para("One", bold: true), para("talk"), para("Two", bold: true)], plainText: "")
    #expect(NoteSlideMarks.AutoMark.nothing.marking(body) == body)
    for choice in [NoteSlideMarks.AutoMark.pickForMe, .boldLines, .structure] {
        let mode = NoteSlideMarks.SuggestMode(rawValue: choice.rawValue)!
        #expect(NoteSlideMarks.groups(in: choice.marking(body)).map(\.text)
                == NoteSlideMarks.groups(in: NoteSlideMarks.suggesting(body, mode: mode)).map(\.text))
    }
    #expect(NoteSlideMarks.AutoMark.allCases.map(\.title) == ["Pick for me", "Bold lines only", "By structure", "Nothing"])
}

@Test func aLineLabelledWithAnOwnTypesNameIsThatType() {
    let own = ["Announcement", "Video"]
    let groups = NoteSlideMarks.groups(in: NoteSlideMarks.suggesting(NoteBody(blocks: [
        NoteBlock(type: .heading, runs: [NoteRun(text: "Family Sunday")]),
        para("announcement: Camp signups close Friday"),
        para("Video: Sarah (2:40)"),
        para("Psalm 46:1"),
        para("Announcement: Bring a friend"),
        para("Next step: Write it down."),
    ], plainText: ""), ownTypes: own))
    #expect(groups.map(\.type) == ["title", "Announcement", "Video", "scripture", "Announcement", "points"])
    #expect(groups.map(\.blockIndexes) == [[0], [1], [2], [3], [4], [5]], "never a title's subtitle, never a reference's verse")
    #expect(suggested([para("Video: Sarah (2:40)")]).isEmpty, "a run-sheet line without the type")
    #expect(NoteSlideMarks.guessedType(of: "Announcement: Camp", shape: .paragraph, ownTypes: own) == "Announcement")
    #expect(NoteSlideMarks.guessedType(of: "Announcement: Camp", shape: .paragraph) == "points")
    #expect(NoteSlideMarks.selectionBarKinds(guess: "Announcement", ownTypes: own).more == ["lyrics", "body", "media", "Video"])
    #expect(NoteSlideMarks.selectionBarLabel("Announcement") == "Announcement" && NoteSlideMarks.selectionBarLabel("body") == "Statement")
}
