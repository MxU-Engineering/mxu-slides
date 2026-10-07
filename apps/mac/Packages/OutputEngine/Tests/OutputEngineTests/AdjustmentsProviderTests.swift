import Foundation
import RenderEngine
import XCTest
@testable import OutputEngine

@MainActor
final class AdjustmentsProviderTests: XCTestCase {
    private func makeManager() throws -> OutputManager {
        do {
            return OutputManager(compositor: try Compositor())
        } catch CompositorError.noMetalDevice {
            throw XCTSkip("no Metal device on this machine")
        }
    }

    func testProviderSeesLiveEdits() throws {
        let outputs = try makeManager()
        let screen = UUID()
        let provider = outputs.adjustmentsProvider(for: screen.uuidString)
        XCTAssertNil(provider(), "untouched screen reads nil — mirror skips the pass")

        var adjustments = OutputAdjustments()
        adjustments.brightness = -0.5
        outputs.setAdjustments(adjustments, forScreen: screen)
        XCTAssertEqual(provider()?.brightness, -0.5, "a mid-service tweak reaches running mirrors")

        outputs.setAdjustments(OutputAdjustments(), forScreen: screen)
        XCTAssertNil(provider(), "reset to neutral reads nil again")
        XCTAssertNil(outputs.adjustmentsProvider(for: "not-a-uuid")())
    }

    func testRemovalClearsAdjustments() throws {
        let outputs = try makeManager()
        outputs.addPlaceholderScreen(name: "Doomed", width: 192, height: 108)
        let screen = try XCTUnwrap(outputs.placeholderScreens.first(where: { $0.name == "Doomed" }))
        var adjustments = OutputAdjustments()
        adjustments.gamma = 0.2
        outputs.setAdjustments(adjustments, forScreen: screen.id)
        let provider = outputs.adjustmentsProvider(for: screen.id.uuidString)
        outputs.removePlaceholderScreen(id: screen.id)
        XCTAssertNil(outputs.outputAdjustments[screen.id], "removal drops the stored correction")
        XCTAssertNil(provider(), "running feeds read the cleared value")
    }
}
