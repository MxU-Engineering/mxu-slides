import AVFoundation
import Foundation
import Testing
@testable import AudioEngine

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var raised = false
    var isRaised: Bool { lock.withLock { raised } }
    func raise() { lock.withLock { raised = true } }
}

private func toneFile(seconds: Double, hertz: Double, name: String) throws -> URL {
    let sampleRate = 44_100.0
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("audio-engine-smoke-\(name).wav")
    guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else {
        throw AudioEngineError.emptySchedule(url)
    }
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    let frames = AVAudioFrameCount(seconds * sampleRate)
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
        throw AudioEngineError.emptySchedule(url)
    }
    buffer.frameLength = frames
    for index in 0 ..< Int(frames) {
        buffer.floatChannelData?[0][index] =
            Float(sin(2 * .pi * hertz * Double(index) / sampleRate)) * 0.1
    }
    try file.write(from: buffer)
    return url
}

@Test func naturalEndFiresAndCrossfadeHandsOff() async throws {
    let short = try toneFile(seconds: 0.4, hertz: 440, name: "short")
    let long = try toneFile(seconds: 4, hertz: 550, name: "long")
    let engine = AudioEngine()
    engine.masterVolume = 0

    let ended = Flag()
    engine.onTrackPlayedToEnd = { ended.raise() }

    do {
        try engine.play(url: short)
    } catch {
        return 
    }
    #expect(engine.isPlaying)
    #expect(engine.position?.duration ?? 0 > 0.3)

    let deadline = ContinuousClock.now + .seconds(3)
    while !ended.isRaised, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(25))
    }
    #expect(ended.isRaised, "dataPlayedBack natural-end callback fired")

    try engine.play(url: long)
    try await Task.sleep(for: .milliseconds(50))
    try engine.play(url: short, crossfade: 0.2)
    #expect(engine.isPlaying)
    #expect(abs((engine.position?.duration ?? 0) - 0.4) < 0.05, "active deck is the incoming track")
    try await Task.sleep(for: .milliseconds(300))
    #expect(engine.isPlaying, "still playing after the ramp resolves")

    engine.pause()
    #expect(!engine.isPlaying)
    let held = engine.position?.elapsed ?? -1
    try await Task.sleep(for: .milliseconds(60))
    #expect(abs((engine.position?.elapsed ?? -2) - held) < 0.01, "pause holds the clock")
    engine.resume()
    #expect(engine.isPlaying)
    engine.stop()
    #expect(!engine.isPlaying)
    #expect(engine.position == nil)
}

@Test func seekJumpsAndPreservesTransportState() async throws {
    let long = try toneFile(seconds: 4, hertz: 550, name: "seek-long")
    let engine = AudioEngine()
    engine.masterVolume = 0

    do {
        try engine.play(url: long)
    } catch {
        return 
    }

    engine.seek(to: 2.5)
    #expect(engine.isPlaying, "seek keeps a playing track playing")
    let landed = engine.position?.elapsed ?? -1
    #expect(abs(landed - 2.5) < 0.1, "position lands at the seek target")

    engine.pause()
    engine.seek(to: 1.0)
    #expect(!engine.isPlaying, "seek keeps a paused track paused")
    #expect(abs((engine.position?.elapsed ?? -1) - 1.0) < 0.1)
    try await Task.sleep(for: .milliseconds(60))
    #expect(abs((engine.position?.elapsed ?? -1) - 1.0) < 0.1, "still parked after the seek")

    engine.seek(to: 99)
    #expect(engine.position != nil, "clamped seek keeps the track loaded")
    #expect((engine.position?.elapsed ?? 0) > 3.5)

    engine.stop()
}

@Test func trimWindowCapsScheduleAndSurvivesSeek() async throws {
    let tone = try toneFile(seconds: 2, hertz: 440, name: "trim")
    let engine = AudioEngine()
    engine.masterVolume = 0
    let ended = Flag()
    engine.onTrackPlayedToEnd = { ended.raise() }
    do {
        try engine.play(url: tone, trimStart: 0.5, trimEnd: 0.9)
    } catch {
        return 
    }

    #expect(abs((engine.position?.duration ?? 0) - 0.9) < 0.05)
    #expect((engine.position?.elapsed ?? 0) >= 0.45)

    let deadline = ContinuousClock.now + .seconds(3)
    while !ended.isRaised, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(25))
    }
    #expect(ended.isRaised)

    try engine.play(url: tone, trimStart: 0.5, trimEnd: 1.5)
    engine.seek(to: 1.0)
    engine.seek(to: 0.6)
    #expect((engine.position?.elapsed ?? 0) < 0.9)
    #expect((engine.position?.elapsed ?? 0) >= 0.5)
    #expect(abs((engine.position?.duration ?? 0) - 1.5) < 0.05)
    engine.seek(to: 0.1)
    #expect((engine.position?.elapsed ?? 0) >= 0.5)
    engine.stop()
}
