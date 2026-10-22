import PresenterCore
import XCTest
@testable import SlideScene

final class TransitionEditTests: XCTestCase {
    func testDurationChoicesKeepAnOffPresetCurrentValue() {
        XCTAssertEqual(TransitionEdit.durationChoices(current: nil), [0.5, 1, 1.5, 2, 3])
        XCTAssertEqual(
            TransitionEdit.durationChoices(current: Transition(transitionKind: .dissolve, durationSeconds: 0.6000000238)),
            [0.5, 0.6, 1, 1.5, 2, 3])
    }

    func testLabelsReadInSeconds() {
        XCTAssertEqual(TransitionEdit.label(seconds: 1), "1 s")
        XCTAssertEqual(TransitionEdit.label(seconds: 1.5), "1.5 s")
        XCTAssertEqual(TransitionEdit.label(seconds: 0.4115), "0.41 s")
    }

    func testKindAndDurationEdits() {
        let dissolve = Transition(transitionKind: .dissolve, durationSeconds: 2, colorHex: "#FF0000FF")
        XCTAssertNil(TransitionEdit.withKind(nil, from: dissolve), "nil kind = room default")
        XCTAssertEqual(
            TransitionEdit.withKind(.fadeColor, from: dissolve),
            Transition(transitionKind: .fadeColor, durationSeconds: 2, colorHex: "#FF0000FF"))
        XCTAssertEqual(TransitionEdit.withDuration(12, from: dissolve)?.durationSeconds, 12, "typed past the slider")
        XCTAssertEqual(TransitionEdit.withDuration(45, from: dissolve)?.durationSeconds, 30, "clamped to what can be typed")
        XCTAssertNil(TransitionEdit.withDuration(1, from: nil), "no transition stays none")
    }
}
