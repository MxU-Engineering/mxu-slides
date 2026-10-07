import XCTest
@testable import OutputEngine

@MainActor
private final class AssertionRecorder: PowerAsserting {
    var begins = 0
    var ends = 0

    func beginAssertions(reason: String) { begins += 1 }
    func endAssertions() { ends += 1 }
}

@MainActor
final class SleepProofingTests: XCTestCase {
    func testFirstLiveOutputBeginsAssertionsOnce() {
        let recorder = AssertionRecorder()
        let proofing = SleepProofing(assertions: recorder)

        proofing.setLiveOutputCount(1)
        XCTAssertTrue(proofing.isActive)
        XCTAssertEqual(recorder.begins, 1)

        proofing.setLiveOutputCount(3)
        XCTAssertEqual(recorder.begins, 1)
        XCTAssertEqual(recorder.ends, 0)
    }

    func testLastOutputClosingEndsAssertionsOnce() {
        let recorder = AssertionRecorder()
        let proofing = SleepProofing(assertions: recorder)

        proofing.setLiveOutputCount(2)
        proofing.setLiveOutputCount(1)
        XCTAssertEqual(recorder.ends, 0, "still live — must keep the machine awake")

        proofing.setLiveOutputCount(0)
        XCTAssertFalse(proofing.isActive)
        XCTAssertEqual(recorder.ends, 1)

        proofing.setLiveOutputCount(0)
        XCTAssertEqual(recorder.ends, 1)
    }

    func testLiveIdleLiveCycleReasserts() {
        let recorder = AssertionRecorder()
        let proofing = SleepProofing(assertions: recorder)

        proofing.setLiveOutputCount(1)
        proofing.setLiveOutputCount(0)
        proofing.setLiveOutputCount(1)
        XCTAssertEqual(recorder.begins, 2)
        XCTAssertEqual(recorder.ends, 1)
        XCTAssertTrue(proofing.isActive)
    }
}
