import Foundation
import Testing

@Suite struct LibraryGridDragSweepTests {
    @Test func gridCardsSelectOnATapNotAButton() throws {
        let file = try #require(SourceSweep.app().file("LibraryView.swift"))
        for marker in ["private func gridCard<", "struct FolderPreviewCard: View {"] {
            let start = try #require(file.codeLines.firstIndex { $0.contains(marker) }, "\(marker) expected")
            let body = file.codeLines[file.block(from: start)].joined(separator: "\n")
            #expect(!body.contains("Button("), "\(marker): a Button swallows the card's drag")
            #expect(body.contains(".onTapGesture(perform: action)"), "\(marker): selects on a tap")
        }
    }
}
