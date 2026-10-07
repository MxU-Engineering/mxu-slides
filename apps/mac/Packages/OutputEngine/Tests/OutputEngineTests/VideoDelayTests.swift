import Foundation
import RenderEngine
import XCTest
@testable import OutputEngine

@MainActor
final class VideoDelayTests: XCTestCase {
    private func makeManager() throws -> OutputManager {
        do {
            return OutputManager(compositor: try Compositor())
        } catch CompositorError.noMetalDevice {
            throw XCTSkip("no Metal device on this machine")
        }
    }

    func testDelayRoundTripsAndClamps() throws {
        let outputs = try makeManager()
        let screen = UUID()
        outputs.setVideoDelay(5, forScreen: screen)
        XCTAssertEqual(outputs.videoDelay(forScreen: screen), 5)
        outputs.setVideoDelay(999, forScreen: screen)
        XCTAssertEqual(
            outputs.videoDelay(forScreen: screen), OutputManager.maxVideoDelayFrames)
        outputs.setVideoDelay(0, forScreen: screen)
        XCTAssertEqual(outputs.videoDelay(forScreen: screen), 0)
        XCTAssertNil(outputs.videoDelays[screen], "zero is absence, not a stored zero")
    }

    func testProviderSeesLiveEdits() throws {
        let outputs = try makeManager()
        let screen = UUID()
        let provider = outputs.videoDelayProvider(for: screen.uuidString)
        XCTAssertEqual(provider(), 0)
        outputs.setVideoDelay(3, forScreen: screen)
        XCTAssertEqual(provider(), 3, "a mid-service nudge reaches running mirrors")
        XCTAssertEqual(outputs.videoDelayProvider(for: "not-a-uuid")(), 0)
    }

    func testDelayChangeNotifiesPersistence() throws {
        let outputs = try makeManager()
        var saves = 0
        outputs.placeholderConfigurationChanged = { saves += 1 }
        let screen = UUID()
        outputs.setVideoDelay(4, forScreen: screen)
        XCTAssertEqual(saves, 1)
        outputs.setVideoDelay(4, forScreen: screen)
        XCTAssertEqual(saves, 1, "no-op sets don't churn the save path")
    }

    func testRemovingAScreenDropsItsDelay() throws {
        let outputs = try makeManager()
        guard let screen = outputs.addPlaceholderScreen(
            name: "Test", width: 64, height: 36) else {
            return XCTFail("placeholder screen")
        }
        outputs.setVideoDelay(6, forScreen: screen.id)
        let provider = outputs.videoDelayProvider(for: screen.id.uuidString)
        outputs.removePlaceholderScreen(id: screen.id)
        XCTAssertEqual(outputs.videoDelay(forScreen: screen.id), 0)
        XCTAssertEqual(provider(), 0, "running feeds read the cleared value")
    }
}
