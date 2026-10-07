import CoreGraphics
import RenderEngine
import XCTest
@testable import OutputEngine

private func taggedScene(_ side: CGFloat) -> RenderScene {
    RenderScene(canvasSize: CGSize(width: side, height: side))
}

@MainActor
final class ConfidenceRoutingTests: XCTestCase {
    private func makeManager() throws -> OutputManager {
        do {
            return OutputManager(compositor: try Compositor())
        } catch CompositorError.noMetalDevice {
            throw XCTSkip("no Metal device on this machine")
        }
    }

    func testConfidenceScreensCompositePerScreenScenes() throws {
        let outputs = try makeManager()
        let band = UUID()
        let speaker = UUID()
        let audience = UUID()
        outputs.setRole(.confidence, forScreen: band)
        outputs.setRole(.confidence, forScreen: speaker)
        outputs.sceneProvider = { taggedScene(100) }
        outputs.confidenceSceneProvider = { screenID in
            taggedScene(screenID == band ? 200 : 300)
        }

        XCTAssertEqual(outputs.previewProvider(for: band.uuidString)().canvasSize.width, 200,
                       "the band screen composites ITS layout")
        XCTAssertEqual(outputs.previewProvider(for: speaker.uuidString)().canvasSize.width, 300,
                       "the speaker screen composites a DIFFERENT layout")
        XCTAssertEqual(outputs.previewProvider(for: audience.uuidString)().canvasSize.width, 100,
                       "audience targets composite the program scene")
    }

    func testRoleFlipReachesTheProviderOnItsNextPull() throws {
        let outputs = try makeManager()
        let screen = UUID()
        outputs.sceneProvider = { taggedScene(100) }
        outputs.confidenceSceneProvider = { _ in taggedScene(200) }

        let provider = outputs.previewProvider(for: screen.uuidString)
        XCTAssertEqual(provider().canvasSize.width, 100)
        outputs.setRole(.confidence, forScreen: screen)
        XCTAssertEqual(provider().canvasSize.width, 200,
                       "an already-created provider honors the flip per frame")
        outputs.setRole(.audience, forScreen: screen)
        XCTAssertEqual(provider().canvasSize.width, 100)
    }
}
