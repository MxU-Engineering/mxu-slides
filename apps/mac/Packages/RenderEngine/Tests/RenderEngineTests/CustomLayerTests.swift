import Metal
import XCTest
@testable import RenderEngine

@MainActor
final class CustomLayerTests: XCTestCase {
    func testInsertLandsAboveTheNamedLayerOnce() {
        var scene = RenderScene()
        scene.insertCustomLayer(id: "lower", name: "Lower", above: "slide")
        scene.insertCustomLayer(id: "lower", name: "Lower", above: "slide")
        scene.insertCustomLayer(id: "top", name: "Top", above: "lower")
        scene.insertCustomLayer(id: "lost", name: "Lost", above: "nowhere")
        let ids = scene.layers.map(\.id)
        XCTAssertEqual(ids.filter { $0 == "lower" }.count, 1)
        let slide = ids.firstIndex(of: "slide")!
        XCTAssertEqual(ids[slide + 1 ..< slide + 4], ["lost", "lower", "top"],
                       "an unknown anchor lands above the slide; a custom anchor works too")
        XCTAssertNil(scene.layers[slide + 1].kind)
        XCTAssertTrue(scene.layers[slide + 1].isMediaLayer)
    }

    func testACustomLayerAboveTheSlideCoversIt() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("No Metal device") }
        let compositor = try Compositor()
        let canvas = CGSize(width: 192, height: 108)
        var scene = RenderScene(canvasSize: canvas)
        let full = CGRect(origin: .zero, size: canvas)
        scene.addItem(RenderItem(id: "lyric", frame: full, content: .solid(SceneColor(red: 0, green: 1, blue: 0))), to: .slide)
        scene.insertCustomLayer(id: "lower", name: "Lower", above: "slide")
        scene.addItem(RenderItem(id: "bug", frame: CGRect(x: 0, y: 54, width: 192, height: 54),
                                 content: .solid(SceneColor(red: 1, green: 0, blue: 0))), toLayerID: "lower")
        let frame = try compositor.renderFrame(scene: scene, width: 192, height: 108)
        func red(_ y: Int) -> Float {
            frame.data.withUnsafeBytes { raw in
                Float(raw.baseAddress!.advanced(by: y * frame.bytesPerRow + 96 * 8).assumingMemoryBound(to: Float16.self)[0])
            }
        }
        XCTAssertLessThan(red(20), 0.1, "the top half is the slide's green")
        XCTAssertGreaterThan(red(90), 0.5, "the bottom half is the custom layer's red, over the slide")

        scene.layers[scene.layers.firstIndex { $0.id == "lower" }!].isHidden = true
        let hidden = try compositor.renderFrame(scene: scene, width: 192, height: 108)
        let bottom = hidden.data.withUnsafeBytes { raw in
            Float(raw.baseAddress!.advanced(by: 90 * hidden.bytesPerRow + 96 * 8).assumingMemoryBound(to: Float16.self)[0])
        }
        XCTAssertLessThan(bottom, 0.1)
    }
}
