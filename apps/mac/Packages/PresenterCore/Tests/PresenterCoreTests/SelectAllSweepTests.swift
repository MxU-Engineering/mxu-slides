import Foundation
import Testing

@Suite struct SelectAllSweepTests {
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

    @Test func presentGridBandStartsInTheHostsPadding() throws {
        let grid = try source("PresentGridView.swift")
        let continuous = try source("ServiceContinuousView.swift")
        #expect(grid.contains(".padding(-marqueeMargin)"), "the catcher reaches out over the host's padding")
        #expect(grid.contains("pastesAtEnd: true,\n                        marqueeMargin: 12\n                    )\n                    .padding(12)"), "the deck view hands its padding to the band")
        #expect(continuous.contains("marqueeMargin: 12"), "the continuous view's cards hand their padding to the band")
    }

    @Test func presentGridTakesCommandA() throws {
        let grid = try source("PresentGridView.swift")
        #expect(grid.contains("case \"a\": return .selectAll"), "the grid's key monitor hears ⌘A")
        #expect(grid.contains(".onChange(of: clipboardRequests.selectAlls) { _, _ in selectAllFromKeyboard() }"))
        #expect(grid.contains("NewSlideRouter.shared.route.answers(contextID, contexts: contexts, isHostTarget: pastesAtEnd)"), "⌘A lands on the deck last pointed at, New Slide's rule")
    }

    @Test func editorListsAndCanvasTakeCommandA() throws {
        let editor = try source("SlideEditorView.swift")
        let canvas = try source("EditorInteractionView.swift")
        #expect(editor.contains("case .selectAll: model.selectAllSlides()"), "the slide list")
        #expect(editor.contains("case .selectAll: model.selectAllObjects(includingHidden: true)"), "the Objects panel")
        #expect(canvas.contains("model.selectAllObjects(includingHidden: false)"), "the canvas")
    }
}
