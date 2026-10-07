import AVFoundation
import CoreMedia
import CoreVideo
import VideoToolbox
import XCTest
@testable import StreamEngine

final class HLSHDREncoderTests: XCTestCase {
    func testHDREncodeSignalsHLGInTheBitstream() async throws {
        let encoder = try HLSVideoEncoder(
            video: StreamVideoConfiguration(
                width: 640, height: 360, frameRate: 30, bitrateKbps: 2000,
                codec: .hevc, hdr: true),
            segmentDuration: 2.0)

        let source = try Self.bgraBuffer(width: 640, height: 360)
        let scaler = PixelScaler()
        let hdrBuffer = try XCTUnwrap(
            scaler.transfer(source, width: 640, height: 360, hdr: true))
        XCTAssertEqual(
            CVPixelBufferGetPixelFormatType(hdrBuffer),
            kCVPixelFormatType_ARGB2101010LEPacked)

        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: hdrBuffer, formatDescriptionOut: &format)
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: hdrBuffer,
            formatDescription: format!, sampleTiming: &timing, sampleBufferOut: &sample)

        encoder.encode(try XCTUnwrap(sample))
        encoder.finish()

        var encoded: CMSampleBuffer?
        for await compressed in encoder.output {
            encoded = compressed
            break
        }
        let description = try XCTUnwrap(try XCTUnwrap(encoded).formatDescription)
        XCTAssertEqual(description.mediaSubType, .hevc)
        let transfer = CMFormatDescriptionGetExtension(
            description, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String
        XCTAssertEqual(
            transfer, kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String,
            "bitstream must signal HLG — this is what YouTube's HDR detection reads")
        let primaries = CMFormatDescriptionGetExtension(
            description, extensionKey: kCMFormatDescriptionExtension_ColorPrimaries) as? String
        XCTAssertEqual(primaries, kCMFormatDescriptionColorPrimaries_ITU_R_2020 as String)
    }

    static func bgraBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
        ]
        CVPixelBufferCreate(
            nil, width, height, kCVPixelFormatType_32BGRA,
            attributes as CFDictionary, &buffer)
        let pixelBuffer = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
            memset(base, 128, CVPixelBufferGetDataSize(pixelBuffer))
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        CVBufferSetAttachment(
            pixelBuffer, kCVImageBufferColorPrimariesKey,
            kCVImageBufferColorPrimaries_P3_D65, .shouldPropagate)
        CVBufferSetAttachment(
            pixelBuffer, kCVImageBufferTransferFunctionKey,
            kCVImageBufferTransferFunction_sRGB, .shouldPropagate)
        return pixelBuffer
    }
}
