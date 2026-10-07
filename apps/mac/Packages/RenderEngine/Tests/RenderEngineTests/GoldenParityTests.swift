import Metal
import XCTest
@testable import RenderEngine

@MainActor
final class GoldenParityTests: XCTestCase {
    private func makeCompositor() throws -> Compositor {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("No Metal device available on this machine")
        }
        return try Compositor()
    }

    private func pixel(_ frame: RenderedFrame, x: Int, y: Int) -> SIMD4<Float> {
        var out = SIMD4<Float>()
        frame.data.withUnsafeBytes { raw in
            let base = raw.baseAddress! + y * frame.bytesPerRow + x * 8
            let halves = base.assumingMemoryBound(to: Float16.self)
            out = SIMD4(Float(halves[0]), Float(halves[1]), Float(halves[2]), Float(halves[3]))
        }
        return out
    }

    func testEditorCanvasAndOutputPixelsAreIdentical() throws {
        let compositor = try makeCompositor()
        let scene = RenderScene.sampleLyricScene()

        let editorCanvas = try compositor.renderFrame(scene: scene, width: 1920, height: 1080)
        let outputWindow = try compositor.renderFrame(scene: scene, width: 1920, height: 1080)

        XCTAssertEqual(editorCanvas.data, outputWindow.data,
                       "Editor canvas and output must be byte-for-byte identical")

        var withoutText = scene
        withoutText.setLayerHidden(true, kind: .slide)
        let bare = try compositor.renderFrame(scene: withoutText, width: 1920, height: 1080)
        XCTAssertNotEqual(editorCanvas.data, bare.data,
                          "The text layer must contribute rendered pixels")
    }

    func testParityHoldsAcrossEngineRestart() throws {

        let scene = RenderScene.sampleLyricScene()
        let first = try makeCompositor().renderFrame(scene: scene, width: 960, height: 540)
        let second = try makeCompositor().renderFrame(scene: scene, width: 960, height: 540)
        XCTAssertEqual(first.data, second.data)
    }

    func testAllLayersHiddenRendersPureBlack() throws {

        let compositor = try makeCompositor()
        var scene = RenderScene.sampleLyricScene()
        for layer in scene.layers {
            scene.setLayerHidden(true, kind: layer.kind)
        }

        let frame = try compositor.renderFrame(scene: scene, width: 192, height: 108)
        for (x, y) in [(0, 0), (191, 0), (0, 107), (191, 107), (96, 54)] {
            let p = pixel(frame, x: x, y: y)
            XCTAssertEqual(p.x, 0, "empty scene must render black at (\(x),\(y))")
            XCTAssertEqual(p.y, 0, "empty scene must render black at (\(x),\(y))")
            XCTAssertEqual(p.z, 0, "empty scene must render black at (\(x),\(y))")
            XCTAssertEqual(p.w, 1, "empty scene must stay opaque at (\(x),\(y))")
        }
    }

    func testBackgroundRendersLinearizedP3() throws {
        let compositor = try makeCompositor()
        var scene = RenderScene()
        scene.background = SceneColor(red: 0.5, green: 0.25, blue: 0.75)

        let frame = try compositor.renderFrame(scene: scene, width: 192, height: 108)
        let center = pixel(frame, x: 96, y: 54)
        let expected = scene.background.linear

        XCTAssertEqual(center.x, Float(expected.x), accuracy: 0.005, "red should be linearized")
        XCTAssertEqual(center.y, Float(expected.y), accuracy: 0.005, "green should be linearized")
        XCTAssertEqual(center.z, Float(expected.z), accuracy: 0.005, "blue should be linearized")
        XCTAssertEqual(center.w, 1.0, accuracy: 0.005)
    }

    func testAspectMismatchLetterboxesInBlack() throws {
        let compositor = try makeCompositor()
        var scene = RenderScene() 
        scene.background = .white

        let frame = try compositor.renderFrame(scene: scene, width: 200, height: 200)
        let bar = pixel(frame, x: 100, y: 5)
        let canvas = pixel(frame, x: 100, y: 100)

        XCTAssertEqual(bar, SIMD4<Float>(0, 0, 0, 1), "letterbox must be opaque black")
        XCTAssertEqual(canvas.x, 1.0, accuracy: 0.005, "canvas region must show the scene")
    }

    func testTextRendersInkInsideItsFrame() throws {
        let compositor = try makeCompositor()
        var scene = RenderScene()
        scene.background = .black
        scene.addItem(
            RenderItem(
                id: "t",
                frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                content: .text(StyledText(string: "GRACE", fontSize: 400, color: .white))
            ),
            to: .slide
        )

        let frame = try compositor.renderFrame(scene: scene, width: 960, height: 540)
        var maxLuminance: Float = 0
        for y in stride(from: 0, to: 540, by: 4) {
            for x in stride(from: 0, to: 960, by: 4) {
                maxLuminance = max(maxLuminance, pixel(frame, x: x, y: y).x)
            }
        }
        XCTAssertGreaterThan(maxLuminance, 0.9, "white text should reach near-full linear luminance")
    }
}
