import Testing

@testable import PresenterCore

struct ChordProExportTests {
    private func song() -> Presentation {
        let chart = """
        Amazing Grace
        Key: G

        Verse 1
        G       C         G
        Amazing grace how sweet the sound
             G       D      G
        That saved a wretch like me
        I once was lost
        Was blind

        Tag
        G  D

        Chorus
        G
        My chains are gone
        """
        var presentation = LyricTextImporter.makePresentation(
            chart, linesPerSlide: 2, lyricLines: [])

        if let tag = presentation.sections?.firstIndex(where: { $0.name == "Tag" }) {
            presentation.sections?[tag].name = "Free Worship"
        }
        presentation.ccli = CCLIInfo(songNumber: 4_768_151, author: "Chris Tomlin", copyright: "© 2006 sixsteps Music")
        return presentation
    }

    @Test func writesMetadataSectionsSlidesAndChordsAsTheSongStands() throws {
        var presentation = song()

        let verseIndex = try #require(presentation.slides.firstIndex { $0.objects.first?.text.hasPrefix("Amazing") == true })
        presentation.slides[verseIndex].objects[0].chords?[1].symbol = "Cmaj7"

        let text = ChordProExport.text(for: presentation)

        #expect(text.hasPrefix("{title: Amazing Grace}\n{artist: Chris Tomlin}\n{key: G}\n{copyright: © 2006 sixsteps Music}\n{ccli: 4768151}\n"))
        #expect(text.contains("{start_of_verse: Verse 1}\n[G]Amazing [Cmaj7]grace how [G]sweet the sound\nThat [G]saved a [D]wretch [G]like me\n\nI once was lost\nWas blind\n{end_of_verse}"))
        #expect(text.contains("{start_of_part: Free Worship}\n[G][D]\n{end_of_part}"))
        #expect(text.contains("{start_of_chorus: Chorus}\n[G]My chains are gone\n{end_of_chorus}"))
        #expect(ChordProExport.fileName(for: presentation) == "Amazing Grace.txt", "plain text by default")
        #expect(ChordProExport.fileName(for: presentation, format: .chordPro) == "Amazing Grace.cho")
    }

    @Test func reimportingTheExportRebuildsTheSameSong() {
        let original = song()
        let reimported = LyricTextImporter.makePresentation(ChordProExport.text(for: original), linesPerSlide: 2)

        func shape(_ presentation: Presentation) -> [[String]] {
            let names = Dictionary(uniqueKeysWithValues: (presentation.sections ?? []).map { ($0.id, $0.name) })
            return presentation.slides.compactMap { slide in
                slide.objects.first.map { object in
                    [names[slide.sectionId ?? ""] ?? "", ChordMath.bracketed(object.text, chords: object.chords ?? [])]
                }
            }
        }
        #expect(LyricTextImporter.detectFormat(ChordProExport.text(for: original)) == .chordPro)
        #expect(shape(reimported) == shape(original))
        #expect(reimported.musicKey == "G")
        #expect(reimported.ccli?.songNumber == 4_768_151)
        #expect(reimported.name == "Amazing Grace")
    }

    @Test func flippingAChordLineToLyricsKeepsItAsWords() throws {
        let chart = """
        G       C
        Amazing grace
        A
        song of praise
        """
        #expect(LyricTextImporter.chordChartLines(chart) == ["G       C", "A"])

        let read = LyricTextImporter.makePresentation(chart, linesPerSlide: 4)
        let flipped = LyricTextImporter.makePresentation(chart, linesPerSlide: 4, lyricLines: ["A"])

        let readLyrics = try #require(read.slides.first { !$0.objects.isEmpty }?.objects.first)
        let flippedLyrics = try #require(flipped.slides.first { !$0.objects.isEmpty }?.objects.first)
        #expect(readLyrics.text == "Amazing grace\nsong of praise")
        #expect(flippedLyrics.text == "Amazing grace\nA\nsong of praise")
        #expect(flippedLyrics.chords?.map(\.symbol) == ["G", "C"])
    }

    @Test func reflowStartsFromTheSourceUntilTheSlidesMoveOn() throws {
        var presentation = LyricTextImporter.makePresentation(
            "Verse 1\n[G]Amazing grace\nHow sweet\n\nChorus\n[C]My chains", linesPerSlide: 1)
        let source = try #require(presentation.reflowSource)
        #expect(ChordProExport.reflowSeed(for: presentation) == source)

        let index = try #require(presentation.slides.firstIndex { $0.objects.first?.text == "Amazing grace" })
        presentation.slides[index].objects[0].chords = [ChordPlacement(line: 0, column: 8, symbol: "D")]
        let seed = ChordProExport.reflowSeed(for: presentation)
        #expect(seed == "Verse 1\nAmazing [D]grace\n\nHow sweet\n\nChorus\n[C]My chains")
        #expect(Reflow.build(from: seed, linesPerSlide: 1).slides.contains { $0.objects.first?.chords?.first?.symbol == "D" })
    }
}
