import AVFoundation
import CoreVideo
import VideoToolbox
import XCTest
@testable import OutputEngine

final class Main10RecordingTests: XCTestCase {
    func testHevc10SettingsCarryMain10AndHLGColor() {
        let configuration = RecordingConfiguration(
            codec: .hevc10, width: 640, height: 360)
        let settings = configuration.videoSettings()
        let compression = settings[AVVideoCompressionPropertiesKey] as? [String: Any]
        XCTAssertEqual(
            compression?[AVVideoProfileLevelKey] as? String,
            kVTProfileLevel_HEVC_Main10_AutoLevel as String)
        let color = settings[AVVideoColorPropertiesKey] as? [String: Any]
        XCTAssertEqual(
            color?[AVVideoTransferFunctionKey] as? String,
            AVVideoTransferFunction_ITU_R_2100_HLG)
        XCTAssertEqual(
            color?[AVVideoColorPrimariesKey] as? String,
            AVVideoColorPrimaries_ITU_R_2020)
        XCTAssertTrue(RecordingConfiguration.Codec.hevc10.wantsHDRSource)
    }

    func testMain10RecordingRoundTripsHLGTags() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("main10-test-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: url) }

        let recorder = try Recorder(
            url: url,
            configuration: RecordingConfiguration(
                codec: .hevc10, width: 640, height: 360, frameRate: 30))

        let buffer = try Self.hlgBuffer(width: 640, height: 360)
        for frame in 0..<10 {
            _ = recorder.append(buffer, atHostSeconds: Double(frame) / 30.0)
        }
        await recorder.finish()

        let tracks = try await AVURLAsset(url: url).loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let descriptions = try await track.load(.formatDescriptions)
        let description = try XCTUnwrap(descriptions.first)
        XCTAssertEqual(description.mediaSubType, .hevc)
        let transfer = CMFormatDescriptionGetExtension(
            description, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String
        XCTAssertEqual(transfer, kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String)
        let primaries = CMFormatDescriptionGetExtension(
            description, extensionKey: kCMFormatDescriptionExtension_ColorPrimaries) as? String
        XCTAssertEqual(primaries, kCMFormatDescriptionColorPrimaries_ITU_R_2020 as String)

        let depth = CMFormatDescriptionGetExtension(
            description, extensionKey: kCMFormatDescriptionExtension_Depth) as? Int
        if let depth { XCTAssertGreaterThanOrEqual(depth, 24) }
    }

    private static func hlgBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
        ]
        CVPixelBufferCreate(
            nil, width, height, kCVPixelFormatType_ARGB2101010LEPacked,
            attributes as CFDictionary, &buffer)
        let pixelBuffer = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {

            memset(base, 0xBB, CVPixelBufferGetDataSize(pixelBuffer))
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        CVBufferSetAttachment(
            pixelBuffer, kCVImageBufferColorPrimariesKey,
            kCVImageBufferColorPrimaries_ITU_R_2020, .shouldPropagate)
        CVBufferSetAttachment(
            pixelBuffer, kCVImageBufferTransferFunctionKey,
            kCVImageBufferTransferFunction_ITU_R_2100_HLG, .shouldPropagate)
        CVBufferSetAttachment(
            pixelBuffer, kCVImageBufferYCbCrMatrixKey,
            kCVImageBufferYCbCrMatrix_ITU_R_2020, .shouldPropagate)
        return pixelBuffer
    }
}
