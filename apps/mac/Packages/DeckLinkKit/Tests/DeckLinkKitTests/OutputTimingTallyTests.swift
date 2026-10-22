import XCTest
@testable import DeckLinkKit

final class OutputTimingTallyTests: XCTestCase {
    func testOneLatchPerCompletionIsClean() {
        var timing = DeckLinkOutputTiming()
        for frame in 1...5 {
            timing.latched += 1
            timing.tallyCompletion(at: Double(frame) / 30)
        }
        XCTAssertEqual(timing.completions, 5)
        XCTAssertEqual(timing.lastCompletionHostTime, 5.0 / 30)
        XCTAssertEqual(timing.repeats, 0)
        XCTAssertEqual(timing.skips, 0)
    }

    func testAMissedLatchRepeatsAndADoubleLatchSkips() {
        var timing = DeckLinkOutputTiming()
        timing.latched = 1
        timing.tallyCompletion(at: 1)
        timing.tallyCompletion(at: 2)
        timing.latched += 3
        timing.tallyCompletion(at: 3)
        XCTAssertEqual(timing.repeats, 1)
        XCTAssertEqual(timing.skips, 2)
        XCTAssertEqual(timing.shownLatch, 4)
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
