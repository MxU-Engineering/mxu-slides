import AVFoundation
import CoreVideo
import XCTest
@testable import StreamEngine

final class HLSVideoEncoderTests: XCTestCase {
    func testHEVCKeyframeCadenceHoldsOnStaticContent() async throws {
        try await assertKeyframeCadence(codec: .hevc)
    }

    func testH264KeyframeCadenceHoldsOnStaticContent() async throws {
        try await assertKeyframeCadence(codec: .h264)
    }

    private func assertKeyframeCadence(codec: StreamVideoConfiguration.Codec) async throws {
        let segmentDuration = 2.0
        let frameRate = 30
        let totalFrames = 300 
        let encoder = try HLSVideoEncoder(
            video: StreamVideoConfiguration(
                width: 1920, height: 1080, frameRate: frameRate,
                bitrateKbps: 9000, codec: codec),
            segmentDuration: segmentDuration)

        let pool = try HLSLoopbackTests.makePixelBufferPool(width: 1920, height: 1080)
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
        let frame = try XCTUnwrap(pixelBuffer)
        HLSLoopbackTests.fill(frame, shade: 128) 

        let collector = expectation(description: "encoder drained")
        let box = UnsafeSendableBox<[Bool]>([]) 
        let task = Task {
            for await sample in encoder.output {
                box.value.append(!sample.isNotSync)
            }
            collector.fulfill()
        }
        var formatDescription: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: frame,
            formatDescriptionOut: &formatDescription)
        for index in 0..<totalFrames {
            var timing = CMSampleTimingInfo(
                duration: CMTime(value: 1, timescale: CMTimeScale(frameRate)),
                presentationTimeStamp: CMTime(
                    seconds: Double(index) / Double(frameRate), preferredTimescale: 60_000),
                decodeTimeStamp: .invalid)
            var sample: CMSampleBuffer?
            CMSampleBufferCreateReadyWithImageBuffer(
                allocator: kCFAllocatorDefault, imageBuffer: frame,
                formatDescription: try XCTUnwrap(formatDescription),
                sampleTiming: &timing, sampleBufferOut: &sample)
            encoder.encode(try XCTUnwrap(sample))

            try await Task.sleep(nanoseconds: UInt64(1_000_000_000 / frameRate))
        }
        encoder.finish()
        await fulfillment(of: [collector], timeout: 30)
        task.cancel()

        let syncFlags = box.value
        XCTAssertGreaterThan(syncFlags.count, totalFrames * 9 / 10, "encoder dropped frames")
        let keyframeIndexes = syncFlags.enumerated().filter(\.element).map(\.offset)
        XCTAssertFalse(keyframeIndexes.isEmpty, "no keyframes at all")
        let cadenceFrames = Int(segmentDuration * Double(frameRate))
        var previous = keyframeIndexes[0]
        for index in keyframeIndexes.dropFirst() {
            XCTAssertLessThanOrEqual(
                index - previous, cadenceFrames + 1,
                "GOP stretched to \(index - previous) frames — segments would outgrow \(segmentDuration)s and YouTube drops anything over 5s")
            previous = index
        }
        let tailGap = syncFlags.count - 1 - previous
        XCTAssertLessThanOrEqual(tailGap, cadenceFrames + 1, "final GOP stretched to \(tailGap)+ frames")
    }
}
