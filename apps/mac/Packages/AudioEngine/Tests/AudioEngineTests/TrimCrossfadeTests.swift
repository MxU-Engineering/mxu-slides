import AVFoundation
import Foundation
import Testing
@testable import AudioEngine

private func stereoTone(seconds: Double, hertz: Double, name: String) throws -> URL {
    let sampleRate = 44_100.0
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("audio-engine-trim-xfade-\(name).wav")
    guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else {
        throw AudioEngineError.emptySchedule(url)
    }
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    let frames = AVAudioFrameCount(seconds * sampleRate)
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
        throw AudioEngineError.emptySchedule(url)
    }
    buffer.frameLength = frames
    for index in 0 ..< Int(frames) {
        let sample = Float(sin(2 * .pi * hertz * Double(index) / sampleRate)) * 0.1
        buffer.floatChannelData?[0][index] = sample
        buffer.floatChannelData?[1][index] = sample
    }
    try file.write(from: buffer)
    return url
}

@Test func trimmedTracksCrossfadeInsteadOfCutting() async throws {
    let outgoing = try stereoTone(seconds: 10, hertz: 440, name: "out")
    let incoming = try stereoTone(seconds: 10, hertz: 660, name: "in")
    let engine = AudioEngine()
    engine.masterVolume = 0
    engine.setMetering(true)
    do {
        try engine.play(url: outgoing, trimStart: 2, trimEnd: 5)
    } catch {
        return 
    }

    let crossfade = 2.0
    var fired = false
    var levels: [Float] = []
    let deadline = ContinuousClock.now + .seconds(5)
    while ContinuousClock.now < deadline, !fired {
        if let position = engine.position, position.duration - position.elapsed <= crossfade {
            fired = true
            try engine.play(
                url: incoming, crossfade: position.duration - position.elapsed,
                trimStart: 1, trimEnd: 4
            )
        }
        try await Task.sleep(for: .milliseconds(100))
    }
    #expect(fired, "a trimmed track's poll reaches the crossfade window before its out point")

    _ = engine.takeMeterLevels()
    for _ in 0 ..< 20 {
        try await Task.sleep(for: .milliseconds(100))
        levels.append(engine.takeMeterLevels().source.rms)
    }
    let steady = levels.suffix(4).max() ?? 0
    let dip = levels.prefix(12).min() ?? 1
    #expect(steady > 0.06, "the incoming trimmed track is at full after the ramp")
    #expect(dip < steady * 0.75, "the handoff ramped (\(levels))")
    #expect(abs((engine.position?.duration ?? 0) - 4) < 0.05, "active deck is the incoming track's window")
    engine.stop()
}
