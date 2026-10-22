import Foundation
import Testing

@Suite struct ChordChartTypingSweepTests {
    private var appSources: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources", isDirectory: true)
    }

    private func body(of function: String, in text: String) throws -> Substring {
        let start = try #require(text.range(of: function))
        let end = try #require(text.range(of: "\n    }\n", range: start.upperBound..<text.endIndex))
        return text[start.lowerBound..<end.upperBound]
    }

    @Test func addingAChordWritesOnlyWhenItCommitsWithASymbol() throws {
        let sheet = try String(contentsOf: appSources.appendingPathComponent("ChordEditorSheet.swift"), encoding: .utf8)
        let add = try body(of: "private func addChord(at x: CGFloat, row: Row) {", in: sheet)
        #expect(add.contains("commitOpenEdit()"), "the open field saves before the next one opens")
        #expect(add.contains("addingChord = AddingChord(row: row, column: column)"))
        #expect(!add.contains("writeChords("), "a click never stores a chord by itself")

        let commit = try body(of: "private func commitAdding() {", in: sheet)
        #expect(commit.contains("if !symbol.isEmpty {") && commit.contains("writeChords(row: adding.row)"))
    }

    @Test func theChordFieldTakesFocusAsItAppears() throws {
        let sheet = try String(contentsOf: appSources.appendingPathComponent("ChordEditorSheet.swift"), encoding: .utf8)
        let field = try body(of: "private func chordField(", in: sheet)
        #expect(field.contains(".onAppear { DispatchQueue.main.async { focusedChip = id } }"))
        #expect(sheet.contains(".onAppear { DispatchQueue.main.async { NSApp.keyWindow?.makeFirstResponder(nil) } }"), "no lyric line holds the keys as the sheet opens")
        #expect(field.contains("if was == id, focus != id, isOpen(id) { commit() }"), "click-away commits only when focus leaves the field")
    }
}
