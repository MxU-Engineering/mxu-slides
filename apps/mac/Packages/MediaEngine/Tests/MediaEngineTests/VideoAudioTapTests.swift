import AVFoundation
import RenderEngine
import XCTest
@testable import MediaEngine

final class VideoAudioTapTests: XCTestCase {
    private let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!

    private func impulse(at frame: Int, frames: Int = 48) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        for channel in 0 ..< 2 {
            for index in 0 ..< frames { buffer.floatChannelData![channel][index] = 0 }
            buffer.floatChannelData![channel][frame] = 1
        }
        return buffer
    }

    private func left(_ buffer: AVAudioPCMBuffer) -> [Float] {
        Array(UnsafeBufferPointer(
            start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
    }

    func testDelayHoldsPlayoutBackAfterFeedingTheSinkUndelayed() {
        let heard = Locked<[[Float]]>([])
        let sink = Locked<VideoAudioTap.Sink?>({ buffer in
            heard.withLock { $0.append(Array(UnsafeBufferPointer(
                start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))) }
        })
        let context = VideoAudioTap.Context(sink: sink, delay: Locked(1))  
        context.prepare(format: format)
        XCTAssertFalse(context.isIdle)

        let first = impulse(at: 0)
        context.handle(first)
        XCTAssertEqual(heard.value.count, 1)
        XCTAssertEqual(heard.value[0][0], 1, "the sink hears the program where it is")
        XCTAssertEqual(left(first), [Float](repeating: 0, count: 48), "playout opens silent")

        let second = impulse(at: 5)
        second.floatChannelData![0][5] = 0
        second.floatChannelData![1][5] = 0
        context.handle(second)
        XCTAssertEqual(left(second)[0], 1, "the impulse plays out one delay later")
        XCTAssertEqual(second.floatChannelData![1][0], 1)
    }

    func testZeroDelayLeavesPlayoutUntouchedAndIdlesWithoutASink() {
        let context = VideoAudioTap.Context(sink: Locked(nil), delay: Locked(0))
        context.prepare(format: format)
        XCTAssertTrue(context.isIdle, "no sink, no delay: the callback fetches and returns")
        let buffer = impulse(at: 3)
        context.handle(buffer)
        XCTAssertEqual(left(buffer)[3], 1)
    }

    func testDelayChangeLandsOnTheNextCallback() {
        let delay = Locked<Double>(0)
        let context = VideoAudioTap.Context(sink: Locked(nil), delay: delay)
        context.prepare(format: format)
        context.handle(impulse(at: 0))
        delay.value = 1
        XCTAssertFalse(context.isIdle)
        let buffer = impulse(at: 0)
        context.handle(buffer)
        XCTAssertEqual(left(buffer), [Float](repeating: 0, count: 48), "held back from the next buffer")
    }
}
