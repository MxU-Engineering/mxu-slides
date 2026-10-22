import AudioToolbox
import CoreAudio
import Foundation
import QuartzCore

public final class MultitrackEngine: @unchecked Sendable {
    public private(set) var sampleRate: Double
    public private(set) var deviceChannels: Int
    public private(set) var deviceUID: String?
    private(set) var renderer: MultitrackRenderer
    private let queue = DispatchQueue(label: "io.prodcontrol.multitrack", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private var output: MultitrackOutput?
    private var song: MultitrackSong?
    private var routing = MultitrackRouting()
    private var session: MultitrackSession?
    private var readers: [ObjectIdentifier: [StemReader]] = [:]
    private var program: MultitrackProgram?

    private var retired: [(program: MultitrackProgram, at: CFTimeInterval)] = []

    static let ringSeconds = 3.0

    static let primeSeconds = 0.75

    public init(sampleRate: Double = 48_000, deviceChannels: Int = 2) {
        self.sampleRate = sampleRate
        self.deviceChannels = deviceChannels
        renderer = MultitrackRenderer(deviceChannels: deviceChannels, sampleRate: sampleRate)
    }

    deinit {
        timer?.cancel()
        output?.stop()
    }

    public func attach(device: AudioOutputDevice?) throws {
        try queue.sync {
            guard let device = device ?? AudioDeviceList.defaultOutputDevice() else { return }
            let rate = MultitrackOutput.nominalRate(device.id) ?? sampleRate

            if output != nil, device.uid == deviceUID, rate == sampleRate, device.channelCount == deviceChannels { return }
            output?.stop()
            output = nil
            if rate != sampleRate || device.channelCount != deviceChannels {
                let resume = positionLocked()
                let wasPlaying = renderer.published.playing
                sampleRate = rate
                deviceChannels = device.channelCount
                renderer = MultitrackRenderer(deviceChannels: deviceChannels, sampleRate: sampleRate)
                if let song { cueLocked(song, at: resume) }
                if wasPlaying { renderer.play() }
            }
            deviceUID = device.uid
            output = try MultitrackOutput(device: device, sampleRate: sampleRate, renderer: renderer)
            startTimer()
        }
    }

    public func detach() {
        queue.sync {
            output?.stop()
            output = nil
            deviceUID = nil
        }
    }

    public func cue(_ song: MultitrackSong, at seconds: Double = 0) {
        queue.sync { cueLocked(song, at: seconds) }
    }

    public func setRouting(_ routing: MultitrackRouting) {
        queue.sync {
            guard routing != self.routing else { return }
            self.routing = routing
            if let session { publish(session) }
        }
    }

    public func play(atHostTime hostTime: UInt64 = 0) {
        queue.sync { renderer.play(atHostTime: hostTime) }
    }

    public func stop() {
        queue.sync { renderer.stop() }
    }

    public func seek(to seconds: Double) {
        queue.sync {
            guard let song else { return }
            cueLocked(song, at: seconds)
        }
    }

    public func position(atHostTime hostTime: UInt64 = mach_absolute_time()) -> Double {
        queue.sync { positionLocked(atHostTime: hostTime) }
    }

    private func positionLocked(atHostTime hostTime: UInt64 = mach_absolute_time()) -> Double {
        if let program, !renderer.isCurrent(program) {
            return Double(program.session.startFrame) / sampleRate
        }
        return renderer.position(atHostTime: hostTime)
    }

    public var songChannelIDs: [String] { queue.sync { song?.stems.map(\.channelId) ?? [] } }

    public var isPlaying: Bool { renderer.published.playing }

    public var songLength: Double? {
        queue.sync {
            guard let session, let group = readers[ObjectIdentifier(session)] else { return nil }
            return group.map { Double($0.audioEnd) / sampleRate }.max()
        }
    }
    public var songID: String? { queue.sync { song?.id } }

    public func takeMeters() -> [String: (rms: Float, peak: Float)] {
        queue.sync {
            guard let session else { return [:] }
            var levels: [String: (rms: Float, peak: Float)] = [:]
            for (stem, level) in MultitrackRenderer.takeMeters(session).enumerated() {
                let id = session.stemChannels[stem]
                let held = levels[id] ?? (0, 0)
                levels[id] = (max(held.rms, level.rms), max(held.peak, level.peak))
            }
            return levels
        }
    }

    public var starvedFrames: Int64 {
        queue.sync { session?.rings.reduce(0) { $0 + $1.starvedFrames } ?? 0 }
    }

    public func drainFeeds(_ body: (String, UnsafePointer<Float>, UnsafePointer<Float>, Int) -> Void) {
        queue.sync {
            guard let program else { return }
            let frames = 2048
            let left = UnsafeMutablePointer<Float>.allocate(capacity: frames)
            let right = UnsafeMutablePointer<Float>.allocate(capacity: frames)
            defer { left.deallocate(); right.deallocate() }
            for (index, ring) in program.feeds.enumerated() {
                while ring.buffered > 0 {
                    let count = min(frames, ring.buffered)
                    ring.read(into: left, right, count: count)
                    body(program.matrix.feedMixIds[index], left, right, count)
                }
            }
        }
    }

    private func cueLocked(_ song: MultitrackSong, at seconds: Double) {
        self.song = song
        let start = Int64((max(0, seconds) * sampleRate).rounded())
        let capacity = Int(Self.ringSeconds * sampleRate)
        let stemReaders = song.stems.map {
            StemReader(stem: $0, sampleRate: sampleRate, startFrame: start, capacity: capacity)
        }

        let prime = Int(Self.primeSeconds * sampleRate)
        for reader in stemReaders { reader.fill(upTo: prime) }
        let session = MultitrackSession(
            rings: stemReaders.map(\.ring), stemChannels: song.stems.map(\.channelId), startFrame: start)
        readers[ObjectIdentifier(session)] = stemReaders
        self.session = session
        publish(session)
    }

    private func publish(_ session: MultitrackSession) {
        let matrix = MultitrackMatrix(routing, stemChannels: session.stemChannels, deviceChannels: deviceChannels)
        let next = MultitrackProgram(session: session, matrix: matrix, feedCapacity: Int(sampleRate))
        if let program { retired.append((program, CACurrentMediaTime())) }
        program = next
        renderer.publish(next)
    }

    private func startTimer() {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(20), leeway: .milliseconds(5))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    func tick() {
        let now = CACurrentMediaTime()
        retired.removeAll { !renderer.isHolding($0.program) && now - $0.at > 1 }
        let live = Set(([program] + retired.map(\.program)).compactMap { $0.map { ObjectIdentifier($0.session) } })
        readers = readers.filter { live.contains($0.key) }
        for group in readers.values {
            for reader in group { reader.fill() }
        }
    }

    func tickNow() { queue.sync { tick() } }
}

final class MultitrackOutput {
    private var unit: AudioUnit?
    private let context: Context

    final class Context {
        let renderer: MultitrackRenderer
        let pointers: UnsafeMutablePointer<UnsafeMutablePointer<Float>>
        let spare: UnsafeMutablePointer<Float>
        let channels: Int

        init(renderer: MultitrackRenderer) {
            self.renderer = renderer
            channels = renderer.deviceChannels
            spare = .allocate(capacity: 8192)
            pointers = .allocate(capacity: max(1, channels))
            pointers.initialize(repeating: spare, count: max(1, channels))
        }

        deinit { pointers.deallocate(); spare.deallocate() }
    }

    init(device: AudioOutputDevice, sampleRate: Double, renderer: MultitrackRenderer) throws {
        context = Context(renderer: renderer)
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &description) else { throw MultitrackError.noOutputUnit }
        var created: AudioUnit?
        try check(AudioComponentInstanceNew(component, &created))
        guard let unit = created else { throw MultitrackError.noOutputUnit }
        self.unit = unit
        var deviceID = device.id
        try check(AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
            &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size)))
        var format = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: UInt32(renderer.deviceChannels), mBitsPerChannel: 32, mReserved: 0)
        try check(AudioUnitSetProperty(
            unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0,
            &format, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)))
        var maxFrames = UInt32(renderer.maxFrames)
        AudioUnitSetProperty(
            unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0,
            &maxFrames, UInt32(MemoryLayout<UInt32>.size))
        var callback = AURenderCallbackStruct(
            inputProc: multitrackRenderProc,
            inputProcRefCon: Unmanaged.passUnretained(context).toOpaque())
        try check(AudioUnitSetProperty(
            unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0,
            &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)))
        try check(AudioUnitInitialize(unit))
        try check(AudioOutputUnitStart(unit))
    }

    func stop() {
        guard let unit else { return }
        AudioOutputUnitStop(unit)
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
        self.unit = nil
    }

    deinit { stop() }

    static func nominalRate(_ device: AudioDeviceID) -> Double? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var rate = Float64(0)
        var size = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &rate) == noErr, rate > 0 else { return nil }
        return rate
    }

    private func check(_ status: OSStatus) throws {
        guard status == noErr else { throw MultitrackError.status(status) }
    }
}

public enum MultitrackError: Error {
    case noOutputUnit
    case status(OSStatus)
}

private func multitrackRenderProc(
    refCon: UnsafeMutableRawPointer, flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    timestamp: UnsafePointer<AudioTimeStamp>, bus: UInt32, frames: UInt32,
    data: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
    let context = Unmanaged<MultitrackOutput.Context>.fromOpaque(refCon).takeUnretainedValue()
    guard let data else { return noErr }
    let buffers = UnsafeMutableAudioBufferListPointer(data)
    for channel in 0 ..< context.channels {
        context.pointers[channel] = channel < buffers.count
            ? buffers[channel].mData?.assumingMemoryBound(to: Float.self) ?? context.spare
            : context.spare
    }
    context.renderer.render(frames: Int(frames), hostTime: timestamp.pointee.mHostTime, outputs: context.pointers)
    return noErr
}
