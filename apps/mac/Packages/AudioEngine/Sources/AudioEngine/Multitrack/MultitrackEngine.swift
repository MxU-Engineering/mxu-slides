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

    private var delays: MultitrackDelays?

    public private(set) var share: TracksShare?

    private var preloaded: [(song: MultitrackSong, rate: Double, readers: [StemReader])] = []

    private var preloadWanted: [MultitrackSong] = []
    private let preloadQueue = DispatchQueue(label: "io.prodcontrol.multitrack.preload", qos: .userInitiated)

    private(set) var cuesDecoded = 0

    private var chaseSongID: String?
    private var chaseStarted: CFTimeInterval = 0
    private var chase = MultitrackChase()

    public private(set) var chaseLandings = 0

    private var retired: [(program: MultitrackProgram, at: CFTimeInterval)] = []

    static let ringSeconds = 3.0

    static let primeSeconds = 0.75

    static let preloadLimit = 2

    public init(sampleRate: Double = 48_000, deviceChannels: Int = 2, share: TracksShare? = nil) {
        self.sampleRate = sampleRate
        self.deviceChannels = deviceChannels
        self.share = share
        share?.sampleRate = sampleRate
        renderer = MultitrackRenderer(deviceChannels: deviceChannels, sampleRate: sampleRate, share: share)
    }

    public func setShare(_ share: TracksShare) {
        queue.sync {
            self.share = share
            share.sampleRate = sampleRate
            renderer = MultitrackRenderer(deviceChannels: deviceChannels, sampleRate: sampleRate, share: share)
            if let session { publish(session) }
        }
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
                share?.sampleRate = rate
                renderer = MultitrackRenderer(deviceChannels: deviceChannels, sampleRate: sampleRate, share: share)
                delays = nil
                preloaded = []
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
        queue.sync {
            chaseSongID = nil
            cueLocked(song, at: seconds)
        }
    }

    public func chase(song: MultitrackSong?, songID: String, position: Double, hostTime: UInt64) {
        queue.sync {
            guard let target = song ?? (self.song?.id == songID ? self.song : nil) else { return }
            let now = CACurrentMediaTime()
            let playing = renderer.published.playing
            let current = program.map { renderer.isCurrent($0) } ?? false
            if chaseSongID == target.id, !(current && playing) {

                if now - chaseStarted < 1 { return }
            }
            guard chaseSongID == target.id, target == self.song, playing, current else {
                cueLocked(target, at: position, anchor: hostTime)
                renderer.play()
                chaseSongID = target.id
                chaseStarted = now
                chase.reset()
                return
            }
            let error = renderer.position(atHostTime: hostTime) - position
            switch chase.step(error: error, at: Self.seconds(hostTime)) {
            case .land:
                cueLocked(target, at: position, anchor: hostTime)
                chaseStarted = now
                chaseLandings += 1
            case .speed(let speed):
                renderer.speed = speed
            }
        }
    }

    public func preload(_ songs: [MultitrackSong]) {
        let rate: Double = queue.sync {
            preloadWanted = Array(songs.suffix(Self.preloadLimit))
            preloaded.removeAll { entry in !preloadWanted.contains { $0 == entry.song } }
            return sampleRate
        }
        preloadQueue.async { [weak self] in
            for song in songs.suffix(Self.preloadLimit) {
                guard let self, self.queue.sync(execute: { self.needsPreload(song, rate: rate) }) else { continue }
                let readers = Self.openReaders(song, sampleRate: rate, startFrame: 0)
                self.queue.async {
                    guard self.needsPreload(song, rate: rate) else { return }
                    self.preloaded.append((song, rate, readers))
                }
            }
        }
    }

    static func seconds(_ hostTime: UInt64) -> Double {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        return Double(hostTime) * Double(timebase.numer) / Double(timebase.denom) / 1e9
    }

    private func needsPreload(_ song: MultitrackSong, rate: Double) -> Bool {
        rate == sampleRate && preloadWanted.contains(song) && !preloaded.contains { $0.song == song && $0.rate == rate }
    }

    public var preloadedSongIDs: [String] { queue.sync { preloaded.map(\.song.id) } }

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
        queue.sync {
            chaseSongID = nil
            renderer.stop()
        }
    }

    public func seek(to seconds: Double) {
        queue.sync {
            guard let song else { return }
            chaseSongID = nil
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

    public func takeMeters() -> [String: (left: AudioLevel.Reading, right: AudioLevel.Reading)] {
        queue.sync {
            guard let session else { return [:] }
            var levels: [String: (left: AudioLevel.Reading, right: AudioLevel.Reading)] = [:]
            for (stem, level) in MultitrackRenderer.takeMeters(session).enumerated() {
                let id = session.stemChannels[stem]
                var window = LevelWindow()
                if let held = levels[id] { window.fold(left: held.left, right: held.right) }
                window.fold(left: level.left, right: level.right)
                levels[id] = (window.left, window.right)
            }
            return levels
        }
    }

    public var starvedFrames: Int64 {
        queue.sync { session?.rings.reduce(0) { $0 + $1.starvedFrames } ?? 0 }
    }

    private func cueLocked(_ song: MultitrackSong, at seconds: Double, anchor: UInt64? = nil) {
        self.song = song
        var start = Int64((max(0, seconds) * sampleRate).rounded())
        let stemReaders: [StemReader]
        let ready = preloaded.firstIndex(where: { $0.song == song && $0.rate == sampleRate })

        let nearTop = anchor != nil && seconds < Self.primeSeconds - 0.25
        if let ready, start == 0 || nearTop {
            stemReaders = preloaded.remove(at: ready).readers
            start = 0
        } else {
            stemReaders = Self.openReaders(song, sampleRate: sampleRate, startFrame: start)
            cuesDecoded += 1
        }

        let session = MultitrackSession(
            rings: stemReaders.map(\.ring), stemChannels: song.stems.map(\.channelId), startFrame: start,
            anchor: anchor.map { (Int64((max(0, seconds) * sampleRate).rounded()), $0) },
            varispeed: anchor.map { _ in MultitrackVarispeed(stems: stemReaders.count, maxFrames: renderer.maxFrames) })
        readers[ObjectIdentifier(session)] = stemReaders
        self.session = session
        publish(session)
    }

    private static func openReaders(_ song: MultitrackSong, sampleRate: Double, startFrame: Int64) -> [StemReader] {
        let capacity = Int(ringSeconds * sampleRate)
        let readers = song.stems.map {
            StemReader(stem: $0, sampleRate: sampleRate, startFrame: startFrame, capacity: capacity)
        }
        let prime = Int(primeSeconds * sampleRate)
        for reader in readers { reader.fill(upTo: prime) }
        return readers
    }

    private func publish(_ session: MultitrackSession) {
        let matrix = MultitrackMatrix(routing, stemChannels: session.stemChannels, deviceChannels: deviceChannels)
        let frames = routing.delayFrames(deviceChannels: deviceChannels, sampleRate: sampleRate)
        if delays?.frames != frames { delays = frames.contains { $0 > 0 } ? MultitrackDelays(frames: frames) : nil }
        let next = MultitrackProgram(session: session, matrix: matrix, delays: delays)
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
