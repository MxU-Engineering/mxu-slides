import Foundation
import Testing

@Suite struct NoteReaderDeckReadsSweepTests {
    private func body(_ file: SourceSweep.File, _ signature: String) throws -> String {
        let start = try #require(file.lines.firstIndex { $0.contains(signature) }, "\(signature)")
        return file.lines[file.block(from: start)].joined(separator: "\n")
    }

    @Test func theNoteSurfacesReadTheirDeckNotTheKind() throws {
        for name in ["NoteReaderView.swift", "NoteEditorView.swift"] {
            let file = try #require(try SourceSweep.app().file(name))
            let reads = file.lines.enumerated().filter {
                $0.element.contains("version(of: .presentation)") || $0.element.contains("fillVersion(of: .presentation)")
            }
            #expect(reads.isEmpty, "\(reads.map { "\(name):\($0.offset + 1)" })")
            #expect(file.text.contains(".task(id: NoteDeckKey(deck:"), "\(name)")
        }
    }

    @Test func theServiceDeckMenuIsItsOwnView() throws {
        let reader = try #require(try SourceSweep.app().file("NoteReaderView.swift"))
        let header = try body(reader, "private var header: some View {")
        #expect(header.contains("PlaceSlidesMenu(model: model"))
        #expect(!header.contains("let decks = servicePresentations"))
    }
}
