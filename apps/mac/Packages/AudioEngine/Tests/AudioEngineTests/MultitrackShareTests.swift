import AVFoundation
import Foundation
import Testing
@testable import AudioEngine

private func file(_ name: String, rate: Double = 48_000, seconds: Double, _ sample: (Int) -> Float) throws -> String {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("share-\(name)-\(UUID().uuidString).wav")
    let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
    let output = try AVAudioFile(forWriting: url, settings: format.settings)
    let frames = AVAudioFrameCount(seconds * rate)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    buffer.frameLength = frames
    for index in 0 ..< Int(frames) { buffer.floatChannelData![0][index] = sample(index) }
    try output.write(from: buffer)
    return url.path
}

private final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value { lock.withLock { stored } }
    func withLock<T>(_ body: (inout Value) -> T) -> T { lock.withLock { body(&stored) } }
}

private func ramp(_ index: Int) -> Float { Float(index % 4801) / 9602 + 0.01 }

private func render(
    _ engine: MultitrackEngine, seconds: Double, buffer: Int = 512, hostTime: UInt64 = 0,
    perBuffer: (_ outputs: [UnsafeMutablePointer<Float>], _ count: Int) -> Void = { _, _ in }
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
        engine.tickNow()
        let count = min(buffer, total - done)
        engine.renderer.render(frames: count, hostTime: done == 0 ? hostTime : 0, outputs: pointers)
        perBuffer(storage, count)
        for channel in 0 ..< channels { out[channel] += Array(UnsafeBufferPointer(start: storage[channel], count: count)) }
        done += count
    }
    return out
}

private func shareFrames(_ share: TracksShare, slot: Int, last count: Int) -> (left: [Float], right: [Float]) {
    var left = [Float](repeating: 0, count: count), right = left
    left.withUnsafeMutableBufferPointer { l in
        right.withUnsafeMutableBufferPointer { r in
            share.read(slot: slot, from: share.writtenFrames(slot: slot) - Int64(count), count: count,
                       left: l.baseAddress!, right: r.baseAddress!)
        }
    }
    return (left, right)
}

private func mainOnPair(slot: Int?, delayMs: Double = 0) -> MultitrackRouting {
    MultitrackRouting(
        channels: [.init(id: "keys", sends: ["main": 1])],
        mixes: [.init(id: "main", outputs: [.init(channels: [0, 1], delayMs: delayMs)], feedSlot: slot)])
}

@Test func aMixShareMatchesTheDeviceFrameForFrameForAMinute() throws {
    let share = TracksShare()
    let engine = MultitrackEngine(sampleRate: 48_000, deviceChannels: 2, share: share)
    engine.setRouting(mainOnPair(slot: 5))
    engine.cue(MultitrackSong(id: "s", stems: [.init(path: try file("long", seconds: 61, ramp), channelId: "keys")]))

    var timebase = mach_timebase_info_data_t()
    mach_timebase_info(&timebase)
    let ticks = UInt64((100.0 / 48_000 * 1e9 * Double(timebase.denom) / Double(timebase.numer)).rounded())
    engine.renderer.play(atHostTime: 1_000_000_000 + ticks)
    var rendered = 0
    var mismatches = 0
    _ = render(engine, seconds: 60, buffer: 333, hostTime: 1_000_000_000) { outputs, count in
        let shared = shareFrames(share, slot: 5, last: count)
        if rendered == 0 {

            #expect(shared.left.prefix(100).allSatisfy { $0 == 0 })
            #expect(abs(shared.left[100] - 0.01) < 1e-6)
        }
        rendered += count
        for frame in 0 ..< count where shared.left[frame] != outputs[0][frame] || shared.right[frame] != outputs[1][frame] {
            mismatches += 1
        }
    }
    #expect(mismatches == 0)
    #expect(share.writtenFrames(slot: 5) == Int64(rendered))
    #expect(share.writtenFrames(slot: 4) == 0, "only the fed slot is written")
}

@Test func aMixKeepsItsSlotThroughMixerEdits() throws {
    let share = TracksShare()
    let engine = MultitrackEngine(sampleRate: 48_000, deviceChannels: 2, share: share)
    engine.setRouting(mainOnPair(slot: 2))
    engine.cue(MultitrackSong(id: "s", stems: [.init(path: try file("edit", seconds: 2) { _ in 0.5 }, channelId: "keys")]))
    engine.play()
    _ = render(engine, seconds: 0.2)
    var quieter = mainOnPair(slot: 2)
    quieter.channels[0].gain = 0.5
    engine.setRouting(quieter)
    _ = render(engine, seconds: 0.2)
    #expect(share.writtenFrames(slot: 2) == 19_200)
    #expect(abs(shareFrames(share, slot: 2, last: 1).left[0] - 0.25) < 1e-6)
}

@Test func slotsStayWithTheirMixes() {
    var held = MultitrackRouting.assignSlots(["stream", "main"], held: [:])
    #expect(held == ["main": 0, "stream": 1])

    held = MultitrackRouting.assignSlots(["stream", "lobby"], held: held)
    #expect(held == ["main": 0, "stream": 1, "lobby": 2])

    var full: [String: Int] = [:]
    for slot in 0 ..< TracksShare.slots { full["m\(slot)"] = slot }
    let reused = MultitrackRouting.assignSlots(["m1", "new"], held: full)
    #expect(reused["new"] == 0 && reused["m0"] == nil && reused["m1"] == 1)

    let routing = MultitrackRouting(mixes: [.init(id: "main"), .init(id: "stream")]).feeding(["stream"], slots: held)
    #expect(routing.mixes.map(\.feedSlot) == [nil, 1])
    let reach = MultitrackRouting(channels: [.init(id: "a", sends: ["main": 1, "zero": 0]), .init(id: "b", muted: true, sends: ["b": 1])])
    #expect(reach.reachedMixIds == ["main"])
}

@Test func theFeederConvertsTheDeviceRate() throws {
    let share = TracksShare()
    share.sampleRate = 44_100
    let received = Locked<[Float]>([])
    let feeder = TracksShareFeeder(share: share, startsClock: false) { slot, buffer in
        #expect(slot == 7)
        #expect(buffer.format.sampleRate == 48_000)
        received.withLock { $0 += Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))) }
    }
    let ones = [Float](repeating: 0.5, count: 441)

    for _ in 0 ..< 100 {
        ones.withUnsafeBufferPointer { share.write(slot: 7, left: $0.baseAddress, right: $0.baseAddress, count: 441) }
        feeder.drainNow()
    }
    let frames = received.value.count
    #expect(abs(frames - 48_000) < 200, "\(frames) frames")
    #expect(received.value.suffix(1000).allSatisfy { abs($0 - 0.5) < 1e-3 })
    #expect(feeder.droppedFrames == 0)
}

@Test func aStalledFeederSkipsToTheLastFortyMilliseconds() {
    let share = TracksShare()
    share.sampleRate = 48_000
    let received = Locked(0)
    let feeder = TracksShareFeeder(share: share, startsClock: false) { _, buffer in
        received.withLock { $0 += Int(buffer.frameLength) }
    }
    let chunk = [Float](repeating: 0.1, count: 480)
    chunk.withUnsafeBufferPointer { share.write(slot: 0, left: $0.baseAddress, right: $0.baseAddress, count: 480) }
    feeder.drainNow()
    #expect(received.value == 480)
    for _ in 0 ..< 50 {
        chunk.withUnsafeBufferPointer { share.write(slot: 0, left: $0.baseAddress, right: $0.baseAddress, count: 480) }
    }
    feeder.drainNow()
    #expect(received.value == 480 + 1920)
    #expect(feeder.droppedFrames == 24_000 - 1920)
}

@Test func anOutputsDelayShiftsTheTracksOnIt() throws {
    let share = TracksShare()
    let engine = MultitrackEngine(sampleRate: 48_000, deviceChannels: 3, share: share)
    func routing(gain: Float) -> MultitrackRouting {
        MultitrackRouting(
            channels: [.init(id: "k", gain: gain, sends: ["fx": 1, "dry": 1])],
            mixes: [
                .init(id: "fx", outputs: [.init(channels: [0], delayMs: 10)], feedSlot: 0),
                .init(id: "dry", outputs: [.init(channels: [2])]),
            ])
    }
    engine.setRouting(routing(gain: 1))
    let at = 24_000
    engine.cue(MultitrackSong(id: "s", stems: [.init(path: try file("impulse", seconds: 1) { $0 == at ? 1 : 0 }, channelId: "k")]))
    engine.play()
    var shared: [Float] = []
    var out = render(engine, seconds: 0.505) { _, count in shared += shareFrames(share, slot: 0, last: count).left }

    engine.setRouting(routing(gain: 0.999))
    out = zip(out, render(engine, seconds: 0.095) { _, count in shared += shareFrames(share, slot: 0, last: count).left }).map { $0 + $1 }
    let peak = { (samples: [Float]) in samples.indices.max { abs(samples[$0]) < abs(samples[$1]) }! }
    #expect(peak(out[0]) == at + 480, "delayed output at \(peak(out[0]))")
    #expect(peak(out[2]) == at)
    #expect(peak(shared) == at, "streams take mixes, not outputs")
    #expect(out[1].allSatisfy { $0 == 0 })
    let delays = routing(gain: 1).delayFrames(deviceChannels: 3, sampleRate: 48_000)
    #expect(delays == [480, 0, 0])
}

@Test func aPreloadedSongCuesWithoutDecoding() throws {
    let engine = MultitrackEngine(sampleRate: 48_000, deviceChannels: 1)
    let next = MultitrackSong(id: "next", stems: [.init(path: try file("next", seconds: 2) { $0 == 4_800 ? 1 : 0 }, channelId: "a")])
    let other = MultitrackSong(id: "other", stems: [.init(path: try file("other", seconds: 1) { _ in 0 }, channelId: "a")])
    let third = MultitrackSong(id: "third", stems: [.init(path: try file("third", seconds: 1) { _ in 0 }, channelId: "a")])
    engine.setRouting(MultitrackRouting(
        channels: [.init(id: "a", sends: ["m": 1])], mixes: [.init(id: "m", outputs: [.init(channels: [0])])]))
    engine.preload([other, next])
    let deadline = Date().addingTimeInterval(3)
    while engine.preloadedSongIDs.count < 2, Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
    #expect(Set(engine.preloadedSongIDs) == ["other", "next"])
    engine.cue(next)
    #expect(engine.cuesDecoded == 0)
    engine.play()
    let out = render(engine, seconds: 0.2)[0]
    #expect(out.indices.max { abs(out[$0]) < abs(out[$1]) } == 4_800)

    engine.preload([third])
    #expect(!engine.preloadedSongIDs.contains("other"))
    engine.seek(to: 0.5)
    #expect(engine.cuesDecoded == 1)
}
