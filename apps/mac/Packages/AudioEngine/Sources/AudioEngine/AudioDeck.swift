import AVFoundation

final class AudioDeck: @unchecked Sendable {

    static let graphFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!

    let player = AVAudioPlayerNode()
    private(set) var url: URL?

    private(set) var duration: TimeInterval = 0

    private(set) var trimStart: TimeInterval = 0
    private(set) var trimUntil: TimeInterval?

    private(set) var generation = 0

    private var scheduleStart: TimeInterval = 0

    private var heldElapsed: TimeInterval = 0

    private let fillQueue = DispatchQueue(label: "com.example.mxuslides.audio.deck.fill", qos: .userInitiated)
    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    private var chunksInFlight = 0
    private var scheduledToEnd = false
    private var onPlayedToEnd: (@Sendable (Int) -> Void)?

    private var endFrame: AVAudioFramePosition = 0

    private static let chunkFrames: AVAudioFrameCount = 32_768
    private static let chunksAhead = 4

    func load(
        url: URL, from startTime: TimeInterval,
        windowStart: TimeInterval = 0, until endTime: TimeInterval? = nil,
        onPlayedToEnd: @escaping @Sendable (Int) -> Void
    ) throws {

        fillQueue.sync {
            generation += 1
            self.file = nil
            self.converter = nil
            self.chunksInFlight = 0
            self.scheduledToEnd = true
            self.onPlayedToEnd = nil
        }
        player.stop()
        let file = try AVAudioFile(forReading: url)
        let fileRate = file.processingFormat.sampleRate
        let total = Double(file.length) / fileRate
        let startFrame = AVAudioFramePosition(
            (startTime.clamped(to: 0 ... max(0, total)) * fileRate).rounded(.down)
        )

        let cappedEnd: AVAudioFramePosition = endTime.map {
            min(file.length, AVAudioFramePosition(($0.clamped(to: 0 ... total) * fileRate).rounded(.up)))
        } ?? file.length
        guard cappedEnd - startFrame > 0 else { throw AudioEngineError.emptySchedule(url) }
        self.url = url
        duration = Double(cappedEnd) / fileRate
        trimStart = min(windowStart.clamped(to: 0 ... max(0, total)), duration)
        trimUntil = endTime == nil ? nil : duration
        scheduleStart = Double(startFrame) / fileRate
        heldElapsed = scheduleStart
        try fillQueue.sync {
            generation += 1
            self.file = file
            self.endFrame = cappedEnd
            file.framePosition = startFrame
            if file.processingFormat == Self.graphFormat {
                converter = nil
            } else {
                guard let converter = AVAudioConverter(from: file.processingFormat, to: Self.graphFormat) else {
                    throw AudioEngineError.emptySchedule(url)
                }
                self.converter = converter
            }
            chunksInFlight = 0
            scheduledToEnd = false
            self.onPlayedToEnd = onPlayedToEnd
            fill(generation: generation)
        }
    }

    var elapsed: TimeInterval {
        guard player.isPlaying,
              let nodeTime = player.lastRenderTime,
              let playerTime = player.playerTime(forNodeTime: nodeTime),
              playerTime.sampleRate > 0
        else { return heldElapsed }

        let live = max(
            scheduleStart,
            scheduleStart + Double(playerTime.sampleTime) / playerTime.sampleRate
        )
        heldElapsed = live
        return live
    }

    func pause() {
        heldElapsed = elapsed
        player.pause()
    }

    func clear() {
        fillQueue.sync {
            generation += 1
            file = nil
            converter = nil
            chunksInFlight = 0
            scheduledToEnd = false
            onPlayedToEnd = nil
        }
        heldElapsed = 0
        scheduleStart = 0
        duration = 0
        trimStart = 0
        trimUntil = nil
        url = nil
        player.stop()
        player.volume = 1
    }

    private func fill(generation gen: Int) {
        guard gen == generation, !scheduledToEnd, file != nil else { return }
        while chunksInFlight < Self.chunksAhead, !scheduledToEnd {
            guard let (buffer, isLast) = readChunk() else {

                scheduledToEnd = true
                break
            }
            if isLast { scheduledToEnd = true }
            chunksInFlight += 1
            player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                guard let self else { return }

                RealtimeAudioCallback.scope {
                    self.fillQueue.async {
                        guard gen == self.generation else { return }
                        self.chunksInFlight -= 1
                        if self.scheduledToEnd, self.chunksInFlight == 0 {
                            self.onPlayedToEnd?(gen)
                        } else {
                            self.fill(generation: gen)
                        }
                    }
                }
            }
        }
    }

    private func readChunk() -> (buffer: AVAudioPCMBuffer, isLast: Bool)? {
        guard let file else { return nil }
        let remaining = AVAudioFrameCount(max(0, endFrame - file.framePosition))
        guard remaining > 0 else { return nil }
        let srcFrames = min(Self.chunkFrames, remaining)
        guard let src = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: srcFrames)
        else { return nil }
        do {
            try file.read(into: src, frameCount: srcFrames)
        } catch {
            return nil
        }
        guard src.frameLength > 0 else { return nil }
        let isLast = file.framePosition >= endFrame
        guard let converter else { return (src, isLast) }
        let ratio = Self.graphFormat.sampleRate / file.processingFormat.sampleRate
        let capacity = AVAudioFrameCount((Double(src.frameLength) * ratio).rounded(.up)) + 64
        guard let dst = AVAudioPCMBuffer(pcmFormat: Self.graphFormat, frameCapacity: capacity)
        else { return nil }
        var fed = false
        var conversionError: NSError?
        let status = converter.convert(to: dst, error: &conversionError) { _, outStatus in
            if fed {
                outStatus.pointee = .noDataNow
                return nil
            }
            fed = true
            outStatus.pointee = .haveData
            return src
        }
        guard status != .error, dst.frameLength > 0 else { return nil }
        return (dst, isLast)
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

public enum AudioEngineError: Error {

    case emptySchedule(URL)

    case engineStartFailed(any Error)
}
