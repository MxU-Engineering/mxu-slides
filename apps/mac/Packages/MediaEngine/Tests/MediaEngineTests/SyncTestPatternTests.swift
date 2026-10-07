import AVFoundation
import XCTest
@testable import MediaEngine

final class SyncTestPatternTests: XCTestCase {
    func testTheClickStartsOnEachBeatsFirstSampleAndNowhereElse() {
        let audio = SyncTestPattern.audio()
        XCTAssertEqual(audio.count, 384_000)
        XCTAssertEqual(audio[0], 0)
        XCTAssertGreaterThan(audio[0..<1_920].map { abs($0) }.max() ?? 0, 0.4)
        XCTAssertGreaterThan(audio[24_000..<25_920].map { abs($0) }.max() ?? 0, 0.4)
        XCTAssertGreaterThan(audio[7_000..<7_600].map { abs($0) }.max() ?? 0, 0.4, "beat 1's beep runs 160 ms")
        XCTAssertTrue(audio[8_000..<24_000].allSatisfy { $0 == 0 })
        XCTAssertTrue(audio[26_000..<48_000].allSatisfy { $0 == 0 }, "beat 2's click is 40 ms")
        XCTAssertEqual(SyncTestPattern.framesPerBeat, 15)
        XCTAssertEqual(SyncTestPattern.loopFrames, 240)
        XCTAssertTrue(SyncTestPattern.isFlash(frame: 15) && SyncTestPattern.isFlash(frame: 17))
        XCTAssertFalse(SyncTestPattern.isFlash(frame: 18) || SyncTestPattern.isFlash(frame: 14))
        XCTAssertTrue(SyncTestPattern.isDownbeat(frame: 60) && !SyncTestPattern.isDownbeat(frame: 75))
    }

    func testTheCachedMovieIsAuthoredOnceAndNamedByVersion() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sync-test-cache-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var writes: [URL] = []
        let write: (URL) async throws -> Void = { url in
            writes.append(url)
            try Data().write(to: url)
        }
        let first = try await SyncTestPattern.cachedMovie(in: dir, write: write)
        let second = try await SyncTestPattern.cachedMovie(in: dir, write: write)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.lastPathComponent, "sync-test-v\(SyncTestPattern.version).mov")
        XCTAssertEqual(writes.count, 1, "written once, reused after")
        XCTAssertEqual(writes.first?.lastPathComponent, "sync-test-v\(SyncTestPattern.version).partial.mov",
                       "authored beside and moved in whole")
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))

        let flaky = dir.appendingPathComponent("flaky", isDirectory: true)
        var flakyWrites = 0
        let recovered = try await SyncTestPattern.cachedMovie(in: flaky) { url in
            flakyWrites += 1
            if flakyWrites == 1 { throw MediaEngineError.authoringFailed("first try") }
            try Data().write(to: url)
        }
        XCTAssertEqual(flakyWrites, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: recovered.path))

        let failing = dir.appendingPathComponent("failing", isDirectory: true)
        var failingWrites = 0
        let failed: Error? = await {
            do {
                _ = try await SyncTestPattern.cachedMovie(in: failing) { _ in
                    failingWrites += 1
                    throw MediaEngineError.authoringFailed("test")
                }
                return nil
            } catch {
                return error
            }
        }()
        XCTAssertNotNil(failed)
        XCTAssertEqual(failingWrites, SyncTestPattern.writeAttempts)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: failing.path), [],
                       "a failed write leaves nothing to reuse")
    }

    func testTheWrittenLoopFlashesAndClicksOnTheBeat() async throws {
        try XCTSkipIf(isVirtualMachine(), "the movie writer has no hardware encoder on a virtual machine (VirtualMachine.swift)")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sync-test-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: url) }
        try await SyncTestPattern.write(to: url)

        let asset = AVURLAsset(url: url)
        let videoTrack = try await asset.loadTracks(withMediaType: .video).first
        let audioTrack = try await asset.loadTracks(withMediaType: .audio).first
        XCTAssertNotNil(videoTrack)

        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        func pixel(atFrame frame: Int, x: Double, y: Double) async throws -> (red: Double, green: Double, blue: Double) {
            let image = try await generator.image(
                at: CMTime(value: CMTimeValue(frame), timescale: 30)).image
            var pixel = [UInt8](repeating: 0, count: 4)
            let context = try XCTUnwrap(CGContext(
                data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: -x, y: -y, width: 1920, height: 1080))
            return (Double(pixel[0]) / 255, Double(pixel[1]) / 255, Double(pixel[2]) / 255)
        }
        let symbol = SyncTestPattern.symbolCenter
        let lit = try await pixel(atFrame: 15, x: symbol.x, y: symbol.y)
        let dark = try await pixel(atFrame: 20, x: symbol.x, y: symbol.y)
        XCTAssertGreaterThan(lit.green, 0.9, "beat 2's first frame lights the symbol white")
        XCTAssertLessThan(dark.green, 0.15, "between beats the symbol is an outline")

        let downbeat = try await pixel(atFrame: 60, x: 1850, y: 1000)
        let ordinary = try await pixel(atFrame: 75, x: 1850, y: 1000)
        XCTAssertGreaterThan(downbeat.red, 0.85, "beat 1 floods the whole frame orange")
        XCTAssertLessThan(downbeat.blue, 0.3)
        XCTAssertLessThan(ordinary.red, 0.15, "beat 2 lights only the symbol")

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: try XCTUnwrap(audioTrack), outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        reader.add(output)
        reader.startReading()
        var samples: [Int16] = []
        while let buffer = output.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(buffer) {
            var data = [Int16](repeating: 0, count: CMBlockBufferGetDataLength(block) / 2)
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: data.count * 2, destination: &data)
            samples += data
        }
        let onsets = samples.indices.filter { index in
            abs(Int(samples[index])) > 3_000
                && samples[max(0, index - 480)..<index].allSatisfy { abs(Int($0)) < 3_000 }
        }
        XCTAssertEqual(onsets.count, 16)
        XCTAssertLessThan(onsets[0], 48)
        XCTAssertEqual(Double(onsets[1]), 24_000, accuracy: 48)
    }
}
