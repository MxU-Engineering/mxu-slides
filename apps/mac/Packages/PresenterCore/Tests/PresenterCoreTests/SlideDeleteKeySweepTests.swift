import Foundation
import Testing

@Suite struct SlideDeleteKeySweepTests {
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

    @Test func keyMonitorHearsBareDelete() throws {
        let grid = try source("PresentGridView.swift")
        #expect(grid.contains("let backspace = event.keyCode == 51 || event.keyCode == 117"), "⌫ and ⌦")
        #expect(grid.contains("case ([], _) where backspace: return .delete"), "bare only: ⌘⌫ stays the menus'")
    }

    @Test func presentGridsDeleteTheSelection() throws {
        let grid = try source("PresentGridView.swift")
        let continuous = try source("ServiceContinuousView.swift")
        #expect(grid.contains(".onChange(of: clipboardRequests.deletes) { _, _ in deleteSelectedSlides() }"))
        #expect(grid.contains(".onSlideClipboardKeys(active: focused) { clipboardRequests.take($0) }"), "the deck view")
        #expect(continuous.contains(".onSlideClipboardKeys(active: focused) { clipboardRequests.take($0) }"), "the continuous view")
    }

    @Test func editorListsDeleteTheSelection() throws {
        let editor = try source("SlideEditorView.swift")
        #expect(editor.contains("case .delete: model.deleteSlides(Array(model.selectedSlideIDs))"), "the slide list")
        #expect(editor.contains("case .delete: model.deleteSelectedObjects()"), "the Objects panel")
    }
}
