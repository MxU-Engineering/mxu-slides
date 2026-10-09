import Testing

@testable import PresenterCore

struct ChordEditingTests {
    private let text = "Amazing grace\nhow sweet"
    private let chords = [
        ChordPlacement(line: 0, column: 0, symbol: "G"),
        ChordPlacement(line: 0, column: 8, symbol: "C"),
        ChordPlacement(line: 1, column: 4, symbol: "D"),
    ]

    @Test func revealShowsLetterChordsOnUnlinkedChordedTextOnly() {
        var chorded = SlideObject(id: "a", objectKind: .text, name: "Lyrics", text: text, chords: chords)
        chorded.textStyle = TextStyle(chordNotation: .numbers)
        let plain = SlideObject(id: "b", objectKind: .text, name: "Plain", text: "Hi")
        let linked = SlideObject(
            id: "c", objectKind: .text, name: "Next", text: "", textLink: TextLink(source: .nextSlide),
            chords: chords)

        let revealed = ChordEditing.revealed([chorded, plain, linked])

        #expect(revealed[0].textStyle?.showChords == true)
        #expect(revealed[0].textStyle?.chordNotation == .chords, "edit what's stored, not a transform")
        #expect(revealed[0].textStyle?.autoShrink == true, "chord rows fit the box, not push words out of it")
        #expect(revealed[1] == plain)
        #expect(revealed[2] == linked)
    }

    @Test func movingAlongAndAcrossLinesKeepsOrderAndTracksTheChord() {
        let along = ChordEditing.moving(at: 0, toLine: 0, column: 10, in: chords, text: text)
        #expect(along.chords.map(\.symbol) == ["C", "G", "D"])
        #expect(along.index == 1)
        #expect(along.chords[1] == ChordPlacement(line: 0, column: 10, symbol: "G"))

        let down = ChordEditing.moving(at: 1, toLine: 1, column: 0, in: chords, text: text)
        #expect(down.chords.map(\.symbol) == ["G", "C", "D"])
        #expect(down.chords[1] == ChordPlacement(line: 1, column: 0, symbol: "C"))
        #expect(down.index == 1)

        let clamped = ChordEditing.moving(at: 2, toLine: 7, column: 40, in: chords, text: text)
        #expect(clamped.chords[2] == ChordPlacement(line: 1, column: 9, symbol: "D"))
    }

    @Test func retypingAddingAndRemoving() {
        let retyped = ChordEditing.setting(" Cmaj7 ", at: 1, in: chords)
        #expect(retyped.chords[1].symbol == "Cmaj7")
        #expect(retyped.index == 1)

        let emptied = ChordEditing.setting("", at: 1, in: chords)
        #expect(emptied.chords.map(\.symbol) == ["G", "D"], "an emptied chord is removed")
        #expect(emptied.index == nil)

        let added = ChordEditing.adding("Em", line: 1, column: 0, to: chords, text: text)
        #expect(added.chords.map(\.symbol) == ["G", "C", "Em", "D"])
        #expect(added.index == 2)

        let blank = ChordEditing.adding("  ", line: 0, column: 3, to: chords, text: text)
        #expect(blank.chords == chords)
        #expect(blank.index == nil)

        #expect(ChordEditing.removing(at: 0, from: chords).map(\.symbol) == ["C", "D"])
    }
}
