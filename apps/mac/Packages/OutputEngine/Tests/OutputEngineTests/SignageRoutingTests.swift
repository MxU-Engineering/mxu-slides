import CoreGraphics
import RenderEngine
import XCTest
@testable import OutputEngine

private func taggedScene(_ side: CGFloat) -> RenderScene {
    RenderScene(canvasSize: CGSize(width: side, height: side))
}

@MainActor
final class SignageRoutingTests: XCTestCase {
    private func makeManager() throws -> OutputManager {
        do {
            return OutputManager(compositor: try Compositor())
        } catch CompositorError.noMetalDevice {
            throw XCTSkip("no Metal device on this machine")
        }
    }

    func testAssignmentPresenceDivertsAndReleasesPerScreen() throws {
        let outputs = try makeManager()
        let lobby = UUID()
        let cafe = UUID()
        let auditorium = UUID()
        let assignments = Locked<[UUID: CGFloat]>([lobby: 200, cafe: 300])
        outputs.sceneProvider = { taggedScene(100) }
        outputs.signageSceneProvider = { screenID in
            assignments.value[screenID].map(taggedScene)
        }

        XCTAssertEqual(outputs.previewProvider(for: lobby.uuidString)().canvasSize.width, 200,
                       "the lobby loops ITS playlist")
        XCTAssertEqual(outputs.previewProvider(for: cafe.uuidString)().canvasSize.width, 300,
                       "the café loops a DIFFERENT playlist, simultaneously")
        XCTAssertEqual(outputs.previewProvider(for: auditorium.uuidString)().canvasSize.width, 100,
                       "unassigned screens composite the program")

        let provider = outputs.previewProvider(for: lobby.uuidString)
        assignments.value = [:]
        XCTAssertEqual(provider().canvasSize.width, 100,
                       "releasing the assignment returns the screen to program")
    }

    func testSignageOutranksConfidenceRoleAndRouting() throws {
        let outputs = try makeManager()
        let screen = UUID()
        outputs.setRole(.confidence, forScreen: screen)
        outputs.setLayerRouting([screen.uuidString: []])
        outputs.sceneProvider = { taggedScene(100) }
        outputs.confidenceSceneProvider = { _ in taggedScene(300) }
        outputs.signageSceneProvider = { _ in taggedScene(200) }

        XCTAssertEqual(outputs.previewProvider(for: screen.uuidString)().canvasSize.width, 200,
                       "an assigned screen shows signage regardless of role or routing")
    }
}
