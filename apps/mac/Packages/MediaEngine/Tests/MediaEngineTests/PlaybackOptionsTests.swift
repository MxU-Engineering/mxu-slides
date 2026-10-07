import XCTest
@testable import MediaEngine

final class PlaybackOptionsTests: XCTestCase {
    private let duration = 10.0
    private let frame = 1.0 / 30

    func testResolvedClampsAndFallsBack() {

        var r = PlaybackOptions().resolved(duration: duration, frameDuration: frame)
        XCTAssertEqual(r.start, 0)
        XCTAssertEqual(r.end, duration)
        XCTAssertEqual(r.rate, 1)

        r = PlaybackOptions(inPoint: 2, outPoint: 8).resolved(duration: duration, frameDuration: frame)
        XCTAssertEqual(r.start, 2)
        XCTAssertEqual(r.end, 8)

        r = PlaybackOptions(inPoint: -3, outPoint: 99).resolved(duration: duration, frameDuration: frame)
        XCTAssertEqual(r.start, 0)
        XCTAssertEqual(r.end, duration)

        r = PlaybackOptions(inPoint: 8, outPoint: 2).resolved(duration: duration, frameDuration: frame)
        XCTAssertEqual(r.start, 0)
        XCTAssertEqual(r.end, duration)

        r = PlaybackOptions(inPoint: 5, outPoint: 5.01).resolved(duration: duration, frameDuration: frame)
        XCTAssertEqual(r.start, 0)
        XCTAssertEqual(r.end, duration)

        r = PlaybackOptions(rate: 100).resolved(duration: duration, frameDuration: frame)
        XCTAssertEqual(r.rate, PlaybackOptions.rateRange.upperBound)
        r = PlaybackOptions(rate: 0).resolved(duration: duration, frameDuration: frame)
        XCTAssertEqual(r.rate, PlaybackOptions.rateRange.lowerBound)
    }

    func testEffectiveWallClockDuration() {

        let options = PlaybackOptions(inPoint: 2, outPoint: 8, rate: 2)
        XCTAssertEqual(
            options.effectiveWallClockDuration(duration: duration, frameDuration: frame),
            3, accuracy: 0.001
        )
    }

    func testProjectionAdvancesAtRate() {
        let t0 = Date()
        let state = MediaTransportState(
            duration: 6, position: 1, isPlaying: true, isLooping: false,
            capturedAt: t0, rate: 2
        )

        XCTAssertEqual(state.position(at: t0.addingTimeInterval(1)), 3, accuracy: 0.001)

        XCTAssertEqual(state.position(at: t0.addingTimeInterval(10)), 6, accuracy: 0.001)
    }
}
