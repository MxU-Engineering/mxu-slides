import AVFoundation
import Foundation
import Testing
@testable import AudioEngine

private func file(
    _ name: String, rate: Double, channels: AVAudioChannelCount, seconds: Double,
    _ sample: (Int) -> Float
) throws -> String {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("multitrack-\(name)-\(UUID().uuidString).wav")
    let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels)!
    let output = try AVAudioFile(forWriting: url, settings: format.settings)
    let frames = AVAudioFrameCount(seconds * rate)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    buffer.frameLength = frames
    for channel in 0 ..< Int(channels) {
        for index in 0 ..< Int(frames) { buffer.floatChannelData![channel][index] = sample(index) }
    }
    try output.write(from: buffer)
    return url.path
}

private func impulse(_ name: String, rate: Double, channels: AVAudioChannelCount, at seconds: Double) throws -> String {
    let target = Int((seconds * rate).rounded())
    return try file(name, rate: rate, channels: channels, seconds: 3) { $0 == target ? 1 : 0 }
}

private func render(
    _ engine: MultitrackEngine, seconds: Double, buffer: Int = 512,
    starve: ClosedRange<Double>? = nil, at start: Double = 0
) -> [[Float]] {
    let channels = engine.deviceChannels
    var out = [[Float]](repeating: [], count: channels)
    let pointers = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: channels)
    let storage = (0 ..< channels).map { _ in UnsafeMutablePointer<Float>.allocate(capacity: buffer) }
    defer { storage.forEach { $0.deallocate() }; pointers.deallocate() }
    for (index, pointer) in storage.enumerated() { pointers[index] = pointer }
    let total = Int(seconds * engine.sampleRate)
    var done = 0
    while done < total {
        let now = start + Double(done) / engine.sampleRate
        if starve.map({ !$0.contains(now) }) ?? true { engine.tickNow() }
        let count = min(buffer, total - done)
        engine.renderer.render(frames: count, hostTime: 0, outputs: pointers)
        for channel in 0 ..< channels { out[channel] += Array(UnsafeBufferPointer(start: storage[channel], count: count)) }
        done += count
    }
    return out
}

private func peakIndex(_ samples: [Float]) -> Int {
    samples.indices.max { abs(samples[$0]) < abs(samples[$1]) } ?? -1
}

private func biggestStep(_ samples: [Float]) -> Float {
    zip(samples, samples.dropFirst()).map { abs($1 - $0) }.max() ?? 0
}

private func solo(_ ids: [String]) -> MultitrackRouting {
    MultitrackRouting(
        channels: ids.map { .init(id: $0, sends: ["mix-\($0)": 1]) },
        mixes: ids.enumerated().map { .init(id: "mix-\($1)", outputs: [.init(channels: [$0])]) })
}

@Test func routingBecomesOneGainTable() {
    let routing = MultitrackRouting(
        channels: [
            .init(id: "click", gain: 0.5, sends: ["clicks": 1]),
            .init(id: "keys", pan: -1, sends: ["main": 1, "stream": 0.5]),
            .init(id: "bass", muted: true, sends: ["main": 1]),
        ],
        mixes: [
            .init(id: "clicks", outputs: [.init(channels: [4])]),
            .init(id: "main", gain: 0.8, outputs: [.init(channels: [0, 1], level: 0.5)], feeds: true),
            .init(id: "stream", feeds: true),
        ])
    let matrix = MultitrackMatrix(routing, stemChannels: ["click", "keys", "bass"], deviceChannels: 6)
    #expect(matrix.feedMixIds == ["main", "stream"])
    #expect(matrix.destinations == 10)

    #expect(matrix.gain(stem: 0, side: 0, destination: 4) == 0.25)
    #expect(matrix.gain(stem: 0, side: 1, destination: 4) == 0.25)
    #expect(matrix.gain(stem: 0, side: 0, destination: 0) == 0)

    #expect(abs(matrix.gain(stem: 1, side: 0, destination: 0) - 0.4) < 1e-6)
    #expect(matrix.gain(stem: 1, side: 1, destination: 1) == 0)

    #expect(abs(matrix.gain(stem: 1, side: 0, destination: 6) - 0.8) < 1e-6)
    #expect(matrix.gain(stem: 1, side: 0, destination: 8) == 0.5)

    #expect((0 ..< 10).allSatisfy { matrix.gain(stem: 2, side: 0, destination: $0) == 0 })
}

@Test func stemsAtMixedRatesAndOffsetsStartSampleLocked() throws {

    let song = MultitrackSong(id: "song", stems: [
        .init(path: try impulse("a", rate: 44_100, channels: 1, at: 1.5), channelId: "a"),
        .init(path: try impulse("b", rate: 48_000, channels: 2, at: 1.5), channelId: "b"),
        .init(path: try impulse("c", rate: 48_000, channels: 1, at: 1.0), channelId: "c", at: 0.5),
        .init(path: try impulse("d", rate: 44_100, channels: 2, at: 1.75), channelId: "d", inPoint: 0.25),
    ])
    let engine = MultitrackEngine(sampleRate: 48_000, deviceChannels: 4)
    engine.setRouting(solo(["a", "b", "c", "d"]))
    engine.cue(song)
    engine.play()

    let out = render(engine, seconds: 2, buffer: 333)
    let peaks = out.map(peakIndex)
    for peak in peaks { #expect(abs(peak - 72_000) <= 1, "peaks \(peaks)") }
    #expect(Set(peaks).count == 1 || peaks.max()! - peaks.min()! <= 1)
}

@Test func aStarvedStemComesBackInStep() throws {
    let song = MultitrackSong(id: "song", stems: [
        .init(path: try impulse("e", rate: 48_000, channels: 2, at: 1.5), channelId: "e"),
        .init(path: try impulse("f", rate: 44_100, channels: 1, at: 1.5), channelId: "f"),
    ])
    let engine = MultitrackEngine(sampleRate: 48_000, deviceChannels: 2)
    engine.setRouting(solo(["e", "f"]))
    engine.cue(song)
    engine.play()

    let out = render(engine, seconds: 2, starve: 0 ... 1.2)
    #expect(engine.starvedFrames > 0)
    #expect(out.map(peakIndex).allSatisfy { abs($0 - 72_000) <= 1 })
}

@Test func playStartsOnTheAskedHostTimeInsideABuffer() throws {
    let path = try file("ones", rate: 48_000, channels: 2, seconds: 1) { _ in 0.5 }
    let engine = MultitrackEngine(sampleRate: 48_000, deviceChannels: 2)
    engine.setRouting(solo(["x"]))
    engine.cue(MultitrackSong(id: "s", stems: [.init(path: path, channelId: "x")]))
    var timebase = mach_timebase_info_data_t()
    mach_timebase_info(&timebase)
    let bufferStart: UInt64 = 1_000_000_000
    let ticks = UInt64((100.0 / 48_000 * 1e9 * Double(timebase.denom) / Double(timebase.numer)).rounded())
    engine.renderer.play(atHostTime: bufferStart + ticks)
    let left = UnsafeMutablePointer<Float>.allocate(capacity: 512), right = UnsafeMutablePointer<Float>.allocate(capacity: 512)
    defer { left.deallocate(); right.deallocate() }
    let pointers = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: 2)
    defer { pointers.deallocate() }
    pointers[0] = left; pointers[1] = right
    engine.renderer.render(frames: 512, hostTime: bufferStart, outputs: pointers)
    let first = (0 ..< 512).first { left[$0] != 0 }
    #expect(first.map { abs($0 - 100) <= 1 } == true, "first sound at \(String(describing: first))")
}

@Test func jumpsAndFaderMovesNeverClick() throws {

    let path = try file("sine", rate: 48_000, channels: 1, seconds: 4) { Float(sin(2 * .pi * 100 * Double($0) / 48_000)) * 0.5 }
    let engine = MultitrackEngine(sampleRate: 48_000, deviceChannels: 1)
    var routing = solo(["s"])
    engine.setRouting(routing)
    engine.cue(MultitrackSong(id: "s", stems: [.init(path: path, channelId: "s")]))
    engine.play()
    var out = render(engine, seconds: 0.5)[0]
    engine.seek(to: 2.0025)
    out += render(engine, seconds: 0.2)[0]
    routing.channels[0].muted = true
    engine.setRouting(routing)
    out += render(engine, seconds: 0.1)[0]
    #expect(biggestStep(out) < 0.05, "step \(biggestStep(out))")
    #expect(out.suffix(100).allSatisfy { $0 == 0 })
}

@Test func stopFadesAndHoldsThenPlayResumes() throws {
    let path = try file("dc", rate: 48_000, channels: 1, seconds: 3) { _ in 0.5 }
    let engine = MultitrackEngine(sampleRate: 48_000, deviceChannels: 1)
    engine.setRouting(solo(["d"]))
    engine.cue(MultitrackSong(id: "s", stems: [.init(path: path, channelId: "d")]))
    engine.play()
    _ = render(engine, seconds: 0.5)
    engine.stop()
    let stopped = render(engine, seconds: 0.1)[0]
    #expect(biggestStep(stopped) < 0.01)
    #expect(stopped.suffix(100).allSatisfy { $0 == 0 })
    let held = engine.position(atHostTime: 0)
    #expect(abs(held - 0.51) < 0.005)
    engine.play()
    let resumed = render(engine, seconds: 0.1)[0]
    #expect(biggestStep(resumed) < 0.01)
    #expect(abs(resumed.last! - 0.5) < 1e-5)
    #expect(engine.takeMeters()["d"].map { abs($0.peak - 0.5) < 1e-4 } == true)
}

@Test func fedMixesHandTheirShareBack() throws {
    let path = try file("feed", rate: 48_000, channels: 1, seconds: 1) { _ in 0.25 }
    let engine = MultitrackEngine(sampleRate: 48_000, deviceChannels: 2)
    engine.setRouting(MultitrackRouting(
        channels: [.init(id: "t", sends: ["main": 1])],
        mixes: [.init(id: "main", gain: 0.5, outputs: [.init(channels: [0, 1])], feeds: true)]))
    engine.cue(MultitrackSong(id: "s", stems: [.init(path: path, channelId: "t")]))
    engine.play()
    _ = render(engine, seconds: 0.1)
    var frames = 0
    var last: Float = 0
    engine.drainFeeds { mix, left, _, count in
        #expect(mix == "main")
        frames += count
        last = left[count - 1]
    }
    #expect(frames == 4800)
    #expect(abs(last - 0.125) < 1e-5)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["MXU_MULTITRACK_LIVE"] == "1"))
func playsOnARealDeviceByItsClock() throws {
    let device = try #require(AudioDeviceList.outputDevices().first { $0.name == "BlackHole 2ch" })
    let path = try file("live", rate: 44_100, channels: 2, seconds: 3) { Float(sin(2 * .pi * 440 * Double($0) / 44_100)) * 0.1 }
    let engine = MultitrackEngine()
    try engine.attach(device: device)
    engine.setRouting(solo(["l"]))
    engine.cue(MultitrackSong(id: "s", stems: [.init(path: path, channelId: "l")]))
    engine.play()
    Thread.sleep(forTimeInterval: 1)
    let position = engine.position()
    engine.stop()
    Thread.sleep(forTimeInterval: 0.1)
    engine.detach()
    #expect(abs(position - 1) < 0.1, "position \(position)")
    #expect(engine.starvedFrames == 0)
    #expect(engine.sampleRate == 48_000)
}

@Test func theTracksPlayOnTheDeviceTheirMixesLandOn() {

    let channels: [MultitrackRouting.Channel] = [
        .init(id: "keys", sends: ["keys-mix": 1, "main": 0.5]),
        .init(id: "bass", sends: ["bass-mix": 1]),
        .init(id: "click", muted: true, sends: ["main": 1]),
    ]
    let mixes: [MultitrackRouting.ConsoleMix] = [
        .init(id: "main", landings: [("speakers", .init(channels: [0, 1]))]),
        .init(id: "keys-mix", landings: [("dante", .init(channels: [4]))]),
        .init(id: "bass-mix", landings: [("dante", .init(channels: [5]))]),
        .init(id: "unused", landings: [("other", .init(channels: [0, 1])), ("other", .init(channels: [2, 3]))]),
    ]
    let resolved = MultitrackRouting.resolve(channels: channels, mixes: mixes, trim: 1, muted: false, fallbackDevice: "speakers")
    #expect(resolved.deviceUID == "dante")
    #expect(resolved.routing.mixes.first { $0.id == "keys-mix" }?.outputs == [.init(channels: [4])])
    #expect(resolved.routing.mixes.first { $0.id == "main" }?.outputs == [])

    let idle = MultitrackRouting.resolve(channels: [], mixes: mixes, trim: 1, muted: false, fallbackDevice: "speakers")
    #expect(idle.deviceUID == "speakers")
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["MXU_MULTITRACK_LIVE"] == "1"))
func aNewDeviceRateKeepsTheSongsPlace() throws {
    let speakers = try #require(AudioDeviceList.outputDevices().first { $0.name.contains("Speakers") })
    let path = try file("rate", rate: 48_000, channels: 2, seconds: 3) { _ in 0 }
    let engine = MultitrackEngine(sampleRate: 48_000, deviceChannels: 2)
    engine.cue(MultitrackSong(id: "s", stems: [.init(path: path, channelId: "x")]), at: 1.5)
    try engine.attach(device: speakers)
    #expect(engine.sampleRate == (MultitrackOutput.nominalRate(speakers.id) ?? 48_000))
    #expect(abs(engine.position() - 1.5) < 0.01)
    try engine.attach(device: speakers)
    #expect(abs(engine.position() - 1.5) < 0.01)
    engine.detach()
}
