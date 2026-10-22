import AVFoundation

public protocol ExternalInputFeed: AnyObject, Sendable {
    func start(into hub: AudioInputHub) throws
    func stop()
}

public enum DeckLinkAudioUID {
    public static let prefix = "decklink:"

    public static func uid(persistentID: Int64) -> String {
        "\(prefix)\(persistentID)"
    }

    public static func persistentID(_ uid: String) -> Int64? {
        uid.hasPrefix(prefix) ? Int64(uid.dropFirst(prefix.count)) : nil
    }
}

public extension AudioInputHub {

    static func deviceBuffer(
        int32Interleaved samples: UnsafeRawBufferPointer, frames: Int, channels: Int
    ) -> AVAudioPCMBuffer? {
        if frames > 0, channels > 0,
            samples.count >= frames * channels * MemoryLayout<Int32>.size,
            let format = deviceWideFormat(channels: AVAudioChannelCount(channels)),
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
            let output = buffer.floatChannelData {
            buffer.frameLength = AVAudioFrameCount(frames)
            let input = samples.bindMemory(to: Int32.self)

            let scale = 1 / Float(1 << 31)
            for channel in 0..<channels {
                let destination = output[channel]
                for frame in 0..<frames {
                    destination[frame] = Float(input[frame * channels + channel]) * scale
                }
            }
            return buffer
        } else {
            return nil
        }
    }
}
