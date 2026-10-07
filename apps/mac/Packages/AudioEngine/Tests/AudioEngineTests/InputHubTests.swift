import AVFoundation
import Testing

@testable import AudioEngine

private func deviceBuffer(
    channels: Int, frames: AVAudioFrameCount = 480, sampleRate: Double = 48_000
) -> AVAudioPCMBuffer {
    let layout = AVAudioChannelLayout(
        layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | UInt32(channels))!
    let format = AVAudioFormat(
        standardFormatWithSampleRate: sampleRate, channelLayout: layout)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    buffer.frameLength = frames
    for channel in 0 ..< channels {
        for frame in 0 ..< Int(frames) {
            buffer.floatChannelData![channel][frame] = Float(channel + 1) / 100
        }
    }
    return buffer
}

private func value(_ buffer: AVAudioPCMBuffer, channel: Int) -> Float {
    buffer.floatChannelData![channel][0]
}

@Test func extractStereoPairFromMultichannel() {
    let out = ChannelExtraction.extract(
        deviceBuffer(channels: 8), selection: .stereoPair(offset: 2))!
    #expect(out.format.channelCount == 2)
    #expect(out.frameLength == 480)
    #expect(abs(value(out, channel: 0) - 0.03) < 0.0001)  
    #expect(abs(value(out, channel: 1) - 0.04) < 0.0001)  
}

@Test func extractMonoDoubles() {
    let out = ChannelExtraction.extract(
        deviceBuffer(channels: 8), selection: .mono(channel: 5))!
    #expect(abs(value(out, channel: 0) - 0.06) < 0.0001)
    #expect(abs(value(out, channel: 1) - 0.06) < 0.0001)
}

@Test func extractClampsOutOfRange() {

    let pair = ChannelExtraction.extract(
        deviceBuffer(channels: 8), selection: .stereoPair(offset: 10))!
    #expect(abs(value(pair, channel: 0) - 0.01) < 0.0001)
    #expect(abs(value(pair, channel: 1) - 0.02) < 0.0001)

    let mono = ChannelExtraction.extract(
        deviceBuffer(channels: 8), selection: .mono(channel: 12))!
    #expect(abs(value(mono, channel: 0) - 0.01) < 0.0001)

    let negative = ChannelExtraction.extract(
        deviceBuffer(channels: 8), selection: .stereoPair(offset: -2))!
    #expect(abs(value(negative, channel: 0) - 0.01) < 0.0001)
}

@Test func extractFromMonoDeviceDoubles() {
    let out = ChannelExtraction.extract(
        deviceBuffer(channels: 1), selection: .stereoPair(offset: 0))!
    #expect(abs(value(out, channel: 0) - 0.01) < 0.0001)
    #expect(abs(value(out, channel: 1) - 0.01) < 0.0001)
}

@Test func extractAppliesTrimAndMuteEmitsSilence() {
    let trimmed = ChannelExtraction.extract(
        deviceBuffer(channels: 8), selection: .stereoPair(offset: 2), gain: 0.5)!
    #expect(abs(value(trimmed, channel: 0) - 0.015) < 0.0001)

    let muted = ChannelExtraction.extract(
        deviceBuffer(channels: 8), selection: .stereoPair(offset: 2), muted: true)!
    #expect(muted.frameLength == 480)
    #expect(value(muted, channel: 0) == 0)
    #expect(value(muted, channel: 1) == 0)
}

@Test func fanoutDeliversPerTapSelections() {
    let fanout = InputFanout()
    let pairOut = Locked<AVAudioPCMBuffer?>(nil)
    let monoOut = Locked<AVAudioPCMBuffer?>(nil)
    _ = fanout.add(channels: .stereoPair(offset: 2)) { buffer, _, _ in
        pairOut.withLock { $0 = buffer }
    }
    _ = fanout.add(channels: .mono(channel: 5)) { buffer, _, _ in
        monoOut.withLock { $0 = buffer }
    }
    fanout.push(deviceBuffer(channels: 8), when: AVAudioTime(hostTime: 0), hostSeconds: 0)
    let pair = pairOut.withLock { $0 }!
    let mono = monoOut.withLock { $0 }!
    #expect(abs(value(pair, channel: 0) - 0.03) < 0.0001)
    #expect(abs(value(pair, channel: 1) - 0.04) < 0.0001)
    #expect(abs(value(mono, channel: 0) - 0.06) < 0.0001)

    #expect(pair !== mono)
}

@Test func fanoutTapLifecycle() {
    let fanout = InputFanout()
    let received = Locked(0)
    let token = fanout.add(channels: .stereoPair(offset: 0)) { _, _, _ in
        received.withLock { $0 += 1 }
    }
    #expect(fanout.count == 1)
    fanout.push(deviceBuffer(channels: 4), when: AVAudioTime(hostTime: 0), hostSeconds: 0)
    #expect(received.withLock { $0 } == 1)

    let latest = Locked<AVAudioPCMBuffer?>(nil)
    let updateToken = fanout.add(channels: .stereoPair(offset: 0)) { buffer, _, _ in
        latest.withLock { $0 = buffer }
    }
    fanout.update(updateToken, channels: .mono(channel: 3))
    fanout.push(deviceBuffer(channels: 4), when: AVAudioTime(hostTime: 0), hostSeconds: 0)
    #expect(abs(value(latest.withLock { $0 }!, channel: 0) - 0.04) < 0.0001)
    #expect(received.withLock { $0 } == 2, "first tap still live for the second push")

    fanout.remove(token)
    fanout.remove(updateToken)
    #expect(fanout.count == 0)
    fanout.push(deviceBuffer(channels: 4), when: AVAudioTime(hostTime: 0), hostSeconds: 0)
    #expect(received.withLock { $0 } == 2, "removed taps stop receiving")
}

@Test func poolRefCountsHubs() throws {
    let pool = AudioInputHubPool()
    let built = Locked(0)
    pool.hubFactory = { uid, trim in
        built.withLock { $0 += 1 }
        return AudioInputHub(deviceUID: uid, engine: AVAudioEngine(), trim: trim)
    }
    let first = try pool.acquire(deviceUID: "wing")
    let second = try pool.acquire(deviceUID: "wing")
    #expect(first === second, "same device shares one hub")
    #expect(built.withLock { $0 } == 1)
    #expect(pool.hubCount == 1)

    _ = try pool.acquire(deviceUID: "interface")
    #expect(pool.hubCount == 2)

    pool.release(deviceUID: "wing")
    #expect(pool.hubCount == 2, "one holder remains")
    pool.release(deviceUID: "wing")
    #expect(pool.hubCount == 1, "last release tears down")
    _ = try pool.acquire(deviceUID: "wing")
    #expect(built.withLock { $0 } == 3, "reacquire builds fresh")
}

@Test func hubConfigChangePostDoesNotBlockPostingThread() {

    let hub = AudioInputHub(deviceUID: "test", engine: AVAudioEngine())
    hub.lock.lock()
    let posted = Locked(false)
    Thread.detachNewThread {
        NotificationCenter.default.post(
            name: .AVAudioEngineConfigurationChange, object: hub.engine
        )
        posted.withLock { $0 = true }
    }
    var waited = 0
    while !posted.withLock({ $0 }), waited < 100 {
        Thread.sleep(forTimeInterval: 0.02)
        waited += 1
    }
    #expect(posted.withLock { $0 }, "config-change post must not wait on the hub lock")
    hub.lock.unlock()
}

@Test func converterPathResamplesDeviceWide() throws {

    let source = deviceBuffer(channels: 4, frames: 441, sampleRate: 44_100)
    let target = AudioInputHub.deviceWideFormat(channels: 4)!
    let converter = try #require(AVAudioConverter(from: source.format, to: target))
    let converted = try #require(AudioInputHub.convertDeviceBuffer(
        source, converter: converter, to: target))
    #expect(converted.format.sampleRate == 48_000)
    #expect(converted.format.channelCount == 4)

    #expect(abs(Int(converted.frameLength) - 480) < 64)

    let out = try #require(ChannelExtraction.extract(
        converted, selection: .stereoPair(offset: 2)))
    let mid = Int(out.frameLength) / 2
    #expect(abs(out.floatChannelData![0][mid] - 0.03) < 0.005)
}

private final class Locked<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()
    init(_ value: Value) { self.value = value }
    func withLock<R>(_ body: (inout Value) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}
