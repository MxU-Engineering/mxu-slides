import Foundation
import Testing
@testable import PresenterCore

@Test func wrappedChartLinesRejoinTheLineAbove() {
    let lines = [
        "I cannot describe it",
        "But nothing is brighter",
        "[G]Than this",
        "Out in the open sky",
        "And my heart found the",
        "Most High",
        "It has never been about",
        "Perf[D]ormance only",
        "Everything for the glory",
        "Of Your name",
    ]
    #expect(LyricPhrasing.rejoined(lines, casing: .init(lines.joined(separator: "\n"))) == [
        "I cannot describe it",
        "But nothing is brighter [G]than this",
        "Out in the open sky",
        "And my heart found the Most High",
        "It has never been about perf[D]ormance only",
        "Everything for the glory of Your name",
    ], "\"Than\" lowercases, \"Most High\" keeps its capitals, the chord rides along")
}

@Test func linesThatStandAloneDoNotRejoin() {
    let lines = [
        "The person I was",
        "Before I found the way",
        "Sing it out",
        "Sing it out",
        "Oh",
        "We are going higher than the mountains ever were",
        "Of every nation",
        "This is the end.",
        "Of it",
    ]
    #expect(LyricPhrasing.rejoined(lines, casing: .init("")) == lines,
            "a phrase ending on \"was\", a refrain sung twice, a cry, a join past 45 characters, after a full stop")
}

@Test func shortChartLinesThatStartAPhraseKeepTheChartsBreaks() {

    let verse1 = [
        "[G]Who else would rocks", "Cry out to [G]worship", "[G]Whose glory [C6]taught",
        "The stars to [G]shine", "[C2]Perhaps creation [D]longs", "To [Em]have the [D]words to [C2]sing",
        "[C2]But this [D]joy is [G]mine",
    ]
    #expect(LyricPhrasing.rejoined(verse1, casing: .init(verse1.joined(separator: "\n"))) == verse1)
    #expect(LyricPhrasing.slides(verse1, perSlide: 2).map(\.count) == [2, 2, 2, 1])
    let verse2 = ["Who else would die", "For our redemption", "Whose resurrection", "Means I’ll rise"]
    #expect(LyricPhrasing.rejoined(verse2, casing: .init("")) == verse2, "a short pair sings together")
    let jesus = ["I don’t want anything but You", "You’re more than every dream", "Come true", "All of the things I thought I wanted"]
    #expect(LyricPhrasing.rejoined(jesus, casing: .init(""))[1] == "You’re more than every dream come true")
}

@Test func slidesBreakWherePhrasesEndNotEveryTwoLines() {

    let lines = [
        "We lift our eyes",
        "We see the morning come",
        "Only by grace",
        "We never earned the light",
        "Only by grace",
    ]
    #expect(LyricPhrasing.slides(lines, perSlide: 2) == [
        ["We lift our eyes", "We see the morning come"],
        ["Only by grace"],
        ["We never earned the light", "Only by grace"],
    ])
    #expect(LyricPhrasing.slides(["Walk into the", "Light of day", "Run"], perSlide: 2)
        == [["Walk into the", "Light of day"], ["Run"]], "a slide never ends on \"the\"")
    #expect(LyricPhrasing.slides(["One", "Two"], perSlide: 2) == [["One", "Two"]])
    #expect(LyricPhrasing.slides([], perSlide: 2).isEmpty)
}

@Test func phrasedReflowRejoinsAndSplitsByPhrase() {
    let text = """
    Verse 1
    [D]I cannot describe it
    But nothing is [A]brighter
    Than [G]this
    Out in the open sky
    """
    let phrased = Reflow.parse(text, linesPerSlide: 2, phrased: true)
    #expect(phrased.sections[0].slides == [
        "[D]I cannot describe it\nBut nothing is [A]brighter than [G]this",
        "Out in the open sky",
    ])
    #expect(Reflow.parse(text, linesPerSlide: 2).sections[0].slides.count == 2, "unphrased pairs as written")
    #expect(Reflow.parse(text, linesPerSlide: 2).sections[0].slides[1] == "Than [G]this\nOut in the open sky")
    #expect(Reflow.materialize(text, linesPerSlide: 2, phrased: true) == """
    Verse 1
    [D]I cannot describe it
    But nothing is [A]brighter than [G]this

    Out in the open sky
    """)
}

@Test func typedLyricsKeepTheirBreaksChartsSplitByPhrase() {
    let words = "I cannot describe it\nBut nothing is brighter\nThan this\nOut in the open sky"
    let typed = LyricTextImporter.makePresentation(words, linesPerSlide: 2)
    #expect(typed.slides.compactMap { $0.objects.first?.text } == [
        "I cannot describe it\nBut nothing is brighter", "Than this\nOut in the open sky",
    ], "plain text typed into MxU Slides stays as written")

    let chart = LyricTextImporter.makePresentation("{title: Bright}\n[D]" + words, linesPerSlide: 2)
    #expect(chart.slides.compactMap { $0.objects.first?.text } == [
        "I cannot describe it\nBut nothing is brighter than this", "Out in the open sky",
    ])
    #expect(chart.reflowSource == "Verse 1\n[D]I cannot describe it\nBut nothing is brighter than this\n\nOut in the open sky",
            "Reflow opens on the lines as joined")
    #expect(ChordProExport.reflowSeed(for: chart) == chart.reflowSource)
    #expect(typed.reflowSource == words)
}

@Test func planningCenterLyricsSplitByPhraseButTheCreateSheetsTextStands() {
    let source = PlanLyricsImporter.Source(lyrics: "Verse 1\nI cannot describe it\nBut nothing is brighter\nThan this\nOut in the open sky")
    #expect(PlanLyricsImporter.parse(source, linesPerSlide: 2).sections.last?.slides == [
        "I cannot describe it\nBut nothing is brighter than this", "Out in the open sky",
    ])
    #expect(PlanLyricsImporter.parse(source, linesPerSlide: Reflow.stanzaOnly).sections.last?.slides == [
        "I cannot describe it\nBut nothing is brighter\nThan this\nOut in the open sky",
    ])
}

@Test func lyricsAndChordsDropsLayoutCommandsAndCountsAsASourceOnlyWithChords() {
    let text = "Verse 1\r\n[G]Amazing grace\r\nCOLUMN_BREAK\r\nHow sweet the sound\r\nPAGE_BREAK"
    #expect(PlanLyricsImporter.lyricsAndChordsText(text) == "Verse 1\n[G]Amazing grace\nHow sweet the sound")
    #expect(PlanLyricsImporter.hasChords(text))
    #expect(PlanLyricsImporter.hasChords("G       C\nAmazing grace how sweet"))
    #expect(!PlanLyricsImporter.hasChords("Verse 1\r\n\r\nAmazing grace\r\nHow sweet the sound"))
}

@Test func joinLinesPullsTheNextLineUpAcrossASlideBreak() {
    let text = "Verse 1\nBut nothing is [A]brighter\n\n[G]Than this\nOut in the open sky"
    let caret = ("Verse 1\nBut noth" as NSString).length
    let edit = LyricPhrasing.joinEdit(at: caret, in: text)
    #expect(edit?.location == ("Verse 1\n" as NSString).length)
    #expect(edit?.length == ("But nothing is [A]brighter\n\n[G]Than this" as NSString).length)
    #expect(edit?.replacement == "But nothing is [A]brighter [G]than this")
    #expect(LyricPhrasing.joinEdit(at: 0, in: text) == nil, "a label line never joins")
    #expect(LyricPhrasing.joinEdit(at: (text as NSString).length, in: text) == nil, "nothing after the last line")
    #expect(LyricPhrasing.joinEdit(at: 9, in: "Verse 1\nWords here\nChorus\nMore") == nil, "never into the next section")
}

@Test func reflowSplitsImportedDecksByPhraseButNotTypedOnes() {
    #expect(LyricPhrasing.applies(to: PresentationOrigin(.planningCenterLyrics), text: "Words"))
    #expect(LyricPhrasing.applies(to: PresentationOrigin(.chartFile), text: "Words"))
    #expect(LyricPhrasing.applies(to: PresentationOrigin(.pastedLyrics), text: "[G]Words\n[C]More"))
    #expect(!LyricPhrasing.applies(to: PresentationOrigin(.pastedLyrics), text: "Words\nMore"))
    #expect(!LyricPhrasing.applies(to: PresentationOrigin(.proPresenter), text: "Words"))
    #expect(!LyricPhrasing.applies(to: nil, text: "Words"))
}
