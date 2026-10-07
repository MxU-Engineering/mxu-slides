import AVFoundation
import Testing
@testable import AudioEngine

struct AudioDelayLineTests {

    private func makeBuffer(_ samples: [Float], rate: Double = 48_000) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
        let buffer = AVAudioPCMBuffer(
            pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        for (index, sample) in samples.enumerated() {
            buffer.floatChannelData![0][index] = sample
            buffer.floatChannelData![1][index] = -sample
        }
        return buffer
    }

    private func left(_ buffer: AVAudioPCMBuffer) -> [Float] {
        Array(UnsafeBufferPointer(
            start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
    }

    @Test func zeroDelayLeavesTheBufferUntouched() {
        let line = AudioDelayLine()
        var samples = [Float](repeating: 0, count: 64)
        samples[3] = 0.5
        let buffer = makeBuffer(samples)
        line.process(buffer)
        #expect(left(buffer) == samples)
    }

    @Test func delayShiftsSamplesAcrossBuffers() {
        let line = AudioDelayLine()
        line.delayMilliseconds = 1  
        var impulse = [Float](repeating: 0, count: 48)
        impulse[0] = 1

        let first = makeBuffer(impulse)
        line.process(first)
        #expect(left(first) == [Float](repeating: 0, count: 48), "delay opens with silence")

        let second = makeBuffer([Float](repeating: 0, count: 48))
        line.process(second)
        #expect(left(second)[0] == 1, "the impulse lands exactly one delay later")
        #expect(second.floatChannelData![1][0] == -1, "right channel rides its own ring")
    }

    @Test func partialBufferDelayShiftsWithinTheBuffer() {
        let line = AudioDelayLine()
        line.delayMilliseconds = 0.25  
        var impulse = [Float](repeating: 0, count: 48)
        impulse[0] = 1
        let buffer = makeBuffer(impulse)
        line.process(buffer)
        let output = left(buffer)
        #expect(output[12] == 1)
        #expect(output[0] == 0)
    }

    @Test func delayChangeRebuildsWithSilenceNotArtifacts() {
        let line = AudioDelayLine()
        line.delayMilliseconds = 1
        line.process(makeBuffer([Float](repeating: 0.7, count: 48)))
        line.delayMilliseconds = 2  
        let buffer = makeBuffer([Float](repeating: 0.7, count: 96))
        line.process(buffer)
        #expect(left(buffer) == [Float](repeating: 0, count: 96),
                "a resized ring opens silent — never replays stale samples")
    }

    @Test func delayedCopyLeavesTheSharedBufferUntouched() {

        let line = AudioDelayLine()
        line.delayMilliseconds = 1  
        var impulse = [Float](repeating: 0, count: 48)
        impulse[0] = 1
        let shared = makeBuffer(impulse)
        let delayed = line.delayedCopy(shared)
        #expect(delayed !== shared)
        #expect(left(shared) == impulse, "the shared instance keeps its samples")
        #expect(left(delayed) == [Float](repeating: 0, count: 48),
                "the copy opens with the delay's silence")
        let next = line.delayedCopy(makeBuffer([Float](repeating: 0, count: 48)))
        #expect(left(next)[0] == 1, "the impulse lands one delay later, on the copies")
    }

    @Test func delayedCopyWithoutDelayIsFree() {
        let line = AudioDelayLine()
        let buffer = makeBuffer([0.1, 0.2, 0.3])
        #expect(line.delayedCopy(buffer) === buffer, "no delay = no copy paid")
    }

    @Test func requestedDelayClampsToTheCeiling() {
        let line = AudioDelayLine()
        line.delayMilliseconds = 99_999
        #expect(line.delayMilliseconds == 2000)
        line.delayMilliseconds = -5
        #expect(line.delayMilliseconds == 0)
    }
}
