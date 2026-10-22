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

    @Test func emptyDecksOfferNewSlideAndDrops() throws {
        let grid = try source("PresentGridView.swift")
        let editor = try source("SlideEditorView.swift")
        let model = try source("SlideEditorModel.swift")
        let inspector = try source("SlideObjectInspector.swift")
        #expect(grid.contains("EmptyDeckPrompt(onNewSlide: runOnly ? nil : { newSlideTarget = NewSlideTarget(after: nil) })"), "the grid")
        #expect(grid.contains("presentation.slides.isEmpty ? EmptyDeckPrompt.height + marqueeMargin * 2 : 0"), "the drop catcher covers the prompt")
        #expect(editor.contains("EmptyDeckPrompt(onNewSlide: { model.addSlide() })"), "the canvas")
        #expect(editor.contains(".disabled(model.isThemeEditor && model.presentation.slides.count == 1)"), "Delete on the last row")
        #expect(model.contains("if !(isThemeEditor && survivors.isEmpty), survivors.count < presentation.slides.count {"), "a theme keeps a category")
        #expect(model.contains("return insertMediaSlide(mediaID: mediaID, beforeSlideID: nil)"), "a canvas drop on an empty deck is a slide")
        #expect(inspector.contains("Add a slide to edit its settings."))
    }

    @Test func serviceFlowSweepSpansItems() throws {
        let grid = try source("PresentGridView.swift")
        let continuous = try source("ServiceContinuousView.swift")
        #expect(continuous.contains(".overlay(alignment: .topLeading) { GridSweepBand(sweep: sweep) }\n                            .coordinateSpace(name: Self.contentSpace)"), "one band, in the cards' shared space")
        #expect(continuous.contains("sweep: sweep,\n                    deleteEverySelection: { clipboardRequests.take(.delete) }"))
        #expect(grid.contains("GridSweepFollow(sweep: sweep, pick: pickTiles(under:), clear: clearSelection)"), "every card picks under it")
        #expect(grid.contains("DragGesture(minimumDistance: 4, coordinateSpace: .named(sweep?.space ?? \"slideGrid\"))"))
        #expect(grid.contains("Button(\"Delete \\(slideIDs.count + elsewhere) Slides\", role: .destructive) { deleteEverySelection() }"), "Delete takes the whole sweep")
    }
}
