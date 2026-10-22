import AVFoundation
import Foundation
import Testing
@testable import AudioEngine

private func file(_ name: String, seconds: Double, _ sample: (Int) -> Float) throws -> String {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("transition-\(name)-\(UUID().uuidString).wav")
    let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
    let output = try AVAudioFile(forWriting: url, settings: format.settings)
    let frames = AVAudioFrameCount(seconds * 48_000)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    buffer.frameLength = frames
    for index in 0 ..< Int(frames) { buffer.floatChannelData![0][index] = sample(index) }
    try output.write(from: buffer)
    return url.path
}

private func level(_ id: String, _ value: Float = 0.5, seconds: Double = 3) throws -> MultitrackSong {
    MultitrackSong(id: id, stems: [.init(path: try file(id, seconds: seconds) { _ in value }, channelId: id)])
}

private func tone(_ id: String, hz: Double, seconds: Double = 3) throws -> MultitrackSong {
    MultitrackSong(id: id, stems: [.init(
        path: try file(id, seconds: seconds) { Float(sin(2 * .pi * hz * Double($0) / 48_000)) * 0.5 }, channelId: id)])
}

private let apart = MultitrackRouting(
    channels: [.init(id: "a", sends: ["mix-a": 1]), .init(id: "b", sends: ["mix-b": 1])],
    mixes: [.init(id: "mix-a", outputs: [.init(channels: [0])]), .init(id: "mix-b", outputs: [.init(channels: [1])])])

private func render(
    _ engine: MultitrackEngine, seconds: Double, buffer: Int = 333,
    at: [(Double, () -> Void)] = [], perBuffer: (_ outputs: [UnsafeMutablePointer<Float>], _ count: Int) -> Void = { _, _ in }
) -> [[Float]] {
    let channels = engine.deviceChannels
    var out = [[Float]](repeating: [], count: channels)
    let pointers = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: channels)
    let storage = (0 ..< channels).map { _ in UnsafeMutablePointer<Float>.allocate(capacity: buffer) }
    defer { storage.forEach { $0.deallocate() }; pointers.deallocate() }
    for (index, pointer) in storage.enumerated() { pointers[index] = pointer }
    var pending = at
    let total = Int(seconds * 48_000)
    var done = 0
    while done < total {
        while let (time, action) = pending.first, Double(done) / 48_000 >= time {
            action()
            pending.removeFirst()
        }
        engine.tickNow()
        let count = min(buffer, total - done)
        engine.renderer.render(frames: count, hostTime: 0, outputs: pointers)
        perBuffer(storage, count)
        for channel in 0 ..< channels { out[channel] += Array(UnsafeBufferPointer(start: storage[channel], count: count)) }
        done += count
    }
    return out
}

private func playing(_ a: MultitrackSong, _ transition: MultitrackTransition?) -> MultitrackEngine {
    let engine = MultitrackEngine(sampleRate: 48_000, deviceChannels: 2)
    engine.setRouting(apart)
    engine.cue(a)
    engine.transition(transition)
    engine.play()
    return engine
}

private func near(_ value: Float, _ expected: Float, within tolerance: Float = 1e-5) -> Bool {
    abs(value - expected) <= tolerance
}

private func silent(_ samples: ArraySlice<Float>) -> Bool { samples.allSatisfy { abs($0) <= 1e-6 } }

private func firstSound(_ samples: [Float]) -> Int { samples.firstIndex { abs($0) > 1e-6 } ?? -1 }

private func biggestStep(_ samples: ArraySlice<Float>) -> Float {
    zip(samples, samples.dropFirst()).map { abs($1 - $0) }.max() ?? 0
}

@Test func overlapStartsTheNextSongOnItsFrameAtFullLevel() throws {
    let a = try level("a"), b = try level("b")
    let engine = playing(a, MultitrackTransition(
        fromSongID: "a", next: b, nextAt: 1.5, fadeFrom: nil, fadeSeconds: 0, fadeInSeconds: 0, end: 2))
    let out = render(engine, seconds: 2.5)

    #expect(firstSound(out[1]) == 72_000)
    #expect(near(out[1][72_000], 0.5))

    #expect(near(out[0][95_000], 0.5))
    #expect(near(out[0][96_000 - 240], 0.25, within: 0.001), "half way down the cut")
    #expect(silent(out[0][96_000 ..< 120_000]))

    #expect(engine.songID == "b")
    #expect(abs(engine.position() - 1.0) < 0.02, "b at \(engine.position())")
    #expect(engine.armedTransition == nil)
}

@Test func crossfadeKeepsTheSummedPowerAndNeverClicks() throws {
    let a = try level("a"), b = try level("b")
    let engine = playing(a, MultitrackTransition(
        fromSongID: "a", next: b, nextAt: 1.5, fadeFrom: 1.5, fadeSeconds: 0.5, fadeInSeconds: 0.5, end: 2))
    let out = render(engine, seconds: 2.5)

    #expect(abs(out[0][84_000] - 0.5 * Float(cos(Double.pi / 4))) < 0.003)
    #expect(abs(out[1][84_000] - 0.5 * Float(sin(Double.pi / 4))) < 0.003)
    for frame in stride(from: 72_000, to: 96_000, by: 100) {
        let power = out[0][frame] * out[0][frame] + out[1][frame] * out[1][frame]
        #expect(abs(power - 0.25) < 0.0025, "power \(power) at \(frame)")
    }
    #expect(silent(out[0][96_000...]))
    #expect(near(out[1][100_000], 0.5))

    let fadeStep: Float = 0.5 / 480
    #expect(biggestStep(out[0][70_000 ..< 100_000]) <= fadeStep)
    #expect(biggestStep(out[1][72_001 ..< 100_000]) <= fadeStep)
}

@Test func fadeEndsTheSongThenTheNextStartsAtItsEnd() throws {
    let a = try level("a"), b = try level("b")
    let engine = playing(a, MultitrackTransition(
        fromSongID: "a", next: b, nextAt: 2, fadeFrom: 1.5, fadeSeconds: 0.5, fadeInSeconds: 0, end: 2))
    let out = render(engine, seconds: 2.5)
    #expect(near(out[0][71_000], 0.5))

    #expect(abs(out[0][84_000] - 0.25) < 0.003)
    #expect(silent(out[0][96_000...]))
    #expect(firstSound(out[1]) == 96_000)
    #expect(biggestStep(out[0][70_000 ..< 97_000]) <= 0.5 / 480)
}

@Test func fadeWithNothingNextStopsTheTransport() throws {
    let a = try level("a")
    let engine = playing(a, MultitrackTransition(
        fromSongID: "a", next: nil, nextAt: 2, fadeFrom: 1.5, fadeSeconds: 0.5, fadeInSeconds: 0, end: 2))
    let out = render(engine, seconds: 2.5)
    #expect(silent(out[0][96_000...]))
    #expect(!engine.isPlaying)
    #expect(engine.songID == "a")
}

@Test func aToneCrossfadesIntoAToneWithoutAClick() throws {
    let a = try tone("a", hz: 440), b = try tone("b", hz: 660)
    let engine = playing(a, MultitrackTransition(
        fromSongID: "a", next: b, nextAt: 1, fadeFrom: 1, fadeSeconds: 1, fadeInSeconds: 1, end: 2))
    let out = render(engine, seconds: 2.5)

    let own = Float(2 * Double.pi * 660 / 48_000) * 0.5
    #expect(biggestStep(out[0][40_000 ..< 110_000]) <= own * 1.01)
    #expect(biggestStep(out[1][48_000 ..< 110_000]) <= own * 1.01)
}

@Test func aFaderMoveMidOverlapMovesBothSongs() throws {
    let a = try level("a"), b = try level("b")
    var quieter = apart
    quieter.channels = quieter.channels.map { var channel = $0; channel.gain = 0.5; return channel }
    let engine = MultitrackEngine(sampleRate: 48_000, deviceChannels: 2)
    engine.setRouting(apart)
    engine.cue(a)
    engine.transition(MultitrackTransition(
        fromSongID: "a", next: b, nextAt: 1, fadeFrom: nil, fadeSeconds: 0, fadeInSeconds: 0, end: 2))
    engine.play()
    let out = render(engine, seconds: 2, at: [(1.5, { engine.setRouting(quieter) })])
    #expect(near(out[0][60_000], 0.5) && near(out[1][60_000], 0.5))

    #expect(near(out[0][75_000], 0.25))
    #expect(near(out[1][75_000], 0.25))
}

@Test func aMixShareCarriesBothSongsFrameForFrame() throws {
    let share = TracksShare()
    let engine = MultitrackEngine(sampleRate: 48_000, deviceChannels: 2, share: share)
    engine.setRouting(MultitrackRouting(
        channels: [.init(id: "a", sends: ["main": 1]), .init(id: "b", sends: ["main": 1])],
        mixes: [.init(id: "main", outputs: [.init(channels: [0, 1])], feedSlot: 4)]))
    engine.cue(try tone("a", hz: 440))
    engine.transition(MultitrackTransition(
        fromSongID: "a", next: try tone("b", hz: 660), nextAt: 0.5, fadeFrom: 0.5, fadeSeconds: 0.5, fadeInSeconds: 0.5, end: 1))
    engine.play()
    var mismatches = 0
    _ = render(engine, seconds: 1.5, buffer: 512) { outputs, count in
        var left = [Float](repeating: 0, count: count), right = left
        left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in
                share.read(slot: 4, from: share.writtenFrames(slot: 4) - Int64(count), count: count,
                           left: l.baseAddress!, right: r.baseAddress!)
            }
        }
        for index in 0 ..< count where abs(left[index] - outputs[0][index]) > 1e-6 { mismatches += 1 }
    }
    #expect(mismatches == 0)
    #expect(share.writtenFrames(slot: 4) == 72_000)
}

@Test func stopMidTransitionStopsBothAndDisarms() throws {
    let a = try level("a"), b = try level("b")
    let engine = playing(a, MultitrackTransition(
        fromSongID: "a", next: b, nextAt: 1, fadeFrom: 1, fadeSeconds: 1, fadeInSeconds: 1, end: 2))
    let out = render(engine, seconds: 2.5, at: [(1.5, { engine.stop() })])

    #expect(silent(out[0][73_100 ..< 120_000]))
    #expect(silent(out[1][73_100 ..< 120_000]))
    #expect(!engine.isPlaying)
    #expect(engine.armedTransition == nil)
}

@Test func disarmingBeforeTheHandoverLeavesTheSongAlone() throws {
    let a = try level("a"), b = try level("b")
    let engine = playing(a, MultitrackTransition(
        fromSongID: "a", next: b, nextAt: 1, fadeFrom: 1, fadeSeconds: 0.5, fadeInSeconds: 0.5, end: 1.5))
    let out = render(engine, seconds: 2, at: [(0.5, { engine.transition(nil) })])
    #expect(silent(out[1][...]))
    #expect(near(out[0][90_000], 0.5), "Stop: A plays on")
    #expect(engine.songID == "a")
}

@Test func aManualJumpCrossfadesIntoTheOtherSong() throws {
    let a = try level("a"), b = try level("b")
    let engine = MultitrackEngine(sampleRate: 48_000, deviceChannels: 2)
    engine.setRouting(apart)
    engine.cue(a)
    engine.play()
    let out = render(engine, seconds: 2, at: [(0.5, { engine.crossfade(to: b, over: 0.5) })])
    let start = firstSound(out[1])
    #expect(abs(start - 24_000) <= 333, "starts with the next buffer: \(start)")
    let middle = start + 12_000
    #expect(abs(out[0][middle] - 0.5 * Float(cos(Double.pi / 4))) < 0.003)
    #expect(abs(out[1][middle] - 0.5 * Float(sin(Double.pi / 4))) < 0.003)
    #expect(silent(out[0][(start + 24_000)...]))
    #expect(engine.songID == "b")
}

@Test func theWireCarriesATransition() throws {
    let message = TracksPlayerMessage.transition(MultitrackTransition(
        fromSongID: "a", next: MultitrackSong(id: "b", stems: []), nextAt: 1, fadeFrom: 1, fadeSeconds: 2,
        fadeInSeconds: 2, end: 3))
    let decoded = try JSONDecoder().decode(TracksPlayerMessage.self, from: JSONEncoder().encode(message))
    #expect(decoded == message)
    #expect(try JSONDecoder().decode(TracksPlayerMessage.self, from: JSONEncoder().encode(TracksPlayerMessage.transition(nil)))
        == .transition(nil))
}

@Test func theMusicLayerFadesOnTheStemsCurves() {

    #expect(AudioFadeCurve.linear.falling(0.25) == 0.75)
    #expect(abs(AudioFadeCurve.equalPower.falling(0.5) - Float(cos(Double.pi / 4))) < 1e-6)
    #expect(abs(AudioFadeCurve.cosine.falling(0.5) - 0.5) < 1e-6)
    #expect(AudioFadeCurve.cosine.falling(1) < 1e-6 && AudioFadeCurve.equalPower.falling(0) == 1)
}
