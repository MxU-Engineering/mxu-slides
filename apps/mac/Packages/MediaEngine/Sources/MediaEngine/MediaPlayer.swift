import AVFoundation
import CoreVideo
import RenderEngine

final class MediaPlayer: @unchecked Sendable {
    let media: PreparedMedia
    private let player: AVQueuePlayer
    private let factory: SurfaceFactory

    private let windowStart: Double
    private let windowEnd: Double
    private let playRate: Double

    private let needsInitialSeek: Locked<Bool>

    private struct Guarded {
        var looper: AVPlayerLooper?
        var outputs: [ObjectIdentifier: AVPlayerItemVideoOutput] = [:]
        var stats = PlaybackStats()
        var currentSurface: MediaSurface?

        var recentSurfaces: [MediaSurface] = []

        var lastVendedPTS: Double?
    }

    private let guarded: Locked<Guarded>

    let onFrameVended = Locked<(@Sendable (Double) -> Void)?>(nil)

    var stats: PlaybackStats {
        guarded.value.stats
    }

    var transport: MediaTransportState {
        let raw = player.currentTime().seconds
        let windowDuration = windowEnd - windowStart
        let position = raw.isFinite ? min(max(0, raw - windowStart), windowDuration) : 0
        return MediaTransportState(
            duration: windowDuration,
            position: position,
            isPlaying: player.rate != 0,
            isLooping: guarded.value.looper != nil,
            capturedAt: Date(),
            rate: playRate
        )
    }

    init(
        media: PreparedMedia, loop: Bool, factory: SurfaceFactory,
        audioDeviceUID: String? = nil,
        audioSink: Locked<VideoAudioTap.Sink?>? = nil,
        audioDelay: Locked<Double> = Locked(0),
        options: PlaybackOptions = PlaybackOptions()
    ) {
        self.media = media
        self.factory = factory
        let (start, end, rate) = options.resolved(
            duration: media.duration, frameDuration: media.frameDuration
        )
        windowStart = start
        windowEnd = end
        playRate = rate
        player = AVQueuePlayer()
        player.audioOutputDeviceUniqueID = audioDeviceUID
        player.actionAtItemEnd = loop ? .advance : .pause
        let item = AVPlayerItem(asset: media.asset)

        if let audioSink {
            VideoAudioTap.attach(to: item, sink: audioSink, delay: audioDelay)
        }
        var state = Guarded()
        if loop {

            state.looper = AVPlayerLooper(
                player: player, templateItem: item,
                timeRange: CMTimeRange(
                    start: CMTime(seconds: start, preferredTimescale: 60000),
                    end: CMTime(seconds: end, preferredTimescale: 60000)
                )
            )
            needsInitialSeek = Locked(false)
        } else {

            if end < media.duration - media.frameDuration / 2 {
                item.forwardPlaybackEndTime = CMTime(seconds: end, preferredTimescale: 60000)
            }
            player.insert(item, after: nil)
            needsInitialSeek = Locked(start > 0)
        }
        guarded = Locked(state)
        ensureOutputs()
    }

    func play() {
        ensureOutputs()
        if needsInitialSeek.withLock({ needed in
            defer { needed = false }
            return needed
        }) {

            seek(to: 0, precise: true) { [weak self] _ in
                self?.applyRate()
            }
        } else {
            applyRate()
        }
    }

    private func applyRate() {
        player.rate = Float(playRate)
    }

    func preroll() async -> Bool {
        ensureOutputs()

        let deadline = Date(timeIntervalSinceNow: 10)
        while player.currentItem?.status != .readyToPlay {
            if Date() > deadline || player.currentItem?.status == .failed { return false }
            try? await Task.sleep(for: .milliseconds(20))
        }

        if needsInitialSeek.withLock({ needed in
            defer { needed = false }
            return needed
        }) {
            await withCheckedContinuation { continuation in
                seek(to: 0, precise: true) { _ in continuation.resume() }
            }
        }
        return await player.preroll(atRate: Float(playRate))
    }

    func setAudioOutputDevice(uid: String?) {
        player.audioOutputDeviceUniqueID = uid
    }

    func setAudioVolume(_ volume: Float) {
        player.volume = volume
    }

    func pause() {
        player.pause()
    }

    func resume() {
        ensureOutputs()
        applyRate()
    }

    func seek(to seconds: Double, precise: Bool, completion: (@Sendable (Bool) -> Void)? = nil) {
        let upperBound = max(windowStart, windowEnd - media.frameDuration)
        let target = min(max(windowStart, windowStart + seconds), upperBound)
        guarded.withLock { state in
            state.lastVendedPTS = nil
            state.stats.noteSeek()
        }
        let tolerance = precise ? CMTime.zero : CMTime(seconds: 0.25, preferredTimescale: 600)
        player.seek(
            to: CMTime(seconds: target, preferredTimescale: 60000),
            toleranceBefore: tolerance,
            toleranceAfter: tolerance
        ) { [guarded] finished in
            guarded.withLock { state in
                state.lastVendedPTS = nil
                state.stats.noteSeek()
            }
            completion?(finished)
        }
    }

    func stop() {
        player.pause()
        guarded.withLock { state in
            state.looper?.disableLooping()
            state.looper = nil
            state.outputs.removeAll()
            state.currentSurface = nil
            state.recentSurfaces.removeAll()
        }
        player.removeAllItems()
    }

    func surface(at hostTime: CFTimeInterval) -> MediaSurface? {

        ensureOutputs()
        guard let item = player.currentItem else {
            return guarded.value.currentSurface
        }
        return guarded.withLock { state in
            guard let output = state.outputs[ObjectIdentifier(item)] else {
                return state.currentSurface
            }
            let itemTime = output.itemTime(forHostTime: hostTime)
            guard itemTime.isValid else { return state.currentSurface }

            let requestTime = player.rate == 0
                ? itemTime
                : pullTime(itemTime: itemTime, state: state)

            var displayTime = CMTime.invalid
            if output.hasNewPixelBuffer(forItemTime: requestTime),
               let pixelBuffer = output.copyPixelBuffer(forItemTime: requestTime, itemTimeForDisplay: &displayTime),
               let surface = factory.makeSurface(from: pixelBuffer) {

                let frameTime = displayTime.isNumeric ? displayTime.seconds : requestTime.seconds
                onFrameVended.value?(frameTime)
                state.stats.recordFrame(
                    at: frameTime,
                    frameDuration: media.frameDuration,
                    loopDuration: state.looper != nil ? windowEnd - windowStart : nil
                )
                state.lastVendedPTS = frameTime
                state.currentSurface = surface
                state.recentSurfaces.append(surface)
                if state.recentSurfaces.count > 3 {
                    state.recentSurfaces.removeFirst(state.recentSurfaces.count - 3)
                }
            }
            return state.currentSurface
        }
    }

    private func pullTime(itemTime: CMTime, state: Guarded) -> CMTime {
        let frameDuration = media.frameDuration
        guard let last = state.lastVendedPTS, frameDuration > 0 else { return itemTime }
        var expected = last + frameDuration

        if state.looper != nil, expected >= windowEnd - frameDuration / 2 {
            expected = windowStart
        }
        let now = itemTime.seconds

        if expected > now + frameDuration / 4 {
            return itemTime
        }

        if now > expected + 3 * frameDuration {
            return itemTime
        }
        return CMTime(seconds: expected + frameDuration / 4, preferredTimescale: 60000)
    }

    private func ensureOutputs() {
        guarded.withLock { state in
            if let looper = state.looper {
                for item in looper.loopingPlayerItems {
                    attachOutputIfNeeded(to: item, state: &state)
                }
            } else if let item = player.currentItem {
                attachOutputIfNeeded(to: item, state: &state)
            }
        }
    }

    private func attachOutputIfNeeded(to item: AVPlayerItem, state: inout Guarded) {
        guard state.outputs[ObjectIdentifier(item)] == nil else { return }
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: media.outputPixelBufferAttributes)
        item.add(output)
        state.outputs[ObjectIdentifier(item)] = output
    }
}
