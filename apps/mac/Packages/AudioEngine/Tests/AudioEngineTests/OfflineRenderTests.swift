import AVFoundation
import Foundation
import Testing
@testable import AudioEngine

private func tone(seconds: Double, hertz: Double, rate: Double, name: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("audio-forensics-\(name).wav")
    let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    let frames = AVAudioFrameCount(seconds * rate)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    buffer.frameLength = frames
    for index in 0 ..< Int(frames) {
        buffer.floatChannelData?[0][index] =
            Float(sin(2 * .pi * hertz * Double(index) / rate)) * 0.5
    }
    try file.write(from: buffer)
    return url
}

private func discontinuities(in buffer: AVAudioPCMBuffer, threshold: Float = 0.08) -> Int {
    guard let data = buffer.floatChannelData?[0] else { return .max }
    var count = 0
    for index in 1 ..< Int(buffer.frameLength) {
        if abs(data[index] - data[index - 1]) > threshold { count += 1 }
    }
    return count
}

@Test func crossfadeAdvanceRendersCleanSamples() throws {

    let first = try tone(seconds: 4, hertz: 440, rate: 44_100, name: "a441")
    let second = try tone(seconds: 4, hertz: 330, rate: 44_100, name: "b441")
    let engine = AudioEngine()
    try engine.enableManualRenderingForTests()
    try engine.play(url: first)
    let before = try engine.renderOfflineForTests(frames: 24_000) 
    #expect(discontinuities(in: before) == 0, "steady-state playback is clean")

    try engine.play(url: second, crossfade: 1.0)
    let during = try engine.renderOfflineForTests(frames: 96_000) 
    #expect(discontinuities(in: during) == 0, "crossfade handoff is clean")
}

@Test func sameFileCrossfadeRendersCleanSamples() throws {

    let only = try tone(seconds: 4, hertz: 440, rate: 44_100, name: "dup441")
    let engine = AudioEngine()
    try engine.enableManualRenderingForTests()
    try engine.play(url: only)
    _ = try engine.renderOfflineForTests(frames: 24_000)
    try engine.play(url: only, crossfade: 1.0)
    let during = try engine.renderOfflineForTests(frames: 96_000)
    #expect(discontinuities(in: during) == 0, "same-file handoff is clean")
}

private func dominantHertz(in buffer: AVAudioPCMBuffer, first frames: Int) -> Double {
    guard let data = buffer.floatChannelData?[0] else { return 0 }
    let count = min(frames, Int(buffer.frameLength))
    guard count > 1 else { return 0 }
    var crossings = 0
    for index in 1 ..< count where (data[index - 1] < 0) != (data[index] < 0) {
        crossings += 1
    }
    return Double(crossings) / 2 * buffer.format.sampleRate / Double(count)
}

@Test func cutAdvanceRendersTheNewTrackImmediately() throws {
    let first = try tone(seconds: 4, hertz: 440, rate: 44_100, name: "cut-a")
    let second = try tone(seconds: 4, hertz: 330, rate: 44_100, name: "cut-b")
    let engine = AudioEngine()
    try engine.enableManualRenderingForTests()
    try engine.play(url: first)
    _ = try engine.renderOfflineForTests(frames: 24_000)

    try engine.play(url: second)
    let during = try engine.renderOfflineForTests(frames: 96_000)

    #expect(discontinuities(in: during) <= 2, "cut path emits no stale audio")

    let hertz = dominantHertz(in: during, first: 24_000)
    #expect(abs(hertz - 330) < 20, "post-cut audio is the new file, not stale chunks (\(hertz)Hz)")
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["AUDIO_FORENSICS_DIR"] != nil))
func realLibraryFilesRenderCleanly() throws {
    let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["AUDIO_FORENSICS_DIR"]!)
    let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        .filter { ["mp3", "m4a", "wav", "aac"].contains($0.pathExtension.lowercased()) }
    try #require(!files.isEmpty)
    for first in files {
        for second in files {
            let engine = AudioEngine()
            try engine.enableManualRenderingForTests()
            try engine.play(url: first)
            let start = try engine.renderOfflineForTests(frames: 96_000)
            try engine.play(url: second, crossfade: 1.0)
            let handoff = try engine.renderOfflineForTests(frames: 96_000)
            let startGlitches = discontinuities(in: start, threshold: 0.3)
            let handoffGlitches = discontinuities(in: handoff, threshold: 0.3)
            print("FORENSICS \(first.lastPathComponent) -> \(second.lastPathComponent): start=\(startGlitches) handoff=\(handoffGlitches)")
            #expect(startGlitches == 0)
            #expect(handoffGlitches == 0)
        }
    }
}

@Test func restartAfterPauseBeginsAtTheTop() throws {

    let song = try tone(seconds: 4, hertz: 440, rate: 44_100, name: "restart")
    let engine = AudioEngine()
    try engine.enableManualRenderingForTests()
    try engine.play(url: song)
    _ = try engine.renderOfflineForTests(frames: 48_000) 
    engine.pause()
    let held = try #require(engine.position).elapsed
    #expect(held > 0.9, "paused a second into the track")

    try engine.play(url: song) 
    let restarted = try #require(engine.position).elapsed
    #expect(restarted < 0.05, "position snapped to the top")
    let after = try engine.renderOfflineForTests(frames: 24_000)
    #expect(engine.isPlaying)
    #expect(try #require(engine.position).elapsed > 0.4, "playing forward from the top")
    #expect(discontinuities(in: after) == 0)
}
