import AVFoundation
import Foundation
import RenderEngine

public final class SyncMonitorMeter: @unchecked Sendable {
    public struct Reading: Equatable, Sendable {
        public var videoFrames = 0
        public var audioBuffers = 0

        public var audioReanchors = 0

        public var peak: Float = 0
        public var sampleRate: Double = 0
        public var channels = 0

        public var peakDecibels: Double {
            peak > 0 ? max(-90, 20 * log10(Double(peak))) : -90
        }
    }

    private let reading = Locked(Reading())

    public init() {}

    public func videoFrame() {
        reading.withLock { $0.videoFrames += 1 }
    }

    public func audioReanchored() {
        reading.withLock { $0.audioReanchors += 1 }
    }

    public func audio(_ buffer: AVAudioPCMBuffer) {
        var peak: Float = 0
        if let data = buffer.floatChannelData {
            for channel in 0..<Int(buffer.format.channelCount) {
                for frame in stride(from: 0, to: Int(buffer.frameLength), by: 4) {
                    peak = max(peak, abs(data[channel][frame]))
                }
            }
        }
        reading.withLock {
            $0.audioBuffers += 1
            $0.peak = max($0.peak, peak)
            $0.sampleRate = buffer.format.sampleRate
            $0.channels = Int(buffer.format.channelCount)
        }
    }

    public func drain() -> Reading {
        reading.withLock { current in
            defer { current = Reading() }
            return current
        }
    }
}
