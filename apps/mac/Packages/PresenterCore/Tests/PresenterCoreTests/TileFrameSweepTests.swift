import Foundation
import Testing

@Suite struct TileFrameSweepTests {
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

    @Test func anEvictedTileKeepsTheFrameItShows() throws {
        let thumbs = try source("ThumbnailStore.swift")
        #expect(thumbs.contains("shown?.hold(hit.image, key: shownKey)"), "a cache hit is held by the tile")
        #expect(thumbs.contains("if let image = shown?.image(for: shownKey) { return image }\n        guard let compositor"),
                "the held frame answers before any re-render")
        #expect(thumbs.contains("let shownKey = \"\\(cacheKey)|\\(mediaFilesGeneration)\""), "a file swap still re-renders")
        let grid = try source("PresentGridView.swift")
        #expect(grid.contains("@State private var shown = ThumbnailStore.ShownFrame()"))
        #expect(grid.contains("pixelWidth: pixelWidth,\n            shown: shown,"))
    }

    @Test func tileScenesNeverBindTheLivePlayer() throws {
        let thumbs = try source("ThumbnailStore.swift")
        #expect(thumbs.contains("let built = SlideSceneBuilder.withoutLayerMedia("))
    }
}

@Suite struct ThumbnailCacheCostSweepTests {
    @Test func everyCachedImageCostsItsBytes() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/ThumbnailStore.swift")
        let thumbs = try String(contentsOf: sources, encoding: .utf8)
        #expect(thumbs.contains("private static func cost(of image: CGImage) -> Int {\n        image.bytesPerRow * image.height\n    }"))
        let sets = thumbs.components(separatedBy: ".setObject(Box(").count - 1
        let costed = thumbs.components(separatedBy: "cost: Self.cost(of: image))").count - 1
        #expect(sets > 0 && sets == costed, "an image with no cost never ages out")
    }
}
