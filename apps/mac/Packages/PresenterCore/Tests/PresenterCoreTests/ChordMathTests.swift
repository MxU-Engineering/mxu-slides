import Testing

@testable import PresenterCore

struct ChordMathTests {
    @Test func displayKeyFromPlayedKeySpellsFromTheChartAndCrossesModesByRelative() {

        #expect(ChordMath.displayKey(playing: "A", musicKey: "G") == "A")
        #expect(ChordMath.displayKey(playing: "A#", musicKey: "G") == "Bb", "the chart's spelling wins")
        #expect(ChordMath.displayKey(playing: "G", musicKey: "G") == "G")
        #expect(ChordMath.displayKey(playing: "Em", musicKey: "G") == "G", "relative minor = same chords")
        #expect(ChordMath.displayKey(playing: "F#m", musicKey: "G") == "A")
        #expect(ChordMath.displayKey(playing: "C", musicKey: "Am") == "Am")
        #expect(ChordMath.displayKey(playing: "Bbm", musicKey: "F#m") == "Bbm")
        #expect(ChordMath.displayKey(playing: "?", musicKey: "G") == nil)
        #expect(ChordMath.displayKey(playing: "A", musicKey: "") == nil)
    }

    @Test func parsesSymbols() {
        #expect(ChordMath.parseSymbol("C") == .init(root: "C"))
        #expect(ChordMath.parseSymbol("F#m7") == .init(root: "F#", suffix: "m7"))
        #expect(ChordMath.parseSymbol("G/B") == .init(root: "G", bass: "B"))
        #expect(ChordMath.parseSymbol("Bbsus4") == .init(root: "Bb", suffix: "sus4"))
        #expect(ChordMath.parseSymbol("Cmaj7/E") == .init(root: "C", suffix: "maj7", bass: "E"))
        #expect(ChordMath.parseSymbol("A7b5") == .init(root: "A", suffix: "7b5"))
    }

    @Test func rejectsNonChords() {

        for text in ["x2", "Repeat", "Bridge", "Down", "Go", "Hm", ""] {
            #expect(!ChordMath.isChordToken(text), "'\(text)' should not parse")
        }
        for text in ["E", "Am", "Db", "G7", "F#m7/A"] {
            #expect(ChordMath.isChordToken(text), "'\(text)' should parse")
        }
    }

    @Test func parsesKeys() {
        #expect(ChordMath.parseKey("C")! == (0, false))
        #expect(ChordMath.parseKey("Bb")! == (10, false))
        #expect(ChordMath.parseKey("F#m")! == (6, true))
        #expect(ChordMath.parseKey("Am")! == (9, true))
        #expect(ChordMath.parseKey("nonsense") == nil)
    }

    @Test func transposesWithKeySpelling() {

        #expect(ChordMath.display("C", musicKey: "G", displayKey: "A", notation: .chords) == "D")
        #expect(ChordMath.display("F#m", musicKey: "G", displayKey: "A", notation: .chords) == "G#m")

        #expect(ChordMath.display("A", musicKey: "C", displayKey: "Eb", notation: .chords) == "C")
        #expect(ChordMath.display("B", musicKey: "C", displayKey: "Eb", notation: .chords) == "D")
        #expect(ChordMath.display("E", musicKey: "C", displayKey: "Eb", notation: .chords) == "G")
        #expect(ChordMath.display("F", musicKey: "C", displayKey: "Eb", notation: .chords) == "Ab")

        #expect(ChordMath.display("C", musicKey: "C", displayKey: "C#", notation: .chords) == "C#")

        #expect(ChordMath.display("G/B", musicKey: "G", displayKey: "A", notation: .chords) == "A/C#")

        #expect(ChordMath.display("Csus4", musicKey: "C", displayKey: "D", notation: .chords) == "Dsus4")
    }

    @Test func noKeysMeansNoTransposition() {
        #expect(ChordMath.display("F#m7", musicKey: nil, displayKey: "A", notation: .chords) == "F#m7")
        #expect(ChordMath.display("F#m7", musicKey: "A", displayKey: nil, notation: .chords) == "F#m7")
        #expect(ChordMath.transposeInterval(musicKey: "junk", displayKey: "A") == nil)
    }

    @Test func nashvilleNumbers() {
        #expect(ChordMath.display("C", musicKey: "C", displayKey: nil, notation: .numbers) == "1")
        #expect(ChordMath.display("Am7", musicKey: "C", displayKey: nil, notation: .numbers) == "6m7")
        #expect(ChordMath.display("F", musicKey: "C", displayKey: nil, notation: .numbers) == "4")
        #expect(ChordMath.display("Bb", musicKey: "C", displayKey: nil, notation: .numbers) == "b7")
        #expect(ChordMath.display("F#", musicKey: "C", displayKey: nil, notation: .numbers) == "#4")
        #expect(ChordMath.display("G/B", musicKey: "C", displayKey: nil, notation: .numbers) == "5/7")

        #expect(ChordMath.display("D", musicKey: "G", displayKey: "Bb", notation: .numbers) == "5")

        #expect(ChordMath.display("Am", musicKey: "Am", displayKey: nil, notation: .numbers) == "1m")
    }

    @Test func romanNumerals() {
        #expect(ChordMath.display("C", musicKey: "C", displayKey: nil, notation: .numerals) == "I")
        #expect(ChordMath.display("Am", musicKey: "C", displayKey: nil, notation: .numerals) == "vi")
        #expect(ChordMath.display("Am7", musicKey: "C", displayKey: nil, notation: .numerals) == "vi7")
        #expect(ChordMath.display("Cmaj7", musicKey: "C", displayKey: nil, notation: .numerals) == "Imaj7")
        #expect(ChordMath.display("G/B", musicKey: "C", displayKey: nil, notation: .numerals) == "V/VII")
        #expect(ChordMath.display("Bb", musicKey: "C", displayKey: nil, notation: .numerals) == "bVII")
    }

    @Test func doReMi() {
        #expect(ChordMath.display("C", musicKey: "C", displayKey: nil, notation: .doReMi) == "Do")
        #expect(ChordMath.display("G", musicKey: "C", displayKey: nil, notation: .doReMi) == "Sol")
        #expect(ChordMath.display("Am", musicKey: "C", displayKey: nil, notation: .doReMi) == "Lam")
        #expect(ChordMath.display("Bb", musicKey: "C", displayKey: nil, notation: .doReMi) == "Te")
        #expect(ChordMath.display("F#", musicKey: "C", displayKey: nil, notation: .doReMi) == "Fi")
    }

    @Test func degreeNotationWithoutKeyFallsBackToLetters() {
        #expect(ChordMath.display("Am7", musicKey: nil, displayKey: nil, notation: .numbers) == "Am7")
        #expect(ChordMath.display("Am7", musicKey: nil, displayKey: "D", notation: .numerals) == "Am7")
    }

    @Test func keyChoicesMatchMode() {
        #expect(ChordMath.keyChoices(matching: "G").contains("Bb"))
        #expect(!ChordMath.keyChoices(matching: "G").contains("Bbm"))
        #expect(ChordMath.keyChoices(matching: "Em") == ChordMath.keyChoices(matching: "G").map { $0 + "m" })
        #expect(ChordMath.keyChoices(matching: "G").count == 12)
    }

    @Test func displayPlacementsKeepAnchors() {
        let chords = [
            ChordPlacement(line: 0, column: 0, symbol: "G"),
            ChordPlacement(line: 0, column: 8, symbol: "C/E"),
            ChordPlacement(line: 2, column: 4, symbol: "Em7"),
        ]
        let out = ChordMath.displayPlacements(chords, musicKey: "G", displayKey: "A", notation: .chords)
        #expect(out.map(\.symbol) == ["A", "D/F#", "F#m7"])
        #expect(out.map(\.line) == [0, 0, 2])
        #expect(out.map(\.column) == [0, 8, 4])
    }

    @Test func hasChordsFindsPlacementsAnywhere() {
        var object = SlideObject(id: "t", objectKind: .text, name: "", text: "lyric")
        var song = Presentation(
            id: "p", name: "S", presentationKind: .deck, themeId: "",
            slides: [
                Slide(id: "s1", name: "", objects: []),
                Slide(id: "s2", name: "", objects: [object]),
            ]
        )
        #expect(!ChordMath.hasChords(in: song), "empty placements don't count")
        object.chords = [ChordPlacement(line: 0, column: 0, symbol: "G")]
        song.slides[1].objects = [object]
        #expect(ChordMath.hasChords(in: song))
    }
}
