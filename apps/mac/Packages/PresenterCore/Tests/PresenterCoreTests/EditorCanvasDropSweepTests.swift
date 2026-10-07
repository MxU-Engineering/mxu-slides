import Foundation
import Testing

@Suite struct EditorCanvasDropSweepTests {
    private var appSources: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  
            .deletingLastPathComponent()  
            .deletingLastPathComponent()  
            .deletingLastPathComponent()  
            .deletingLastPathComponent()  
            .appendingPathComponent("Sources", isDirectory: true)
    }

    private func source(_ name: String) throws -> String {
        try String(contentsOf: appSources.appendingPathComponent(name), encoding: .utf8)
    }

    @Test func theTextOverlayLeavesDropsToTheCanvas() throws {
        let canvas = try source("EditorInteractionView.swift")
        let overlay = try #require(canvas.range(of: "final class OverlayTextView: NSTextView {"))
        #expect(canvas[overlay.upperBound...].contains(
            "override var acceptableDragTypes: [NSPasteboard.PasteboardType] { [] }"),
            "the overlay registers no drag types, so the canvas drop target gets every drop")
    }

    @Test func anAddedObjectClosesTheTextEdit() throws {
        let model = try source("SlideEditorModel.swift")
        #expect(model.contains("""
            guard !isMultiView, let slideIndex = currentSlideIndex else { return }
                    endCanvasTextEdit()
                    updateDocument { $0.slides[slideIndex].objects.append(object) }
                    selectedObjectIDs = [object.id]
            """), "every Add door ends an in-place text edit before selecting the new object")
    }
}
