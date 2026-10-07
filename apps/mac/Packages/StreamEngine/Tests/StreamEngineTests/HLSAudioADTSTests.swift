import AVFoundation
import XCTest
@testable import StreamEngine

final class HLSAudioADTSTests: XCTestCase {
    func testEncodedPacketsCarryValidADTSHeaders() throws {
        let input = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let encoder = try XCTUnwrap(HLSAudioEncoder(inputFormat: input))

        var packets: [(AVAudioCompressedBuffer, AVAudioTime)] = []
        var sample: Int64 = 0

        for _ in 0..<24 {
            let buffer = AVAudioPCMBuffer(pcmFormat: input, frameCapacity: 1024)!
            buffer.frameLength = 1024
            for channel in 0..<2 {
                let samples = buffer.floatChannelData![channel]
                for index in 0..<1024 {
                    samples[index] = sinf(Float(sample + Int64(index)) * 2 * .pi * 440 / 48_000) * 0.5
                }
            }
            packets.append(contentsOf: encoder.encode(
                buffer, when: AVAudioTime(sampleTime: sample, atRate: 48_000)))
            sample += 1024
        }
        try XCTSkipIf(packets.isEmpty, "AAC converter produced nothing on this host")

        for (packet, _) in packets {
            var data = Data(count: Int(packet.byteLength) + AudioSpecificConfig.adtsHeaderSize)
            packet.encode(to: &data)

            XCTAssertEqual(data[0], 0xFF, "ADTS syncword high byte")
            XCTAssertEqual(data[1], 0xF9, "ADTS syncword low byte + MPEG-2/no-CRC")

            XCTAssertEqual(data[2], 0x4C, "AAC-LC @ 48kHz header byte")
            XCTAssertEqual(data[3] & 0xC0, 0x80, "2-channel configuration")
            let declaredLength = (Int(data[3] & 0x03) << 11) | (Int(data[4]) << 3) | (Int(data[5]) >> 5)
            XCTAssertEqual(declaredLength, Int(packet.byteLength) + 7, "ADTS frame length")
            XCTAssertTrue(
                data.dropFirst(7).contains { $0 != 0 },
                "audio payload is all zeros — the ADTS writer gave up silently")
        }
    }
}
