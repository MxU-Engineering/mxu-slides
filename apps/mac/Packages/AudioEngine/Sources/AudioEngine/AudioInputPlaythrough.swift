import AVFoundation
import Accelerate
import CoreAudio
import Foundation

public final class AudioInputPlaythrough: @unchecked Sendable {

    let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()

    private let delayUnit = AVAudioUnitDelay()
    private let format: AVAudioFormat
    let lock = EngineStateLock()
    private var running = false
    private var storedGain: Float = 1

    private var muted = true
    private var desiredChannelOffset = 0
    private var deviceChannelCount = 2

    private var appliedDeviceID: AudioDeviceID?

    private var pendingFrames: AVAudioFramePosition = 0

    private var scheduleGeneration = 0

    private static let maxPendingFrames: AVAudioFramePosition = 24_000
    private var configObserver: (any NSObjectProtocol)?

    public init() {
        format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        engine.attach(player)
        engine.attach(delayUnit)
        delayUnit.delayTime = 0
        delayUnit.feedback = 0
        delayUnit.wetDryMix = 100

        delayUnit.lowPassCutoff = Float(format.sampleRate / 2)
        engine.connect(player, to: delayUnit, format: format)
        engine.connect(delayUnit, to: engine.mainMixerNode, format: format)
        engine.prepare()

        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in

            RealtimeAudioCallback.scope {
                DispatchQueue.global(qos: .utility).async { [weak self] in
                    guard let self else { return }
                    self.lock.withLock {
                        guard self.running, !self.engine.isRunning else { return }
                        self.scheduleGeneration += 1
                        self.pendingFrames = 0
                        self.applyChannelMap()
                        try? self.engine.start()
                        self.player.play()
                    }
                }
            }
        }
    }

    deinit {
        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
        }
    }

    public var isRunning: Bool { lock.withLock { running } }

    public func start() throws {
        try lock.withLock {
            guard !running else { return }
            applyChannelMap()
            try engine.start()
            applyGainLocked()
            player.play()
            running = true
        }
    }

    public func stop() {
        lock.withLock {
            guard running else { return }
            running = false
            scheduleGeneration += 1
            player.stop()
            engine.stop()
            pendingFrames = 0
        }
    }

    @discardableResult
    public func push(_ buffer: AVAudioPCMBuffer) -> Bool {

        lock.tryWithLock {
            guard running else { return false }
            let frames = AVAudioFramePosition(buffer.frameLength)
            guard pendingFrames < Self.maxPendingFrames else { return false }
            pendingFrames += frames
            let generation = scheduleGeneration

            let scheduled = Self.panned(buffer, pan: storedPan) ?? buffer
            player.scheduleBuffer(scheduled, completionCallbackType: .dataPlayedBack) {
                [weak self] _ in

                RealtimeAudioCallback.scope {
                    DispatchQueue.global(qos: .utility).async {
                        guard let self else { return }
                        self.lock.withLock {
                            guard self.scheduleGeneration == generation else { return }
                            self.pendingFrames = max(0, self.pendingFrames - frames)
                        }
                    }
                }
            }
            return true
        } ?? false
    }

    public var gain: Float {
        get { lock.withLock { storedGain } }
        set {
            lock.withLock {
                storedGain = newValue.clamped(to: 0 ... 1)
                applyGainLocked()
            }
        }
    }

    public var isMuted: Bool {
        get { lock.withLock { muted } }
        set {
            lock.withLock {
                muted = newValue
                applyGainLocked()
            }
        }
    }

    private func applyGainLocked() {
        engine.mainMixerNode.outputVolume = muted ? 0 : storedGain
    }

    public var pan: Float {
        get { lock.withLock { storedPan } }
        set {
            lock.withLock { storedPan = newValue.clamped(to: -1 ... 1) }
        }
    }

    private var storedPan: Float = 0

    static func panned(_ buffer: AVAudioPCMBuffer, pan: Float) -> AVAudioPCMBuffer? {
        guard pan != 0, buffer.frameLength > 0,
              buffer.format.channelCount >= 2,
              let source = buffer.floatChannelData,
              let copy = AVAudioPCMBuffer(
                  pcmFormat: buffer.format, frameCapacity: buffer.frameLength),
              let dest = copy.floatChannelData
        else { return nil }
        copy.frameLength = buffer.frameLength
        let frames = vDSP_Length(buffer.frameLength)
        var leftGain = min(1, 1 - pan)
        var rightGain = min(1, 1 + pan)
        vDSP_vsmul(source[0], 1, &leftGain, dest[0], 1, frames)
        vDSP_vsmul(source[1], 1, &rightGain, dest[1], 1, frames)
        return copy
    }

    public var outputDelayMilliseconds: Double {
        get { lock.withLock { delayUnit.delayTime * 1000 } }
        set {
            lock.withLock {
                delayUnit.delayTime = max(0, min(newValue, 2000)) / 1000
            }
        }
    }

    public func setOutputDevice(
        _ device: AudioOutputDevice?, channelOffset: Int = 0
    ) throws {
        try lock.withLock {
            let target = device ?? AudioDeviceList.defaultOutputDevice()

            if appliedDeviceID == target?.id, desiredChannelOffset == channelOffset,
               deviceChannelCount == (target?.channelCount ?? 2),
               engine.isRunning == running {
                return
            }
            let wasRunning = running
            scheduleGeneration += 1
            player.stop()
            engine.stop()
            pendingFrames = 0
            if let id = target?.id {
                try engine.outputNode.auAudioUnit.setDeviceID(id)
            }
            appliedDeviceID = target?.id
            desiredChannelOffset = channelOffset
            deviceChannelCount = target?.channelCount ?? 2
            applyChannelMap()
            if wasRunning {
                try engine.start()
                applyGainLocked()
                player.play()
            }
        }
    }

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
}
