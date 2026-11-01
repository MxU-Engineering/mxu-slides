import CoreGraphics
import RenderEngine
import XCTest
@testable import OutputEngine

private func program(_ side: CGFloat = 1920) -> RenderScene {
    var scene = RenderScene(canvasSize: CGSize(width: side, height: side * 9 / 16))
    scene.addItem(RenderItem(id: "bg", frame: .zero, content: .solid(.white)), to: .loopingVideos)
    scene.addItem(RenderItem(id: "lyric", frame: .zero, content: .solid(.white)), to: .slide)
    return scene
}

@MainActor
final class LayerPlacementRoutingTests: XCTestCase {
    private func makeManager() throws -> OutputManager {
        do {
            return OutputManager(compositor: try Compositor())
        } catch CompositorError.noMetalDevice {
            throw XCTSkip("no Metal device on this machine")
        }
    }

    private func wall(_ outputs: OutputManager) throws -> (left: UUID, right: UUID) {
        let left = try XCTUnwrap(outputs.addPlaceholderScreen(name: "Left", width: 1920, height: 1080)).id
        let right = try XCTUnwrap(outputs.addPlaceholderScreen(name: "Right", width: 1920, height: 1080)).id
        var map = ScreenMap()
        map.place(left, at: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        map.place(right, at: CGRect(x: 1920, y: 0, width: 1920, height: 1080))
        outputs.setScreenMap(map)
        return (left, right)
    }

    private func layer(_ kind: LayerKind, in scene: RenderScene) -> RenderLayer {
        scene.layers.first { $0.kind == kind }!
    }

    func testNoPlacementsRendersExactlyAsBefore() throws {
        let outputs = try makeManager()
        outputs.sceneProvider = { program() }
        let screens = try wall(outputs)
        outputs.setLayerRouting([screens.left.uuidString: [LayerKind.slide.rawValue]])
        let before = outputs.previewProvider(for: screens.left.uuidString)()
        outputs.setLayerPlacements([:])
        XCTAssertEqual(outputs.previewProvider(for: screens.left.uuidString)(), before)

        outputs.setLayerPlacements([LayerKind.alerts.rawValue: [MapPlacement(rect: CGRect(x: 0, y: 0, width: 100, height: 100))]])
        let after = outputs.previewProvider(for: screens.left.uuidString)()
        XCTAssertEqual(layer(.slide, in: after), layer(.slide, in: before))
        XCTAssertEqual(layer(.loopingVideos, in: after), layer(.loopingVideos, in: before))
    }

    func testASpannedLayerLandsHalfOnEachScreenAndIgnoresTheDot() throws {
        let outputs = try makeManager()
        outputs.sceneProvider = { program() }
        let screens = try wall(outputs)

        outputs.setLayerRouting([screens.left.uuidString: [LayerKind.slide.rawValue]])
        outputs.setLayerPlacements([LayerKind.loopingVideos.rawValue: [
            MapPlacement(rect: CGRect(x: 0, y: 0, width: 3840, height: 1080), fill: true),
        ]])
        let left = layer(.loopingVideos, in: outputs.previewProvider(for: screens.left.uuidString)())
        let right = layer(.loopingVideos, in: outputs.previewProvider(for: screens.right.uuidString)())
        XCTAssertFalse(left.isHidden)
        XCTAssertEqual(left.placed, PlacedLayer(
            canvasSize: CGSize(width: 1920, height: 1080),
            frames: [.init(rect: CGRect(x: 0, y: 0, width: 3840, height: 1080), fill: true)]))
        XCTAssertEqual(right.placed?.frames.first?.rect, CGRect(x: -1920, y: 0, width: 3840, height: 1080),
                       "the right piece shows the right half")
        XCTAssertEqual(left.items.map(\.id), ["bg"], "the picture is the layer itself")
    }

    func testPlacedElsewhereDrawsNothingHereAndOffTheMapFollowsTheDot() throws {
        let outputs = try makeManager()
        outputs.sceneProvider = { program() }
        let screens = try wall(outputs)
        let lobby = try XCTUnwrap(outputs.addPlaceholderScreen(name: "Lobby", width: 1920, height: 1080)).id
        outputs.setLayerPlacements([LayerKind.loopingVideos.rawValue: [
            MapPlacement(rect: CGRect(x: 1920, y: 0, width: 1920, height: 1080)),
        ]])
        XCTAssertTrue(layer(.loopingVideos, in: outputs.previewProvider(for: screens.left.uuidString)()).isHidden)
        XCTAssertFalse(layer(.loopingVideos, in: outputs.previewProvider(for: screens.right.uuidString)()).isHidden)
        let offMap = layer(.loopingVideos, in: outputs.previewProvider(for: lobby.uuidString)())
        XCTAssertFalse(offMap.isHidden)
        XCTAssertNil(offMap.placed, "a screen off the map keeps its dot")

        outputs.setRole(.confidence, forScreen: screens.left)
        outputs.confidenceSceneProvider = { _ in program(100) }
        XCTAssertNil(layer(.loopingVideos, in: outputs.previewProvider(for: screens.left.uuidString)()).placed)
    }

    func testAPlacedSlideLayerTakesTheLookOfTheScreenItMostlyLandsOn() throws {
        let outputs = try makeManager()
        outputs.sceneProvider = { program() }
        let screens = try wall(outputs)
        var variant = program()
        variant.addItem(RenderItem(id: "themed", frame: .zero, content: .solid(.white)), to: .slide)
        let themed = variant
        outputs.variantSceneProvider = { $0 == "wall-look" ? themed : nil }
        outputs.setSlideThemeRouting([screens.right.uuidString: "wall-look"])

        outputs.setLayerPlacements([LayerKind.slide.rawValue: [
            MapPlacement(rect: CGRect(x: 1440, y: 0, width: 1920, height: 1080)),
        ]])
        let onLeft = layer(.slide, in: outputs.previewProvider(for: screens.left.uuidString)())
        XCTAssertEqual(onLeft.items.map(\.id), ["lyric", "themed"], "the left piece draws the right piece's look")
        XCTAssertEqual(onLeft.placed?.frames.first?.rect.minX, 1440)
    }
}
