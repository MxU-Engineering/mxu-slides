import CoreGraphics
import RenderEngine
import XCTest
@testable import OutputEngine

private func taggedScene(_ side: CGFloat) -> RenderScene {
    RenderScene(canvasSize: CGSize(width: side, height: side))
}

@MainActor
final class SlideThemeRoutingTests: XCTestCase {
    private func makeManager() throws -> OutputManager {
        do {
            return OutputManager(compositor: try Compositor())
        } catch CompositorError.noMetalDevice {
            throw XCTSkip("no Metal device on this machine")
        }
    }

    func testThemeRoutedTargetCompositesItsVariant() throws {
        let outputs = try makeManager()
        let stream = UUID().uuidString
        let projector = UUID().uuidString
        outputs.sceneProvider = { taggedScene(100) }
        outputs.variantSceneProvider = { themeID in
            themeID == "lower-third" ? taggedScene(200) : nil
        }
        outputs.setSlideThemeRouting([stream: "lower-third"])

        XCTAssertEqual(outputs.previewProvider(for: stream)().canvasSize.width, 200,
                       "the stream feed composites the lower-third variant")
        XCTAssertEqual(outputs.previewProvider(for: projector)().canvasSize.width, 100,
                       "unrouted outputs keep the base scene — WYSIWYG")

        let provider = outputs.previewProvider(for: stream)
        outputs.setSlideThemeRouting([:])
        XCTAssertEqual(provider().canvasSize.width, 100,
                       "clearing the routing returns the output to the base scene")
    }

    func testMissingVariantFallsBackToBaseNeverBlank() throws {
        let outputs = try makeManager()
        let stream = UUID().uuidString
        outputs.sceneProvider = { taggedScene(100) }
        outputs.variantSceneProvider = { _ in nil } 
        outputs.setSlideThemeRouting([stream: "lower-third"])
        XCTAssertEqual(outputs.previewProvider(for: stream)().canvasSize.width, 100)
    }

    func testLayerRoutingAppliesToTheVariantScene() throws {
        let outputs = try makeManager()
        let stream = UUID().uuidString
        var variant = taggedScene(200)
        variant.addItem(
            RenderItem(id: "x", frame: .zero, content: .solid(.white)), to: .alerts
        )
        variant.addItem(
            RenderItem(id: "y", frame: .zero, content: .solid(.white)), to: .slide
        )
        let scene = variant
        outputs.sceneProvider = { taggedScene(100) }
        outputs.variantSceneProvider = { _ in scene }
        outputs.setSlideThemeRouting([stream: "lower-third"])
        outputs.setLayerRouting([stream: [LayerKind.slide.rawValue]])

        let composited = outputs.previewProvider(for: stream)()
        XCTAssertEqual(composited.canvasSize.width, 200)
        XCTAssertTrue(composited.layers.first { $0.kind == .alerts }!.isHidden,
                      "non-routed layers hide on the variant exactly like the base")
        XCTAssertFalse(composited.layers.first { $0.kind == .slide }!.isHidden)
    }
}
