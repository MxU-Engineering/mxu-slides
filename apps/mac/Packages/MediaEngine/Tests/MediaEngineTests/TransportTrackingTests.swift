import XCTest
@testable import MediaEngine

final class TransportTrackingTests: XCTestCase {
    private let anchor = Date(timeIntervalSince1970: 1_700_000_000)

    private func state(
        position: Double, at date: Date, playing: Bool = true, looping: Bool = false,
        duration: Double = 30, rate: Double = 1
    ) -> MediaTransportState {
        MediaTransportState(
            duration: duration, position: position, isPlaying: playing, isLooping: looping,
            capturedAt: date, rate: rate)
    }

    func testAPlayingVideoReadAgainTracksItsHeldAnchor() {
        let held = state(position: 5, at: anchor)

        let later = anchor + 0.25
        XCTAssertTrue(held.tracks(state(position: 5.26, at: later), at: later))

        XCTAssertTrue(held.tracks(state(position: 25.1, at: anchor + 20), at: anchor + 20))
        XCTAssertFalse(held.tracks(state(position: 5, at: anchor, duration: 90), at: anchor), "a different length is news")
    }

    func testASeekOrStallPastTheToleranceIsNews() {
        let held = state(position: 5, at: anchor)
        let later = anchor + 1
        XCTAssertFalse(held.tracks(state(position: 10, at: later), at: later), "seek forward")
        XCTAssertFalse(held.tracks(state(position: 5.5, at: later), at: later), "stalled half a second")
        XCTAssertTrue(held.tracks(state(position: 5.8, at: later), at: later), "0.2 s of jitter")
    }

    func testPlayLoopAndRateFlipsAreNews() {
        let held = state(position: 5, at: anchor)
        XCTAssertFalse(held.tracks(state(position: 5, at: anchor, playing: false), at: anchor))
        XCTAssertFalse(held.tracks(state(position: 5, at: anchor, looping: true), at: anchor))
        XCTAssertFalse(held.tracks(state(position: 5, at: anchor, rate: 2), at: anchor))
    }

    func testAPausedPlayheadIsExactToAFrame() {
        let held = state(position: 5, at: anchor, playing: false)
        let later = anchor + 10
        XCTAssertTrue(held.tracks(state(position: 5, at: later, playing: false), at: later), "holding still")
        XCTAssertFalse(held.tracks(state(position: 5.1, at: later, playing: false), at: later), "a paused scrub")
    }

    func testALoopCrossingItsSeamStillTracks() {
        let held = state(position: 29.9, at: anchor, looping: true)

        let later = anchor + 0.2
        XCTAssertTrue(held.tracks(state(position: 0.12, at: later, looping: true), at: later))
        XCTAssertFalse(held.tracks(state(position: 15, at: later, looping: true), at: later))
    }
}
