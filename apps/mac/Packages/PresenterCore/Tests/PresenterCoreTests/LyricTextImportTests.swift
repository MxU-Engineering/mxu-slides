import Foundation
import Testing
@testable import PresenterCore

struct LyricTextImportTests {

    private let songSelectText = """
    Amazing Grace (My Chains Are Gone)

    Verse 1
    Amazing grace how sweet the sound
    That saved a wretch like me
    I once was lost but now am found
    Was blind but now I see

    Chorus
    My chains are gone I've been set free
    My God my Savior has ransomed me

    Verse 2
    The Lord has promised good to me
    His word my hope secures

    Chorus
    My chains are gone I've been set free
    My God my Savior has ransomed me

    CCLI Song # 4768151
    Chris Tomlin | John Newton | Louie Giglio
    © 2006 sixsteps Music | Vamos Publishing | worshiptogether.com songs
    For use solely with the SongSelect® Terms of Use. All rights reserved. www.ccli.com
    CCLI Licence # 123456
    """

    private let chordProText = """
    {title: Living Hope}
    {artist: Phil Wickham}
    {ccli: 7106807}
    {copyright: © 2018 Phil Wickham Music}
    {key: G}

    {c: Verse 1}
    How great the [G]chasm that [C]lay between us
    How high the [Em]mountain I could not [D]climb

    {soc}
    Hallelujah [G]praise the One who [C]set me free
    {eoc}
    """

    private let plainText = """
    On the mountain we will worship
    In the valley we will sing

    You are faithful in each season
    Every sunrise every evening
    """

    @Test func detectsSongSelect() {
        #expect(LyricTextImporter.detectFormat(songSelectText) == .songSelect)
    }

    @Test func detectsChordProByDirective() {
        #expect(LyricTextImporter.detectFormat(chordProText) == .chordPro)
    }

    @Test func detectsChordProByChordDensityWithoutDirectives() {
        let bare = """
        How great the [G]chasm that [C]lay between us
        How high the [Em]mountain I could not [D]climb
        """
        #expect(LyricTextImporter.detectFormat(bare) == .chordPro)
    }

    @Test func plainLyricsStayPlain() {
        #expect(LyricTextImporter.detectFormat(plainText) == .plainText)

        #expect(LyricTextImporter.detectFormat("Sing it loud [oh oh]\nLift it high [yeah]") == .plainText)
    }

    @Test func songSelectExtractsCCLIAndTitle() {
        let normalized = LyricTextImporter.normalize(songSelectText)
        #expect(normalized.title == "Amazing Grace (My Chains Are Gone)")
        #expect(normalized.ccli?.songNumber == 4768151)
        #expect(normalized.ccli?.author == "Chris Tomlin | John Newton | Louie Giglio")
        #expect(normalized.ccli?.copyright == "© 2006 sixsteps Music | Vamos Publishing | worshiptogether.com songs")
        #expect(normalized.ccli?.copyrightYear == 2006)

        #expect(!normalized.body.contains("CCLI"))
        #expect(!normalized.body.contains("SongSelect"))
    }

    @Test func songSelectImportBuildsSectionedPresentation() {
        let presentation = LyricTextImporter.makePresentation(songSelectText, linesPerSlide: 2)
        #expect(presentation.name == "Amazing Grace (My Chains Are Gone)")
        #expect(presentation.folder == nil, "no built-in folder: the app files it where the library is looking, else Needs Sorted")
        #expect(presentation.ccli?.songNumber == 4768151)

        let sections = try! #require(presentation.sections)

        #expect(sections.map(\.name) == ["Intro", "Verse 1", "Chorus", "Verse 2"])

        #expect(presentation.slides.count == 5)
        #expect(presentation.slides[0].objects.isEmpty)
        let arrangement = try! #require(presentation.arrangements?.first)
        let names = arrangement.sectionIds.map { id in sections.first { $0.id == id }!.name }
        #expect(names == ["Intro", "Verse 1", "Chorus", "Verse 2", "Chorus"])
        #expect(presentation.defaultArrangementId == arrangement.id)

        for slide in presentation.slides {
            #expect(slide.themeSlideName == "Lyrics")
        }
        for slide in presentation.slides.dropFirst() {
            #expect(slide.objects.count == 1)
            #expect(slide.objects[0].textStyle == nil)
        }
    }

    @Test func importOpensOnABlankNamedForWhatTheTextHas() {

        #expect(LyricTextImporter.makePresentation(plainText).sections?.first?.name == "Intro")

        let worded = LyricTextImporter.makePresentation("Intro\nOh oh oh\n\nVerse 1\nAmazing grace")
        #expect(worded.sections?.map(\.name) == ["Blank", "Intro", "Verse 1"])
        #expect(worded.slides[0].objects.isEmpty)
        #expect(worded.slides[1].objects[0].text == "Oh oh oh")

        let cue = LyricTextImporter.makePresentation("Intro\n\nVerse 1\nAmazing grace")
        #expect(cue.sections?.map(\.name) == ["Intro", "Verse 1"])
        #expect(cue.slides.count == 2)
        #expect(cue.slides[0].objects.isEmpty)
    }

    @Test func chordProKeepsCleanGlassAndKeepsSource() {
        let presentation = LyricTextImporter.makePresentation(chordProText)
        #expect(presentation.name == "Living Hope")
        #expect(presentation.ccli?.songNumber == 7106807)
        #expect(presentation.ccli?.author == "Phil Wickham")
        #expect(presentation.ccli?.copyrightYear == 2018)
        #expect(presentation.chordProSource == chordProText.replacingOccurrences(of: "\r\n", with: "\n"))
        #expect(presentation.musicKey == "G")

        let allText = presentation.slides.flatMap(\.objects).map(\.text).joined(separator: "\n")
        #expect(allText.contains("How great the chasm that lay between us"))
        #expect(!allText.contains("["))

        let sections = try! #require(presentation.sections)
        #expect(sections.map(\.name) == ["Intro", "Verse 1", "Chorus"])
    }

    @Test func chordProImportsChordsAsPlacements() {

        let presentation = LyricTextImporter.makePresentation(chordProText)

        let verse = presentation.slides[1].objects[0]
        let verseChords = try! #require(verse.chords)
        #expect(verseChords.map(\.symbol) == ["G", "C", "Em", "D"])
        #expect(verseChords.map(\.line) == [0, 0, 1, 1])
        let line0 = verse.text.components(separatedBy: "\n")[0]
        let line1 = verse.text.components(separatedBy: "\n")[1]
        #expect(verseChords[0].column == line0.distance(
            from: line0.startIndex, to: line0.range(of: "chasm")!.lowerBound))
        #expect(verseChords[1].column == line0.distance(
            from: line0.startIndex, to: line0.range(of: "lay")!.lowerBound))
        #expect(verseChords[3].column == line1.distance(
            from: line1.startIndex, to: line1.range(of: "climb")!.lowerBound))

        let chorus = presentation.slides[2].objects[0]
        #expect(chorus.chords?.map(\.symbol) == ["G", "C"])

        let source = try! #require(presentation.reflowSource)
        #expect(source.contains("[G]"))
        let rebuilt = Reflow.build(from: source, linesPerSlide: 2)
        #expect(rebuilt.slides[0].objects[0].chords == verseChords)
    }

    @Test func bracketExtractionLeavesLyricPunctuationAndNonChords() {
        let extracted = ChordMath.extractLine("How [G]great is our [C/E]God")
        #expect(extracted.text == "How great is our God")
        #expect(extracted.chords.map(\.symbol) == ["G", "C/E"])

        #expect(ChordMath.extractLine("[D]").text == "")

        let stage = ChordMath.extractLine("Sing it loud [oh oh]")
        #expect(stage.text == "Sing it loud [oh oh]")
        #expect(stage.chords.isEmpty)
    }

    @Test func bracketedSerializationRoundTrips() {
        let source = "How great the chasm that lay between us"
        let chords = [
            ChordPlacement(line: 0, column: 14, symbol: "G"),
            ChordPlacement(line: 0, column: 25, symbol: "C"),
        ]
        let bracketed = ChordMath.bracketed(source, chords: chords)
        #expect(bracketed == "How great the [G]chasm that [C]lay between us")
        let back = ChordMath.extract(bracketed)
        #expect(back.text == source)
        #expect(back.chords == chords)
    }

    @Test func plainTextChunksAtBlankLines() {
        let presentation = LyricTextImporter.makePresentation(plainText, fallbackTitle: "New Song", linesPerSlide: 2)
        #expect(presentation.name == "New Song")
        #expect(presentation.ccli == nil)

        #expect(presentation.sections?.map(\.name) == ["Intro", "Verse 1", "Verse 2"])
        #expect(presentation.slides.count == 3)
        #expect(presentation.slides[1].objects[0].text == "On the mountain we will worship\nIn the valley we will sing")
    }

    @Test func emptyPasteStillMakesAValidPresentation() {
        let presentation = LyricTextImporter.makePresentation("   \n\n  ")
        #expect(presentation.name == "Imported Lyrics")
        #expect(presentation.slides.count == 1)
        #expect(presentation.reflowSource == nil)
    }

    @Test func songSelectMiscLabelIsASection() {
        #expect(Reflow.labelName(of: "Misc 1") == "Misc 1")
        #expect(Reflow.labelName(of: "Instrumental") == "Instrumental")
    }
}
