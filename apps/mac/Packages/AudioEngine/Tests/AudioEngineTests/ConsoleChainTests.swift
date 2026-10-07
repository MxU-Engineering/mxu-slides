import AVFoundation
import Foundation
import Testing
@testable import AudioEngine

private func tone(name: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("console-chain-\(name).wav")
    let rate = 44_100.0
    let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    let frames = AVAudioFrameCount(2 * rate)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    buffer.frameLength = frames
    for index in 0 ..< Int(frames) {
        buffer.floatChannelData?[0][index] =
            Float(sin(2 * .pi * 440 * Double(index) / rate)) * 0.5
    }
    try file.write(from: buffer)
    return url
}

private func settled(_ read: () -> Float, above threshold: Float) -> Float {
    for _ in 0 ..< 200 {
        let value = read()
        if value > threshold { return value }
        usleep(10_000)
    }
    return read()
}

private final class FeedPeak: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Float = 0
    var peak: Float { lock.withLock { value } }
    func note(_ buffer: AVAudioPCMBuffer) {
        let measured = AudioLevel.measure(buffer).peak
        lock.withLock { value = max(value, measured) }
    }
}

@Test func virtualBusFeedsAndMetersWithHardwareSilent() throws {
    let engine = AudioEngine()
    try engine.enableManualRenderingForTests()
    engine.setMetering(true)
    let feed = FeedPeak()
    engine.setFeedConsumer { feed.note($0) }
    engine.masterVolume = 0.8
    engine.hardwareOutputEnabled = false 
    try engine.play(url: tone(name: "virtual"))
    let rendered = try engine.renderOfflineForTests(frames: 24_000)
    let sourcePeak = settled({ engine.sourceMeterLevel.peak }, above: 0.01)

    #expect(AudioLevel.measure(rendered).peak < 0.001, "no hardware leg, no device audio")
    #expect(feed.peak > 0.3, "the stream feed still hears the bus at console gain")
    #expect(feed.peak < 0.45, "feed carries gain 0.8 over the 0.5 tone, not raw")
    #expect(sourcePeak > 0.4, "source meter reads raw program")
    #expect(engine.meterLevel.peak > 0.3, "post meter reads console-scaled program")
}

@Test func mutedBusStillMetersSource() throws {
    let engine = AudioEngine()
    try engine.enableManualRenderingForTests()
    engine.setMetering(true)
    let feed = FeedPeak()
    engine.setFeedConsumer { feed.note($0) }
    engine.isMuted = true
    try engine.play(url: tone(name: "muted"))
    let rendered = try engine.renderOfflineForTests(frames: 24_000)
    let sourcePeak = settled({ engine.sourceMeterLevel.peak }, above: 0.01)

    #expect(AudioLevel.measure(rendered).peak < 0.001, "muted bus is silent at the device")
    #expect(feed.peak < 0.001, "muted bus pushes silence to feeds")
    #expect(engine.meterLevel.peak < 0.001, "post meter follows the mute")
    #expect(sourcePeak > 0.4, "fader down ≠ meter dead: source still reads")
}

@Test func consoleGainScalesHardwareAndFeedAlike() throws {
    let engine = AudioEngine()
    try engine.enableManualRenderingForTests()
    engine.setMetering(true)
    let feed = FeedPeak()
    engine.setFeedConsumer { feed.note($0) }
    engine.masterVolume = 0.5
    try engine.play(url: tone(name: "physical"))
    let rendered = try engine.renderOfflineForTests(frames: 24_000)
    let feedPeak = settled({ feed.peak }, above: 0.01)

    let hardware = AudioLevel.measure(rendered).peak
    #expect(abs(hardware - 0.25) < 0.05, "device hears gain 0.5 over the 0.5 tone (\(hardware))")
    #expect(abs(feedPeak - 0.25) < 0.05, "feed hears the same console gain (\(feedPeak))")
}
