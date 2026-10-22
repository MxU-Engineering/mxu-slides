import AudioEngine
import Foundation
import PresenterCore
import RenderEngine

@MainActor
final class TracksController {
    weak var model: AppModel?
    weak var mixer: AudioMixerController?
    private let client: TracksPlayerClient

    nonisolated let latest = Locked<TracksPlayerStatus?>(nil)

    private let driving = Locked<String?>(nil)

    private let awaitingStatus = Locked(false)
    private var sentRouting: MultitrackRouting?
    private var sentDevice: String??
    private var refreshQueued = false

    private var songChannels: Set<String> = []

    var onFoundPlaying: ((TracksPlayerStatus) -> Void)?

    nonisolated static let playerName = "MxU Tracks Player"

    init() {
        let path = TracksPlayerWire.socketPath(appIdentity: Bundle.main.bundleIdentifier ?? "io.prodcontrol.mxupresenter")
        client = TracksPlayerClient(socketPath: path) { Self.launchPlayer(socketPath: path) }
        let latest = latest, driving = driving, awaiting = awaitingStatus
        client.onStatus = { [weak self] status in
            latest.value = status
            if awaiting.withLock({ let was = $0; $0 = false; return was }) {
                Task { @MainActor in
                    self?.songChannels.formUnion(status.channels ?? [])
                    self?.resend()
                }
            }

            if status.playing, let song = status.songID, driving.value == nil {
                driving.value = song
                Task { @MainActor in self?.onFoundPlaying?(status) }
            }
        }
        client.onConnect = { awaiting.value = true }
        client.onDisconnect = { latest.value = nil }

        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.queueRefresh() }
        }
    }

    func start() {
        client.reattach()
    }

    func quit() {
        guard client.isConnected else { return }
        client.send(.quit)
    }

    nonisolated static func launchPlayer(socketPath: String) {
        guard let url = Bundle.main.url(forAuxiliaryExecutable: playerName) else {
            DiagnosticsStore.shared.note("tracks.launchFailed", detail: "no \(playerName) in the bundle")
            return
        }
        let process = Process()
        process.executableURL = url
        process.arguments = ["--socket", socketPath]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            DiagnosticsStore.shared.note("tracks.launch", detail: "pid \(process.processIdentifier)")
        } catch {
            DiagnosticsStore.shared.note("tracks.launchFailed", detail: "\(error)")
        }
    }

    func play(_ song: MultitrackSong, from position: Double) {
        driving.value = song.id
        songChannels = Set(song.stems.map(\.channelId))
        refresh()
        client.send(.cue(song: song, at: position))
        client.send(.play(hostTime: 0))
        DiagnosticsStore.shared.note("tracks.play", detail: "\(song.stems.count) stems from \(String(format: "%.2f", position))")
    }

    func stop() {
        guard driving.value != nil else { return }
        client.send(.stop)
        DiagnosticsStore.shared.note("tracks.stop")
    }

    func seek(to position: Double) {
        client.send(.seek(seconds: position))
    }

    nonisolated func position(of songID: String) -> Double? {
        latest.withLock { status in
            guard let status, status.playing, status.songID == songID else { return nil }
            return status.position()
        }
    }

    nonisolated var isPlaying: Bool { latest.value?.playing == true }

    nonisolated var meters: [String: (rms: Float, peak: Float)] {
        (latest.value?.meters ?? [:]).compactMapValues { $0.count == 2 ? ($0[0], $0[1]) : nil }
    }

    nonisolated static func gain(_ id: String) -> Float {
        (UserDefaults.standard.object(forKey: "audio.track.\(id).gain") as? Float).map { min(max($0, 0), 1) } ?? 1
    }

    nonisolated static func pan(_ id: String) -> Float {
        (UserDefaults.standard.object(forKey: "audio.track.\(id).pan") as? Float).map { min(max($0, -1), 1) } ?? 0
    }

    nonisolated static func muted(_ id: String) -> Bool {
        UserDefaults.standard.bool(forKey: "audio.track.\(id).muted")
    }

    static func mixId(_ channel: TrackChannel) -> String? {
        if let stored = UserDefaults.standard.string(forKey: "audio.track.\(channel.id).mixId") {
            return stored.isEmpty ? nil : stored
        }
        return channel.trackRole == .music ? AudioMixInventory.mainID : nil
    }

    static func setMix(_ mixId: String?, for channel: String) {
        UserDefaults.standard.set(mixId ?? "", forKey: "audio.track.\(channel).mixId")
    }

    static func setGain(_ gain: Float, for channel: String) {
        UserDefaults.standard.set(min(max(gain, 0), 1), forKey: "audio.track.\(channel).gain")
    }

    static func setPan(_ pan: Float, for channel: String) {
        UserDefaults.standard.set(min(max(pan, -1), 1), forKey: "audio.track.\(channel).pan")
    }

    static func setMuted(_ muted: Bool, for channel: String) {
        UserDefaults.standard.set(muted, forKey: "audio.track.\(channel).muted")
    }

    nonisolated static var trim: Float {
        (UserDefaults.standard.object(forKey: "audio.tracks.gain") as? Float).map { min(max($0, 0), 1) } ?? 1
    }

    nonisolated static var trimMuted: Bool { UserDefaults.standard.bool(forKey: "audio.tracks.muted") }

    static func setTrim(_ gain: Float) { UserDefaults.standard.set(min(max(gain, 0), 1), forKey: "audio.tracks.gain") }

    static func setTrimMuted(_ muted: Bool) { UserDefaults.standard.set(muted, forKey: "audio.tracks.muted") }

    private func seedSends(_ channels: [TrackChannel]) {
        for channel in channels where channel.trackRole != .music {
            let key = "audio.channel.track:\(channel.id).sends"
            guard UserDefaults.standard.object(forKey: key) == nil,
                  let data = try? JSONEncoder().encode([AudioMixInventory.mainID: Float(0)]) else { continue }
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private func queueRefresh() {
        guard !refreshQueued else { return }
        refreshQueued = true
        DispatchQueue.main.async { [weak self] in
            self?.refreshQueued = false
            self?.refresh()
        }
    }

    func refresh() {
        guard let model, let mixer else { return }
        let channels = model.trackChannels
        seedSends(channels)
        let resolved = Self.routing(channels: channels, extra: heardChannels(), mixer: mixer)
        guard client.isConnected || driving.value != nil else { return }
        if sentDevice != .some(resolved.deviceUID) {
            sentDevice = .some(resolved.deviceUID)
            client.send(.attach(deviceUID: resolved.deviceUID))
        }
        if sentRouting != resolved.routing {
            sentRouting = resolved.routing
            client.send(.routing(resolved.routing))
        }
    }

    private func resend() {
        sentRouting = nil
        sentDevice = nil
        refresh()
    }

    private func heardChannels() -> Set<String> {
        songChannels.union(latest.value?.channels ?? [])
    }

    static func routing(
        channels: [TrackChannel], extra: Set<String> = [], mixer: AudioMixerController
    ) -> (routing: MultitrackRouting, deviceUID: String?) {
        let defaultUID = AudioDeviceList.defaultOutputDevice()?.uid ?? ""
        let devices = AudioDeviceList.outputDevices()
        let known = Set(channels.map(\.id))
        let all = channels + extra.subtracting(known).sorted().map { TrackChannel(id: $0, name: $0) }
        let trackChannels = all.map { channel -> MultitrackRouting.Channel in
            var sends = mixer.channelSends("track:\(channel.id)")
            if let route = mixId(channel) { sends[route] = 1 }
            return .init(
                id: channel.id, gain: gain(channel.id), pan: pan(channel.id), muted: muted(channel.id), sends: sends,
                mono: channel.mono == true)
        }
        let mixes = AudioMixInventory.shared.entries.map { mix -> MultitrackRouting.ConsoleMix in
            var landings: [(deviceUID: String, output: MultitrackRouting.Output)] = []
            if !AudioMixInventory.isVirtual(mix.outputIds) {
                let ids: [String?] = mix.outputIds.isEmpty ? [nil] : mix.outputIds.map { $0 == AudioMixInventory.defaultOutputID ? nil : $0 }
                for (index, id) in ids.enumerated() {
                    let entry = id.flatMap { AudioOutputInventory.shared.entry(id: $0) }
                    if entry?.isDeviceless == true || AudioController.outputMuted(id) { continue }
                    let uid = entry?.deviceUID ?? defaultUID
                    let count = max(2, devices.first { $0.uid == uid }?.channelCount ?? 2)
                    let offset = entry?.channelOffset ?? 0
                    let pair = offset >= 0 && offset + 1 < count ? offset : 0
                    let channels = entry?.monoChannel.flatMap { $0 < count ? [$0] : nil } ?? [pair, pair + 1]
                    let send = index == 0 ? 1 : (id.map { mixer.sendLevel(mixId: mix.id, outputId: $0) } ?? 1)
                    landings.append((uid, .init(channels: channels, level: send * AudioController.outputTrim(id))))
                }
            }
            return .init(
                id: mix.id,
                gain: (UserDefaults.standard.object(forKey: "audio.mix.\(mix.id).gain") as? Float).map { min(max($0, 0), 1) } ?? 1,
                muted: UserDefaults.standard.bool(forKey: "audio.mix.\(mix.id).muted"),
                landings: landings)
        }
        let resolved = MultitrackRouting.resolve(
            channels: trackChannels, mixes: mixes, trim: trim, muted: trimMuted, fallbackDevice: defaultUID)
        return (resolved.routing, resolved.deviceUID.isEmpty ? nil : resolved.deviceUID)
    }
}
