import XCTest
@testable import RenderEngine

final class SceneModelTests: XCTestCase {
    func testDefaultStackMatchesPRDOrder() {

        let kinds = RenderScene.defaultLayerStack().map(\.kind)
        XCTAssertEqual(kinds, [
            .videoInput, .loopingVideos, .stillGraphics, .videos,
            .slide, .overlays, .alerts,
        ])
    }

    func testRenderItemClampsOpacity() {

        let over = RenderItem(
            id: "o", frame: .zero, content: .solid(.white), opacity: 100
        )
        XCTAssertEqual(over.opacity, 1)
        let under = RenderItem(
            id: "u", frame: .zero, content: .solid(.white), opacity: -2
        )
        XCTAssertEqual(under.opacity, 0)
    }

    func testRemappingMediaIDsPreservesEverythingButTheID() {

        let crop = SceneSourceRect(x: 0.1, y: 0.2, width: 0.5, height: 0.25)
        var scene = RenderScene()
        scene.addItem(
            RenderItem(
                id: "obj", frame: CGRect(x: 0, y: 0, width: 10, height: 10),
                content: .media(id: "lib-1", scaleMode: .fit, sourceRect: crop)
            ),
            to: .slide
        )
        scene.addItem(
            RenderItem(
                id: "fill", frame: CGRect(x: 0, y: 0, width: 10, height: 10),
                content: .shape(ShapeStyle(
                    kind: .rectangle,
                    fill: .media(id: "lib-2", scaleMode: .stretch, sourceRect: crop)
                ))
            ),
            to: .slide
        )

        let remapped = scene.remappingMediaIDs { "edit::" + $0 }
        let items = remapped.layers.first { $0.kind == .slide }!.items
        XCTAssertEqual(
            items[0].content, .media(id: "edit::lib-1", scaleMode: .fit, sourceRect: crop)
        )
        guard case .shape(let style) = items[1].content else {
            return XCTFail("expected shape content")
        }
        XCTAssertEqual(
            style.fill, .media(id: "edit::lib-2", scaleMode: .stretch, sourceRect: crop)
        )
    }

    func testAddItemTargetsTheRightLayer() {
        var scene = RenderScene()
        let item = RenderItem(
            id: "x",
            frame: CGRect(x: 0, y: 0, width: 10, height: 10),
            content: .solid(.white)
        )
        scene.addItem(item, to: .overlays)
        let overlays = scene.layers.first { $0.kind == .overlays }
        XCTAssertEqual(overlays?.items.map(\.id), ["x"])
        XCTAssertTrue(scene.layers.filter { $0.kind != .overlays }.allSatisfy(\.items.isEmpty))
    }

    func testLinearizationEndpoints() {
        XCTAssertEqual(SceneColor.srgbToLinear(0), 0)
        XCTAssertEqual(SceneColor.srgbToLinear(1), 1, accuracy: 1e-9)

        XCTAssertEqual(SceneColor.srgbToLinear(0.5), 0.2140, accuracy: 0.001)
    }

    func testPremultiplicationHappensInLinearSpace() {
        let color = SceneColor(red: 1, green: 0.5, blue: 0, alpha: 0.5)
        let premultiplied = color.linearPremultiplied
        XCTAssertEqual(premultiplied.x, 0.5, accuracy: 0.001)
        XCTAssertEqual(premultiplied.y, Float(SceneColor.srgbToLinear(0.5)) * 0.5, accuracy: 0.001)
        XCTAssertEqual(premultiplied.w, 0.5, accuracy: 0.001)
    }
}
