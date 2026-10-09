import Testing

@testable import PresenterCore

struct ChordChartTextTests {
    private let chart = """
    Amazing Grace
    Key: G

    Intro: G  C  G  D

    Verse 1
    G       C         G
    Amazing grace how sweet the sound
         G       D      G
    That saved a wretch like me

    Chorus
    | G  /  / | C  /  / |
    I once was lost
    """

    @Test func chordLinesFoldIntoTheWordsBeneathThem() {
        let inlined = ChordChartText.inlined(chart)

        #expect(inlined.musicKey == "G")
        #expect(inlined.chordCount == 12)
        #expect(inlined.text.contains("[G]Amazing [C]grace how [G]sweet the sound"))
        #expect(inlined.text.contains("That [G]saved a [D]wretch [G]like me"))

        #expect(inlined.text.contains("Intro\n[G][C][G][D]"))
        #expect(inlined.text.contains("I [G]once was l[C]ost"))
        #expect(!inlined.text.contains("Key:"))
    }

    @Test func importedChartLandsCleanTextAndPlacements() throws {
        #expect(LyricTextImporter.detectFormat(chart) == .chordChart)
        let presentation = LyricTextImporter.makePresentation(chart, linesPerSlide: 2)

        #expect(presentation.name == "Amazing Grace")
        #expect(presentation.musicKey == "G")
        let verse = try #require(presentation.slides.first { $0.objects.first?.text.hasPrefix("Amazing") == true })
        let lyrics = try #require(verse.objects.first)
        #expect(lyrics.text == "Amazing grace how sweet the sound\nThat saved a wretch like me")
        #expect(lyrics.chords == [
            ChordPlacement(line: 0, column: 0, symbol: "G"),
            ChordPlacement(line: 0, column: 8, symbol: "C"),
            ChordPlacement(line: 0, column: 18, symbol: "G"),
            ChordPlacement(line: 1, column: 5, symbol: "G"),
            ChordPlacement(line: 1, column: 13, symbol: "D"),
            ChordPlacement(line: 1, column: 20, symbol: "G"),
        ])
    }

    @Test func songSelectChordSheetKeepsChordsAndItsFooter() throws {
        let sheet = """
        Amazing Grace (My Chains Are Gone)

        Verse 1
        G              C          G
        Amazing grace how sweet the sound

        CCLI Song # 4768151
        Chris Tomlin | John Newton | Louie Giglio
        """
        #expect(LyricTextImporter.detectFormat(sheet) == .songSelect)
        let presentation = LyricTextImporter.makePresentation(sheet)
        let lyrics = try #require(presentation.slides.first { !$0.objects.isEmpty }?.objects.first)

        #expect(presentation.ccli?.songNumber == 4_768_151)
        #expect(lyrics.text == "Amazing grace how sweet the sound")
        #expect(lyrics.chords?.map(\.symbol) == ["G", "C", "G"])
    }

    @Test func lyricsAndLabelsAreNeverChordLines() {
        for line in ["Verse 1", "Chorus", "Amazing grace", "Be still", "A mighty fortress", "Oh oh oh"] {
            #expect(ChordChartText.chordTokens(in: line) == nil, "'\(line)'")
        }
        let plain = "Verse 1\nAmazing grace how sweet the sound\nThat saved a wretch like me"
        #expect(LyricTextImporter.detectFormat(plain) == .plainText)
        #expect(ChordChartText.inlined(plain).text == plain)

        #expect(LyricTextImporter.detectFormat("[G]Amazing grace\n[C]How sweet") == .chordPro)
    }

    @Test func chordsPastTheWordsLandAtTheEndInOrder() {
        #expect(ChordChartText.merging([(0, "G"), (12, "C"), (16, "D")], into: "Short") == "[G]Short[C][D]")
    }
}
