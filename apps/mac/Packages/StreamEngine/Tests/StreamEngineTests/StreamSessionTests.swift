import AVFAudio
import CoreVideo
import XCTest
@testable import StreamEngine

final class StreamSessionTests: XCTestCase {

    func testCopiedAudioBufferIsDeep() throws {
        let format = try XCTUnwrap(AVAudioFormat(
            standardFormatWithSampleRate: 48_000, channels: 2))
        let original = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 256))
        original.frameLength = 256
        original.floatChannelData?[0][0] = 0.5
        original.floatChannelData?[1][255] = -0.25

        let copy = try XCTUnwrap(StreamSession.copiedAudioBuffer(original))

        XCTAssertEqual(copy.format, original.format)
        XCTAssertEqual(copy.frameLength, 256)
        XCTAssertEqual(copy.floatChannelData?[0][0], 0.5)
        XCTAssertEqual(copy.floatChannelData?[1][255], -0.25)

        original.floatChannelData?[0][0] = 99
        XCTAssertEqual(copy.floatChannelData?[0][0], 0.5)
    }

    func testAppendAudioIsSafeWhenNotPublishing() throws {
        let session = StreamSession(
            destination: StreamEndpoint(
                name: "Test", kind: .rtmp, url: "rtmp://127.0.0.1:19999/live", streamKey: "x"),
            video: StreamVideoConfiguration(width: 320, height: 180))
        let format = try XCTUnwrap(AVAudioFormat(
            standardFormatWithSampleRate: 48_000, channels: 2))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 128))
        buffer.frameLength = 128

        session.appendAudio(buffer, when: AVAudioTime(hostTime: 0))
        let empty = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 128))
        session.appendAudio(empty, when: AVAudioTime(hostTime: 0))
        session.stop()
        session.appendAudio(buffer, when: AVAudioTime(hostTime: 0))

        XCTAssertEqual(session.status.state, .stopped)
    }

    func testSessionStartsIdleAndStopsCleanly() {
        let session = StreamSession(
            destination: StreamEndpoint(
                name: "Test", kind: .rtmp, url: "rtmp://127.0.0.1:19999/live", streamKey: "x"),
            video: StreamVideoConfiguration(width: 320, height: 180))
        XCTAssertEqual(session.status.state, .idle)
        session.stop()
        XCTAssertEqual(session.status.state, .stopped)
    }

    func testPublishesToLocalRTMPServer() async throws {
        guard let apiURL = URL(string: "http://127.0.0.1:8000/api/streams"),
              (try? await URLSession.shared.data(from: apiURL)) != nil
        else {
            throw XCTSkip("no local RTMP test server on 127.0.0.1:1935/8000")
        }

        let key = "mxu-loopback-\(ProcessInfo.processInfo.processIdentifier)"
        let session = StreamSession(
            destination: StreamEndpoint(
                name: "Local", kind: .rtmp,
                url: "rtmp://127.0.0.1:1935/live", streamKey: key),
            video: StreamVideoConfiguration(
                width: 640, height: 360, frameRate: 30, bitrateKbps: 800))
        session.start()
        defer { session.stop() }

        var out: CVPixelBuffer?
        CVPixelBufferCreate(
            kCFAllocatorDefault, 640, 360, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary,
            &out)
        let buffer = try XCTUnwrap(out)

        let deadline = Date(timeIntervalSinceNow: 20)
        while Date() < deadline {
            session.append(buffer, atHostSeconds: CACurrentMediaTime())
            if session.status.state == .publishing, session.status.framesSubmitted > 60 {
                break
            }
            try await Task.sleep(nanoseconds: 33_000_000)
        }
        XCTAssertEqual(session.status.state, .publishing, "session never reached publishing")
        XCTAssertGreaterThan(session.status.framesSubmitted, 60)

        let (data, _) = try await URLSession.shared.data(from: apiURL)
        let body = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(body.contains(key), "server does not list our publisher: \(body)")
    }

    func testAppendBeforePublishingDropsNothingAndSubmitsNothing() throws {
        let session = StreamSession(
            destination: StreamEndpoint(
                name: "Test", kind: .rtmp, url: "rtmp://127.0.0.1:19999/live", streamKey: "x"),
            video: StreamVideoConfiguration(width: 320, height: 180))
        var out: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 320, 180, kCVPixelFormatType_32BGRA, nil, &out)
        let buffer = try XCTUnwrap(out)
        session.append(buffer, atHostSeconds: 1)
        XCTAssertEqual(session.status.framesSubmitted, 0)
        XCTAssertEqual(session.status.framesDropped, 0, "pre-publish frames are ignored, not counted")
    }
}
