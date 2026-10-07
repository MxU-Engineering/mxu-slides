import AVFoundation
import CoreVideo
import Metal
import RenderEngine
import XCTest
@testable import OutputEngine

final class RecorderTests: XCTestCase {
    private var scratchURL: URL!

    override func setUpWithError() throws {
        scratchURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecorderTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratchURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratchURL)
    }

    private func makeBuffer(width: Int = 320, height: Int = 180, gray: UInt8 = 0x80) throws -> CVPixelBuffer {
        var out: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
        XCTAssertEqual(
            CVPixelBufferCreate(
                kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                attrs as CFDictionary, &out),
            kCVReturnSuccess)
        let buffer = try XCTUnwrap(out)
        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            memset(base, Int32(gray), CVPixelBufferGetBytesPerRow(buffer) * height)
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }

    private func record(
        _ configuration: RecordingConfiguration,
        frames: Int,
        frameInterval: Double = 1.0 / 30.0,
        name: String = "out.mov"
    ) async throws -> (Recorder, URL) {
        let url = scratchURL.appendingPathComponent(name)
        let recorder = try Recorder(url: url, configuration: configuration)
        let buffer = try makeBuffer(width: configuration.width, height: configuration.height)
        for frame in 0..<frames {
            recorder.append(buffer, atHostSeconds: 1000 + Double(frame) * frameInterval)

            try await Task.sleep(nanoseconds: UInt64(frameInterval * 1_000_000_000))
        }
        await recorder.finish()
        return (recorder, url)
    }

    private func videoTrack(of url: URL) async throws -> AVAssetTrack {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        return try XCTUnwrap(tracks.first, "no video track in \(url.lastPathComponent)")
    }

    private func codec(of track: AVAssetTrack) async throws -> FourCharCode {
        let descriptions = try await track.load(.formatDescriptions)
        let description = try XCTUnwrap(descriptions.first)
        return CMFormatDescriptionGetMediaSubType(description)
    }

    func testH264RecordingProducesPlayableFile() async throws {
        let configuration = RecordingConfiguration(codec: .h264, width: 320, height: 180, frameRate: 30)
        let (recorder, url) = try await record(configuration, frames: 30)

        XCTAssertEqual(recorder.status.state, .finished(.requested))
        XCTAssertEqual(recorder.status.appendedFrames, 30)
        XCTAssertEqual(recorder.status.droppedFrames, 0)

        let track = try await videoTrack(of: url)
        let size = try await track.load(.naturalSize)
        XCTAssertEqual(Int(size.width), 320)
        XCTAssertEqual(Int(size.height), 180)
        let codec = try await codec(of: track)
        XCTAssertEqual(codec, kCMVideoCodecType_H264)

        let duration = try await AVURLAsset(url: url).load(.duration)
        XCTAssertGreaterThan(duration.seconds, 0.8, "30 frames at 30fps should span ~1s")
    }

    func testProRes4444CarriesItsCodec() async throws {
        let configuration = RecordingConfiguration(codec: .proRes4444, width: 320, height: 180, frameRate: 30)
        let (_, url) = try await record(configuration, frames: 10, name: "alpha.mov")
        let track = try await videoTrack(of: url)
        let codec = try await codec(of: track)
        XCTAssertEqual(codec, kCMVideoCodecType_AppleProRes4444)
        XCTAssertTrue(RecordingConfiguration.Codec.proRes4444.preservesAlpha)
    }

    func testHEVCRecordingProducesPlayableFile() async throws {
        let configuration = RecordingConfiguration(codec: .hevc, width: 320, height: 180, frameRate: 30)
        let (_, url) = try await record(configuration, frames: 10, name: "hevc.mov")
        let track = try await videoTrack(of: url)
        let codec = try await codec(of: track)
        XCTAssertEqual(codec, kCMVideoCodecType_HEVC)
    }

    func testSameInstantAppendsNudgeForwardInsteadOfDropping() async throws {
        let configuration = RecordingConfiguration(codec: .h264, width: 320, height: 180)
        let url = scratchURL.appendingPathComponent("nudge.mov")
        let recorder = try Recorder(url: url, configuration: configuration)
        let buffer = try makeBuffer()
        recorder.append(buffer, atHostSeconds: 5)
        recorder.append(buffer, atHostSeconds: 5)
        recorder.append(buffer, atHostSeconds: 5)
        await recorder.finish()
        XCTAssertEqual(recorder.status.appendedFrames, 3)
        XCTAssertEqual(recorder.status.droppedFrames, 0)
    }

    func testAudioAppendsLandInAnAudioTrack() async throws {
        var configuration = RecordingConfiguration(codec: .h264, width: 320, height: 180)
        configuration.includesAudio = true
        let url = scratchURL.appendingPathComponent("audio.mov")
        let recorder = try Recorder(url: url, configuration: configuration)
        let video = try makeBuffer()

        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800))
        pcm.frameLength = 4800
        for channel in 0..<2 {
            let samples = pcm.floatChannelData![channel]
            for index in 0..<4800 {
                samples[index] = sinf(Float(index) * 0.05)
            }
        }

        for frame in 0..<10 {
            let seconds = 100 + Double(frame) / 30.0
            recorder.append(video, atHostSeconds: seconds)
            recorder.appendAudio(pcm, atHostSeconds: seconds)
        }
        await recorder.finish()

        let asset = AVURLAsset(url: url)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(audioTracks.count, 1, "audio appends should produce one audio track")
    }

    func testAudioBeforeFirstVideoFrameDropsHonestly() async throws {
        var configuration = RecordingConfiguration(codec: .h264, width: 320, height: 180)
        configuration.includesAudio = true
        let url = scratchURL.appendingPathComponent("early-audio.mov")
        let recorder = try Recorder(url: url, configuration: configuration)

        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480))
        pcm.frameLength = 480
        recorder.appendAudio(pcm, atHostSeconds: 1)
        XCTAssertEqual(recorder.status.droppedAudioBuffers, 1)

        recorder.append(try makeBuffer(), atHostSeconds: 2)
        await recorder.finish()
    }

    func testImpossibleDiskFloorAutoStops() async throws {
        var configuration = RecordingConfiguration(codec: .h264, width: 320, height: 180)
        configuration.minimumFreeDiskBytes = .max
        let url = scratchURL.appendingPathComponent("disk.mov")
        let recorder = try Recorder(url: url, configuration: configuration)
        recorder.append(try makeBuffer(), atHostSeconds: 0)

        for _ in 0..<50 {
            if case .finished = recorder.status.state { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertEqual(recorder.status.state, .finished(.diskFull))
    }

    func testForceKilledRecordingStaysPlayable() async throws {
        let harness = productsDirectory.appendingPathComponent("recorder-kill-harness")
        try XCTSkipUnless(
            FileManager.default.isExecutableFile(atPath: harness.path),
            "harness binary not built (run swift build first)")

        let url = scratchURL.appendingPathComponent("killed.mov")
        let process = Process()
        process.executableURL = harness
        process.arguments = [url.path]
        let stdout = Pipe()
        process.standardOutput = stdout
        try process.run()

        let ready = stdout.fileHandleForReading.availableData
        XCTAssertTrue(String(decoding: ready, as: UTF8.self).contains("HARNESS_RECORDING"))
        try await Task.sleep(nanoseconds: 4_000_000_000)

        kill(process.processIdentifier, SIGKILL)
        process.waitUntilExit()
        XCTAssertEqual(process.terminationReason, .uncaughtSignal, "harness must die by SIGKILL, not exit")

        let asset = AVURLAsset(url: url)
        let readable = try await asset.load(.isReadable)
        XCTAssertTrue(readable, "a force-killed recording must remain a readable movie")
        let duration = try await asset.load(.duration)
        XCTAssertGreaterThan(
            duration.seconds, 1.0,
            "with 1s fragments over ~4s of writing, at least a couple of fragments must survive")
        let tracks = try await asset.loadTracks(withMediaType: .video)
        XCTAssertFalse(tracks.isEmpty)
    }

    private var productsDirectory: URL {
        for bundle in Bundle.allBundles where bundle.bundlePath.hasSuffix(".xctest") {
            return bundle.bundleURL.deletingLastPathComponent()
        }
        fatalError("couldn't find the products directory")
    }
}
