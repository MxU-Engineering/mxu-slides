import AVFoundation
import AudioEngine
import Foundation

final class ProgramAudioSummer: @unchecked Sendable {
    private let lock = NSLock()
    private var queueLeft: [Float] = []
    private var queueRight: [Float] = []
    private var converter: AVAudioConverter?
    private var converterInputFormat: AVAudioFormat?
    private let targetFormat: AVAudioFormat

    private let maxQueuedFrames = 24_000

    init(targetFormat: AVAudioFormat) {
        self.targetFormat = targetFormat
    }

    func pushProgram(_ buffer: AVAudioPCMBuffer) {
        guard let normalized = normalize(buffer),
              let channels = normalized.floatChannelData,
              normalized.frameLength > 0
        else { return }
        let frames = Int(normalized.frameLength)
        let channelCount = Int(normalized.format.channelCount)
        let left = Array(UnsafeBufferPointer(start: channels[0], count: frames))
        let right = channelCount > 1
            ? Array(UnsafeBufferPointer(start: channels[1], count: frames))
            : left
        lock.withLock {
            queueLeft.append(contentsOf: left)
            queueRight.append(contentsOf: right)
            if queueLeft.count > maxQueuedFrames {
                queueLeft.removeFirst(queueLeft.count - maxQueuedFrames)
                queueRight.removeFirst(queueRight.count - maxQueuedFrames)
            }
        }
    }

    func sum(into buffer: AVAudioPCMBuffer) {
        guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { return }
        let frames = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        let (left, right): ([Float], [Float]) = lock.withLock {
            let take = min(frames, queueLeft.count)
            guard take > 0 else { return ([], []) }
            let left = Array(queueLeft.prefix(take))
            let right = Array(queueRight.prefix(take))
            queueLeft.removeFirst(take)
            queueRight.removeFirst(take)
            return (left, right)
        }
        guard !left.isEmpty else { return }
        for frame in 0..<left.count {
            channels[0][frame] = max(-1, min(1, channels[0][frame] + left[frame]))
            if channelCount > 1 {
                channels[1][frame] = max(-1, min(1, channels[1][frame] + right[frame]))
            }
        }
    }

    private func normalize(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if buffer.format.isEqual(targetFormat) { return buffer }
        if converter == nil || converterInputFormat?.isEqual(buffer.format) != true {
            converter = AVAudioConverter(from: buffer.format, to: targetFormat)
            converterInputFormat = buffer.format
        }
        guard let converter else { return nil }
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let converted = AVAudioPCMBuffer(
            pcmFormat: targetFormat, frameCapacity: capacity)
        else { return nil }
        nonisolated(unsafe) var fed = false
        nonisolated(unsafe) let source = buffer
        var conversionError: NSError?
        converter.convert(to: converted, error: &conversionError) { _, outStatus in
            if fed {
                outStatus.pointee = .noDataNow
                return nil
            }
            fed = true
            outStatus.pointee = .haveData
            return source
        }
        guard conversionError == nil, converted.frameLength > 0 else { return nil }
        return converted
    }
}

final class SessionAudioFeed: @unchecked Sendable {
    typealias Consumer = ProgramAudioSource.Consumer

    private enum Backing {
        case program(token: UUID)
        case warmInput(source: AudioInputSource, token: UUID)
        case mixedWarm(source: AudioInputSource, inputToken: UUID, programToken: UUID)

        case mixFeed(mixId: String, token: UUID)
        case mixFeedWithProgram(mixId: String, token: UUID, programToken: UUID)
    }

    private let lock = NSLock()
    private var backing: Backing?

    @MainActor
    static func open(
        audioMixId: String? = nil,
        audioInputId: String? = nil,
        audioInputUid: String?,
        includeProgram: Bool = false,
        delayMilliseconds: Int = 0,
        consumer: @escaping Consumer
    ) -> SessionAudioFeed {
        let consumer = delayed(consumer, milliseconds: delayMilliseconds)
        if let mixId = audioMixId, !mixId.isEmpty {
            if let mixer = AudioMixerController.current,
               AudioMixInventory.shared.entry(id: mixId) != nil {

                let scaled: @Sendable (AVAudioPCMBuffer) -> AVAudioPCMBuffer? = { buffer in
                    let gain = AudioMixerController.streamGain(mixId: mixId)
                    if abs(gain - 1) < 0.001 { return buffer }
                    guard let copy = buffer.deepCopyForSum(),
                          let data = copy.floatChannelData else { return buffer }
                    for channel in 0 ..< Int(copy.format.channelCount) {
                        for frame in 0 ..< Int(copy.frameLength) {
                            data[channel][frame] *= gain
                        }
                    }
                    return copy
                }
                if includeProgram, let target = AVAudioFormat(
                    standardFormatWithSampleRate: 48_000, channels: 2) {
                    let summer = ProgramAudioSummer(targetFormat: target)
                    let token = mixer.addFeedConsumer(mixId: mixId) { buffer, when, hostSeconds in
                        guard let leveled = scaled(buffer) else { return }
                        summer.sum(into: leveled)
                        consumer(leveled, when, hostSeconds)
                    }
                    let programToken = ProgramAudioSource.shared.addConsumer { buffer, _, _ in
                        summer.pushProgram(buffer)
                    }
                    return SessionAudioFeed(backing: .mixFeedWithProgram(
                        mixId: mixId, token: token, programToken: programToken))
                }
                let token = mixer.addFeedConsumer(mixId: mixId) { buffer, when, hostSeconds in
                    guard let leveled = scaled(buffer) else { return }
                    consumer(leveled, when, hostSeconds)
                }
                return SessionAudioFeed(backing: .mixFeed(mixId: mixId, token: token))
            }
            DiagnosticsStore.shared.note(
                "input.audio",
                detail: "mix \(mixId) not available — session fell back to Program Audio")
        } else if let inputId = audioInputId, !inputId.isEmpty {
            if let source = AudioInputInventory.shared.source(forId: inputId),
               source.isRunning {
                return attach(source: source, includeProgram: includeProgram,
                              consumer: consumer)
            }
            let name = AudioInputInventory.shared.name(forId: inputId) ?? inputId
            DiagnosticsStore.shared.note(
                "input.audio",
                detail: "input \(name) not available — session fell back to Program Audio")
        } else if let uid = audioInputUid, !uid.isEmpty {

            if let source = AudioInputInventory.shared.source(forUid: uid), source.isRunning {
                return attach(source: source, includeProgram: includeProgram,
                              consumer: consumer)
            }
            DiagnosticsStore.shared.note(
                "input.audio",
                detail: "input \(uid) not available — session fell back to Program Audio")
        }
        let token = ProgramAudioSource.shared.addConsumer(consumer)
        return SessionAudioFeed(backing: .program(token: token))
    }

    private static func delayed(
        _ consumer: @escaping Consumer, milliseconds: Int
    ) -> Consumer {
        guard milliseconds > 0 else { return consumer }
        let line = AudioDelayLine()
        line.delayMilliseconds = Double(milliseconds)
        return { buffer, when, hostSeconds in
            consumer(line.delayedCopy(buffer), when, hostSeconds)
        }
    }

    @MainActor
    private static func attach(
        source: AudioInputSource,
        includeProgram: Bool,
        consumer: @escaping Consumer
    ) -> SessionAudioFeed {
        if includeProgram, let target = AVAudioFormat(
            standardFormatWithSampleRate: 48_000, channels: 2) {
            let summer = ProgramAudioSummer(targetFormat: target)
            let inputToken = source.addConsumer { buffer, when, hostSeconds in

                guard let copy = buffer.deepCopyForSum() else { return }
                summer.sum(into: copy)
                consumer(copy, when, hostSeconds)
            }
            let programToken = ProgramAudioSource.shared.addConsumer { buffer, _, _ in
                summer.pushProgram(buffer)
            }
            return SessionAudioFeed(backing: .mixedWarm(
                source: source, inputToken: inputToken, programToken: programToken))
        }
        let token = source.addConsumer(consumer)
        return SessionAudioFeed(backing: .warmInput(source: source, token: token))
    }

    private init(backing: Backing) {
        self.backing = backing
    }

    func close() {
        let closed: Backing? = lock.withLock {
            defer { backing = nil }
            return backing
        }
        switch closed {
        case .program(let token):
            ProgramAudioSource.shared.removeConsumer(token)
        case .warmInput(let source, let token):
            source.removeConsumer(token)  
        case .mixedWarm(let source, let inputToken, let programToken):
            source.removeConsumer(inputToken)
            ProgramAudioSource.shared.removeConsumer(programToken)
        case .mixFeed(let mixId, let token):
            Task { @MainActor in
                AudioMixerController.current?.removeFeedConsumer(mixId: mixId, token: token)
            }
        case .mixFeedWithProgram(let mixId, let token, let programToken):
            ProgramAudioSource.shared.removeConsumer(programToken)
            Task { @MainActor in
                AudioMixerController.current?.removeFeedConsumer(mixId: mixId, token: token)
            }
        case .none:
            break
        }
    }
}

private extension AVAudioPCMBuffer {

    func deepCopyForSum() -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCapacity),
              let src = floatChannelData, let dst = copy.floatChannelData
        else { return nil }
        copy.frameLength = frameLength
        let bytes = Int(frameLength) * MemoryLayout<Float>.size
        for channel in 0..<Int(format.channelCount) {
            memcpy(dst[channel], src[channel], bytes)
        }
        return copy
    }
}

final class ProgramAudioSource: @unchecked Sendable {
    static let shared = ProgramAudioSource()

    typealias Consumer = @Sendable (AVAudioPCMBuffer, AVAudioTime, Double) -> Void

    private let lock = EngineStateLock()
    private var consumers: [UUID: Consumer] = [:]
    private var tap: AnyObject?

    private init() {}

    func addConsumer(_ consumer: @escaping Consumer) -> UUID {
        let token = UUID()
        let needsTap: Bool = lock.withLock {
            consumers[token] = consumer
            return tap == nil
        }
        if needsTap { startTap() }
        return token
    }

    func removeConsumer(_ token: UUID) {

        let dropped: AnyObject? = lock.withLock {
            guard consumers.removeValue(forKey: token) != nil,
                  consumers.isEmpty else { return nil }
            defer { tap = nil }
            return tap
        }
        _ = dropped
    }

    private func startTap() {
        guard #available(macOS 14.2, *) else {
            DiagnosticsStore.shared.note(
                "audio.tap", detail: "process taps need macOS 14.2+ — video-only")
            return
        }
        do {
            let fresh = try ProgramAudioTap { [weak self] buffer, when, hostSeconds in
                guard let self else { return }

                guard let sinks: [Consumer] = self.lock.tryWithLock({
                    Array(self.consumers.values)
                }) else { return }
                for sink in sinks { sink(buffer, when, hostSeconds) }
            }
            lock.withLock { tap = fresh }
        } catch {
            DiagnosticsStore.shared.note(
                "audio.tap", detail: "tap creation failed (\(error)) — video-only")
        }
    }
}
