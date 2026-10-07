import XCTest
@testable import OutputEngine

final class SyncMonitorAudioTimelineTests: XCTestCase {

    func testWobblingMarksBecomeBuffersThatAbutExactly() {
        var timeline = SyncMonitorAudioTimeline()
        var generator = SystemRandomNumberGenerator()
        var last: Double?
        for index in 0..<2000 {
            let mark = 500 + Double(index) * 0.010 + Double.random(in: -0.003...0.003, using: &generator)
            let stamp = timeline.stamp(hostSeconds: mark, frameCount: 480, sampleRate: 48_000)
            XCTAssertEqual(stamp.reanchored, index == 0)
            if let last { XCTAssertEqual(stamp.seconds - last, 0.010, accuracy: 1e-9) }
            XCTAssertEqual(stamp.seconds, mark, accuracy: 0.0065)
            last = stamp.seconds
        }
    }

    func testARealJumpReanchorsOnceAndSoon() {
        var timeline = SyncMonitorAudioTimeline()
        var reanchors: [Int] = []
        for index in 0..<200 {
            let mark = 500 + Double(index) * 0.010 + (index >= 100 ? 0.030 : 0)
            if timeline.stamp(hostSeconds: mark, frameCount: 480, sampleRate: 48_000).reanchored {
                reanchors.append(index)
            }
        }
        XCTAssertEqual(reanchors.count, 2)
        XCTAssertEqual(reanchors.first, 0)
        XCTAssertLessThan(reanchors.last ?? 0, 125)
    }

    func testANewSampleRateStartsTheTimelineOver() {
        var timeline = SyncMonitorAudioTimeline()
        _ = timeline.stamp(hostSeconds: 10, frameCount: 480, sampleRate: 48_000)
        let stamp = timeline.stamp(hostSeconds: 10.010, frameCount: 441, sampleRate: 44_100)
        XCTAssertEqual(stamp, .init(seconds: 10.010, reanchored: true))
    }
}
