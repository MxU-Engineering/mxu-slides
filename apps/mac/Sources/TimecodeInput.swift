import AVFoundation
import Accelerate
import AudioEngine
import Foundation
import Observation
import PresenterCore
import QuartzCore
import SlideScene
import SwiftUI

final class LTCReader: TimecodeReader, @unchecked Sendable {
    let deviceUID: String
    private let hub: AudioInputHub
    private var token: UUID?
    private let lock = NSLock()
    private var heard: [TimecodeHeard] = []
    private var peak: Float = 0

    private var decoder = LTCDecoder(sampleRate: 48_000)

    init(deviceUID: String, channel: Int) throws {
        self.deviceUID = deviceUID
        hub = try AudioInputHubPool.shared.acquire(deviceUID: deviceUID)
        token = hub.addTap(channels: .mono(channel: channel), trimmed: false) { [weak self] buffer, _, host in
            self?.read(buffer, hostSeconds: host)
        }
    }

    func setChannel(_ channel: Int) {
        if let token { hub.updateTap(token, channels: .mono(channel: channel)) }
    }

    func stop() {
        guard let token else { return }
        hub.removeTap(token)
        self.token = nil
        AudioInputHubPool.shared.release(deviceUID: deviceUID)
    }

    private func read(_ buffer: AVAudioPCMBuffer, hostSeconds: Double) {
        guard let data = buffer.floatChannelData, buffer.frameLength > 0 else { return }
        let count = Int(buffer.frameLength)
        if decoder.sampleRate != buffer.format.sampleRate {
            decoder = LTCDecoder(sampleRate: buffer.format.sampleRate)
        }
        let start = decoder.sampleCount
        let frames = decoder.decode(UnsafeBufferPointer(start: data[0], count: count))
        var level: Float = 0
        vDSP_maxmgv(data[0], 1, &level, vDSP_Length(count))
        let rate = decoder.rate ?? .fps30
        let sampleRate = buffer.format.sampleRate
        let new = frames.map {
            TimecodeHeard(ltc: $0, rate: rate, hostTime: hostSeconds + Double($0.endSample - start) / sampleRate)
        }
        lock.withLock {
            heard += new

            if heard.count > 90 { heard.removeFirst(heard.count - 90) }
            peak = max(peak, level)
        }
    }

    func drain() -> (heard: [TimecodeHeard], peak: Float) {
        lock.withLock {
            defer {
                heard.removeAll(keepingCapacity: true)
                peak = 0
            }
            return (heard, peak)
        }
    }
}

@MainActor
@Observable
final class TimecodeFollower {
    @ObservationIgnored weak var controls: ServiceControls?

    private(set) var source = UserDefaults.standard.string(forKey: TimecodeStation.sourceKey)
        .flatMap(TimecodeSource.init(rawValue:)) ?? .ltc

    private(set) var deviceUID: String? = UserDefaults.standard.string(forKey: TimecodeStation.deviceKey)

    private(set) var midiSourceUID = (UserDefaults.standard.object(forKey: TimecodeStation.midiSourceKey) as? Int)
        .map { Int32(truncatingIfNeeded: $0) }
    private(set) var channel = UserDefaults.standard.integer(forKey: TimecodeStation.channelKey)
    private(set) var offsetFrames = UserDefaults.standard.integer(forKey: TimecodeStation.offsetKey)
    private(set) var follows = UserDefaults.standard.object(forKey: TimecodeStation.followKey) as? Bool ?? true

    private(set) var playsAudio = UserDefaults.standard.bool(forKey: TimecodeStation.audioKey)

    @ObservationIgnored private var audioRunning = false

    private(set) var problem: String?

    private(set) var timecodeReading = TimecodeClock.Reading(state: .noInput)

    private(set) var timecodeLevel: Float = 0

    private(set) var isLocked = false

    private(set) var detectedRate: TimecodeRate?

    private(set) var anchoredDisplay: TimecodeDisplay?

    private(set) var songItemID: String?

    @ObservationIgnored private var reader: (any TimecodeReader)?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var clock = TimecodeClock()
    @ObservationIgnored private var follow = TimecodeFollow()

    @ObservationIgnored private var revealPending: String?

    static func status(_ reading: TimecodeClock.Reading, follows: Bool) -> (word: String, color: Color) {
        guard follows else { return ("Off", .secondary) }

        if reading.state == .noInput { return ("Waiting", .secondary) }
        return reading.state == .locked ? ("Locked", .green) : ("Lost", .orange)
    }

    enum Input: Hashable {
        case none
        case audio(String)
        case midi(Int32)
    }

    var input: Input {
        switch source {
        case .ltc: deviceUID.map(Input.audio) ?? .none
        case .mtc: midiSourceUID.map(Input.midi) ?? .none
        }
    }

    var hasInput: Bool { input != .none }

    func start() {
        guard reader == nil else { return }
        switch input {
        case .none:
            return
        case .audio(let deviceUID):
            do {
                reader = try LTCReader(deviceUID: deviceUID, channel: channel)
                problem = nil
            } catch {
                problem = "Not connected"
                DiagnosticsStore.shared.note("timecode.input", detail: "\(deviceUID): \(error)")
                return
            }
            DiagnosticsStore.shared.note("timecode.input", detail: "\(deviceUID) ch \(channel + 1)")
        case .midi(let uid):

            reader = MTCReader(sourceUID: uid)
            problem = nil
            DiagnosticsStore.shared.note("timecode.input", detail: "MTC \(uid)")
        }
        clock = TimecodeClock()
        follow = TimecodeFollow()
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stopInput() {
        timer?.invalidate()
        timer = nil
        reader?.stop()
        reader = nil
        controls?.render.confidenceInfo.timecode = nil
        anchoredDisplay = nil

        if controls?.timeline.timecodeRecording != nil { controls?.timeline.stop() }
        timecodeReading = TimecodeClock.Reading(state: .noInput)
        timecodeLevel = 0
        isLocked = false
    }

    func setInput(_ input: Input) {
        guard input != self.input else { return }
        stopInput()
        switch input {
        case .none:
            deviceUID = nil
            midiSourceUID = nil
        case .audio(let uid):
            source = .ltc
            deviceUID = uid
        case .midi(let uid):
            source = .mtc
            midiSourceUID = uid
        }
        let defaults = UserDefaults.standard
        defaults.set(source.rawValue, forKey: TimecodeStation.sourceKey)
        defaults.set(deviceUID, forKey: TimecodeStation.deviceKey)
        defaults.set(midiSourceUID.map { Int($0) }, forKey: TimecodeStation.midiSourceKey)
        problem = nil
        start()
    }

    func setChannel(_ channel: Int) {
        self.channel = channel
        UserDefaults.standard.set(channel, forKey: TimecodeStation.channelKey)
        (reader as? LTCReader)?.setChannel(channel)
    }

    func setOffset(_ frames: Int) {
        offsetFrames = min(max(frames, TimecodeStation.offsetRange.lowerBound), TimecodeStation.offsetRange.upperBound)
        UserDefaults.standard.set(offsetFrames, forKey: TimecodeStation.offsetKey)
    }

    func setFollows(_ on: Bool) {
        follows = on
        UserDefaults.standard.set(on, forKey: TimecodeStation.followKey)

        follow = TimecodeFollow()

        if !on, controls?.timeline.timecodeRecording != nil { controls?.timeline.stop() }
    }

    func readingNow() -> TimecodeClock.Reading {
        var reading = clock.reading(at: CACurrentMediaTime())
        if let rate = reading.rate, let position = reading.position {
            reading.position = position + Double(offsetFrames) / rate.actual
        }
        return reading
    }

    func setPlaysAudio(_ on: Bool) {
        playsAudio = on
        UserDefaults.standard.set(on, forKey: TimecodeStation.audioKey)
        if !on, audioRunning {
            controls?.timeline.stopTracks()
            audioRunning = false
        }
    }

    func retry() {
        if reader == nil { start() }
    }

    private func tick() {
        guard let reader else { return }
        let (heard, peak) = reader.drain()
        for frame in heard { clock.receive(frame) }
        var reading = clock.reading(at: CACurrentMediaTime())
        publishDisplay(reading)
        if let rate = reading.rate, let position = reading.position {
            reading.position = position + Double(offsetFrames) / rate.actual
            if detectedRate != rate { detectedRate = rate }
        }
        if reading != timecodeReading { timecodeReading = reading }
        if isLocked != (reading.state == .locked) { isLocked = reading.state == .locked }
        let level = max(peak, timecodeLevel * 0.85)
        if abs(level - timecodeLevel) > 0.002 { timecodeLevel = level < 0.001 ? 0 : level }

        if audioRunning, reading.state == .stopped || reading.state == .noInput {
            controls?.timeline.stopTracks()
            audioRunning = false
        }
        guard follows, let controls else { return }

        let take = controls.timeline.timecodeRecordingTick(reading)
        guard reading.live else {

            if reading.state != .freewheel { controls.timeline.timecodeHeld() }
            return
        }
        var songs = Self.songs(controls.appModel)
        if let take {
            songs = songs.compactMap { followed in
                take.songs([followed.song]).first.map {
                    var song = followed
                    song.song = $0
                    return song
                }
            }
        }
        if let command = follow.step(reading, songs: songs.map(\.song)),
           let item = songs.first(where: { $0.song.itemID == command.itemID }) {
            let newSong = controls.timeline.itemID != command.itemID
            if newSong { revealPending = command.itemID }
            if songItemID != command.itemID { songItemID = command.itemID }
            if case .land = command {
                DiagnosticsStore.shared.note("timecode.land", detail: "\(command.itemID) at \(String(format: "%.3f", command.position))")
            } else if newSong {
                DiagnosticsStore.shared.note("timecode.song", detail: "\(command.itemID) at \(String(format: "%.3f", command.position))")
            }
            controls.timeline.follow(
                command, itemID: item.song.itemID, presentation: item.presentation, arrangementId: item.arrangementId,
                playsAudio: playsAudio)
            audioRunning = playsAudio
        }

        if let pending = revealPending, controls.liveContextID == pending {
            revealPending = nil
            controls.noteKeyboardFire()
        }
    }

    private func publishDisplay(_ reading: TimecodeClock.Reading) {
        guard let render = controls?.render else { return }
        let now = Date()
        var display: TimecodeDisplay?
        if let seconds = reading.position, let rate = reading.rate {
            display = TimecodeDisplay(
                seconds: seconds, rate: rate, anchoredAt: now,
                isRunning: reading.state == .locked || reading.state == .freewheel, reverse: reading.reverse)
        }
        let held = render.confidenceInfo.timecode
        if let held, let display, held.rate == display.rate, held.isRunning == display.isRunning,
           held.reverse == display.reverse, abs(held.seconds(at: now) - display.seconds) < 0.5 / display.rate.actual {
            return
        }
        guard held != display else { return }
        render.confidenceInfo.timecode = display
        anchoredDisplay = display
    }

    struct FollowedSong {
        var song: TimecodeFollow.Song
        var item: ServiceItem
        var presentation: Presentation
        var timeline: PresentationTimeline
        var arrangementId: String? { item.arrangementId }
    }

    static func songs(_ model: AppModel) -> [FollowedSong] {
        guard let serviceID = model.currentServiceID, let service = try? model.service(serviceID) else { return [] }
        let starts = starts(model, service: service)
        return model.runOfShow(service).compactMap { item in
            guard item.itemKind == .presentation, let deck = model.presentation(item.refId),
                  let timeline = PresentationTimelines.timeline(for: item.arrangementId, in: deck),
                  timeline.timecodeEnabled
            else { return nil }
            return FollowedSong(
                song: TimecodeFollow.Song(itemID: item.id, timeline: timeline, start: starts[item.id]), item: item,
                presentation: deck, timeline: timeline)
        }
    }

    static func starts(_ model: AppModel, service: Service) -> [String: Int] {
        PresentationTimelines.serviceStarts(
            model.runOfShow(service).compactMap { item in
                guard item.itemKind == .presentation else { return nil }
                return (item.id, model.presentation(item.refId).flatMap {
                    PresentationTimelines.timeline(for: item.arrangementId, in: $0)
                })
            },
            byOrder: service.timecodeByOrder == true)
    }
}

struct TimecodeInputControl: View {
    let follower: TimecodeFollower
    @State private var devices: [AudioDeviceList.AudioInputDevice] = []

    private typealias Input = TimecodeFollower.Input

    var body: some View {
        let input = follower.input
        let midiSources = MIDIDeviceInventory.shared.discoveredSources
        let device: AudioDeviceList.AudioInputDevice? = if case .audio(let uid) = input {
            devices.first { $0.uid == uid }
        } else {
            nil
        }
        let missing: String? = switch input {
        case .none: nil
        case .audio: device == nil ? "Device (not connected)" : nil
        case .midi(let uid): midiSources.contains { $0.uid == uid } ? nil : "MIDI source (not connected)"
        }
        HStack(spacing: 8) {
            if follower.problem != nil {
                Text("Not connected").foregroundStyle(.orange)
            }
            Picker("", selection: Binding(get: { input }, set: { follower.setInput($0) })) {
                Text("None").tag(Input.none)
                Section("LTC (audio)") {
                    ForEach(devices, id: \.uid) { Text($0.name).tag(Input.audio($0.uid)) }
                }
                Section("MTC (MIDI)") {
                    ForEach(midiSources, id: \.uid) { Text($0.name).tag(Input.midi($0.uid)) }
                }
                if let missing {
                    Text(missing).tag(input)
                }
            }
            .labelsHidden()
            .fixedSize()
            if let device, device.channelCount > 1 {
                Picker("", selection: Binding(get: { follower.channel }, set: { follower.setChannel($0) })) {
                    ForEach(0..<device.channelCount, id: \.self) { Text("Channel \($0 + 1)").tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
        }
        .task {
            while !Task.isCancelled {
                devices = AudioDeviceList.inputDevices()
                if case .audio(let uid) = follower.input, devices.contains(where: { $0.uid == uid }) {
                    follower.retry()
                }
                try? await Task.sleep(for: .seconds(4))
            }
        }
    }
}

struct TimecodeSignalReadout: View {
    let follower: TimecodeFollower

    var body: some View {
        let reading = follower.timecodeReading
        let status = TimecodeFollower.status(reading, follows: follower.follows)
        HStack(spacing: 8) {
            Text(reading.label.map { $0.text(dropFrame: reading.rate == .fps2997DropFrame) } ?? "--:--:--:--")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .trailing)
            Text(status.word)
                .font(.caption.weight(.medium))
                .foregroundStyle(status.color)
                .frame(width: 46, alignment: .leading)
            Text(follower.detectedRate?.title ?? "—")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 118, alignment: .leading)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule().fill(Color.green.opacity(0.8))
                    .frame(width: 90 * CGFloat(AudioLevel.meterFraction(follower.timecodeLevel)))
            }
            .frame(width: 90, height: 5, alignment: .leading)
        }
    }
}

struct TimecodeOffsetControl: View {
    let follower: TimecodeFollower

    var body: some View {
        Stepper(value: Binding(get: { follower.offsetFrames }, set: { follower.setOffset($0) }), in: TimecodeStation.offsetRange) {
            Text("\(follower.offsetFrames > 0 ? "+" : "")\(follower.offsetFrames) frames")
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .fixedSize()
    }
}
