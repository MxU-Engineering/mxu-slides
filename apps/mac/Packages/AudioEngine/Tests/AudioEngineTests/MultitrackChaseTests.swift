import AVFoundation
import Foundation
import Testing
@testable import AudioEngine

private func file(_ name: String, seconds: Double, _ sample: (Int) -> Float) throws -> String {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("chase-\(name)-\(UUID().uuidString).wav")
    let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
    let output = try AVAudioFile(forWriting: url, settings: format.settings)
    let frames = AVAudioFrameCount(seconds * 48_000)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    buffer.frameLength = frames
    for index in 0 ..< Int(frames) { buffer.floatChannelData![0][index] = sample(index) }
    try output.write(from: buffer)
    return url.path
}

private let ticksPerSecond: Double = {
    var timebase = mach_timebase_info_data_t()
    mach_timebase_info(&timebase)
    return 1e9 * Double(timebase.denom) / Double(timebase.numer)
}()

private func host(_ seconds: Double) -> UInt64 { 1_000_000_000_000 + UInt64((seconds * ticksPerSecond).rounded()) }

private struct Run {
    var out: [Float] = []

    var errors: [(Double, Double)] = []
}

private func chase(
    _ engine: MultitrackEngine, _ song: MultitrackSong, seconds: Double, buffer: Int = 512,
    from start: Double = 0, jitter: Double = 0, timecode: (Double) -> Double?
) -> Run {
    var run = Run()
    let pointers = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: 1)
    let storage = UnsafeMutablePointer<Float>.allocate(capacity: buffer)
    defer { storage.deallocate(); pointers.deallocate() }
    pointers[0] = storage
    var nextAnchor = start
    var generator = SystemRandomNumberGenerator()
    var done = 0
    let total = Int(seconds * 48_000)
    while done < total {
        let t = start + Double(done) / 48_000
        if t >= nextAnchor {
            nextAnchor += 0.1
            if let p = timecode(t) {
                let noise = jitter > 0 ? Double.random(in: -jitter ... jitter, using: &generator) : 0
                engine.chase(song: song, songID: song.id, position: p + noise, hostTime: host(t))
            }
        }
        engine.tickNow()
        let count = min(buffer, total - done)
        engine.renderer.render(frames: count, hostTime: host(t), outputs: pointers)
        run.out += Array(UnsafeBufferPointer(start: storage, count: count))
        done += count
        let after = start + Double(done) / 48_000
        if engine.isPlaying, let p = timecode(after) {
            run.errors.append((after, engine.renderer.position(atHostTime: host(after)) - p))
        }
    }
    return run
}

private func biggestStep(_ samples: [Float]) -> Float {
    zip(samples, samples.dropFirst()).map { abs($1 - $0) }.max() ?? 0
}

private func sine(_ name: String, seconds: Double) throws -> MultitrackSong {
    let path = try file(name, seconds: seconds) { Float(sin(2 * .pi * 440 * Double($0) / 48_000)) * 0.5 }
    return MultitrackSong(id: name, stems: [.init(path: path, channelId: "s")])
}

private func engine() -> MultitrackEngine {
    let engine = MultitrackEngine(sampleRate: 48_000, deviceChannels: 1)
    engine.setRouting(MultitrackRouting(
        channels: [.init(id: "s", sends: ["m": 1])], mixes: [.init(id: "m", outputs: [.init(channels: [0])])]))
    return engine
}

private let smooth: Float = 0.06

@Test func stemsStartWhereTimecodeIsOnTheSample() throws {
    let path = try file("impulse", seconds: 4) { $0 == 96_000 ? 1 : 0 }
    let song = MultitrackSong(id: "impulse", stems: [.init(path: path, channelId: "s")])
    let engine = engine()

    let run = chase(engine, song, seconds: 1, buffer: 333) { 1.5 + $0 }
    let peak = run.out.indices.max { abs(run.out[$0]) < abs(run.out[$1]) }!
    #expect(abs(peak - 24_000) <= 1, "impulse at \(peak)")
    #expect(engine.cuesDecoded == 1)
}

@Test func aPreloadedSongStartsFromTimecodeWithoutDecoding() throws {
    let path = try file("top", seconds: 2) { $0 == 9_600 ? 1 : 0 }
    let song = MultitrackSong(id: "top", stems: [.init(path: path, channelId: "s")])
    let engine = engine()
    engine.preload([song])
    let deadline = Date().addingTimeInterval(3)
    while engine.preloadedSongIDs.isEmpty, Date() < deadline { Thread.sleep(forTimeInterval: 0.005) }

    let run = chase(engine, song, seconds: 0.5) { 0.1 + $0 }
    let peak = run.out.indices.max { abs(run.out[$0]) < abs(run.out[$1]) }!
    #expect(abs(peak - 4_800) <= 1, "impulse at \(peak)")
    #expect(engine.cuesDecoded == 0)
}

@Test func varispeedHoldsStemsOnDriftingTimecode() throws {
    let song = try sine("drift", seconds: 190)
    let engine = engine()
    let run = chase(engine, song, seconds: 180) { 5 + $0 * 1.0001 }
    let settled = run.errors.filter { $0.0 > 10 }.map { abs($0.1) }
    #expect(settled.max()! < 0.002, "worst \(settled.max()!)")
    #expect(engine.chaseLandings == 0)
    #expect(biggestStep(run.out) < smooth, "step \(biggestStep(run.out))")

    #expect(abs(run.errors.last!.1) < 0.001)
    #expect(abs(engine.renderer.speed - 1.0001) < 0.00002, "speed \(engine.renderer.speed)")
}

@Test func varispeedKeepsTheTopOctaveSteady() throws {
    let path = try file("hf", seconds: 30) { Float(sin(2 * .pi * 15_000 * Double($0) / 48_000)) * 0.5 }
    let song = MultitrackSong(id: "hf", stems: [.init(path: path, channelId: "s")])
    let engine = engine()
    let run = chase(engine, song, seconds: 25) { 1 + $0 * 1.00068 }
    let blocks = stride(from: 48_000 * 4, to: run.out.count - 480, by: 480).map { start in
        (run.out[start ..< start + 480].map { $0 * $0 }.reduce(0, +) / 480).squareRoot()
    }
    let decibels = blocks.map { 20 * log10($0 / (0.5 / Float(2).squareRoot())) }
    #expect(decibels.max()! - decibels.min()! < 0.1, "flutter \(decibels.max()! - decibels.min()!) dB")
    #expect(abs(decibels.max()!) < 0.1, "level \(decibels.max()!) dB")
    #expect(abs(engine.renderer.speed - 1.00068) < 0.00003, "speed \(engine.renderer.speed)")
}

@Test func stemsLandWithJumpsAndLoops() throws {
    let song = try sine("jumps", seconds: 70)
    let engine = engine()
    let run = chase(engine, song, seconds: 30) { t in
        t < 10 ? 2 + t : t < 20 ? 22 + t : 5 + t
    }
    #expect(engine.chaseLandings == 2)
    let afterJumps = run.errors.filter { ($0.0 > 10.15 && $0.0 < 20) || $0.0 > 20.15 }.map { abs($0.1) }
    #expect(afterJumps.max()! < 0.001, "worst \(afterJumps.max()!)")
    #expect(biggestStep(run.out) < 0.1, "step \(biggestStep(run.out))")
}

@Test func aSmallStepBackIsNeverALanding() throws {
    let song = try sine("stepback", seconds: 80)
    let engine = engine()
    let back = 3.0 / 24
    let run = chase(engine, song, seconds: 70) { t in t < 5 ? 1 + t : 1 + t - back }
    #expect(engine.chaseLandings == 0)
    #expect(biggestStep(run.out) < smooth)
    let early = run.errors.first { $0.0 > 6 }!.1
    let late = run.errors.last!.1
    #expect(early > 0.1 && late < early - 0.03, "\(early) → \(late)")
}

@Test func aDropoutFreewheelsWithoutAGap() throws {
    let song = try sine("dropout", seconds: 20)
    let engine = engine()
    let run = chase(engine, song, seconds: 8) { t in (3 ... 3.6).contains(t) ? nil : 1 + t }
    #expect(engine.chaseLandings == 0)
    #expect(biggestStep(run.out) < smooth)
    let quietest = stride(from: 48_000, to: run.out.count - 480, by: 480).map { start in
        (run.out[start ..< start + 480].map { $0 * $0 }.reduce(0, +) / 480).squareRoot()
    }.min()!
    #expect(quietest > 0.3, "a gap: rms \(quietest)")
}

@Test func timecodeJitterIsNeverChased() throws {
    let song = try sine("jitter", seconds: 40)
    let engine = engine()
    let run = chase(engine, song, seconds: 30, jitter: 0.002) { 1 + $0 }
    #expect(engine.chaseLandings == 0)
    #expect(biggestStep(run.out) < smooth)
    #expect(run.errors.filter { $0.0 > 5 }.map { abs($0.1) }.max()! < 0.003)
}

@Test func aStopFadesAndTimecodeStartsTheStemsAgain() throws {
    let song = try sine("stop", seconds: 20)
    let engine = engine()
    var run = chase(engine, song, seconds: 1) { 1 + $0 }
    engine.stop()
    run.out += chase(engine, song, seconds: 0.5, from: 1) { _ in nil }.out
    #expect(biggestStep(run.out) < smooth)
    #expect(run.out.suffix(1000).allSatisfy { $0 == 0 })
    let again = chase(engine, song, seconds: 1, from: 5) { 4 + $0 }
    #expect(biggestStep(again.out) < smooth)
    #expect(abs(again.errors.last!.1) < 0.001)
}
