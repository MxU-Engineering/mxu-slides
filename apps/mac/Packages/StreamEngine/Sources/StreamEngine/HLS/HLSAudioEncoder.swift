import AVFoundation
import Foundation

final class HLSAudioEncoder {
    static let packetFrames = 1024.0  

    let outputFormat: AVAudioFormat
    private let converter: AVAudioConverter
    private var pending: [AVAudioPCMBuffer] = []
    private var anchorSeconds: Double?
    private var packetsOut = 0

    init?(inputFormat: AVAudioFormat) {
        var description = AudioStreamBasicDescription(
            mSampleRate: inputFormat.sampleRate,
            mFormatID: kAudioFormatMPEG4AAC,

            mFormatFlags: UInt32(MPEG4ObjectID.AAC_LC.rawValue),
            mBytesPerPacket: 0, mFramesPerPacket: 0,
            mBytesPerFrame: 0, mChannelsPerFrame: min(2, inputFormat.channelCount),
            mBitsPerChannel: 0, mReserved: 0)
        guard let aac = AVAudioFormat(streamDescription: &description),
              let converter = AVAudioConverter(from: inputFormat, to: aac) else { return nil }
        converter.bitRate = 128_000
        self.outputFormat = aac
        self.converter = converter
    }

    func encode(_ buffer: AVAudioPCMBuffer, when: AVAudioTime) -> [(AVAudioCompressedBuffer, AVAudioTime)] {
        let rate = outputFormat.sampleRate
        let incomingSeconds = when.isHostTimeValid
            ? AVAudioTime.seconds(forHostTime: when.hostTime)
            : nil
        if let incomingSeconds {
            let expected = (anchorSeconds ?? incomingSeconds) + Double(packetsOut) * Self.packetFrames / rate
            if anchorSeconds == nil || abs(incomingSeconds - expected) > 0.25 {

                anchorSeconds = incomingSeconds - Double(packetsOut) * Self.packetFrames / rate
            }
        }
        pending.append(buffer)

        var packets: [(AVAudioCompressedBuffer, AVAudioTime)] = []

        let feed = UnsafeSendableBox(pending)
        pending = []
        defer { pending = feed.value }
        while true {
            let out = AVAudioCompressedBuffer(
                format: outputFormat, packetCapacity: 1,
                maximumPacketSize: converter.maximumOutputPacketSize)
            var conversionError: NSError?
            let status = converter.convert(to: out, error: &conversionError) { _, outStatus in
                guard let next = feed.value.first else {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                feed.value.removeFirst()
                outStatus.pointee = .haveData
                return next
            }
            guard status == .haveData, out.packetCount > 0 else { break }
            let seconds = (anchorSeconds ?? 0) + Double(packetsOut) * Self.packetFrames / rate
            packetsOut += 1
            packets.append((out, AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: seconds))))
        }
        return packets
    }
}
