import Foundation
import Testing

@Suite struct EditorCarriedMediaSweepTests {
    private func source(_ file: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/\(file)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test func gridCompositesTheMemoizedCarriedMedia() throws {
        let grid = try source("PresentGridView.swift")
        let tile = try #require(grid.range(of: "struct SlideThumbnailView: View {"))
        #expect(grid[tile.upperBound...].contains("ThumbnailStore.shared.carriedMedia("))
        #expect(!grid[tile.upperBound...].contains("SlideSceneBuilder.carriedMedia"), "tiles read the store's map, never walk per body pass")
        let store = try source("ThumbnailStore.swift")
        #expect(store.contains("@ObservationIgnored private var carriedMaps"), "a cache write during a body pass must not invalidate views (the 2026-08-20 loop)")
    }

    @Test func editorSceneAndPosterSyncShareTheCarriedMedia() throws {
        let model = try source("SlideEditorModel.swift")
        let pipeline = try #require(model.range(of: "private func editorScene(for slide: Slide"))
        let sync = try #require(model.range(of: "private func syncMedia(for slide: Slide)"))
        #expect(model[pipeline.upperBound...].prefix(3000).contains("carriedMedia: carriedMedia(for: slide)"))
        #expect(model[sync.upperBound...].prefix(2000).contains("carriedMedia(for: slide).values"))
    }
}
