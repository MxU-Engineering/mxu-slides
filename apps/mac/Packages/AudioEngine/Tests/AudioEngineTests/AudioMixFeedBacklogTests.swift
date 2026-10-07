import AVFoundation
import XCTest
@testable import AudioEngine

final class AudioMixFeedBacklogTests: XCTestCase {
    private func buffer(frames: AVAudioFrameCount) throws -> AVAudioPCMBuffer {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        pcm.frameLength = frames
        return pcm
    }

    func testBacklogIsTheDeepestRingAndStopsAtTheCap() throws {
        let feed = AudioMixFeed(startsClock: false) { _, _, _ in }
        XCTAssertEqual(feed.backlogMilliseconds, 0)
        feed.push(member: "elgato", buffer: try buffer(frames: 4800))
        feed.push(member: "music", buffer: try buffer(frames: 480))
        XCTAssertEqual(feed.backlogMilliseconds, 100, accuracy: 0.001)
        for _ in 0..<10 { feed.push(member: "elgato", buffer: try buffer(frames: 4800)) }
        XCTAssertEqual(feed.backlogMilliseconds, 500, accuracy: 0.001)
    }

    func testAMissedFireIsMadeUpWithNominalMarks() throws {
        let marks = Marks()
        let feed = AudioMixFeed(startsClock: false) { _, _, host in marks.append(host) }
        feed.tick(now: 100)
        feed.push(member: "elgato", buffer: try buffer(frames: 2400))
        feed.tick(now: 100.0501)
        XCTAssertEqual(marks.values.count, 6)
        for (index, mark) in marks.values.enumerated() {
            XCTAssertEqual(mark, 100 + Double(index) * 0.010, accuracy: 1e-9)
        }
        XCTAssertEqual(feed.backlogMilliseconds, 0, accuracy: 0.001)
    }

    func testAFireThatComesEarlyPullsNothingAndALongSuspendDropsTheDebt() {
        let marks = Marks()
        let feed = AudioMixFeed(startsClock: false) { _, _, host in marks.append(host) }
        feed.tick(now: 100)
        feed.tick(now: 100.0098)
        XCTAssertEqual(marks.values.count, 1)
        feed.tick(now: 160)
        XCTAssertEqual(marks.values.count, 2)
        XCTAssertEqual(marks.values.last ?? 0, 160, accuracy: 1e-9)
    }

    func testStandingExcessIsTrimmedToTheTarget() throws {
        let feed = AudioMixFeed(startsClock: false) { _, _, _ in }
        feed.push(member: "late", buffer: try buffer(frames: 9600))
        for tick in 0..<AudioMixFeed.trimWindowTicks {
            feed.push(member: "late", buffer: try buffer(frames: 480))
            feed.tick(now: 200 + Double(tick) * 0.010)
        }
        XCTAssertEqual(feed.trimmedMilliseconds, 180, accuracy: 0.001)
        XCTAssertEqual(feed.backlogMilliseconds, 20, accuracy: 0.001)
    }

    func testABurstyMemberIsNeverTrimmed() throws {
        let feed = AudioMixFeed(startsClock: false) { _, _, _ in }
        for tick in 0..<(AudioMixFeed.trimWindowTicks * 3) {
            if tick % 16 == 0 { feed.push(member: "video", buffer: try buffer(frames: 7680)) }
            feed.tick(now: 300 + Double(tick) * 0.010)
        }
        XCTAssertEqual(feed.trimmedMilliseconds, 0)
    }
}

private final class Marks: @unchecked Sendable {
    private let lock = NSLock()
    private var marks: [Double] = []
    var values: [Double] { lock.withLock { marks } }
    func append(_ mark: Double) { lock.withLock { marks.append(mark) } }
}
