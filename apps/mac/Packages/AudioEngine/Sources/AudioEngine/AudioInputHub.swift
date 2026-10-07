import AVFoundation
import Accelerate
import AudioToolbox
import CoreAudio
import Foundation

public enum InputChannelSelection: Equatable, Sendable {
    case stereoPair(offset: Int)
    case mono(channel: Int)

    public static let `default` = InputChannelSelection.stereoPair(offset: 0)
}

enum ChannelExtraction {

    static func extract(
        _ source: AVAudioPCMBuffer,
        selection: InputChannelSelection,
        gain: Float = 1,
        muted: Bool = false
    ) -> AVAudioPCMBuffer? {
        guard let sourceData = source.floatChannelData,
              source.frameLength > 0,
              let format = AVAudioFormat(
                  standardFormatWithSampleRate: source.format.sampleRate, channels: 2),
              let out = AVAudioPCMBuffer(
                  pcmFormat: format, frameCapacity: source.frameLength),
              let outData = out.floatChannelData
        else { return nil }
        out.frameLength = source.frameLength
        let frames = vDSP_Length(source.frameLength)
        let channels = Int(source.format.channelCount)
        let left: Int
        let right: Int
        switch selection {
        case .stereoPair(let offset):
            if channels == 1 {
                (left, right) = (0, 0)
            } else {
                let clamped = (offset >= 0 && offset + 1 < channels) ? offset : 0
                (left, right) = (clamped, clamped + 1)
            }
        case .mono(let channel):
            let clamped = (channel >= 0 && channel < channels) ? channel : 0
            (left, right) = (clamped, clamped)
        }
        if muted {
            vDSP_vclr(outData[0], 1, frames)
            vDSP_vclr(outData[1], 1, frames)
            return out
        }
        var scale = gain
        vDSP_vsmul(sourceData[left], 1, &scale, outData[0], 1, frames)
        vDSP_vsmul(sourceData[right], 1, &scale, outData[1], 1, frames)
        return out
    }
}

final class InputFanout: @unchecked Sendable {
    typealias Sink = @Sendable (AVAudioPCMBuffer, AVAudioTime, Double) -> Void

    private struct Tap {
        var channels: InputChannelSelection
        let sink: Sink
    }

    private let lock = NSLock()
    private var taps: [UUID: Tap] = [:]

    func add(channels: InputChannelSelection, sink: @escaping Sink) -> UUID {
        let token = UUID()
        lock.withLock { taps[token] = Tap(channels: channels, sink: sink) }
        return token
    }

    func update(_ token: UUID, channels: InputChannelSelection) {
        lock.withLock { taps[token]?.channels = channels }
    }

    func remove(_ token: UUID) {
        lock.withLock { _ = taps.removeValue(forKey: token) }
    }

    var count: Int { lock.withLock { taps.count } }

    func push(
        _ buffer: AVAudioPCMBuffer, when: AVAudioTime, hostSeconds: Double,
        gain: Float = 1, muted: Bool = false
    ) {
        let snapshot = lock.withLock { Array(taps.values) }
        for tap in snapshot {
            guard let extracted = ChannelExtraction.extract(
                buffer, selection: tap.channels, gain: gain, muted: muted)
            else { continue }
            tap.sink(extracted, when, hostSeconds)
        }
    }
}

public final class AudioInputHub: @unchecked Sendable {
    public typealias Sink = @Sendable (AVAudioPCMBuffer, AVAudioTime, Double) -> Void

    public enum CaptureError: Error, Equatable {
        case deviceNotFound(String)
        case deviceBindFailed(OSStatus)
        case engineStartFailed(String)
        case formatUnavailable
    }

    public let deviceUID: String

    let engine: AVAudioEngine
    let lock = EngineStateLock()
    private let fanout = InputFanout()

    private let trim: @Sendable (String) -> (gain: Float, muted: Bool)
    private var running = false
    private var configObserver: (any NSObjectProtocol)?

    public init(
        deviceUID: String,
        trim: @escaping @Sendable (String) -> (gain: Float, muted: Bool)
    ) throws {
        self.deviceUID = deviceUID
        self.trim = trim
        engine = AVAudioEngine()

        try Self.pin(deviceUID: deviceUID, to: engine)
        try installTap()
        engine.prepare()
        do {
            try engine.start()
        } catch {
            engine.inputNode.removeTap(onBus: 0)
            throw CaptureError.engineStartFailed(String(describing: error))
        }
        running = true
        installConfigObserver()
    }

    init(
        deviceUID: String, engine: AVAudioEngine,
        trim: @escaping @Sendable (String) -> (gain: Float, muted: Bool) = { _ in (1, false) }
    ) {
        self.deviceUID = deviceUID
        self.engine = engine
        self.trim = trim
        installConfigObserver()
    }

    deinit {
        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
        }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    public func addTap(
        channels: InputChannelSelection, sink: @escaping Sink
    ) -> UUID {
        fanout.add(channels: channels, sink: sink)
    }

    public func updateTap(_ token: UUID, channels: InputChannelSelection) {
        fanout.update(token, channels: channels)
    }

    public func removeTap(_ token: UUID) {
        fanout.remove(token)
    }

    public var tapCount: Int { fanout.count }

    private static func pin(deviceUID: String, to engine: AVAudioEngine) throws {
        guard let device = AudioDeviceList.inputDevice(uid: deviceUID) else {
            throw CaptureError.deviceNotFound(deviceUID)
        }
        guard let audioUnit = engine.inputNode.audioUnit else {
            throw CaptureError.deviceBindFailed(-1)
        }
        var deviceID = device.id
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size))
        guard status == noErr else {
            throw CaptureError.deviceBindFailed(status)
        }
    }

    static func deviceWideFormat(channels: AVAudioChannelCount) -> AVAudioFormat? {
        if channels <= 2 {
            return AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: channels)
        }
        guard let layout = AVAudioChannelLayout(
            layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | UInt32(channels))
        else { return nil }
        return AVAudioFormat(standardFormatWithSampleRate: 48_000, channelLayout: layout)
    }

    static func convertDeviceBuffer(
        _ buffer: AVAudioPCMBuffer, converter: AVAudioConverter,
        to outputFormat: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let converted = AVAudioPCMBuffer(
            pcmFormat: outputFormat, frameCapacity: capacity)
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

    private func installTap() throws {
        let inputFormat = engine.inputNode.inputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw CaptureError.formatUnavailable
        }
        let needsConversion = inputFormat.sampleRate != 48_000
            || inputFormat.commonFormat != .pcmFormatFloat32
            || inputFormat.isInterleaved
        var converter: AVAudioConverter?
        var deviceFormat = inputFormat
        if needsConversion {
            guard let target = Self.deviceWideFormat(channels: inputFormat.channelCount),
                  let built = AVAudioConverter(from: inputFormat, to: target)
            else { throw CaptureError.formatUnavailable }
            converter = built
            deviceFormat = target
        }
        let fanout = self.fanout
        let trim = self.trim
        let uid = deviceUID
        engine.inputNode.installTap(
            onBus: 0, bufferSize: 1024, format: inputFormat
        ) { [converter] buffer, when in

            RealtimeAudioCallback.scope {
                let device: AVAudioPCMBuffer
                if let converter {
                    guard let converted = Self.convertDeviceBuffer(
                        buffer, converter: converter, to: deviceFormat)
                    else { return }
                    device = converted
                } else {
                    device = buffer
                }
                let hostSeconds = when.isHostTimeValid
                    ? AVAudioTime.seconds(forHostTime: when.hostTime)
                    : CACurrentMediaTime()
                let level = trim(uid)
                fanout.push(
                    device, when: when, hostSeconds: hostSeconds,
                    gain: level.gain, muted: level.muted)
            }
        }
    }

    private func installConfigObserver() {

        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            RealtimeAudioCallback.scope {
                DispatchQueue.global(qos: .utility).async { [weak self] in
                    guard let self else { return }
                    self.lock.withLock {
                        guard self.running, !self.engine.isRunning else { return }
                        self.engine.inputNode.removeTap(onBus: 0)
                        do {

                            try Self.pin(deviceUID: self.deviceUID, to: self.engine)
                            try self.installTap()
                            try self.engine.start()
                        } catch {

                        }
                    }
                }
            }
        }
    }
}

public final class AudioInputHubPool: @unchecked Sendable {
    public static let shared = AudioInputHubPool()

    private let lock = NSLock()

    private let providerLock = NSLock()
    private var _trimProvider: (@Sendable (String) -> (gain: Float, muted: Bool))?
    private var hubs: [String: (hub: AudioInputHub, refCount: Int)] = [:]

    var hubFactory: ((String, @escaping @Sendable (String) -> (gain: Float, muted: Bool)) throws -> AudioInputHub)?

    public var trimProvider: (@Sendable (String) -> (gain: Float, muted: Bool))? {
        get { providerLock.withLock { _trimProvider } }
        set { providerLock.withLock { _trimProvider = newValue } }
    }

    public func acquire(deviceUID: String) throws -> AudioInputHub {
        try lock.withLock {
            if let existing = hubs[deviceUID] {
                hubs[deviceUID] = (existing.hub, existing.refCount + 1)
                return existing.hub
            }
            let trim: @Sendable (String) -> (gain: Float, muted: Bool) = { [weak self] uid in
                self?.trimProvider?(uid) ?? (1, false)
            }
            let hub = try hubFactory?(deviceUID, trim)
                ?? AudioInputHub(deviceUID: deviceUID, trim: trim)
            hubs[deviceUID] = (hub, 1)
            return hub
        }
    }

    public func release(deviceUID: String) {

        var dying: AudioInputHub?
        lock.withLock {
            guard let entry = hubs[deviceUID] else { return }
            if entry.refCount <= 1 {
                hubs.removeValue(forKey: deviceUID)
                dying = entry.hub
            } else {
                hubs[deviceUID] = (entry.hub, entry.refCount - 1)
            }
        }
        _ = dying
    }

    public var hubCount: Int { lock.withLock { hubs.count } }
}
