import AVFoundation
import AudioEngine
import Foundation
import PresenterCore
import QuartzCore
import RenderEngine

@MainActor
final class TracksController {
    weak var model: AppModel?
    weak var mixer: AudioMixerController? {
        didSet {
            let mixer = mixer
            shareSink.value = { [weak mixer] mixId, buffer in mixer?.pushTracksShare(mixId: mixId, buffer: buffer) }
        }
    }
    private let client: TracksPlayerClient

    private nonisolated let shareFeeder = Locked<TracksShareFeeder?>(nil)
    private nonisolated let slotMixes = Locked<[Int: String]>([:])
    private nonisolated let shareSink = Locked<(@Sendable (String, AVAudioPCMBuffer) -> Void)?>(nil)

    private nonisolated let lostAt = Locked<CFTimeInterval?>(nil)

    private var feedSlots: [String: Int] = [:]

    private var preloaded: [MultitrackSong] = []

    nonisolated let latest = Locked<TracksPlayerStatus?>(nil)

    private let driving = Locked<String?>(nil)

    private let awaitingStatus = Locked(false)
    private var sentRouting: MultitrackRouting?
    private var sentDevice: String??
    private var refreshQueued = false

    private var songChannels: Set<String> = []

    var onFoundPlaying: ((TracksPlayerStatus) -> Void)?

    nonisolated static let playerName = "MxU Tracks Player"

    var hasTracks: Bool { TimelineTracks.hasTracks(model?.trackChannels ?? []) }

    nonisolated static var busIDs: Set<String> {
        Set(TimelineTracks.Family.allCases.compactMap {
            UserDefaults.standard.string(forKey: "audio.tracks.bus.\($0.rawValue)")
        })
    }

    init() {
        let path = TracksPlayerWire.socketPath(appIdentity: Bundle.main.bundleIdentifier ?? "io.prodcontrol.mxupresenter")
        client = TracksPlayerClient(socketPath: path) { Self.launchPlayer(socketPath: path) }
        let latest = latest, driving = driving, awaiting = awaitingStatus
        let feeder = shareFeeder, slots = slotMixes, sink = shareSink, lost = lostAt
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

        client.onConnect = {
            awaiting.value = true
            lost.value = nil

            let share = TracksShare.open(name: TracksPlayerWire.shareName(socketPath: path))
            feeder.withLock { held in
                held?.stop()
                held = share.map { share in
                    TracksShareFeeder(share: share) { slot, buffer in
                        guard let mix = slots.value[slot] else { return }
                        sink.value?(mix, buffer)
                    }
                }
            }
            DiagnosticsStore.shared.note("tracks.connect", detail: share == nil ? "no mix shares (an older player)" : "")
        }
        client.onDisconnect = { reason in
            feeder.withLock { $0?.stop(); $0 = nil }
            let status = latest.value
            latest.value = nil
            lost.value = CACurrentMediaTime()
            Self.noteDisconnect(reason: reason, status: status)
        }

        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: nil
        ) { [weak self] _ in
            Task { @MainActor in self?.queueRefresh() }
        }
    }

    func start() {
        client.reattach()
    }

    func quit() {
        guard client.isConnected else { return }
        client.send(.quit)
    }

    private nonisolated static func noteDisconnect(reason: String, status: TracksPlayerStatus?) {
        var detail = reason
        if let status { detail += ", while \(status.playing ? "playing" : "stopped")" }
        let pid = status?.pid
        if let pid { detail += kill(pid, 0) == 0 ? ", player \(pid) still running" : ", player \(pid) gone" }
        DiagnosticsStore.shared.note("tracks.disconnect", detail: detail)
        guard let pid, kill(pid, 0) != 0 else { return }
        let lost = Date()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5) {
            let reports = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Logs/DiagnosticReports")
            let newest = (try? FileManager.default.contentsOfDirectory(
                at: reports, includingPropertiesForKeys: [.contentModificationDateKey]))?
                .filter { $0.lastPathComponent.hasPrefix(playerName) }
                .compactMap { url in
                    (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                        .map { (url.lastPathComponent, $0) }
                }
                .filter { $0.1 >= lost.addingTimeInterval(-10) }
                .max { $0.1 < $1.1 }
            DiagnosticsStore.shared.note("tracks.playerCrash", detail: newest?.0 ?? "no crash report")
        }
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

    func cueAhead(_ songs: [MultitrackSong]) {
        guard hasTracks, songs != preloaded else { return }
        preloaded = songs
        client.send(.preload(songs: songs))
        DiagnosticsStore.shared.note("tracks.cueAhead", detail: songs.map(\.id).joined(separator: ", "))
    }

    nonisolated func position(of songID: String) -> Double? {
        latest.withLock { status in
            guard let status, status.playing, status.songID == songID else { return nil }
            return status.position()
        }
    }

    nonisolated var isPlaying: Bool { latest.value?.playing == true }

    nonisolated var reattaching: Bool { lostAt.value.map { CACurrentMediaTime() - $0 < 1.2 } ?? false }

    nonisolated var meters: [String: [AudioLevel.Reading]] {
        (latest.value?.meters ?? [:]).compactMapValues { values in
            switch values.count {
            case 4: [(values[0], values[1]), (values[2], values[3])]
            case 2: [(values[0], values[1]), (values[0], values[1])]
            default: nil
            }
        }
    }

    nonisolated static func gain(_ id: String) -> Float {
        (UserDefaults.standard.object(forKey: "audio.track.\(id).gain") as? Float).map { min(max($0, 0), 1) } ?? 1
    }

    nonisolated static func pan(_ id: String) -> Float {
        (UserDefaults.standard.object(forKey: "audio.track.\(id).pan") as? Float).map { min(max($0, -1), 1) } ?? 0
    }

    nonisolated static func soloKey(_ id: String) -> String { "audio.track.\(id).solo" }

    nonisolated static func muted(_ id: String) -> Bool {
        UserDefaults.standard.bool(forKey: "audio.track.\(id).muted")
    }

    static func mixId(_ channel: TrackChannel) -> String? {
        if let stored = UserDefaults.standard.string(forKey: "audio.track.\(channel.id).mixId") {
            return stored.isEmpty ? nil : stored
        }

        return channel.trackRole == .music && !UserDefaults.standard.bool(forKey: offMainKey) ? AudioMixInventory.mainID : nil
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
        for channel in channels {
            let seeded = "audio.track.\(channel.id).busSeeded"
            guard !UserDefaults.standard.bool(forKey: seeded) else { continue }
            let key = "audio.channel.track:\(channel.id).sends"
            var sends = mixer?.channelSends("track:\(channel.id)") ?? [:]
            sends[Self.familyBus(TimelineTracks.family(of: channel)).id] = 1
            if channel.trackRole != .music, sends[AudioMixInventory.mainID] == nil {
                sends[AudioMixInventory.mainID] = 0
            }
            if let data = try? JSONEncoder().encode(sends) { UserDefaults.standard.set(data, forKey: key) }
            UserDefaults.standard.set(true, forKey: seeded)
        }
    }

    static func familyBus(_ family: TimelineTracks.Family) -> AudioMixInventory.Entry {
        let inventory = AudioMixInventory.shared
        let key = "audio.tracks.bus.\(family.rawValue)"
        if let id = UserDefaults.standard.string(forKey: key), let mix = inventory.entry(id: id) { return mix }
        let folder = inventory.folder(named: "Tracks")
        let made = inventory.create(name: family.name)
        inventory.setPrimary(mixId: made.id, token: AudioMixInventory.noOutputID)
        inventory.move(made.id, toFolder: folder.id)
        UserDefaults.standard.set(made.id, forKey: key)
        return inventory.entry(id: made.id) ?? made
    }

    static func musicOnMain(_ channels: [TrackChannel]) -> Bool {
        let music = channels.filter { $0.trackRole == .music }
        guard !music.isEmpty else { return !UserDefaults.standard.bool(forKey: offMainKey) }
        return music.contains { mixId($0) == AudioMixInventory.mainID }
    }

    static let offMainKey = "tracks.offMain"

    static func existingBus(_ family: TimelineTracks.Family) -> AudioMixInventory.Entry? {
        UserDefaults.standard.string(forKey: "audio.tracks.bus.\(family.rawValue)")
            .flatMap { AudioMixInventory.shared.entry(id: $0) }
    }

    static func fedMixIDs(_ channels: [TrackChannel], mixer: AudioMixerController) -> Set<String> {
        var fed: Set<String> = []
        for channel in channels {
            if let route = mixId(channel) { fed.insert(route) }
            fed.formUnion(mixer.channelSends("track:\(channel.id)").filter { $0.value > 0 }.keys)
        }
        return fed
    }

    static func setMusicOnMain(_ on: Bool, _ channels: [TrackChannel]) {
        UserDefaults.standard.set(!on, forKey: offMainKey)
        for channel in channels where channel.trackRole == .music {
            let route = mixId(channel)
            if on, route == nil { setMix(AudioMixInventory.mainID, for: channel.id) }
            if !on, route == AudioMixInventory.mainID { setMix(nil, for: channel.id) }
        }
    }

    func queueRefresh() {
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

        let hasTracks = TimelineTracks.hasTracks(channels)
        if hasTracks {
            for family in TimelineTracks.Family.allCases { _ = Self.familyBus(family) }
            seedSends(channels)
        }
        let resolved = Self.routing(channels: channels, extra: heardChannels(), mixer: mixer)

        let reach = hasTracks ? resolved.routing.reachedMixIds : []
        let replays = Self.replays(reach: reach, tracksDevice: resolved.deviceUID)
        mixer.setTracks(deviceUID: resolved.deviceUID, reach: reach, replays: replays)
        let fed = mixer.tracksFeedMixIDs.intersection(reach).union(replays.keys)
        feedSlots = MultitrackRouting.assignSlots(fed, held: feedSlots)
        let routing = resolved.routing.feeding(fed, slots: feedSlots)
        slotMixes.value = Dictionary(feedSlots.filter { fed.contains($0.key) }.map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        guard client.isConnected || driving.value != nil else { return }
        if sentDevice != .some(resolved.deviceUID) {
            sentDevice = .some(resolved.deviceUID)
            client.send(.attach(deviceUID: resolved.deviceUID))
        }
        if sentRouting != routing {
            sentRouting = routing
            client.send(.routing(routing))
        }
    }

    private func resend() {
        sentRouting = nil
        sentDevice = nil
        refresh()

        if !preloaded.isEmpty { client.send(.preload(songs: preloaded)) }
    }

    static func replays(reach: Set<String>, tracksDevice: String?) -> [String: String?] {
        let defaultUID = AudioDeviceList.defaultOutputDevice()?.uid
        var replays: [String: String?] = [:]
        for mix in AudioMixInventory.shared.entries where reach.contains(mix.id) && !AudioMixInventory.isVirtual(mix.outputIds) {
            let first = mix.outputIds.first.flatMap { $0 == AudioMixInventory.defaultOutputID ? nil : $0 }
            let entry = first.flatMap { AudioOutputInventory.shared.entry(id: $0) }
            if entry?.isDeviceless == true { continue }
            if (entry?.deviceUID ?? defaultUID) != (tracksDevice ?? defaultUID) { replays[mix.id] = .some(first) }
        }
        return replays
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
        let quiet = TimelineTracks.silencedBySolo(
            all, soloed: Set(all.map(\.id).filter { UserDefaults.standard.bool(forKey: soloKey($0)) }))
        let trackChannels = all.map { channel -> MultitrackRouting.Channel in
            var sends = mixer.channelSends("track:\(channel.id)")
            if let route = mixId(channel) { sends[route] = 1 }
            return .init(
                id: channel.id, gain: gain(channel.id), pan: pan(channel.id),
                muted: muted(channel.id) || quiet.contains(channel.id), sends: sends,
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
                    landings.append((uid, .init(
                        channels: channels, level: send * AudioController.outputTrim(id),
                        delayMs: Double(entry?.delayMs ?? 0))))
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

extension TracksController {

    @discardableResult
    func addChannel(named name: String) -> TrackChannel? {
        guard let model else { return nil }
        var preview = model.trackChannels
        guard let made = TimelineTracks.adding(named: name, to: &preview) else { return nil }
        model.updateTrackChannels { $0.channels.insert(made, at: TimelineTracks.insertionIndex(for: made, in: $0.channels)) }
        refresh()
        return made
    }

    func editChannel(_ id: String, _ change: @escaping @Sendable (inout TrackChannel) -> Void) {
        guard let model, let mixer, let old = model.trackChannels.first(where: { $0.id == id }) else { return }
        var new = old
        change(&new)
        guard new != old else { return }
        model.updateTrackChannels { list in
            if let index = list.channels.firstIndex(where: { $0.id == id }) { change(&list.channels[index]) }
        }
        let routeKey = "audio.track.\(id).mixId"
        let sends = mixer.channelSends("track:\(id)")
        let edited = TimelineTracks.edited(
            sends: sends, route: UserDefaults.standard.string(forKey: routeKey), from: old, to: new,
            bus: { Self.existingBus($0)?.id }, main: AudioMixInventory.mainID)
        for mix in Set(sends.keys).union(edited.sends.keys) where sends[mix] != edited.sends[mix] {
            mixer.setChannelSend("track:\(id)", mixId: mix, gain: edited.sends[mix])
        }
        if let route = edited.route { UserDefaults.standard.set(route, forKey: routeKey) }
        DiagnosticsStore.shared.note("tracks.channel.edit", detail: "\(old.name) → \(new.name), \(new.trackRole)")
        refresh()
    }

    func moveChannel(_ id: String, before: String?) {
        guard let model, let move = TimelineTracks.move(id, before: before, in: model.trackChannels) else { return }
        model.moveTrackChannel(id, before: before, next: move.next)
        DiagnosticsStore.shared.note("tracks.channel.move", detail: "\(move.from) → before \(before ?? "end")")
        refresh()
    }

    func deleteChannel(_ id: String) {
        guard let model else { return }
        let name = model.trackChannels.first { $0.id == id }?.name ?? id
        model.updateTrackChannels { $0.channels.removeAll { $0.id == id } }
        DiagnosticsStore.shared.note("tracks.channel.delete", detail: name)
        refresh()
    }
}
