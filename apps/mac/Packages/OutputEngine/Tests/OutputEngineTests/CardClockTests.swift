import RenderEngine
import XCTest
@testable import OutputEngine

final class CardClockTests: XCTestCase {
    private let ntsc = 1001.0 / 30000

    func testTheClockWaitsForASecondOfCompletions() {
        var clock = CardClock()
        for count in 1...20 {
            _ = clock.record(completions: count, lastCompletion: Double(count) * ntsc, counters: .init())
        }
        XCTAssertNil(clock.cadence)
        for count in 21...40 {
            _ = clock.record(completions: count, lastCompletion: Double(count) * ntsc, counters: .init())
        }
        XCTAssertEqual(try XCTUnwrap(clock.cadence).period, ntsc, accuracy: 1e-9)
    }

    func testThePeriodComesFromCountsNotReplies() throws {
        var clock = CardClock()
        for count in [1, 3, 3, 4, 7, 7, 8, 12, 20, 33, 34, 40, 41] {
            _ = clock.record(completions: count, lastCompletion: Double(count) * ntsc, counters: .init())
        }
        let cadence = try XCTUnwrap(clock.cadence)
        XCTAssertEqual(cadence.period, ntsc, accuracy: 1e-9)
        XCTAssertEqual(cadence.lastArrival, 41 * ntsc, accuracy: 1e-9)
    }

    func testThePhaseIsTheMeanOfTheWindowNotTheNewestSample() throws {
        var clock = CardClock()
        for count in 1...60 {
            let jitter = count.isMultiple(of: 2) ? 0.002 : -0.002
            _ = clock.record(
                completions: count, lastCompletion: Double(count) * ntsc + jitter, counters: .init())
        }
        _ = clock.record(completions: 61, lastCompletion: 61 * ntsc + 0.003, counters: .init())
        XCTAssertEqual(try XCTUnwrap(clock.cadence).lastArrival, 61 * ntsc, accuracy: 0.0005)
    }

    func testCountersReportAsDeltasAndAFreshOpenRestarts() throws {
        var clock = CardClock()
        _ = clock.record(completions: 10, lastCompletion: 1, counters: .init(repeats: 2, skips: 1))
        let delta = clock.record(
            completions: 11, lastCompletion: 1.03, counters: .init(repeats: 3, skips: 1, late: 1))
        XCTAssertEqual(delta, .init(repeats: 1, late: 1))

        for count in 12...50 {
            _ = clock.record(
                completions: count, lastCompletion: 1 + Double(count - 10) * ntsc,
                counters: .init(repeats: 3, skips: 1, late: 1))
        }
        XCTAssertNotNil(clock.cadence)
        let reopened = clock.record(completions: 2, lastCompletion: 9, counters: .init(repeats: 1))
        XCTAssertEqual(reopened, .init(repeats: 1))
        XCTAssertNil(clock.cadence)
    }
}
