import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

public enum SyncMonitorSamples {

    public static let lag = 0.25

    public static let lagDescription = "a quarter second"
    public static let timescale: CMTimeScale = 60_000

    public static let maxHeight = 540

    public static func renderSize(width: Int, height: Int) -> (width: Int, height: Int) {
        let scale = min(1, Double(maxHeight) / Double(max(height, 1)))
        let even = { (value: Double) in max(2, Int((value / 2).rounded()) * 2) }
        return (even(Double(width) * scale), even(Double(height) * scale))
    }

    public static func heldFrames(framesPerSecond: Int) -> Int {
        Int((lag * Double(framesPerSecond)).rounded(.up)) + 8
    }

    public static func interleaved(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let channels = Int(buffer.format.channelCount)
        let frames = Int(buffer.frameLength)
        guard let source = buffer.floatChannelData,
              let format = AVAudioFormat(
                  commonFormat: .pcmFormatFloat32, sampleRate: buffer.format.sampleRate,
                  channels: buffer.format.channelCount, interleaved: true),
              let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: buffer.frameCapacity),
              let destination = copy.floatChannelData
        else { return nil }
        copy.frameLength = buffer.frameLength
        if buffer.format.isInterleaved {
            memcpy(destination[0], source[0], frames * channels * MemoryLayout<Float>.size)
        } else {
            for frame in 0..<frames {
                for channel in 0..<channels {
                    destination[0][frame * channels + channel] = source[channel][frame]
                }
            }
        }
        return copy
    }

    public static let gainRange: ClosedRange<Double> = -30...36

    public static func applyGain(_ buffer: AVAudioPCMBuffer, decibels: Double) {
        let gain = Float(pow(10, min(max(decibels, gainRange.lowerBound), gainRange.upperBound) / 20))
        if gain != 1, let data = buffer.floatChannelData {
            let planes = buffer.format.isInterleaved ? 1 : Int(buffer.format.channelCount)
            let count = Int(buffer.frameLength)
                * (buffer.format.isInterleaved ? Int(buffer.format.channelCount) : 1)
            for plane in 0..<planes {
                for index in 0..<count {
                    data[plane][index] = min(max(data[plane][index] * gain, -1), 1)
                }
            }
        }
    }

    public static func route(_ renderer: AVSampleBufferAudioRenderer, toDeviceUID uid: String?) {
        if let uid, !uid.isEmpty { renderer.audioOutputDeviceUniqueID = uid }
    }

    public static func clockTime(atHostSeconds hostSeconds: Double) -> CMTime {
        CMTime(seconds: hostSeconds - lag, preferredTimescale: timescale)
    }

    public static func video(_ pixelBuffer: CVPixelBuffer, hostSeconds: Double) -> CMSampleBuffer? {
        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescriptionOut: &format)
        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(seconds: hostSeconds, preferredTimescale: timescale),
            decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        if let format {
            CMSampleBufferCreateReadyWithImageBuffer(
                allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer,
                formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sample)
        }
        return sample
    }
}
