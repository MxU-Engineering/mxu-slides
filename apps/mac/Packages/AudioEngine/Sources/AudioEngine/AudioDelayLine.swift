import AVFoundation
import Foundation

public final class AudioDelayLine: @unchecked Sendable {
    private let lock = NSLock()
    private var requestedMs: Double = 0

    private var rings: [[Float]] = []
    private var writeIndex = 0
    private var appliedSamples = 0
    private var appliedRate: Double = 0

    public init() {}

    public var delayMilliseconds: Double {
        get { lock.withLock { requestedMs } }
        set { lock.withLock { requestedMs = max(0, min(newValue, 2000)) } }
    }

    public func delayedCopy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer {
        guard delayMilliseconds > 0 || appliedSamples > 0,
              let source = buffer.floatChannelData,
              let copy = AVAudioPCMBuffer(
                  pcmFormat: buffer.format, frameCapacity: buffer.frameCapacity),
              let destination = copy.floatChannelData
        else { return buffer }
        copy.frameLength = buffer.frameLength
        let bytes = Int(buffer.frameLength) * MemoryLayout<Float>.size
        for channel in 0 ..< Int(buffer.format.channelCount) {
            memcpy(destination[channel], source[channel], bytes)
        }
        process(copy)
        return copy
    }

    public func process(_ buffer: AVAudioPCMBuffer) {
        let rate = buffer.format.sampleRate
        guard rate > 0, let data = buffer.floatChannelData else { return }
        let target = Int(lock.withLock { requestedMs } * rate / 1000)
        if target != appliedSamples || rate != appliedRate {
            appliedSamples = target
            appliedRate = rate
            writeIndex = 0
            rings = target > 0
                ? Array(repeating: [Float](repeating: 0, count: target), count: 2)
                : []
        }
        guard appliedSamples > 0 else { return }
        let frames = Int(buffer.frameLength)
        let channels = min(2, Int(buffer.format.channelCount))
        var nextIndex = writeIndex
        for channel in 0 ..< channels {
            let samples = data[channel]
            var index = writeIndex
            rings[channel].withUnsafeMutableBufferPointer { ring in
                for frame in 0 ..< frames {
                    let delayed = ring[index]
                    ring[index] = samples[frame]
                    samples[frame] = delayed
                    index += 1
                    if index == ring.count { index = 0 }
                }
            }
            nextIndex = index
        }
        writeIndex = nextIndex
    }
}
