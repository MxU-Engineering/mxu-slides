import Foundation
import Testing
@testable import PresenterCore

@Test func labelLinesAreDetectedInEveryPastedShape() {
    #expect(Reflow.labelName(of: "Verse 1") == "Verse 1")
    #expect(Reflow.labelName(of: "CHORUS") == "Chorus")
    #expect(Reflow.labelName(of: "[Bridge]") == "Bridge")
    #expect(Reflow.labelName(of: "chorus:") == "Chorus")
    #expect(Reflow.labelName(of: "  Pre-Chorus 2  ") == "Pre-Chorus 2")
    #expect(Reflow.labelName(of: "Point 3") == "Point 3", "sermon notes are presentations too")

    #expect(Reflow.labelName(of: "The chorus of creation sings") == nil)
    #expect(Reflow.labelName(of: "Verse 1 tells the story") == nil)
    #expect(Reflow.labelName(of: "") == nil)
}

@Test func labeledLyricsParseIntoSectionsAndChunks() {
    let text = """
    Verse 1
    Amazing grace how sweet the sound
    That saved a wretch like me
    I once was lost but now am found
    Was blind but now I see

    Chorus
    My chains are gone
    I've been set free
    """
    let result = Reflow.parse(text, linesPerSlide: 2)
    #expect(result.sections.map(\.name) == ["Verse 1", "Chorus"])
    #expect(result.sections[0].slides == [
        "Amazing grace how sweet the sound\nThat saved a wretch like me",
        "I once was lost but now am found\nWas blind but now I see",
    ])
    #expect(result.sections[1].slides.count == 1)
    #expect(result.order == [0, 1])
}

@Test func repeatedBareLabelRepeatsTheSectionWithoutDuplicating() {
    let text = """
    Verse 1
    Line one
    Line two

    Chorus
    Sing it out

    Verse 2
    Line three

    Chorus
    """
    let result = Reflow.parse(text, linesPerSlide: 2)
    #expect(result.sections.map(\.name) == ["Verse 1", "Chorus", "Verse 2"])
    #expect(result.order == [0, 1, 2, 1], "the second Chorus re-enters the first")

    let built = Reflow.build(from: text, linesPerSlide: 2)
    #expect(built.arrangement != nil, "repeats need an arrangement")
    #expect(built.arrangement?.sectionIds.count == 4)
    #expect(built.slides.count == 3, "slides are never duplicated")
}

@Test func repeatedLabelWithIdenticalContentMerges() {
    let text = """
    Chorus
    Sing it out

    Verse 1
    A line

    Chorus
    Sing it out
    """
    let result = Reflow.parse(text, linesPerSlide: 2)
    #expect(result.sections.map(\.name) == ["Chorus", "Verse 1"])
    #expect(result.order == [0, 1, 0])
}

@Test func unlabeledStanzasBecomeVerses() {
    let text = """
    First stanza line one
    First stanza line two

    Second stanza line one
    """
    let result = Reflow.parse(text, linesPerSlide: 2)
    #expect(result.sections.map(\.name) == ["Verse 1", "Verse 2"])
    #expect(result.order == [0, 1])
}

@Test func stanzasStayInTheirLabeledSectionWhenLabelsExist() {

    let text = """
    Chorus
    Stanza one line

    Stanza two line
    """
    let result = Reflow.parse(text, linesPerSlide: 4)
    #expect(result.sections.map(\.name) == ["Chorus"])
    #expect(result.sections[0].slides == ["Stanza one line", "Stanza two line"],
            "a slide never spans a stanza boundary, even under a generous chunk size")
}

@Test func chunkingRespectsLinesPerSlide() {
    let five = "Verse 1\nl1\nl2\nl3\nl4\nl5"
    #expect(Reflow.parse(five, linesPerSlide: 2).sections[0].slides == ["l1\nl2", "l3\nl4", "l5"])
    #expect(Reflow.parse(five, linesPerSlide: 4).sections[0].slides == ["l1\nl2\nl3\nl4", "l5"])
    #expect(Reflow.parse(five, linesPerSlide: 0).sections[0].slides.count == 5, "floor of 1")
}

@Test func builtSlidesWireSectionsAndThemeCategory() {
    let built = Reflow.build(from: "Verse 1\nA\nB\n\nChorus\nC", linesPerSlide: 2)
    #expect(built.sections.count == 2)
    #expect(built.slides.count == 2)
    #expect(built.slides[0].sectionId == built.sections[0].id)
    #expect(built.slides[1].sectionId == built.sections[1].id)
    #expect(built.slides.allSatisfy { $0.themeSlideName == "Lyrics" })
    #expect(built.slides[0].objects.count == 1)
    #expect(built.slides[0].objects[0].textStyle == nil, "fully theme-inherited")
    #expect(built.arrangement == nil, "no repeats → base order is enough")
}

@Test func aReflowKeepsTheDeckLyricDesign() {
    let built = Reflow.build(from: "Verse 1\nA\nB", linesPerSlide: 2, themeSlideName: "Lower Third")
    #expect(built.slides.allSatisfy { $0.themeSlideName == "Lower Third" })
    #expect(Reflow.lyricDesign(of: built.slides) == "Lower Third")
    #expect(Reflow.lyricDesign(of: []) == "Lyrics")
}

@Test func extraLabelsReadAsSectionsAndTheWiderVocabularyLands() {
    let text = """
    Vamp Out
    Oh oh oh

    [Half Chorus]
    Praise Him
    """
    let parsed = Reflow.parse(text, linesPerSlide: 2, extraLabels: ["Vamp Out"])
    #expect(parsed.sections.map(\.name) == ["Vamp Out", "Half-Chorus"])

    #expect(Reflow.parse(text, linesPerSlide: 2).sections.map(\.name) == ["Verse 1", "Half-Chorus"])
}

@Test func materializeWritesTheSlideBreaksIntoTheText() {
    let text = """
    Chorus
    a
    b
    c

    d
    e

    Turnaround

    Bridge
    f
    g
    h
    i
    """
    let split = Reflow.materialize(text, linesPerSlide: 2)
    #expect(split == "Chorus\na\nb\n\nc\n\nd\ne\n\nTurnaround\n\nBridge\nf\ng\n\nh\ni")

    let parsed = Reflow.parse(split, linesPerSlide: Reflow.stanzaOnly)
    #expect(parsed.sections.map(\.slides) == [["a\nb", "c", "d\ne"], [], ["f\ng", "h\ni"]])

    #expect(Reflow.materialize(split, linesPerSlide: 3, mergeStanzas: true)
        == "Chorus\na\nb\nc\n\nd\ne\n\nTurnaround\n\nBridge\nf\ng\nh\n\ni")
}

@Test func repeatLinesAreTheLabelAlone() {
    #expect(Reflow.labelName(of: "REPEAT BRIDGE") == "Bridge")
    let parsed = Reflow.parse("Bridge\na\n\nTag\nb\n\nREPEAT BRIDGE", linesPerSlide: 2)
    #expect(parsed.sections.map(\.name) == ["Bridge", "Tag"])
    #expect(parsed.order == [0, 1, 0])
}

@Test func openingOnBlankLeadsWithAnIntroWhenTheTextHasNone() {
    let parsed = Reflow.parse("Verse 1\nAmazing grace\n\nChorus\nMy chains\n\nChorus\n", linesPerSlide: 2)
    let opened = parsed.openingOnBlank()
    #expect(opened.sections.map(\.name) == ["Intro", "Verse 1", "Chorus"])
    #expect(opened.sections[0].slides == [""])

    #expect(opened.order == [0, 1, 2, 2])
}

@Test func openingOnBlankIsNamedBlankWhenTheTextHasAWordedIntro() {
    let parsed = Reflow.parse("Intro\nOh oh oh\n\nVerse 1\nAmazing grace", linesPerSlide: 2)
    let opened = parsed.openingOnBlank()
    #expect(opened.sections.map(\.name) == ["Blank", "Intro", "Verse 1"])
    #expect(opened.sections[1].slides == ["Oh oh oh"])
    #expect(Reflow.isIntro("Intro 2"))
    #expect(!Reflow.isIntro("Introduction"))
}

@Test func openingOnBlankFillsAnEmptyLeadingIntro() {
    let parsed = Reflow.parse("Intro\n\nVerse 1\nAmazing grace", linesPerSlide: 2)
    let opened = parsed.openingOnBlank()

    #expect(opened.sections.map(\.name) == ["Intro", "Verse 1"])
    #expect(opened.sections[0].slides == [""])
    #expect(opened.order == [0, 1])
}

@Test func openingOnBlankLeavesEmptyTextEmpty() {
    #expect(Reflow.parse("", linesPerSlide: 2).openingOnBlank() == Reflow.ParseResult())
}

@Test func buildTurnsAnEmptySlideEntryIntoAnObjectlessSlide() {
    let built = Reflow.build(Reflow.parse("Verse 1\nAmazing grace", linesPerSlide: 2).openingOnBlank())
    #expect(built.sections.map(\.name) == ["Intro", "Verse 1"])
    #expect(built.slides.count == 2)
    #expect(built.slides[0].objects.isEmpty)
    #expect(built.slides[0].sectionId == built.sections[0].id)
    #expect(built.slides[0].themeSlideName == "Lyrics")
    #expect(built.slides[1].objects.map(\.text) == ["Amazing grace"])
    #expect(built.arrangement == nil)
}
