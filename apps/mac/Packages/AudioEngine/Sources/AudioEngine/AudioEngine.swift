import AVFoundation
import CoreAudio

enum CrossfadeCurve {
    static func gains(at progress: Double) -> (incoming: Float, outgoing: Float) {
        let clamped = progress.clamped(to: 0 ... 1)
        let smooth = clamped * clamped * (3 - 2 * clamped)
        var outgoing = pow(10, -16.0 * clamped / 20)
        let releaseStart = 0.85
        if clamped > releaseStart {
            outgoing *= 1 - (clamped - releaseStart) / (1 - releaseStart)
        }
        return (Float(smooth), Float(outgoing))
    }
}

public final class AudioEngine: @unchecked Sendable {

    let engine = AVAudioEngine()
    private let decks = [AudioDeck(), AudioDeck()]

    private let delayUnit = AVAudioUnitDelay()

    private let hardwareLeg = AVAudioMixerNode()
    private var activeIndex = 0
    let lock = EngineStateLock()
    private let rampQueue = DispatchQueue(label: "com.example.mxuslides.audio.ramp", qos: .userInitiated)
    private var rampTimer: DispatchSourceTimer?

    private enum RampKind { case crossfade, transportFade }
    private var rampKind: RampKind?
    private var storedVolume: Float = 1
    private var muted = false
    private var hardwareEnabled = true

    private var transportPlaying = false
    private var configObserver: (any NSObjectProtocol)?

    public var onTrackPlayedToEnd: (@Sendable () -> Void)?

    public init() {

        for deck in decks {
            engine.attach(deck.player)
            engine.connect(deck.player, to: engine.mainMixerNode, format: AudioDeck.graphFormat)
        }
        engine.attach(delayUnit)
        delayUnit.delayTime = 0
        delayUnit.feedback = 0
        delayUnit.wetDryMix = 100

        delayUnit.lowPassCutoff = Float(AudioDeck.graphFormat.sampleRate / 2)
        engine.attach(hardwareLeg)
        engine.connect(engine.mainMixerNode, to: delayUnit, format: AudioDeck.graphFormat)
        engine.connect(delayUnit, to: hardwareLeg, format: AudioDeck.graphFormat)
        engine.connect(hardwareLeg, to: engine.outputNode, format: AudioDeck.graphFormat)
        engine.prepare()

        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in

            RealtimeAudioCallback.scope {
                DispatchQueue.global(qos: .utility).async { [weak self] in
                    guard let self else { return }
                    self.lock.withLock {

                        guard !self.engine.isRunning else { return }
                        self.cancelRamp(resolving: true)
                        self.rebuildPlayback()
                    }
                }
            }
        }
    }

    deinit {
        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
        }

        lock.withLock {
            cancelRamp()
            for each in decks { each.clear() }
            if meterTapInstalled {
                engine.mainMixerNode.removeTap(onBus: 0)
                meterTapInstalled = false
            }
            engine.stop()
        }
    }

    public func play(
        url: URL, crossfade: TimeInterval = 0, fadeIn: TimeInterval = 0,
        trimStart: TimeInterval = 0, trimEnd: TimeInterval? = nil
    ) throws {
        try lock.withLock {
            try ensureRunning()

            cancelRamp(resolving: true)
            let outgoing = decks[activeIndex]
            let crossfading = crossfade > 0 && outgoing.player.isPlaying
            let incoming = crossfading ? decks[1 - activeIndex] : outgoing
            try loadTracked(
                deck: incoming, url: url, from: trimStart,
                windowStart: trimStart, until: trimEnd
            )
            transportPlaying = true
            if crossfading {
                activeIndex = 1 - activeIndex
                incoming.player.volume = 0
                incoming.player.play()
                beginRamp(incoming: incoming, outgoing: outgoing, duration: crossfade)
            } else if fadeIn > 0 {
                incoming.player.volume = 0
                incoming.player.play()
                beginFade(deck: incoming, to: 1, duration: fadeIn)
            } else {
                incoming.player.volume = 1
                incoming.player.play()
            }
        }
    }

    public func pause(fade: TimeInterval = 0) {
        lock.withLock {

            cancelRamp(resolving: true)
            transportPlaying = false
            let deck = decks[activeIndex]
            guard fade > 0, deck.player.isPlaying else {
                deck.pause()
                return
            }
            beginFade(deck: deck, to: 0, duration: fade) { deck.pause() }
        }
    }

    public func resume(fade: TimeInterval = 0) {
        lock.withLock {
            cancelRamp(resolving: true)
            let deck = decks[activeIndex]
            guard deck.url != nil, (try? ensureRunning()) != nil else { return }
            transportPlaying = true
            deck.player.play()
            if fade > 0 {
                beginFade(deck: deck, to: 1, duration: fade)
            } else {
                deck.player.volume = 1
            }
        }
    }

    public func stop(fade: TimeInterval = 0) {
        lock.withLock {
            transportPlaying = false
            let deck = decks[activeIndex]
            guard fade > 0, deck.player.isPlaying else {
                cancelRamp()
                for each in decks { each.clear() }
                return
            }
            cancelRamp(resolving: true)
            decks[1 - activeIndex].clear()
            beginFade(deck: deck, to: 0, duration: fade) { deck.clear() }
        }
    }

    public var isPlaying: Bool {
        lock.withLock { decks[activeIndex].player.isPlaying }
    }

    public func seek(to seconds: TimeInterval) {
        lock.withLock {
            let deck = decks[activeIndex]
            guard let url = deck.url, deck.duration > 0 else { return }
            cancelRamp(resolving: true)

            let floor = deck.trimStart
            let target = seconds.clamped(to: floor ... max(floor, deck.duration - 0.05))
            let resume = transportPlaying
            guard (try? ensureRunning()) != nil,
                  (try? loadTracked(
                      deck: deck, url: url, from: target,
                      windowStart: floor, until: deck.trimUntil
                  )) != nil
            else { return }
            deck.player.volume = 1
            if resume { deck.player.play() }
        }
    }

    public var position: (elapsed: TimeInterval, duration: TimeInterval)? {
        lock.withLock {
            let deck = decks[activeIndex]
            guard deck.url != nil, deck.duration > 0 else { return nil }
            return (min(deck.elapsed, deck.duration), deck.duration)
        }
    }

    public var masterVolume: Float {
        get { lock.withLock { storedVolume } }
        set {
            lock.withLock {
                storedVolume = newValue.clamped(to: 0 ... 1)
                applyConsoleLocked()
            }
        }
    }

    public var isMuted: Bool {
        get { lock.withLock { muted } }
        set {
            lock.withLock {
                muted = newValue
                applyConsoleLocked()
            }
        }
    }

    public var hardwareOutputEnabled: Bool {
        get { lock.withLock { hardwareEnabled } }
        set {
            lock.withLock {
                hardwareEnabled = newValue
                applyConsoleLocked()
            }
        }
    }

    private func applyConsoleLocked() {
        let effective = muted ? 0 : storedVolume
        hardwareLeg.outputVolume = hardwareEnabled ? effective : 0
        tapState.set(gain: effective)
    }

    public var outputDelayMilliseconds: Double {
        get { lock.withLock { delayUnit.delayTime * 1000 } }
        set {
            lock.withLock {
                delayUnit.delayTime = max(0, min(newValue, 2000)) / 1000
            }
        }
    }

    private var meterTapInstalled = false

    private final class TapState: @unchecked Sendable {
        private let lock = NSLock()
        private var meterWanted = false
        private var gain: Float = 1
        private var feed: (@Sendable (AVAudioPCMBuffer) -> Void)?
        private var post: (rms: Float, peak: Float) = (0, 0)
        private var source: (rms: Float, peak: Float) = (0, 0)

        private var postWindow = LevelWindow()
        private var sourceWindow = LevelWindow()

        func set(meterWanted wanted: Bool) { lock.withLock { meterWanted = wanted } }
        func set(gain value: Float) { lock.withLock { gain = value } }
        func set(feed consumer: (@Sendable (AVAudioPCMBuffer) -> Void)?) {
            lock.withLock { feed = consumer }
        }

        var wantsTap: Bool { lock.withLock { meterWanted || feed != nil } }
        var postLevel: (rms: Float, peak: Float) { lock.withLock { post } }
        var sourceLevel: (rms: Float, peak: Float) { lock.withLock { source } }

        func snapshot() -> (
            meterWanted: Bool, gain: Float,
            feed: (@Sendable (AVAudioPCMBuffer) -> Void)?
        ) {
            lock.withLock { (meterWanted, gain, feed) }
        }

        func store(source raw: (rms: Float, peak: Float), gain: Float) {
            lock.withLock {
                source = raw
                post = (min(raw.rms * gain, 1), min(raw.peak * gain, 1))
                sourceWindow.fold(source)
                postWindow.fold(post)
            }
        }

        func takeLevels() -> (
            post: (rms: Float, peak: Float), source: (rms: Float, peak: Float)
        ) {

            lock.withLock { (post: postWindow.take(), source: sourceWindow.take()) }
        }

        func resetLevels() {
            lock.withLock {
                post = (0, 0)
                source = (0, 0)
                _ = postWindow.take()
                _ = sourceWindow.take()
            }
        }
    }

    private let tapState = TapState()

    public func setMetering(_ enabled: Bool) {
        lock.withLock {
            tapState.set(meterWanted: enabled)
            reconcileTapLocked()
        }
    }

    public func setFeedConsumer(_ consumer: (@Sendable (AVAudioPCMBuffer) -> Void)?) {
        lock.withLock {
            tapState.set(feed: consumer)
            reconcileTapLocked()
        }
    }

    private func reconcileTapLocked() {
        let wanted = tapState.wantsTap
        guard wanted != meterTapInstalled else { return }
        meterTapInstalled = wanted
        if wanted {

            let state = tapState
            engine.mainMixerNode.installTap(
                onBus: 0, bufferSize: 1024, format: nil
            ) { buffer, _ in
                RealtimeAudioCallback.scope {
                    let tick = state.snapshot()
                    if tick.meterWanted {

                        state.store(source: AudioLevel.measure(buffer), gain: tick.gain)
                    }
                    guard let feed = tick.feed else { return }

                    Self.scale(buffer, by: tick.gain)
                    feed(buffer)
                }
            }
        } else {
            engine.mainMixerNode.removeTap(onBus: 0)
            tapState.resetLevels()
        }
    }

    private static func scale(_ buffer: AVAudioPCMBuffer, by gain: Float) {
        guard gain != 1, let data = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        for channel in 0 ..< Int(buffer.format.channelCount) {
            let samples = data[channel]
            for frame in 0 ..< frames { samples[frame] *= gain }
        }
    }

    public var meterLevel: (rms: Float, peak: Float) { tapState.postLevel }

    public var sourceMeterLevel: (rms: Float, peak: Float) { tapState.sourceLevel }

    public func takeMeterLevels() -> (
        post: (rms: Float, peak: Float), source: (rms: Float, peak: Float)
    ) {
        tapState.takeLevels()
    }

    public func setOutputDevice(
        _ device: AudioOutputDevice?, channelOffset: Int = 0
    ) throws {
        try lock.withLock {
            cancelRamp(resolving: true)

            for each in decks { each.pause() }
            engine.stop()
            let target = device ?? AudioDeviceList.defaultOutputDevice()
            if let id = target?.id {
                try engine.outputNode.auAudioUnit.setDeviceID(id)
            }
            desiredChannelOffset = channelOffset
            deviceChannelCount = target?.channelCount ?? 2
            applyChannelMap()
            rebuildPlayback()
        }
    }

    private var desiredChannelOffset = 0
    private var deviceChannelCount = 2

    private func applyChannelMap() {
        guard let unit = engine.outputNode.audioUnit else { return }
        let channels = max(2, deviceChannelCount)
        let offset = (desiredChannelOffset + 1 < channels && desiredChannelOffset >= 0)
            ? desiredChannelOffset : 0
        var map = [Int32](repeating: -1, count: channels)
        map[offset] = 0
        map[offset + 1] = 1
        let size = UInt32(MemoryLayout<Int32>.size * channels)
        let status = AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_ChannelMap,
            kAudioUnitScope_Output, 0, &map, size
        )
        if status != noErr {
            AudioUnitSetProperty(
                unit, kAudioOutputUnitProperty_ChannelMap,
                kAudioUnitScope_Global, 0, &map, size
            )
        }
    }

    private func rebuildPlayback() {
        applyChannelMap()
        let deck = decks[activeIndex]
        guard let url = deck.url else { return }
        let position = deck.elapsed
        let resume = transportPlaying
        for each in decks where each !== deck { each.clear() }
        guard (try? ensureRunning()) != nil,
              (try? loadTracked(deck: deck, url: url, from: position)) != nil
        else { return }
        deck.player.volume = 1
        if resume { deck.player.play() }
    }

    func enableManualRenderingForTests() throws {
        lock.withLock {
            engine.stop()
            try? engine.enableManualRenderingMode(
                .offline, format: AudioDeck.graphFormat, maximumFrameCount: 4096
            )
        }
    }

    func renderOfflineForTests(frames: AVAudioFrameCount) throws -> AVAudioPCMBuffer {
        guard let output = AVAudioPCMBuffer(
            pcmFormat: engine.manualRenderingFormat, frameCapacity: frames
        ) else { throw AudioEngineError.emptySchedule(URL(fileURLWithPath: "/render")) }
        let chunk = AVAudioPCMBuffer(
            pcmFormat: engine.manualRenderingFormat, frameCapacity: 4096
        )!
        while output.frameLength < frames {
            let want = min(4096, frames - output.frameLength)
            let status = try engine.renderOffline(want, to: chunk)
            guard status == .success else { break }
            for channel in 0 ..< Int(output.format.channelCount) {
                guard let src = chunk.floatChannelData?[channel],
                      let dst = output.floatChannelData?[channel] else { continue }
                dst.advanced(by: Int(output.frameLength))
                    .update(from: src, count: Int(chunk.frameLength))
            }
            output.frameLength += chunk.frameLength
        }
        return output
    }

    private func ensureRunning() throws {
        guard !engine.isRunning else { return }
        do { try engine.start() } catch { throw AudioEngineError.engineStartFailed(error) }
    }

    private func loadTracked(
        deck: AudioDeck, url: URL, from start: TimeInterval,
        windowStart: TimeInterval = 0, until end: TimeInterval? = nil
    ) throws {
        try deck.load(url: url, from: start, windowStart: windowStart, until: end) {
            [weak self, weak deck] generation in

            DispatchQueue.global(qos: .userInitiated).async {
                guard let self, let deck else { return }
                let isCurrent = self.lock.withLock {
                    let current = deck.generation == generation
                        && self.decks[self.activeIndex] === deck

                    if current { self.transportPlaying = false }
                    return current
                }
                if isCurrent { self.onTrackPlayedToEnd?() }
            }
        }
    }

    private func beginRamp(incoming: AudioDeck, outgoing: AudioDeck, duration: TimeInterval) {
        let start = DispatchTime.now()
        let timer = DispatchSource.makeTimerSource(queue: rampQueue)
        timer.schedule(deadline: .now(), repeating: 1.0 / 60.0)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.lock.withLock {

                guard self.rampTimer === timer else { return }
                let seconds = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e9
                let progress = min(1, seconds / max(duration, 0.01))
                let gains = CrossfadeCurve.gains(at: progress)
                incoming.player.volume = gains.incoming
                outgoing.player.volume = gains.outgoing
                if progress >= 1 {
                    outgoing.clear()
                    self.rampTimer = nil
                    self.rampKind = nil
                    timer.cancel()
                }
            }
        }
        rampTimer = timer
        rampKind = .crossfade
        timer.resume()
    }

    private func beginFade(
        deck: AudioDeck, to target: Float, duration: TimeInterval,
        onDone: (@Sendable () -> Void)? = nil
    ) {
        let start = DispatchTime.now()
        let from = deck.player.volume
        let timer = DispatchSource.makeTimerSource(queue: rampQueue)
        timer.schedule(deadline: .now(), repeating: 1.0 / 60.0)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.lock.withLock {
                guard self.rampTimer === timer else { return }
                let seconds = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e9
                let progress = min(1, seconds / max(duration, 0.01))
                deck.player.volume = from + (target - from) * Float(progress)
                if progress >= 1 {
                    self.rampTimer = nil
                    self.rampKind = nil
                    timer.cancel()
                    onDone?()
                }
            }
        }
        rampTimer = timer
        rampKind = .transportFade
        timer.resume()
    }

    private func cancelRamp(resolving: Bool = false) {
        guard let timer = rampTimer else { return }
        timer.cancel()
        let kind = rampKind
        rampTimer = nil
        rampKind = nil
        if resolving, kind == .crossfade {
            decks[activeIndex].player.volume = 1
            decks[1 - activeIndex].clear()
        }
    }
}
