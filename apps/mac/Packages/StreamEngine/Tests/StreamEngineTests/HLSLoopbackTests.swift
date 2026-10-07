import AVFoundation
import CoreVideo
import XCTest
@testable import StreamEngine

final class HLSLoopbackTests: XCTestCase {
    static let sinkState = URL(string: "http://127.0.0.1:8990/api/state")!
    static let template = "http://127.0.0.1:8990/http_upload_hls?cid=test&copy=0&file="

    func testPublishesSegmentsToLocalSink() async throws {
        try await publishAndAssert(codec: .h264)
    }

    func testPublishesHEVCSegmentsToLocalSink() async throws {
        try await publishAndAssert(codec: .hevc)
    }

    func testPublishesAudioVideoSegmentsToLocalSink() async throws {
        try await publishAndAssert(codec: .hevc, withAudio: true)
    }

    private func publishAndAssert(
        codec: StreamVideoConfiguration.Codec, withAudio: Bool = false
    ) async throws {
        guard (try? await URLSession.shared.data(from: Self.sinkState)) != nil else {
            throw XCTSkip("no local HLS sink on 127.0.0.1:8990 (node scripts/hls-sink.mjs)")
        }

        var reset = URLRequest(url: URL(string: "http://127.0.0.1:8990/api/reset")!)
        reset.httpMethod = "POST"
        _ = try await URLSession.shared.data(for: reset)

        let session = StreamSession(
            destination: StreamEndpoint(
                name: "loopback", kind: .hls, url: Self.template),
            video: StreamVideoConfiguration(
                width: 640, height: 360, frameRate: 30, bitrateKbps: 800, codec: codec))
        session.start()

        let pool = try Self.makePixelBufferPool(width: 640, height: 360)
        let start = Date()
        let audioFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        var audioSample: Int64 = 0
        for frame in 0..<196 {
            var pixelBuffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
            if let pixelBuffer {
                Self.fill(pixelBuffer, shade: UInt8(frame % 255))
                session.append(pixelBuffer, atHostSeconds: Double(frame) / 30.0)
            }

            if withAudio, frame >= 8 {

                let buffer = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: 1600)!
                buffer.frameLength = 1600
                for channel in 0..<2 {
                    let samples = buffer.floatChannelData![channel]
                    for index in 0..<1600 {
                        samples[index] = sinf(Float(audioSample + Int64(index)) * 2 * .pi * 440 / 48_000) * 0.3
                    }
                }
                session.appendAudio(
                    buffer, when: AVAudioTime(sampleTime: audioSample, atRate: 48_000))
                audioSample += 1600
            }

            try await Task.sleep(nanoseconds: 20_000_000)
        }
        session.stop()

        var state: [String: Any] = [:]
        for _ in 0..<50 {
            try await Task.sleep(nanoseconds: 200_000_000)
            let (data, _) = try await URLSession.shared.data(from: Self.sinkState)
            state = (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            if (state["segments"] as? [[String: Any]])?.count ?? 0 >= 3 { break }
        }

        let segments = state["segments"] as? [[String: Any]] ?? []
        let playlists = state["playlists"] as? [[String: Any]] ?? []
        let errors = state["errors"] as? [String] ?? []
        XCTAssertGreaterThanOrEqual(segments.count, 3, "took \(Date().timeIntervalSince(start))s, state: \(state)")
        XCTAssertGreaterThanOrEqual(playlists.count, segments.count, "playlist re-PUT after every segment")
        XCTAssertEqual(errors, [], "sink flagged ingest-contract violations")
    }

    static func makePixelBufferPool(width: Int, height: Int) throws -> CVPixelBufferPool {
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
        ]
        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool)
        return try XCTUnwrap(pool)
    }

    static func fill(_ buffer: CVPixelBuffer, shade: UInt8) {
        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            memset(base, Int32(shade), CVPixelBufferGetDataSize(buffer))
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
    }
}
