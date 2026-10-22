import Foundation
import Testing

@testable import PresenterCore

struct ChordClipboardTests {
    private let source = "Than this\nIn the presence of God"
    private let sourceChords = [
        ChordPlacement(line: 0, column: 0, symbol: "G"),
        ChordPlacement(line: 0, column: 5, symbol: "D"),
        ChordPlacement(line: 1, column: 7, symbol: "Em"),
    ]

    @Test func copyKeepsOnlyTheSelectionsChordsAnchoredInTheCopiedText() throws {
        let payload = try #require(ChordClipboard.copying(0..<9, of: source, chords: sourceChords))
        #expect(payload.text == "Than this")
        #expect(payload.chords == [
            ChordPlacement(line: 0, column: 0, symbol: "G"),
            ChordPlacement(line: 0, column: 5, symbol: "D"),
        ])

        let across = try #require(ChordClipboard.copying(5..<16, of: source, chords: sourceChords))
        #expect(across.text == "this\nIn the")
        #expect(across.chords == [ChordPlacement(line: 0, column: 0, symbol: "D")],
                "Em (on \"presence\") is past the end: it stays behind")

        #expect(ChordClipboard.copying(10..<12, of: source, chords: sourceChords) == nil,
                "no chords sounding in it: a plain copy")
    }

    @Test func pasteLandsTheChordsOnThePastedLettersAfterShiftedOnes() {
        let payload = ChordClipboard.Payload(text: " than this", chords: [
            ChordPlacement(line: 0, column: 1, symbol: "G"),
            ChordPlacement(line: 0, column: 6, symbol: "D"),
        ])

        let text = "I cannot explain\nBut nothing's more real than this\nAmen"
        let existing = [
            ChordPlacement(line: 0, column: 2, symbol: "C"),
            ChordPlacement(line: 2, column: 0, symbol: "A"),
        ]
        let position = "I cannot explain\nBut nothing's more real".count

        let chords = ChordClipboard.pasting(payload, at: position, into: text, chords: existing)

        #expect(chords == [
            ChordPlacement(line: 0, column: 2, symbol: "C"),
            ChordPlacement(line: 1, column: 24, symbol: "G"),
            ChordPlacement(line: 1, column: 29, symbol: "D"),
            ChordPlacement(line: 2, column: 0, symbol: "A"),
        ])
    }

    @Test func multiLinePasteKeepsEachLinesChords() throws {
        let payload = try #require(ChordClipboard.copying(0..<source.count, of: source, chords: sourceChords))
        let chords = ChordClipboard.pasting(payload, at: 4, into: "Amen" + source, chords: [])
        #expect(chords == [
            ChordPlacement(line: 0, column: 4, symbol: "G"),
            ChordPlacement(line: 0, column: 9, symbol: "D"),
            ChordPlacement(line: 1, column: 7, symbol: "Em"),
        ])
    }

    @Test func theTextOverlayCarriesChordsThroughCopyCutAndPaste() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources", isDirectory: true)
        let canvas = try String(contentsOf: sources.appendingPathComponent("EditorInteractionView.swift"), encoding: .utf8)
        let overlay = try #require(canvas.range(of: "final class OverlayTextView: NSTextView {"))
        let body = canvas[overlay.upperBound...]
        #expect(body.contains("override func copy(_ sender: Any?) {\n        let clip = chordClip?(selectedRange())"))
        #expect(body.contains("override func cut(_ sender: Any?) {"))
        #expect(body.contains("insertText(clip.text, replacementRange: selection)\n            onPasteChords?(clip, selection.location)"))
        #expect(canvas.contains("self?.model.canvasTextChordClip(utf16Range: range)"))
        #expect(canvas.contains("self?.model.applyPastedChords(clip, atUTF16: location)"))
        #expect(canvas.contains("model.applyPastedChords(clip, atUTF16: selection.location)"),
                "Paste with Formatting keeps chords too")
    }
}
