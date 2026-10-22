import AppKit
import XCTest
@testable import OutputEngine

@MainActor
final class OutputCloseAffordanceTests: XCTestCase {
    func testCloseButtonShowsOnMoveAndHidesWhenTheMouseRests() {
        let view = OutputContentView(sceneView: NSView(), hideDelay: 0.05, onClose: {})
        XCTAssertFalse(view.isCloseButtonShown, "hidden until the mouse moves")

        view.showCloseButton()
        XCTAssertTrue(view.isCloseButtonShown)

        let rested = expectation(description: "hidden after the delay")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            XCTAssertFalse(view.isCloseButtonShown)
            rested.fulfill()
        }
        wait(for: [rested], timeout: 2)
    }

    func testMouseLeavingHidesAndTheXCloses() {
        var closes = 0
        let view = OutputContentView(sceneView: NSView(), onClose: { closes += 1 })
        view.showCloseButton()
        view.hideCloseButton()
        XCTAssertFalse(view.isCloseButtonShown)

        view.showCloseButton()
        view.closeButton.performClick(nil)
        XCTAssertEqual(closes, 1)
    }

    func testOnlyTheSoleScreenTakesTheKeyboard() {
        XCTAssertTrue(OutputWindowController.takesKeyFocus(screenCount: 1))
        XCTAssertFalse(OutputWindowController.takesKeyFocus(screenCount: 2))
    }
}
