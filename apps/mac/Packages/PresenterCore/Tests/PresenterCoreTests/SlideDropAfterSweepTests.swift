import Foundation
import Testing

@Suite struct SlideDropAfterSweepTests {
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

    @Test func tilesAndRowsTakeTheSharedZones() throws {
        let delegate = try source("GutterDropDelegate.swift")
        #expect(delegate.contains("SlideDropZone.tile(at: info.location, width: tileWidth(), reorder: isReorder, insertOnly: insertOnly)"))
        #expect(delegate.contains("SlideDropZone.row(at: info.location, size: rowSize(), insertOnly: insertOnly)"))
        #expect(delegate.contains("} else if zone == .after {\n            return performAfter(fileURLs: fileURLs, text: text)"),
                "the after zone takes Finder files as well as library media")
    }

    @Test func aTilesTrailingGutterMakesSlidesAfterIt() throws {
        let grid = try source("PresentGridView.swift")
        #expect(grid.contains("insertMediaSlides(mediaIDs: [payload], afterIndex: index)"))
        #expect(grid.contains("_ = insertMediaSlides(mediaIDs: imported, afterIndex: index)"))
        #expect(grid.contains(".frame(minHeight: max(0, minimumHeight + marqueeMargin * 2))"),
                "the empty space below the last row catches drops")
    }

    @Test func theEmptySpaceCatcherHearsTheWholeBandAndRedraws() throws {
        let grid = try source("PresentGridView.swift")
        #expect(grid.contains("""
                            .onDrop(of: [.plainText, .fileURL], delegate: gapDropDelegate(enabled: !runOnly))
                            .padding(-marqueeMargin)
            """), "the catcher's drop area covers the host's padding, not just the grid")
        #expect(grid.contains("let _ = (dropTargetIndex, dropTargetAfterIndex, backgroundDropIndex)"),
                "the body reads the drop feedback, so the catcher's changes redraw")
        #expect(!grid.contains(".padding(.vertical, 14)\n                    .offset(x: "), "insertion lines run the slide's full height")
    }

    @Test func aRowsBottomBandMakesSlidesAfterIt() throws {
        let editor = try source("SlideEditorView.swift")
        #expect(editor.contains("rowSize: { slideRowFrames[slide.id]?.size ?? .zero },"))
        #expect(editor.contains("model.insertMediaSlides(mediaIDs: imported, afterSlideID: slide.id)"))
    }
}
