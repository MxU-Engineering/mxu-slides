import AVFoundation
import Accelerate
import AudioEngine
import Foundation
import Observation
import PresenterCore
import QuartzCore
import SwiftUI

final class LTCReader: @unchecked Sendable {
    struct Heard: Sendable {
        var frame: LTCFrame
        var rate: TimecodeRate

        var hostTime: Double
    }

    let deviceUID: String
    private let hub: AudioInputHub
    private var token: UUID?
    private let lock = NSLock()
    private var heard: [Heard] = []
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
            Heard(frame: $0, rate: rate, hostTime: hostSeconds + Double($0.endSample - start) / sampleRate)
        }
        lock.withLock {
            heard += new

            if heard.count > 90 { heard.removeFirst(heard.count - 90) }
            peak = max(peak, level)
        }
    }

    func drain() -> (heard: [Heard], peak: Float) {
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

    private(set) var deviceUID: String? = UserDefaults.standard.string(forKey: TimecodeStation.deviceKey)
    private(set) var channel = UserDefaults.standard.integer(forKey: TimecodeStation.channelKey)
    private(set) var offsetFrames = UserDefaults.standard.integer(forKey: TimecodeStation.offsetKey)
    private(set) var follows = UserDefaults.standard.object(forKey: TimecodeStation.followKey) as? Bool ?? true

    private(set) var problem: String?

    private(set) var timecodeReading = TimecodeClock.Reading(state: .noInput)

    private(set) var timecodeLevel: Float = 0

    private(set) var detectedRate: TimecodeRate?

    @ObservationIgnored private var reader: LTCReader?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var clock = TimecodeClock()
    @ObservationIgnored private var follow = TimecodeFollow()

    @ObservationIgnored private var revealPending: String?

    static func status(_ reading: TimecodeClock.Reading, follows: Bool) -> (word: String, color: Color) {
        guard follows else { return ("Off", .secondary) }
        return reading.state == .locked ? ("Locked", .green) : ("Lost", .orange)
    }

    func start() {
        guard reader == nil, let deviceUID else { return }
        do {
            reader = try LTCReader(deviceUID: deviceUID, channel: channel)
            problem = nil
        } catch {
            problem = "Not connected"
            DiagnosticsStore.shared.note("timecode.input", detail: "\(deviceUID): \(error)")
            return
        }
        clock = TimecodeClock()
        follow = TimecodeFollow()
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        DiagnosticsStore.shared.note("timecode.input", detail: "\(deviceUID) ch \(channel + 1)")
    }

    func stopInput() {
        timer?.invalidate()
        timer = nil
        reader?.stop()
        reader = nil
        timecodeReading = TimecodeClock.Reading(state: .noInput)
        timecodeLevel = 0
    }

    func setDevice(_ uid: String?) {
        guard uid != deviceUID else { return }
        stopInput()
        deviceUID = uid
        UserDefaults.standard.set(uid, forKey: TimecodeStation.deviceKey)
        problem = nil
        start()
    }

    func setChannel(_ channel: Int) {
        self.channel = channel
        UserDefaults.standard.set(channel, forKey: TimecodeStation.channelKey)
        reader?.setChannel(channel)
    }

    func setOffset(_ frames: Int) {
        offsetFrames = min(max(frames, TimecodeStation.offsetRange.lowerBound), TimecodeStation.offsetRange.upperBound)
        UserDefaults.standard.set(offsetFrames, forKey: TimecodeStation.offsetKey)
    }

    func setFollows(_ on: Bool) {
        follows = on
        UserDefaults.standard.set(on, forKey: TimecodeStation.followKey)

        follow = TimecodeFollow()
    }

    func retry() {
        if reader == nil { start() }
    }

    private func tick() {
        guard let reader else { return }
        let (heard, peak) = reader.drain()
        for frame in heard {
            clock.receive(frame.frame, rate: frame.rate, hostTime: frame.hostTime)
        }
        var reading = clock.reading(at: CACurrentMediaTime())
        if let rate = reading.rate, let position = reading.position {
            reading.position = position + Double(offsetFrames) / rate.actual
            if detectedRate != rate { detectedRate = rate }
        }
        if reading != timecodeReading { timecodeReading = reading }
        let level = max(peak, timecodeLevel * 0.85)
        if abs(level - timecodeLevel) > 0.002 { timecodeLevel = level < 0.001 ? 0 : level }
        guard follows, reading.live, let controls else { return }
        let songs = songs(controls.appModel)
        if let command = follow.step(reading, songs: songs.map(\.song)),
           let item = songs.first(where: { $0.song.itemID == command.itemID }) {
            if controls.timeline.itemID != command.itemID { revealPending = command.itemID }
            controls.timeline.follow(
                command, itemID: item.song.itemID, presentation: item.presentation, arrangementId: item.arrangementId)
        }

        if let pending = revealPending, controls.liveContextID == pending {
            revealPending = nil
            controls.noteKeyboardFire()
        }
    }

    private func songs(_ model: AppModel) -> [(song: TimecodeFollow.Song, presentation: Presentation, arrangementId: String?)] {
        guard let serviceID = model.currentServiceID, let service = try? model.service(serviceID) else { return [] }
        return model.runOfShow(service).compactMap { item in
            guard item.itemKind == .presentation, let deck = model.presentation(item.refId),
                  let timeline = PresentationTimelines.timeline(for: item.arrangementId, in: deck),
                  timeline.timecodeEnabled
            else { return nil }
            return (TimecodeFollow.Song(itemID: item.id, timeline: timeline), deck, item.arrangementId)
        }
    }
}

struct TimecodeInputControl: View {
    let follower: TimecodeFollower
    @State private var devices: [AudioDeviceList.AudioInputDevice] = []

    var body: some View {
        let uid = follower.deviceUID ?? ""
        let device = devices.first { $0.uid == uid }
        HStack(spacing: 8) {
            if follower.problem != nil {
                Text("Not connected").foregroundStyle(.orange)
            }
            Picker("", selection: Binding(get: { uid }, set: { follower.setDevice($0.isEmpty ? nil : $0) })) {
                Text("None").tag("")
                ForEach(devices, id: \.uid) { Text($0.name).tag($0.uid) }
                if !uid.isEmpty, device == nil {
                    Text("Device (not connected)").tag(uid)
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
                if let uid = follower.deviceUID, devices.contains(where: { $0.uid == uid }) { follower.retry() }
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

struct TimecodeStatusChip: View {
    let follower: TimecodeFollower
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        let reading = follower.timecodeReading
        let status = TimecodeFollower.status(reading, follows: follower.follows)
        Button {
            SettingsRouter.shared.pending = .midi
            openSettings()
        } label: {
            HStack(spacing: 5) {
                Circle().fill(status.color).frame(width: 6, height: 6)
                Text(reading.label?.text(dropFrame: reading.rate == .fps2997DropFrame) ?? "Timecode")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text(status.word)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(status.color)
                    .frame(width: 44, alignment: .leading)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help("Timecode: \(status.word). Settings › Connections")
        .accessibilityLabel("Timecode \(status.word)")
    }
}
