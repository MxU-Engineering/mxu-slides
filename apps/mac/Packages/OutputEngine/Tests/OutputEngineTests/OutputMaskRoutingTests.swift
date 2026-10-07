import Foundation
import Metal
import RenderEngine
import XCTest
@testable import OutputEngine

@MainActor
final class OutputMaskRoutingTests: XCTestCase {
    private func makeManager() throws -> OutputManager {
        do {
            return OutputManager(compositor: try Compositor())
        } catch CompositorError.noMetalDevice {
            throw XCTSkip("no Metal device on this machine")
        }
    }

    private let band = "M 0.25 0 L 0.75 0 L 0.75 1 L 0.25 1 Z"

    func testActiveSetIsAlwaysOnPlusPresetActivated() throws {
        let outputs = try makeManager()
        let screen = try XCTUnwrap(
            outputs.addPlaceholderScreen(name: "Main", width: 192, height: 108))
        let column = OutputMask(name: "Column", pathData: band, alwaysOn: true)
        let sermon = OutputMask(name: "Sermon wings", pathData: band, alwaysOn: false)
        outputs.setMasks([column, sermon], forScreen: screen.id)

        XCTAssertEqual(
            outputs.activeMasks(forScreen: screen.id).map(\.id), [column.id],
            "room geometry applies with no preset activation")

        outputs.setActiveMaskIDs([sermon.id], forScreen: screen.id)
        XCTAssertEqual(
            outputs.activeMasks(forScreen: screen.id).map(\.id), [column.id, sermon.id],
            "a preset switch adds its masks to the alwaysOn set")

        outputs.setActiveMaskIDs([], forScreen: screen.id)
        XCTAssertEqual(outputs.activeMasks(forScreen: screen.id).map(\.id), [column.id])
    }

    func testMaskPushReachesScreenTextureAndProvider() throws {
        let outputs = try makeManager()
        let screen = try XCTUnwrap(
            outputs.addPlaceholderScreen(name: "Main", width: 192, height: 108))
        let provider = outputs.maskProvider(for: screen.id.uuidString)
        XCTAssertNil(provider(), "no masks = raw feed")
        XCTAssertNil(screen.outputMask)

        outputs.setMasks(
            [OutputMask(name: "Column", pathData: band)], forScreen: screen.id)
        let pushed = try XCTUnwrap(screen.outputMask, "screen texture path gets the raster")
        XCTAssertTrue(provider() === pushed, "feed mirrors read the same raster")
        XCTAssertEqual(pushed.width, 192, "raster is canvas-sized")

        outputs.setMasks([], forScreen: screen.id)
        XCTAssertNil(provider(), "clearing the library clears the feed")
        XCTAssertNil(screen.outputMask)
    }

    func testPresetFlipReusesCachedRasters() throws {
        let outputs = try makeManager()
        let screen = try XCTUnwrap(
            outputs.addPlaceholderScreen(name: "Main", width: 192, height: 108))
        let column = OutputMask(name: "Column", pathData: band, alwaysOn: true)
        outputs.setMasks([column], forScreen: screen.id)
        let first = try XCTUnwrap(screen.outputMask)
        outputs.setActiveMaskIDs([], forScreen: screen.id)  
        XCTAssertTrue(screen.outputMask === first, "unchanged active set keeps its raster")
    }

    func testMasksPersistViaConfigurationHookAndCleanUpOnRemoval() throws {
        let outputs = try makeManager()
        let screen = try XCTUnwrap(
            outputs.addPlaceholderScreen(name: "Doomed", width: 192, height: 108))
        var saves = 0
        outputs.placeholderConfigurationChanged = { saves += 1 }
        let mask = OutputMask(name: "Column", pathData: band)
        outputs.setMasks([mask], forScreen: screen.id)
        XCTAssertEqual(saves, 1, "library edits persist")
        outputs.setMasks([mask], forScreen: screen.id)
        XCTAssertEqual(saves, 1, "no-op sets don't churn the save path")
        outputs.setActiveMaskIDs([mask.id], forScreen: screen.id)
        XCTAssertEqual(saves, 1, "preset activation is runtime state, never persisted")

        let provider = outputs.maskProvider(for: screen.id.uuidString)
        outputs.removePlaceholderScreen(id: screen.id)
        XCTAssertTrue(outputs.masks(forScreen: screen.id).isEmpty)
        XCTAssertNil(provider(), "running feeds read the cleared value")
    }
}
