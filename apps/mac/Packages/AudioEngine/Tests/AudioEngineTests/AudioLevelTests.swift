import AVFoundation
import Testing

@testable import AudioEngine

private func buffer(filledWith value: Float, frames: AVAudioFrameCount = 480) -> AVAudioPCMBuffer {
    let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    buffer.frameLength = frames
    for channel in 0 ..< 2 {
        for frame in 0 ..< Int(frames) {
            buffer.floatChannelData![channel][frame] = value
        }
    }
    return buffer
}

@Test func levelMeasuresRMSAndPeak() {

    let level = AudioLevel.measure(buffer(filledWith: 0.5))
    #expect(abs(level.rms - 0.5) < 0.001)
    #expect(abs(level.peak - 0.5) < 0.001)

    let silence = AudioLevel.measure(buffer(filledWith: 0))
    #expect(silence.rms == 0)
    #expect(silence.peak == 0)
}

@Test func levelClampsOverloadedSamples() {

    let level = AudioLevel.measure(buffer(filledWith: 1.8))
    #expect(level.rms == 1)
    #expect(level.peak == 1)
}

@Test func outputLevelsFoldEveryMixLandingOnTheOutput() {

    let levels = AudioLevel.outputLevels([
        (level: (rms: 0.4, peak: 0.8),
         sends: [(outputId: "lr", gain: 1), (outputId: "stream", gain: 0.5)]),
        (level: (rms: 0.3, peak: 0.3), sends: [(outputId: "stream", gain: 1)]),
        (level: (rms: 0.9, peak: 0.9), sends: []),  
    ])
    #expect(abs(levels["lr"]!.rms - 0.4) < 0.001)
    #expect(abs(levels["lr"]!.peak - 0.8) < 0.001)
    #expect(abs(levels["stream"]!.rms - (0.2 * 0.2 + 0.3 * 0.3).squareRoot()) < 0.001)
    #expect(abs(levels["stream"]!.peak - 0.4) < 0.001)
    #expect(levels.count == 2)
}

@Test func combinedLevelsSumPowerAndKeepLoudestPeak() {

    let sum = AudioLevel.combine((rms: 0.3, peak: 0.5), adding: (rms: 0.4, peak: 0.4))
    #expect(abs(sum.rms - 0.5) < 0.001)
    #expect(sum.peak == 0.5)

    let gained = AudioLevel.combine((0, 0), adding: (rms: 0.5, peak: 0.8), gain: 0.5)
    #expect(abs(gained.rms - 0.25) < 0.001)
    #expect(abs(gained.peak - 0.4) < 0.001)

    let hot = AudioLevel.combine((rms: 0.9, peak: 0.9), adding: (rms: 0.9, peak: 0.9))
    #expect(hot.rms == 1)
    #expect(hot.peak == 0.9)
}

@Test func meterBallisticsAttackInstantlyDecayTimed() {
    var meter = MeterBallistics(decayDecibelsPerSecond: 20)
    meter.update(rms: 0.8, peak: 0.9, elapsed: 0)
    #expect(meter.rms == 0.8)
    #expect(meter.peak == 0.9)

    meter.update(rms: 0, peak: 0, elapsed: 0.1)
    #expect(abs(meter.rms - 0.8 * 0.7943) < 0.001)
    #expect(abs(meter.peak - 0.9 * 0.7943) < 0.001)

    meter.update(rms: 0.95, peak: 1.0, elapsed: 0.1)
    #expect(meter.rms == 0.95)
    #expect(meter.peak == 1.0)
}

@Test func aDrainedMeterSettlesAtZeroAndStopsChanging() {

    var meter = MeterBallistics()
    meter.update(rms: 0.5, peak: 1, elapsed: 0)
    var ticks = 0
    while meter.peak > 0, ticks < 1000 {
        meter.update(rms: 0, peak: 0, elapsed: 1.0 / 15)
        ticks += 1
    }
    #expect(meter.peak == 0 && meter.rms == 0)

    #expect(ticks <= 61)
    let settled = meter
    meter.update(rms: 0, peak: 0, elapsed: 1.0 / 15)
    #expect(meter == settled)

    meter.update(rms: 0.001, peak: 0.001, elapsed: 0)
    #expect(meter.peak == 0.001)
}

@Test func peakHoldOnlyClimbsUntilReset() {

    var hold = PeakHold()
    #expect(hold.decibels == -.infinity)
    hold.update(0.5)
    #expect(abs(hold.decibels - -6.02) < 0.01)
    hold.update(0.1)
    #expect(abs(hold.decibels - -6.02) < 0.01)
    hold.update(0.8)
    #expect(abs(hold.decibels - -1.94) < 0.01)
    hold.update(0)
    #expect(abs(hold.decibels - -1.94) < 0.01)
    hold.reset()
    #expect(hold.decibels == -.infinity)
}

@Test func peakHoldTickModePinsThenFollows() {

    var tick = PeakHold(holdSeconds: 2)
    tick.update(0.8, at: 0)
    #expect(abs(tick.decibels - -1.94) < 0.01)

    tick.update(0.1, at: 1)
    #expect(abs(tick.decibels - -1.94) < 0.01)

    tick.update(0.1, at: 3)
    #expect(abs(tick.decibels - -20) < 0.01)

    tick.update(0.5, at: 3.5)
    #expect(abs(tick.decibels - -6.02) < 0.01)
}

@Test func faderTaperSpendsTravelWhereMixingHappens() {

    #expect(AudioLevel.faderGain(fraction: 1) == 1)
    #expect(AudioLevel.faderGain(fraction: 0) == 0)
    #expect(abs(AudioLevel.decibels(AudioLevel.faderGain(fraction: 0.7)) - -15) < 0.01)
    #expect(abs(AudioLevel.decibels(AudioLevel.faderGain(fraction: 0.4)) - -30) < 0.01)
    #expect(abs(AudioLevel.decibels(AudioLevel.faderGain(fraction: 0.225)) - -45) < 0.01)
    #expect(abs(AudioLevel.decibels(AudioLevel.faderGain(fraction: 0.05)) - -60) < 0.01)
    #expect(abs(AudioLevel.decibels(AudioLevel.faderGain(fraction: 0.025)) - -75) < 0.01)
    #expect(AudioLevel.faderFraction(gain: 1) == 1)
    #expect(AudioLevel.faderFraction(gain: 0) == 0)
    for fraction in [Float(0.225), 0.05, 0.025] {
        let roundTrip = AudioLevel.faderFraction(gain: AudioLevel.faderGain(fraction: fraction))
        #expect(abs(roundTrip - fraction) < 0.001)
    }

    #expect(AudioLevel.faderFraction(gain: 0.00001) == 0)
}

@Test func faderGainParsesTypedDecibelEntries() {

    #expect(abs(AudioLevel.decibels(AudioLevel.faderGain(entry: "-18")!) - -18) < 0.01)
    #expect(abs(AudioLevel.decibels(AudioLevel.faderGain(entry: "18")!) - -18) < 0.01)
    #expect(abs(AudioLevel.decibels(AudioLevel.faderGain(entry: " -6.5 ")!) - -6.5) < 0.01)
    #expect(AudioLevel.faderGain(entry: "0") == 1)

    #expect(abs(AudioLevel.decibels(AudioLevel.faderGain(entry: "-80")!) - -80) < 0.01)
    #expect(AudioLevel.faderGain(entry: "-95") == 0)
    #expect(AudioLevel.faderGain(entry: "loud") == nil)
    #expect(AudioLevel.faderGain(entry: "") == nil)
}

@Test func levelWindowFoldsEveryBufferAndResetsOnTake() {

    var window = LevelWindow()
    window.fold((rms: 0.3, peak: 0.5))
    window.fold((rms: 0.2, peak: 0.9))
    window.fold((rms: 0.4, peak: 0.1))
    let taken = window.take()
    #expect(taken.rms == 0.4)
    #expect(taken.peak == 0.9)
    let empty = window.take()
    #expect(empty.rms == 0)
    #expect(empty.peak == 0)
}

@Test func meterFractionMapsTheDecibelFace() {

    #expect(AudioLevel.meterFraction(0) == 0)
    #expect(AudioLevel.meterFraction(1) == 1)

    #expect(abs(AudioLevel.meterFraction(0.5) - 0.8445) < 0.001)

    #expect(abs(AudioLevel.meterFraction(0.1) - 0.4833) < 0.001)

    #expect(abs(AudioLevel.meterFraction(0.001) - 0.06) < 0.001)
    #expect(abs(AudioLevel.meterFraction(0.0001) - 0.02) < 0.001)
    #expect(AudioLevel.meterFraction(0.00001) == 0)
    #expect(AudioLevel.meterFraction(1.8) == 1)

    #expect(AudioLevel.meterFraction(decibels: -24) == 0.38)
    #expect(abs(AudioLevel.meterFraction(decibels: -20) - 0.4833) < 0.001)
    #expect(abs(AudioLevel.meterFraction(decibels: -40) - 0.2378) < 0.001)
    #expect(abs(AudioLevel.meterFraction(decibels: -55) - 0.1044) < 0.001)
    #expect(abs(AudioLevel.meterFraction(decibels: -75) - 0.03) < 0.001)
    #expect(AudioLevel.meterFraction(decibels: -.infinity) == 0)
    #expect(AudioLevel.meterFraction(decibels: 2) == 1)
}

@Test func playthroughDropsBuffersWhileStopped() {

    let playthrough = AudioInputPlaythrough()
    #expect(playthrough.push(buffer(filledWith: 0.1)) == false)
    #expect(playthrough.isRunning == false)
}

@Test func playthroughIsBornMutedUntilRouted() {

    let playthrough = AudioInputPlaythrough()
    #expect(playthrough.isMuted == true)
    #expect(playthrough.gain == 1)
    if (try? playthrough.start()) != nil {  
        #expect(playthrough.engine.mainMixerNode.outputVolume == 0)
        playthrough.isMuted = false
        #expect(playthrough.engine.mainMixerNode.outputVolume == 1)
        playthrough.stop()
    }
}

@Test func playthroughConfigChangeDoesNotBlockPostingThread() {

    let playthrough = AudioInputPlaythrough()
    playthrough.lock.lock()
    let posted = Locked(false)
    Thread.detachNewThread {
        NotificationCenter.default.post(
            name: .AVAudioEngineConfigurationChange, object: playthrough.engine
        )
        posted.withLock { $0 = true }
    }

    var waited = 0
    while !posted.withLock({ $0 }), waited < 100 {
        Thread.sleep(forTimeInterval: 0.02)
        waited += 1
    }
    #expect(posted.withLock { $0 }, "config-change post must not wait on the playthrough lock")
    playthrough.lock.unlock()
}

@Test func playthroughPushNeverBlocksOnTheLock() {

    let playthrough = AudioInputPlaythrough()
    playthrough.lock.lock()
    let returned = Locked(false)
    Thread.detachNewThread {
        _ = playthrough.push(buffer(filledWith: 0.1))
        returned.withLock { $0 = true }
    }

    var waited = 0
    while !returned.withLock({ $0 }), waited < 100 {
        Thread.sleep(forTimeInterval: 0.02)
        waited += 1
    }
    #expect(returned.withLock { $0 }, "push must not wait on the playthrough lock")
    playthrough.lock.unlock()
}

@Test func playbackBusConfigChangeDoesNotBlockPostingThread() {

    let bus = AudioEngine()
    bus.lock.lock()
    let posted = Locked(false)
    Thread.detachNewThread {
        NotificationCenter.default.post(
            name: .AVAudioEngineConfigurationChange, object: bus.engine
        )
        posted.withLock { $0 = true }
    }
    var waited = 0
    while !posted.withLock({ $0 }), waited < 100 {
        Thread.sleep(forTimeInterval: 0.02)
        waited += 1
    }
    #expect(posted.withLock { $0 }, "config-change post must not wait on the bus lock")
    bus.lock.unlock()
}

@Test func engineStateLockSemantics() {

    let lock = EngineStateLock()
    #expect(lock.tryWithLock { true } == true)
    lock.lock()
    #expect(lock.tryWithLock { true } == nil)
    lock.unlock()
    #expect(RealtimeAudioCallback.isActive == false)
    RealtimeAudioCallback.scope {
        #expect(RealtimeAudioCallback.isActive)
        RealtimeAudioCallback.scope { #expect(RealtimeAudioCallback.isActive) }
        #expect(RealtimeAudioCallback.isActive)
    }
    #expect(RealtimeAudioCallback.isActive == false)
}

@Test func playthroughGainAndMuteClamp() {
    let playthrough = AudioInputPlaythrough()
    playthrough.gain = 1.7
    #expect(playthrough.gain == 1)
    playthrough.gain = -0.2
    #expect(playthrough.gain == 0)
    playthrough.isMuted = true
    #expect(playthrough.isMuted)
    playthrough.pan = 1.6
    #expect(playthrough.pan == 1)
    playthrough.pan = -2
    #expect(playthrough.pan == -1)
}

@Test func pannedCopyAppliesBalanceLawAndSparesTheOriginal() {

    let source = buffer(filledWith: 0.5)
    #expect(AudioInputPlaythrough.panned(source, pan: 0) == nil)

    let hardLeft = AudioInputPlaythrough.panned(source, pan: -1)!
    #expect(abs(hardLeft.floatChannelData![0][0] - 0.5) < 0.0001)
    #expect(hardLeft.floatChannelData![1][0] == 0)

    let halfRight = AudioInputPlaythrough.panned(source, pan: 0.5)!
    #expect(abs(halfRight.floatChannelData![0][0] - 0.25) < 0.0001)
    #expect(abs(halfRight.floatChannelData![1][0] - 0.5) < 0.0001)

    #expect(source.floatChannelData![0][0] == 0.5)
    #expect(source.floatChannelData![1][0] == 0.5)
}

@Test func mixFeedPanPlacesAMemberInTheImage() async throws {

    let emitted = Locked<[AVAudioPCMBuffer]>([])
    let feed = AudioMixFeed { buffer, _, _ in
        emitted.withLock { $0.append(buffer) }
    }
    feed.push(member: "a", buffer: buffer(filledWith: 0.5, frames: 4800), pan: -1)
    try await Task.sleep(for: .milliseconds(120))
    let buffers = emitted.withLock { $0 }
    #expect(!buffers.isEmpty)
    let leftPeak = buffers.compactMap { $0.floatChannelData.map { $0[0][0] } }.max() ?? 0
    let rightPeak = buffers.compactMap { $0.floatChannelData.map { $0[1][0] } }.max() ?? 0
    #expect(abs(leftPeak - 0.5) < 0.01, "left carries the member")
    #expect(rightPeak == 0, "right stays silent at hard left")
    feed.removeMember("a")
}

@Test func mixFeedSumsMembersOnItsOwnClock() async throws {

    let emitted = Locked<[AVAudioPCMBuffer]>([])
    let feed = AudioMixFeed { buffer, _, _ in
        emitted.withLock { $0.append(buffer) }
    }
    feed.push(member: "a", buffer: buffer(filledWith: 0.25, frames: 4800))
    feed.push(member: "b", buffer: buffer(filledWith: 0.5, frames: 4800), gain: 0.5)
    try await Task.sleep(for: .milliseconds(120))
    let buffers = emitted.withLock { $0 }
    #expect(!buffers.isEmpty, "the 10ms clock must have ticked")
    let peak = buffers.map { AudioLevel.measure($0).peak }.max() ?? 0
    #expect(abs(peak - 0.5) < 0.01, "0.25 + 0.5×0.5 sums to 0.5, got \(peak)")

    feed.removeMember("a")
    feed.removeMember("b")
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
