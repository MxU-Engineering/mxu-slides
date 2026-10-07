import Metal
import QuartzCore
import XCTest
@testable import RenderEngine

@MainActor
final class TextureCacheEvictionTests: XCTestCase {
    private func makeCompositor() throws -> Compositor {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("No Metal device available on this machine")
        }
        return try Compositor()
    }

    private func scene(text: String) -> RenderScene {
        var scene = RenderScene(canvasSize: CGSize(width: 192, height: 108))
        scene.addItem(
            RenderItem(
                id: "timer",
                frame: CGRect(x: 0, y: 0, width: 192, height: 54),
                content: .text(StyledText(string: text, fontSize: 24))
            ),
            to: .slide
        )
        scene.addItem(
            RenderItem(
                id: "shape",
                frame: CGRect(x: 48, y: 58, width: 96, height: 44),
                content: .shape(ShapeStyle(kind: .rectangle, fill: .solid(.white)))
            ),
            to: .slide
        )
        return scene
    }

    func testStaleDynamicTextIsSwept() throws {
        let compositor = try makeCompositor()

        for second in 0..<30 {
            _ = try compositor.renderFrame(
                scene: scene(text: String(format: "0:%02d", second)),
                width: 192, height: 108
            )
        }
        XCTAssertEqual(compositor.textTextureCount, 30)
        XCTAssertEqual(compositor.shapeTextureCount, 1)

        compositor.sweepCaches(at: CACurrentMediaTime() + Compositor.cacheTTL + 1)
        XCTAssertEqual(compositor.textTextureCount, 0)
        XCTAssertEqual(compositor.shapeTextureCount, 0)

        _ = try compositor.renderFrame(scene: scene(text: "0:30"), width: 192, height: 108)
        _ = try compositor.renderFrame(scene: scene(text: "0:30"), width: 192, height: 108)
        XCTAssertEqual(compositor.textTextureCount, 1)
        XCTAssertEqual(compositor.shapeTextureCount, 1)
    }

    func testHotEntriesSurviveSweep() throws {
        let compositor = try makeCompositor()
        _ = try compositor.renderFrame(scene: scene(text: "grace"), width: 192, height: 108)

        compositor.sweepCaches(at: CACurrentMediaTime())
        XCTAssertEqual(compositor.textTextureCount, 1)
        XCTAssertEqual(compositor.shapeTextureCount, 1)
    }

    func testEncodeDrivenSweepEvictsAbandonedEntries() throws {
        let compositor = try makeCompositor()
        _ = try compositor.renderFrame(scene: scene(text: "left behind"), width: 192, height: 108)
        XCTAssertEqual(compositor.textTextureCount, 1)

        compositor.cacheClockOverride = { CACurrentMediaTime() + Compositor.cacheTTL + 2 }
        _ = try compositor.renderFrame(scene: scene(text: "current"), width: 192, height: 108)
        XCTAssertEqual(compositor.textTextureCount, 1)
        XCTAssertEqual(compositor.shapeTextureCount, 1)
    }
}
