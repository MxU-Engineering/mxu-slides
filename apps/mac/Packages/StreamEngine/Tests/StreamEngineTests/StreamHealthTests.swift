import XCTest
@testable import StreamEngine

final class StreamHealthTests: XCTestCase {
    private typealias Input = StreamHealthRollup.Input

    func testBadIsDegradedNeverNoDataAndNeverTints() {
        var tracker = PlatformHealthTracker()
        tracker.record("yt", status: "good", issues: [], elapsed: 200)
        tracker.record("yt", status: "bad", issues: ["not enough video"], elapsed: 210)
        XCTAssertEqual(tracker.verdict("yt"), .degraded(issues: ["not enough video"]))
        let inputs = [Input(state: .publishing, verdict: tracker.verdict("yt"))]
        XCTAssertEqual(StreamHealthRollup.tint(inputs), .green)
        XCTAssertEqual(StreamHealthRollup.word(inputs), "LIVE")

        XCTAssertTrue(tracker.pollsHot("yt"))
    }

    func testNoDataEscalatesOnlyAfterConsecutivePolls() {
        var tracker = PlatformHealthTracker(escalationPolls: 3)
        tracker.record("yt", status: "good", issues: [], elapsed: 200)
        tracker.record("yt", status: "noData", issues: [], elapsed: 210)
        tracker.record("yt", status: "noData", issues: [], elapsed: 220)
        XCTAssertEqual(tracker.verdict("yt"), .healthy, "two polls are a blip")
        tracker.record("yt", status: "noData", issues: [], elapsed: 230)
        XCTAssertEqual(tracker.verdict("yt"), .noData)
        let inputs = [Input(state: .publishing, verdict: .noData)]
        XCTAssertEqual(StreamHealthRollup.tint(inputs), .amber)
        XCTAssertEqual(StreamHealthRollup.word(inputs), "NO DATA")

        tracker.record("yt", status: "good", issues: [], elapsed: 240)
        XCTAssertEqual(tracker.verdict("yt"), .healthy)
        tracker.record("yt", status: "noData", issues: [], elapsed: 250)
        XCTAssertEqual(tracker.verdict("yt"), .healthy)
    }

    func testStartupGraceIgnoresEarlyNoDataUntilSettled() {
        var tracker = PlatformHealthTracker(graceSeconds: 90, escalationPolls: 1)
        tracker.record("yt", status: "noData", issues: [], elapsed: 1)
        tracker.record("yt", status: "noData", issues: [], elapsed: 60)
        XCTAssertNil(tracker.verdict("yt"))
        XCTAssertTrue(tracker.pollsHot("yt"))

        tracker.record("yt", status: "noData", issues: [], elapsed: 91)
        XCTAssertEqual(tracker.verdict("yt"), .noData)
    }

    func testUnknownIsIgnoredAndHealthySettles() {
        var tracker = PlatformHealthTracker()
        tracker.record("yt", status: "unknown", issues: [], elapsed: 500)
        XCTAssertNil(tracker.verdict("yt"))
        tracker.record("yt", status: "ok", issues: [], elapsed: 500)
        XCTAssertEqual(tracker.verdict("yt"), .healthy)
        XCTAssertFalse(tracker.pollsHot("yt"))
    }

    func testCaptionWordMatchesSessionState() {
        XCTAssertEqual(StreamHealthRollup.word([Input(state: .connecting)]), "CONNECTING")
        XCTAssertEqual(StreamHealthRollup.tint([Input(state: .connecting)]), .amber)
        XCTAssertEqual(StreamHealthRollup.word([Input(state: .reconnecting(attempt: 2))]), "RECONNECTING")
        XCTAssertEqual(StreamHealthRollup.word([Input(state: .failed("x")), Input(state: .publishing)]), "STREAM FAILED")
        XCTAssertEqual(StreamHealthRollup.tint([Input(state: .failed("x")), Input(state: .publishing)]), .red)

        XCTAssertEqual(StreamHealthRollup.word([
            Input(state: .publishing, verdict: .noData), Input(state: .reconnecting(attempt: 1)),
        ]), "RECONNECTING")
        XCTAssertEqual(StreamHealthRollup.tint([]), .none)
    }
}
