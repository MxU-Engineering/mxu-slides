import Foundation
import Testing

@Suite struct PosterLookSweepTests {
    private func source(_ file: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/\(file)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test func layerPostersShowTheItemLook() throws {
        let grid = try source("PresentGridView.swift")
        let layer = try #require(grid.range(of: "private func posterLayer(mediaId: String) -> some View {"))
        #expect(grid[layer.upperBound...].prefix(400).contains("PosterLookImage("))
        let pane = try #require(grid.range(of: "struct MediaFireView: View {"))
        #expect(grid[pane.upperBound...].prefix(3000).contains("PosterLookImage("))
        let exporter = try source("StationThumbnailExporter.swift")
        #expect(exporter.contains("ThumbnailStore.shared.posterLook("))
    }

    @Test func looksRenderOffMainThroughTheLookScene() throws {
        let store = try source("ThumbnailStore.swift")
        let start = try #require(store.range(of: "func posterLook("))
        let end = try #require(store.range(of: "private func landLook("))
        let body = store[start.upperBound..<end.lowerBound]
        #expect(body.contains("SlideSceneBuilder.posterLookScene("))
        #expect(body.contains("Self.renderQueue.async"), "renderFrame blocks on the GPU — never on main")
        #expect(store.contains("@ObservationIgnored private var looksInFlight"), "body-pass bookkeeping must not invalidate views")
    }
}
