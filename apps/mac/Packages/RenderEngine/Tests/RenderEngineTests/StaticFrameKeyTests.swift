import XCTest
@testable import RenderEngine

final class StaticFrameKeyTests: XCTestCase {
    private final class Stills: MediaTextureSource, @unchecked Sendable {
        let generations: [String: UInt64]
        init(_ generations: [String: UInt64]) { self.generations = generations }
        func surface(for mediaID: String, hostTime: CFTimeInterval) -> MediaSurface? { nil }
        func stillGeneration(for mediaID: String) -> UInt64? { generations[mediaID] }
    }

    private func scene(_ content: ItemContent) -> RenderScene {
        var scene = RenderScene(canvasSize: CGSize(width: 192, height: 108))
        scene.addItem(
            RenderItem(id: "i", frame: CGRect(x: 0, y: 0, width: 100, height: 100), content: content),
            to: .slide
        )
        return scene
    }

    func testStillsKeyByGenerationAndMovingMediaIsNil() throws {
        let compositor: Compositor
        do { compositor = try Compositor() } catch CompositorError.noMetalDevice {
            throw XCTSkip("no Metal device on this machine")
        }
        let still = scene(.media(id: "slide.jpg", scaleMode: .fill, sourceRect: nil))
        let fill = scene(.shape(ShapeStyle(kind: .rectangle, fill: .media(id: "clip", scaleMode: .fill))))

        XCTAssertNil(compositor.staticFrameKey(for: still), "no source vouches for a still: it moves")

        let source = Stills(["slide.jpg": 7])
        compositor.mediaSource = source
        XCTAssertEqual(compositor.staticFrameKey(for: still), [7])
        XCTAssertEqual(compositor.staticFrameKey(for: scene(.solid(.white))), [])
        XCTAssertNil(compositor.staticFrameKey(for: fill), "a media-filled shape over a player moves")

        var hidden = fill
        hidden.setLayerHidden(true, kind: .slide)
        XCTAssertEqual(compositor.staticFrameKey(for: hidden), [], "hidden layers don't count")
    }
}
