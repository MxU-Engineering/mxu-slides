import Metal
import RenderEngine
import XCTest
@testable import OutputEngine

@MainActor
final class PlaceholderScreenTests: XCTestCase {
    private func makeCompositor() throws -> Compositor {
        do {
            return try Compositor()
        } catch CompositorError.noMetalDevice {
            throw XCTSkip("no Metal device on this machine")
        }
    }

    private func solidWhiteScene() -> RenderScene {
        var scene = RenderScene(canvasSize: CGSize(width: 1080, height: 1920))
        scene.addItem(
            RenderItem(
                id: "fill",
                frame: CGRect(x: 0, y: 0, width: 1080, height: 1920),
                content: .solid(.white)
            ),
            to: .stillGraphics
        )
        return scene
    }

    private func pixel(_ frame: RenderedFrame, x: Int, y: Int) -> [Float] {
        let offset = y * frame.bytesPerRow + x * 8
        return (0..<4).map { channel in
            let lo = UInt16(frame.data[offset + channel * 2])
            let hi = UInt16(frame.data[offset + channel * 2 + 1])
            return Float(Float16(bitPattern: hi << 8 | lo))
        }
    }

    func testVerticalPlaceholderScreenRendersArbitraryResolution() throws {
        let compositor = try makeCompositor()
        let screen = try XCTUnwrap(PlaceholderScreen(
            compositor: compositor, name: "Vertical 9:16", width: 1080, height: 1920
        ))
        let scene = solidWhiteScene()
        screen.sceneProvider = { scene }

        screen.renderNow(at: 0)
        XCTAssertEqual(screen.framesRendered, 1)

        let frame = try compositor.readback(texture: screen.texture)
        XCTAssertEqual(frame.width, 1080)
        XCTAssertEqual(frame.height, 1920)
        let center = pixel(frame, x: 540, y: 960)
        XCTAssertEqual(center, [1, 1, 1, 1], "portrait canvas fills the portrait target edge-to-edge")
    }

    func testStaticSceneRendersOnceThenSkips() throws {

        let compositor = try makeCompositor()
        let screen = try XCTUnwrap(PlaceholderScreen(
            compositor: compositor, name: "Static", width: 108, height: 192
        ))
        let scene = solidWhiteScene()
        screen.sceneProvider = { scene }

        screen.renderNow(at: 0)
        screen.renderNow(at: 1)
        screen.renderNow(at: 2)
        XCTAssertEqual(screen.framesRendered, 1, "equal static scenes skip the encode")

        let changed: RenderScene = {
            var scene = scene
            scene.background = .white
            return scene
        }()
        screen.sceneProvider = { changed }
        screen.renderNow(at: 3)
        XCTAssertEqual(screen.framesRendered, 2, "a changed scene renders again")
        screen.renderNow(at: 4)
        XCTAssertEqual(screen.framesRendered, 2, "and then skips again")
    }

    func testStartStopControlsPacing() throws {
        let compositor = try makeCompositor()
        let screen = try XCTUnwrap(PlaceholderScreen(
            compositor: compositor, name: "Vertical 9:16", width: 108, height: 192
        ))
        XCTAssertFalse(screen.isRunning)
        screen.start()
        XCTAssertTrue(screen.isRunning)
        screen.start() 
        screen.stop()
        XCTAssertFalse(screen.isRunning)
    }

    func testZeroSizeIsRejected() throws {
        let compositor = try makeCompositor()
        XCTAssertNil(PlaceholderScreen(compositor: compositor, name: "bad", width: 0, height: 1080))
        XCTAssertNil(PlaceholderScreen(
            compositor: compositor, name: "bad", width: 1080, height: 1080, framesPerSecond: 0
        ))
    }

    func testPresentPathLetterboxesPreview() throws {

        let compositor = try makeCompositor()
        let screen = try XCTUnwrap(PlaceholderScreen(
            compositor: compositor, name: "Vertical 9:16", width: 1080, height: 1920
        ))
        let scene = solidWhiteScene()
        screen.sceneProvider = { scene }
        screen.renderNow(at: 0)

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: Compositor.pixelFormat, width: 480, height: 270, mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        let previewTarget = try XCTUnwrap(compositor.device.makeTexture(descriptor: descriptor))
        compositor.present(texture: screen.texture, into: previewTarget)

        let frame = try compositor.readback(texture: previewTarget)

        XCTAssertEqual(pixel(frame, x: 240, y: 135), [1, 1, 1, 1], "center shows the white screen")
        XCTAssertEqual(pixel(frame, x: 20, y: 135), [0, 0, 0, 1], "left pillarbox is opaque black")
        XCTAssertEqual(pixel(frame, x: 460, y: 135), [0, 0, 0, 1], "right pillarbox is opaque black")
    }
}
