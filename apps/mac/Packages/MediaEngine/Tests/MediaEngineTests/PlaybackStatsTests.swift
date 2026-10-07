import XCTest
@testable import MediaEngine

final class PlaybackStatsTests: XCTestCase {
    private let frameDuration = 1.0 / 30.0

    func testConsecutiveFramesCountNoDrops() {
        var stats = PlaybackStats()
        for i in 0..<10 {
            stats.recordFrame(at: Double(i) * frameDuration, frameDuration: frameDuration, loopDuration: nil)
        }
        XCTAssertEqual(stats.framesDisplayed, 10)
        XCTAssertEqual(stats.framesDropped, 0)
    }

    func testSkippedSourceFramesAreCounted() {
        var stats = PlaybackStats()
        stats.recordFrame(at: 0, frameDuration: frameDuration, loopDuration: nil)

        stats.recordFrame(at: 3 * frameDuration, frameDuration: frameDuration, loopDuration: nil)
        XCTAssertEqual(stats.framesDropped, 2)
    }

    func testSeamlessLoopWrapIsNotADrop() {
        var stats = PlaybackStats()
        let duration = 1.0 
        stats.recordFrame(at: 29 * frameDuration, frameDuration: frameDuration, loopDuration: duration)
        stats.recordFrame(at: 0, frameDuration: frameDuration, loopDuration: duration)
        XCTAssertEqual(stats.framesDropped, 0, "last frame → first frame is seamless")
    }

    func testDropAtTheLoopSeamIsCounted() {
        var stats = PlaybackStats()
        let duration = 1.0
        stats.recordFrame(at: 29 * frameDuration, frameDuration: frameDuration, loopDuration: duration)

        stats.recordFrame(at: 1 * frameDuration, frameDuration: frameDuration, loopDuration: duration)
        XCTAssertEqual(stats.framesDropped, 1, "the seam is exactly where seamlessness must be measured")
    }

    func testAggregation() {
        var a = PlaybackStats()
        var b = PlaybackStats()
        a.recordFrame(at: 0, frameDuration: frameDuration, loopDuration: nil)
        a.recordFrame(at: 2 * frameDuration, frameDuration: frameDuration, loopDuration: nil)
        b.recordFrame(at: 0, frameDuration: frameDuration, loopDuration: nil)
        let sum = a + b
        XCTAssertEqual(sum.framesDisplayed, 3)
        XCTAssertEqual(sum.framesDropped, 1)
    }
}
