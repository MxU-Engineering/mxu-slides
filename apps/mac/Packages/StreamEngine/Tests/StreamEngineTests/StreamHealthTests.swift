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

    func testEndedBroadcastIsRedUntilForgotten() {
        var tracker = PlatformHealthTracker()
        tracker.record("yt", status: "good", issues: [], elapsed: 200)
        tracker.record("yt", status: "ended", issues: [], elapsed: 300)
        XCTAssertEqual(tracker.verdict("yt"), .ended)
        let inputs = [Input(state: .publishing, verdict: .ended)]
        XCTAssertEqual(StreamHealthRollup.tint(inputs), .red)
        XCTAssertEqual(StreamHealthRollup.word(inputs), "BROADCAST ENDED")
        tracker.forget("yt")
        XCTAssertNil(tracker.verdict("yt"))
        XCTAssertTrue(tracker.pollsHot("yt"))
    }

    func testUploadStallsWhenNothingLeavesOrTheBacklogGrows() {
        var stall = UploadStall()
        for _ in 1..<UploadStall.silentSeconds {
            stall.record(bytesOutPerSecond: 0, queuedBytes: 0)
        }
        XCTAssertNil(stall.stalled(targetKbps: 6000), "a short silence is a blip")
        stall.record(bytesOutPerSecond: 0, queuedBytes: 0)
        XCTAssertEqual(stall.stalled(targetKbps: 6000), "nothing sent for 10s")
        stall.record(bytesOutPerSecond: 100_000, queuedBytes: 6000 * 125 * 20)
        XCTAssertNil(stall.stalled(targetKbps: 6000), "bytes leaving clear the silence")
        stall.record(bytesOutPerSecond: 100_000, queuedBytes: 6000 * 125 * 20 + 1)
        XCTAssertEqual(stall.stalled(targetKbps: 6000), "upload 15 MB behind")
    }

    func testNetworkHealthReadsTheBacklogNotTheSendRate() {
        func status(_ upload: Int?, video: Int = 10000, backlog: Double = 0, state: StreamSession.State = .publishing) -> StreamSession.Status {
            StreamSession.Status(
                state: state, framesSubmitted: 0, framesDropped: 0,
                uploadKbps: upload, videoKbps: video, backlogSeconds: backlog)
        }
        XCTAssertNil(NetworkHealth.of(status(nil), fullKbps: 10000), "not measured yet")
        XCTAssertNil(NetworkHealth.of(status(500, state: .reconnecting(attempt: 1)), fullKbps: 10000))
        XCTAssertEqual(NetworkHealth.of(status(80), fullKbps: 10000), .good, "a still slide sends little")
        XCTAssertEqual(NetworkHealth.of(status(4000, backlog: 2), fullKbps: 10000), .slow)
        XCTAssertEqual(NetworkHealth.of(status(2000, video: 2000), fullKbps: 10000), .slow, "quality lowered")
        XCTAssertEqual(NetworkHealth.of(status(0, backlog: 3), fullKbps: 10000), .stalled)
    }

    func testAdaptiveFloorFollowsThePresetChoice() {
        XCTAssertNil(StreamVideoConfiguration.adaptiveFloor(adapt: false, minKbps: 3000, bitrateKbps: 6000), "constant")
        XCTAssertEqual(StreamVideoConfiguration.adaptiveFloor(adapt: nil, minKbps: nil, bitrateKbps: 6000), 2000)
        XCTAssertEqual(StreamVideoConfiguration.adaptiveFloor(adapt: true, minKbps: 4000, bitrateKbps: 6000), 4000)
        XCTAssertEqual(StreamVideoConfiguration.adaptiveFloor(adapt: true, minKbps: 4000, bitrateKbps: 2500), 2500, "never above its own bitrate")
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
