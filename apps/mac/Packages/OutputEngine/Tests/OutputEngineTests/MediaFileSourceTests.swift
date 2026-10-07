import AVFoundation
import CoreVideo
import XCTest
@testable import OutputEngine

final class MediaFileSourceTests: XCTestCase {
    private func writeMovie(to url: URL, frames: Int) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 64,
            AVVideoHeightKey: 64,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<frames {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            var pixelBuffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pixelBuffer)
            let buffer = try XCTUnwrap(pixelBuffer)
            CVPixelBufferLockBaseAddress(buffer, [])
            memset(CVPixelBufferGetBaseAddress(buffer), Int32(frame * 16), CVPixelBufferGetDataSize(buffer))
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30))
        }
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed)
    }

    func testPumpsEveryFrameThenEndsNaturally() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: url) }
        try await writeMovie(to: url, frames: 8)

        let framesSunk = expectation(description: "frames delivered")
        framesSunk.expectedFulfillmentCount = 8
        let ended = expectation(description: "natural end")
        let endReason = Locked<String??>(nil)

        let source = MediaFileSource(
            url: url,
            frameSink: { _, _ in framesSunk.fulfill() },
            audioSink: { _, _ in },
            onEnded: { reason in
                endReason.value = reason
                ended.fulfill()
            })
        source.start()

        await fulfillment(of: [framesSunk, ended], timeout: 5)
        XCTAssertEqual(endReason.value, .some(nil))  
        XCTAssertEqual(source.framesDelivered, 8)
        XCTAssertEqual(source.framesDropped, 0)
    }

    func testUnreadableFileEndsWithReason() async {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).mov")
        try? Data("not a movie".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let ended = expectation(description: "failed end")
        let endReason = Locked<String??>(nil)
        let source = MediaFileSource(
            url: url,
            frameSink: { _, _ in },
            audioSink: { _, _ in },
            onEnded: { reason in
                endReason.value = reason
                ended.fulfill()
            })
        source.start()
        await fulfillment(of: [ended], timeout: 5)
        if case .some(let reason?) = endReason.value {
            XCTAssertFalse(reason.isEmpty)
        } else {
            XCTFail("expected a failure reason")
        }
    }

    func testStopNeverReportsAnEnd() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: url) }

        try await writeMovie(to: url, frames: 90)

        let endedCalls = Locked(0)
        let source = MediaFileSource(
            url: url,
            frameSink: { _, _ in },
            audioSink: { _, _ in },
            onEnded: { _ in endedCalls.withLock { $0 += 1 } })
        source.start()
        try await Task.sleep(nanoseconds: 300_000_000)
        source.stop()
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(endedCalls.value, 0)  
    }
}

private final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
    func withLock<R>(_ body: (inout Value) -> R) -> R {
        lock.withLock { body(&stored) }
    }
}
