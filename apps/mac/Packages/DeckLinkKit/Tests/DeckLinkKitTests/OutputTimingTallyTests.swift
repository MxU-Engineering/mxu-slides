import XCTest
@testable import DeckLinkKit

final class OutputTimingTallyTests: XCTestCase {
    func testOneLatchPerCompletionIsClean() {
        var timing = DeckLinkOutputTiming()
        for frame in 1...5 {
            let slot = timing.latch()
            XCTAssertEqual(timing.tallyCompletion(at: Double(frame) / 30), slot)
        }
        XCTAssertEqual(timing.completions, 5)
        XCTAssertEqual(timing.lastCompletionHostTime, 5.0 / 30)
        XCTAssertEqual(timing.repeats, 0)
        XCTAssertEqual(timing.skips, 0)
    }

    func testALateLatchIsAbsorbedOnceAFrameWaits() {
        var timing = DeckLinkOutputTiming()
        let a = timing.latch()
        XCTAssertEqual(timing.tallyCompletion(at: 1), a)
        XCTAssertEqual(timing.tallyCompletion(at: 2), a)
        XCTAssertEqual(timing.repeats, 1)
        let b = timing.latch()
        let c = timing.latch()
        XCTAssertEqual(timing.tallyCompletion(at: 3), b)
        XCTAssertEqual(timing.tallyCompletion(at: 4), c)
        let d = timing.latch()
        let e = timing.latch()
        XCTAssertEqual(timing.tallyCompletion(at: 5), d)
        XCTAssertEqual(timing.tallyCompletion(at: 6), e)
        XCTAssertEqual(timing.repeats, 1)
        XCTAssertEqual(timing.skips, 0)
    }

    func testANothingWaitingRepeatsAndAFullQueueSkipsItsOldest() {
        var timing = DeckLinkOutputTiming()
        let shown = timing.latch()
        timing.tallyCompletion(at: 1)
        XCTAssertEqual(timing.tallyCompletion(at: 2), shown)
        timing.latch()
        let second = timing.latch()
        let third = timing.latch()
        XCTAssertEqual(timing.repeats, 1)
        XCTAssertEqual(timing.skips, 1)
        XCTAssertFalse([second, third].contains(shown))
        XCTAssertEqual(timing.tallyCompletion(at: 3), second)
        XCTAssertEqual(timing.tallyCompletion(at: 4), third)
    }

    func testPrerollBeforeTheFirstLatchIsNotARepeat() {
        var timing = DeckLinkOutputTiming()
        timing.tallyCompletion(at: 1)
        timing.tallyCompletion(at: 2)
        XCTAssertEqual(timing.completions, 2)
        XCTAssertEqual(timing.repeats, 0)
    }

    func testCardResultsAndScheduleJumpsCount() {
        var timing = DeckLinkOutputTiming()
        timing.tallyCompletion(at: 1, result: .late)
        timing.tallyCompletion(at: 2, result: .dropped, jumped: true)
        timing.tallyCompletion(at: 3, result: .flushed)
        XCTAssertEqual(timing.late, 1)
        XCTAssertEqual(timing.dropped, 1)
        XCTAssertEqual(timing.jumps, 1)
    }
}
