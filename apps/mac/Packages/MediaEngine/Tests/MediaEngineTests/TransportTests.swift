import AVFoundation
import Metal
import RenderEngine
import XCTest
@testable import MediaEngine

@MainActor
final class TransportTests: XCTestCase {
    private var tempDir: URL!
    private var device: MTLDevice!

    override func setUp() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("No Metal device available on this machine")
        }
        self.device = device
        try XCTSkipIf(isVirtualMachine(), "real-time transport only holds on a real Mac (VirtualMachine.swift)")
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MediaEngineTransportTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
    }

    private func makeClip(name: String, seconds: Int) async throws -> URL {
        let url = tempDir.appendingPathComponent("\(name).mov")
        try await MediaAuthoring.writeMovie(
            to: url, codec: .h264, size: CGSize(width: 320, height: 180), frameCount: seconds * 30
        ) { context, frame in
            context.setFillColor(CGColor(srgbRed: 0.1, green: 0.1, blue: 0.1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 320, height: 180))
            context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            context.fill(CGRect(x: CGFloat(frame % 32) * 10, y: 0, width: 10, height: 180))
        }
        return url
    }

    private func pull(
        _ engine: MediaEngine, id: String, timeout: TimeInterval = 10,
        until condition: () -> Bool
    ) async throws {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline, !condition() {
            _ = engine.surface(for: id, hostTime: CACurrentMediaTime())
            try await Task.sleep(for: .milliseconds(8))
        }
    }

    func testNoteSeekPreventsPhantomDrops() {
        var stats = PlaybackStats()
        let frame = 1.0 / 30.0
        stats.recordFrame(at: 0, frameDuration: frame, loopDuration: nil)
        stats.recordFrame(at: frame, frameDuration: frame, loopDuration: nil)
        XCTAssertEqual(stats.framesDropped, 0)

        stats.noteSeek()
        stats.recordFrame(at: 2.0, frameDuration: frame, loopDuration: nil)
        stats.recordFrame(at: 2.0 + frame, frameDuration: frame, loopDuration: nil)
        XCTAssertEqual(stats.framesDropped, 0, "seek jump was charged as dropped frames")
        XCTAssertEqual(stats.framesDisplayed, 4)
    }

    func testTransportStatePositionProjectsClampsAndWraps() {
        let anchor = Date(timeIntervalSinceReferenceDate: 1000)

        let playing = MediaTransportState(
            duration: 10, position: 4, isPlaying: true, isLooping: false, capturedAt: anchor
        )
        XCTAssertEqual(playing.position(at: anchor + 2), 6, accuracy: 0.0001)
        XCTAssertEqual(playing.position(at: anchor + 60), 10, accuracy: 0.0001, "non-loop must clamp at the end")
        XCTAssertEqual(playing.remaining(at: anchor + 2), 4, accuracy: 0.0001)
        XCTAssertEqual(playing.remaining(at: anchor + 60), 0, accuracy: 0.0001, "remaining must clamp at 0")

        let paused = MediaTransportState(
            duration: 10, position: 4, isPlaying: false, isLooping: false, capturedAt: anchor
        )
        XCTAssertEqual(paused.position(at: anchor + 60), 4, accuracy: 0.0001, "paused playhead must freeze")

        let looping = MediaTransportState(
            duration: 10, position: 8, isPlaying: true, isLooping: true, capturedAt: anchor
        )
        XCTAssertEqual(looping.position(at: anchor + 5), 3, accuracy: 0.0001, "loop must wrap through duration")
        XCTAssertEqual(looping.position(at: anchor + 25), 3, accuracy: 0.0001, "loop must wrap repeatedly")

        let junk = MediaTransportState(
            duration: 10, position: 40, isPlaying: false, isLooping: false, capturedAt: anchor
        )
        XCTAssertEqual(junk.position(at: anchor), 10, accuracy: 0.0001, "out-of-range position must clamp")
    }

    func testEngineTransportReflectsPauseAndSeek() async throws {
        let engine = try MediaEngine(device: device)
        let media = try await engine.prepare(url: makeClip(name: "engine", seconds: 4))
        engine.play(media, id: "v", loop: false)
        try await pull(engine, id: "v") { (engine.stats(for: "v")?.framesDisplayed ?? 0) > 5 }

        var state = try XCTUnwrap(engine.transport(id: "v"))
        XCTAssertTrue(state.isPlaying)
        XCTAssertFalse(state.isLooping)
        XCTAssertEqual(state.duration, media.duration, accuracy: 0.05)

        engine.pause(id: "v")
        try await Task.sleep(for: .milliseconds(100))
        state = try XCTUnwrap(engine.transport(id: "v"))
        XCTAssertFalse(state.isPlaying)

        let player = try XCTUnwrap(engine.playerForTesting(id: "v"))
        let sought = expectation(description: "seek completed")
        player.seek(to: 3.0, precise: true) { _ in sought.fulfill() }
        await fulfillment(of: [sought], timeout: 10)
        state = try XCTUnwrap(engine.transport(id: "v"))
        XCTAssertEqual(state.position, 3.0, accuracy: 0.15, "transport position must reflect the seek")

        engine.resume(id: "v")
        try await pull(engine, id: "v", timeout: 5) { engine.transport(id: "v")?.isPlaying == true }
        XCTAssertEqual(engine.transport(id: "v")?.isPlaying, true)
        XCTAssertNil(engine.transport(id: "missing"), "unknown ids must return nil")
        engine.stopAll()
    }

    func testPauseHoldsTheCurrentFrameAndResumeContinues() async throws {
        let engine = try MediaEngine(device: device)
        let media = try await engine.prepare(url: makeClip(name: "pause", seconds: 4))
        engine.play(media, id: "v", loop: true)
        try await pull(engine, id: "v") { (engine.stats(for: "v")?.framesDisplayed ?? 0) > 10 }
        let player = try XCTUnwrap(engine.playerForTesting(id: "v"))

        player.pause()

        try await Task.sleep(for: .milliseconds(150))
        let frozen = try XCTUnwrap(engine.stats(for: "v")).framesDisplayed
        var heldSurface = true
        let deadline = Date(timeIntervalSinceNow: 0.5)
        while Date() < deadline {
            if engine.surface(for: "v", hostTime: CACurrentMediaTime()) == nil { heldSurface = false }
            try await Task.sleep(for: .milliseconds(8))
        }
        let afterFreeze = try XCTUnwrap(engine.stats(for: "v")).framesDisplayed
        XCTAssertTrue(heldSurface, "paused player stopped returning the held frame")
        XCTAssertLessThanOrEqual(afterFreeze - frozen, 1, "frames kept vending while paused")

        player.resume()
        try await pull(engine, id: "v") {
            (engine.stats(for: "v")?.framesDisplayed ?? 0) > afterFreeze + 5
        }
        XCTAssertGreaterThan(
            try XCTUnwrap(engine.stats(for: "v")).framesDisplayed, afterFreeze + 5,
            "playback did not continue after resume"
        )
        engine.stopAll()
    }

    func testSeekOnNonLoopingItemResumesSequentialVends() async throws {
        let engine = try MediaEngine(device: device)
        let media = try await engine.prepare(url: makeClip(name: "seek", seconds: 4))
        engine.play(media, id: "v", loop: false)
        try await pull(engine, id: "v") { (engine.stats(for: "v")?.framesDisplayed ?? 0) > 5 }
        let player = try XCTUnwrap(engine.playerForTesting(id: "v"))

        let vended = Locked<[Double]>([])
        let sought = expectation(description: "seek completed")
        player.seek(to: 2.5, precise: true) { finished in
            XCTAssertTrue(finished)
            sought.fulfill()
        }
        await fulfillment(of: [sought], timeout: 10)
        player.onFrameVended.value = { t in vended.withLock { $0.append(t) } }
        try await pull(engine, id: "v") { vended.value.count > 15 }

        let times = vended.value
        XCTAssertGreaterThan(times.count, 15, "no frames vended after seek")
        XCTAssertGreaterThan(times.first ?? 0, 2.3, "first post-seek frame was pre-seek content (\(times.first ?? -1))")
        XCTAssertEqual(times, times.sorted(), "post-seek vends were not monotonic")
        engine.stopAll()
    }

    func testSeekWhilePausedVendsTheTargetFrame() async throws {
        let engine = try MediaEngine(device: device)
        let media = try await engine.prepare(url: makeClip(name: "pausedSeek", seconds: 4))
        engine.play(media, id: "v", loop: false)
        try await pull(engine, id: "v") { (engine.stats(for: "v")?.framesDisplayed ?? 0) > 5 }
        let player = try XCTUnwrap(engine.playerForTesting(id: "v"))

        player.pause()
        try await Task.sleep(for: .milliseconds(150))
        let vended = Locked<[Double]>([])
        player.onFrameVended.value = { t in vended.withLock { $0.append(t) } }

        let sought = expectation(description: "seek completed")
        player.seek(to: 2.0, precise: true) { _ in sought.fulfill() }
        await fulfillment(of: [sought], timeout: 10)
        try await pull(engine, id: "v", timeout: 5) { !vended.value.isEmpty }

        let first = try XCTUnwrap(vended.value.first, "paused seek never vended the target frame")
        XCTAssertEqual(first, 2.0, accuracy: 0.15, "paused seek vended the wrong frame")
        engine.stopAll()
    }

    func testSeekOnLoopingItemSurvivesTheSeam() async throws {
        let engine = try MediaEngine(device: device)
        let media = try await engine.prepare(url: makeClip(name: "loopSeek", seconds: 1))
        engine.play(media, id: "v", loop: true)
        try await pull(engine, id: "v") { (engine.stats(for: "v")?.framesDisplayed ?? 0) > 10 }
        let player = try XCTUnwrap(engine.playerForTesting(id: "v"))

        let sought = expectation(description: "seek completed")
        player.seek(to: 0.9, precise: true) { finished in
            XCTAssertTrue(finished)
            sought.fulfill()
        }
        await fulfillment(of: [sought], timeout: 10)

        let vended = Locked<[Double]>([])
        player.onFrameVended.value = { t in vended.withLock { $0.append(t) } }

        try await pull(engine, id: "v", timeout: 20) { vended.value.count > 75 }

        let times = vended.value
        XCTAssertGreaterThan(times.count, 75, "playback stalled after seeking a looping item (\(times.count) frames)")
        var wraps = 0
        for (a, b) in zip(times, times.dropFirst()) where b < a { wraps += 1 }
        XCTAssertGreaterThanOrEqual(wraps, 2, "loop stopped wrapping after seek (\(wraps) wraps)")
        let stats = try XCTUnwrap(engine.stats(for: "v"))
        XCTAssertEqual(stats.framesDroppedAtSeam, 0, "post-seek seam crossings dropped frames")
        engine.stopAll()
    }
}
