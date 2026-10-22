import AVFoundation
import AudioEngine
import Foundation
import Observation
import RenderEngine

@MainActor
@Observable
final class AudioMixerController {
    private let audio: AudioController
    private let videoInputs: VideoInputInventory
    private let audioInputs: AudioInputInventory

    private var playthroughs: [String: AudioInputPlaythrough] = [:]

    private var feedTokens: [String: UUID] = [:]

    private(set) var liveVideoInputIds: Set<String> = []

    private let inputLevels = Locked<[String: LevelWindow]>([:])

    private let videoLevels = Locked(LevelWindow())

    static let videoMeterKey = "video"

    static let tracksMeterKey = "tracks"

    weak var tracks: TracksController?

    private var meterTokens: [String: UUID] = [:]

    private(set) var displayLevels: [String: [MeterBallistics]] = [:]

    private(set) var busLevels: [String: [MeterBallistics]] = [:]

    private(set) var playerLevels: [String: [MeterBallistics]] = [:]

    private(set) var outputLevels: [String: [MeterBallistics]] = [:]
    private var meteringRefCount = 0
    private var lastMeterTick: Date?

    init(
        audio: AudioController,
        videoInputs: VideoInputInventory = .shared,
        audioInputs: AudioInputInventory = .shared
    ) {
        self.audio = audio
        self.videoInputs = videoInputs
        self.audioInputs = audioInputs

        audio.onRoutingChanged = { [weak self] in
            self?.reapplyRouting()
            self?.syncPlaythroughs()
            self?.syncMixFeeds()
        }
        audio.onMixLevelsChanged = { [weak self] in self?.reapplyInputLevels() }
        audio.onPlayersChanged = { [weak self] in self?.syncMixFeeds() }
        audioInputs.onEntriesChanged = { [weak self] in
            self?.syncPlaythroughs()
            self?.syncMixFeeds()
        }
        videoInputs.onEntriesChanged = { [weak self] in self?.syncPlaythroughs() }

        AudioInputHubPool.shared.trimProvider = { uid in
            (Self.deviceTrim(uid), Self.deviceMuted(uid))
        }
        Self.current = self
    }

    nonisolated static func deviceTrim(_ uid: String) -> Float {
        guard let stored = UserDefaults.standard.object(
            forKey: "audio.device.\(uid).gain") as? Float else { return 1 }
        return min(max(stored, 0), 1)
    }

    nonisolated static func deviceMuted(_ uid: String) -> Bool {
        UserDefaults.standard.bool(forKey: "audio.device.\(uid).muted")
    }

    func setDeviceTrim(_ gain: Float, uid: String) {
        UserDefaults.standard.set(
            min(max(gain, 0), 1), forKey: "audio.device.\(uid).gain")
    }

    func setDeviceMuted(_ muted: Bool, uid: String) {
        UserDefaults.standard.set(muted, forKey: "audio.device.\(uid).muted")
    }

    static weak var current: AudioMixerController?

    func gain(forInput id: String) -> Float {
        guard let stored = UserDefaults.standard.object(
            forKey: "audio.input.\(id).gain") as? Float else { return 1 }
        return min(max(stored, 0), 1)
    }

    func setGain(_ gain: Float, forInput id: String) {
        let clamped = min(max(gain, 0), 1)
        UserDefaults.standard.set(clamped, forKey: "audio.input.\(id).gain")
        applyLevels(toInput: id)
        syncMixFeeds()
    }

    func pan(forInput id: String) -> Float {
        guard let stored = UserDefaults.standard.object(
            forKey: "audio.input.\(id).pan") as? Float else { return 0 }
        return min(max(stored, -1), 1)
    }

    func setPan(_ pan: Float, forInput id: String) {
        UserDefaults.standard.set(
            min(max(pan, -1), 1), forKey: "audio.input.\(id).pan")

        applyLevels(toInput: id)
        syncMixFeeds()
    }

    func isMuted(input id: String) -> Bool {
        UserDefaults.standard.bool(forKey: "audio.input.\(id).muted")
    }

    func setMuted(_ muted: Bool, forInput id: String) {
        UserDefaults.standard.set(muted, forKey: "audio.input.\(id).muted")
        applyLevels(toInput: id)
        syncMixFeeds()
    }

    func isManuallyEnabled(input id: String) -> Bool {
        UserDefaults.standard.bool(forKey: "audio.input.\(id).enabled")
    }

    func setManuallyEnabled(_ enabled: Bool, forInput id: String) {
        UserDefaults.standard.set(enabled, forKey: "audio.input.\(id).enabled")
        syncPlaythroughs()
    }

    func mixId(forInput id: String) -> String {
        UserDefaults.standard.string(forKey: "audio.input.\(id).mixId")
            ?? AudioMixInventory.mainID
    }

    func setMix(forInput id: String, mixId: String) {
        let key = "audio.input.\(id).mixId"
        if mixId == AudioMixInventory.mainID {
            UserDefaults.standard.removeObject(forKey: key)
        } else {
            UserDefaults.standard.set(mixId, forKey: key)
        }
        applyRouting(toInput: id)
        applyLevels(toInput: id)
        syncMixFeeds()
    }

    func isLive(input id: String) -> Bool {
        playthroughs[id] != nil
    }

    var anyInputLive: Bool {
        !playthroughs.isEmpty
    }

    func autoEnabledByVideoInput(_ id: String) -> Bool {
        videoInputs.entries.contains {
            $0.audioInputId == id && liveVideoInputIds.contains($0.id)
        }
    }

    func setLiveVideoInputs(_ ids: Set<String>) {
        guard ids != liveVideoInputIds else { return }
        liveVideoInputIds = ids
        syncPlaythroughs()
    }

    func enableInput(id: String) {
        guard audioInputs.entry(id: id) != nil else {
            DiagnosticsStore.shared.note("mixer", detail: "unknown audio input: \(id)")
            return
        }
        setManuallyEnabled(true, forInput: id)
    }

    func disableInput(id: String) {
        guard audioInputs.entry(id: id) != nil else {
            DiagnosticsStore.shared.note("mixer", detail: "unknown audio input: \(id)")
            return
        }
        setManuallyEnabled(false, forInput: id)
    }

    func syncPlaythroughs() {
        var shouldBeLive: Set<String> = []
        for entry in audioInputs.entries {
            if isManuallyEnabled(input: entry.id) || autoEnabledByVideoInput(entry.id) {
                shouldBeLive.insert(entry.id)
            }
        }
        for id in Set(playthroughs.keys).subtracting(shouldBeLive) {
            stopPlaythrough(id: id)
        }
        for id in shouldBeLive.subtracting(playthroughs.keys) {
            startPlaythrough(id: id)
        }
    }

    private func startPlaythrough(id: String) {
        guard playthroughs[id] == nil,
              let source = audioInputs.source(forId: id), source.isRunning
        else { return }
        let playthrough = AudioInputPlaythrough()
        do {
            try playthrough.start()
        } catch {
            DiagnosticsStore.shared.note(
                "mixer", detail: "playout start failed for \(name(of: id)): \(error)")
            return
        }
        playthroughs[id] = playthrough
        applyRouting(toInput: id)
        applyLevels(toInput: id)
        feedTokens[id] = source.addConsumer { [weak playthrough] buffer, _, _ in
            playthrough?.push(buffer)
        }
        DiagnosticsStore.shared.note("mixer", detail: "on air: \(name(of: id))")
    }

    private func stopPlaythrough(id: String) {
        if let token = feedTokens.removeValue(forKey: id) {
            audioInputs.source(forId: id)?.removeConsumer(token)
        }
        playthroughs.removeValue(forKey: id)?.stop()
        DiagnosticsStore.shared.note("mixer", detail: "off air: \(name(of: id))")
    }

    private func applyRouting(toInput id: String) {
        guard let playthrough = playthroughs[id] else { return }
        let mix = audio.mixes.entry(id: mixId(forInput: id)) ?? audio.mixes.main
        applyOutput(mix.outputIds.first, to: playthrough)
    }

    private func applyOutput(_ outputId: String?, to playthrough: AudioInputPlaythrough) {
        let output = outputId.flatMap { AudioOutputInventory.shared.entry(id: $0) }
        let devices = AudioDeviceList.outputDevices()
        let device = output?.deviceUID.flatMap { uid in devices.first { $0.uid == uid } }
        if let mono = output?.monoChannel, mono >= 0, mono < max(2, device?.channelCount ?? 2) {
            try? playthrough.setOutputDevice(device, channelOffset: mono, mono: true)
        } else {
            let offset = output?.channelOffset ?? 0
            let clamped = (offset >= 0 && offset + 1 < max(2, device?.channelCount ?? 2))
                ? offset : 0
            try? playthrough.setOutputDevice(device, channelOffset: clamped)
        }
        playthrough.outputDelayMilliseconds = Double(output?.delayMs ?? 0)
    }

    func reapplyRouting() {
        for id in playthroughs.keys {
            applyRouting(toInput: id)
            applyLevels(toInput: id)
        }
        for mixId in tracksReplays.keys { applyTracksReplay(mixId) }
    }

    private func applyLevels(toInput id: String) {
        guard let playthrough = playthroughs[id] else { return }
        playthrough.pan = pan(forInput: id)
        let mix = mixId(forInput: id)
        let outputIds = audio.mixes.entry(id: mix)?.outputIds ?? []

        if AudioMixInventory.isVirtual(outputIds)
            || AudioOutputInventory.shared.isDeviceless(outputIds.first) {
            playthrough.gain = 0
            playthrough.isMuted = true
            return
        }
        let outputId = outputIds.first
        playthrough.gain = audio.mixGain(mix) * gain(forInput: id)
            * AudioController.outputTrim(outputId)
        playthrough.isMuted = isMuted(input: id) || audio.mixMuted(mix)
            || AudioController.outputMuted(outputId)
    }

    func outputGain(_ outputId: String) -> Float { AudioController.outputTrim(outputId) }
    func outputMuted(_ outputId: String) -> Bool { AudioController.outputMuteSetting(outputId) }

    func setMonitorTakeover(deviceUID: String?, active: Bool) {
        let silenced = active
            ? MonitorTakeover.silencedOutputs(
                outputs: AudioOutputInventory.shared.entries.map { (id: $0.id, deviceUID: $0.deviceUID) },
                monitorDeviceUID: deviceUID,
                systemDefaultUID: AudioDeviceList.defaultOutputDevice()?.uid,
                silentUID: AudioOutputInventory.noDeviceUID)
            : []
        if AudioController.monitorSilencedOutputs.value != silenced {
            AudioController.monitorSilencedOutputs.value = silenced
            let names = AudioOutputInventory.shared.entries.filter { silenced.contains($0.id) }.map(\.name)
            DiagnosticsStore.shared.note(
                "syncMonitor.takeover",
                detail: silenced.isEmpty ? "released" : "silenced: \(names.joined(separator: ", "))")
            refreshOutputLevels()
        }
    }

    func setOutputGain(_ gain: Float, outputId: String) {
        UserDefaults.standard.set(
            min(max(gain, 0), 1), forKey: "audio.output.\(outputId).gain")
        refreshOutputLevels()
    }

    func setOutputMuted(_ muted: Bool, outputId: String) {
        UserDefaults.standard.set(muted, forKey: "audio.output.\(outputId).muted")
        refreshOutputLevels()
    }

    private func refreshOutputLevels() {
        audio.reapplyAllMixLevels()
        reapplyInputLevels()
        for (key, playthrough) in sendPlaythroughs {
            let parts = key.split(separator: "|")
            let mixId = String(parts[0]); let outputId = String(parts[1])
            playthrough.gain = sendLevel(mixId: mixId, outputId: outputId)
                * AudioController.outputTrim(outputId)
            playthrough.isMuted = AudioController.outputMuted(outputId)
                || AudioOutputInventory.shared.isDeviceless(outputId)
        }
        for mixId in tracksReplays.keys { applyTracksReplay(mixId) }
        syncingFeeds = false
        syncMixFeeds()
    }

    func reapplyInputLevels() {
        for id in playthroughs.keys { applyLevels(toInput: id) }

        syncingFeeds = false
        syncMixFeeds()
    }

    private func name(of id: String) -> String {
        audioInputs.name(forId: id) ?? id
    }

    private final class FeedHub: @unchecked Sendable {
        let consumers = Locked<[UUID: AudioMixFeed.Consumer]>([:])

        let dryConsumers = Locked<[UUID: AudioMixFeed.Consumer]>([:])
        var feed: AudioMixFeed?
    }

    private var feedHubs: [String: FeedHub] = [:]

    func addFeedConsumer(
        mixId: String, withoutTracks: Bool = false, consumer: @escaping AudioMixFeed.Consumer
    ) -> UUID {
        let token = UUID()
        let hub = feedHubs[mixId] ?? {
            let hub = FeedHub()
            hub.feed = AudioMixFeed { [weak hub] buffer, when, host in
                guard let hub else { return }
                for consumer in hub.consumers.withLock({ Array($0.values) }) {
                    consumer(buffer, when, host)
                }
            }
            feedHubs[mixId] = hub
            return hub
        }()
        if withoutTracks {
            hub.dryConsumers.withLock { $0[token] = consumer }
            hub.feed?.setPartialConsumer(excluding: Self.tracksFeedMember) { [weak hub] buffer, when, host in
                guard let hub else { return }
                for consumer in hub.dryConsumers.withLock({ Array($0.values) }) {
                    consumer(buffer, when, host)
                }
            }
        } else {
            hub.consumers.withLock { $0[token] = consumer }
        }
        if !syncingFeeds { syncMixFeeds() }
        rebuildTracksSinks()
        tracks?.queueRefresh()
        DiagnosticsStore.shared.note("mixer", detail: "mix feed open: \(mixName(mixId))")
        return token
    }

    func feedBacklogMilliseconds(mixId: String) -> Double? {
        feedHubs[mixId]?.feed?.backlogMilliseconds
    }

    var feedTrimmedMilliseconds: Double {
        feedHubs.values.compactMap { $0.feed?.trimmedMilliseconds }.reduce(0, +)
    }

    var worstFeedBacklogMilliseconds: Double? {
        feedHubs.values.compactMap { $0.feed?.backlogMilliseconds }.max()
    }

    func removeFeedConsumer(mixId: String, token: UUID) {
        guard let hub = feedHubs[mixId] else { return }
        let dryLeft = hub.dryConsumers.withLock { consumers -> Bool in
            consumers.removeValue(forKey: token)
            return !consumers.isEmpty
        }
        if !dryLeft { hub.feed?.setPartialConsumer(excluding: Self.tracksFeedMember, nil) }
        let empty = hub.consumers.withLock { consumers -> Bool in
            consumers.removeValue(forKey: token)
            return consumers.isEmpty
        } && !dryLeft
        if empty {
            feedHubs.removeValue(forKey: mixId)
            DiagnosticsStore.shared.note("mixer", detail: "mix feed closed: \(mixName(mixId))")
        }
        if !syncingFeeds { syncMixFeeds() }
        rebuildTracksSinks()
        tracks?.queueRefresh()
    }

    nonisolated static let tracksFeedMember = "tracks"

    private var tracksDeviceUID: String?
    private var tracksReach: Set<String> = []

    private var tracksReplays: [String: (outputId: String?, playthrough: AudioInputPlaythrough)] = [:]
    private struct TracksSink {
        weak var feed: AudioMixFeed?
        weak var replay: AudioInputPlaythrough?
    }

    private nonisolated let tracksSinks = Locked<[String: TracksSink]>([:])

    var tracksFeedMixIDs: Set<String> {
        Set(feedHubs.filter { !$0.value.consumers.withLock { $0.isEmpty } }.keys)
    }

    func setTracks(deviceUID: String?, reach: Set<String>, replays: [String: String?]) {
        if deviceUID != tracksDeviceUID || reach != tracksReach {
            tracksDeviceUID = deviceUID
            tracksReach = reach
            syncMixFeeds()
        }
        for (mixId, held) in tracksReplays where replays[mixId].map({ $0 != held.outputId }) ?? true {
            held.playthrough.stop()
            tracksReplays.removeValue(forKey: mixId)
        }
        for (mixId, outputId) in replays where tracksReplays[mixId] == nil {
            let playthrough = AudioInputPlaythrough()
            guard (try? playthrough.start()) != nil else { continue }
            tracksReplays[mixId] = (outputId, playthrough)
            applyTracksReplay(mixId)
            DiagnosticsStore.shared.note("mixer", detail: "tracks replay: \(mixName(mixId))")
        }
        rebuildTracksSinks()
    }

    private func applyTracksReplay(_ mixId: String) {
        guard let replay = tracksReplays[mixId] else { return }
        applyOutput(replay.outputId, to: replay.playthrough)
        replay.playthrough.gain = AudioController.outputTrim(replay.outputId)
        replay.playthrough.isMuted = AudioController.outputMuted(replay.outputId)
            || AudioOutputInventory.shared.isDeviceless(replay.outputId)
    }

    private func rebuildTracksSinks() {
        var sinks: [String: TracksSink] = [:]
        for mixId in Set(feedHubs.keys).union(tracksReplays.keys) {
            sinks[mixId] = TracksSink(feed: feedHubs[mixId]?.feed, replay: tracksReplays[mixId]?.playthrough)
        }
        tracksSinks.value = sinks
    }

    nonisolated func pushTracksShare(mixId: String, buffer: AVAudioPCMBuffer) {
        guard let sink = tracksSinks.value[mixId] else { return }
        sink.feed?.push(member: Self.tracksFeedMember, buffer: buffer)
        sink.replay?.push(buffer)
    }

    private func deviceUID(ofOutput outputId: String) -> String? {
        AudioOutputInventory.shared.entry(id: outputId)?.deviceUID ?? AudioDeviceList.defaultOutputDevice()?.uid
    }

    func syncMixFeeds() {
        guard !syncingFeeds else { return }
        syncingFeeds = true
        defer { syncingFeeds = false }
        reconcileOutputSends()
        reconcileChannelSends()

        for player in audio.players {
            let hub = feedHubs[player.targetKey]
            let member = "bus-\(player.targetKey)"
            var sendSinks: [AudioInputPlaythrough] = []

            var hubPushes: [(hub: FeedHub, member: String, gain: Float, mixId: String)] = []
            if let playlistID = player.playlistID {
                for (mixId, sendGain) in channelSends("playlist:\(playlistID)") {
                    if let playthrough = channelSendPlaythroughs["playlist:\(playlistID)|\(mixId)"] {
                        sendSinks.append(playthrough)
                    }
                    if let sendHub = feedHubs[mixId] {
                        hubPushes.append((sendHub, "send-playlist-\(playlistID)", sendGain, mixId))
                    }
                }
            }
            if hub == nil, sendSinks.isEmpty, hubPushes.isEmpty {
                player.engine.setFeedConsumer(nil)
            } else {
                let sinks = sendSinks
                let pushes = hubPushes
                player.engine.setFeedConsumer { [weak hub] buffer in
                    hub?.feed?.push(member: member, buffer: buffer)
                    for sink in sinks { sink.push(buffer) }
                    for push in pushes {
                        let defaults = UserDefaults.standard
                        let muted = defaults.bool(forKey: "audio.mix.\(push.mixId).muted")
                        let mixGain = (defaults.object(
                            forKey: "audio.mix.\(push.mixId).gain") as? Float) ?? 1
                        push.hub.feed?.push(
                            member: push.member, buffer: buffer,
                            gain: muted ? 0 : push.gain * min(max(mixGain, 0), 1))
                    }
                }
            }
        }

        for entry in audioInputs.entries {
            let id = entry.id
            let mix = mixId(forInput: id)
            let shouldFeed = feedHubs[mix] != nil && isLive(input: id)
            if shouldFeed, feedConsumerTokens[id] == nil,
               let source = audioInputs.source(forId: id),
               let hub = feedHubs[mix] {
                feedConsumerTokens[id] = source.addConsumer { [weak hub] buffer, _, _ in
                    let defaults = UserDefaults.standard
                    let muted = defaults.bool(forKey: "audio.input.\(id).muted")
                        || defaults.bool(forKey: "audio.mix.\(mix).muted")
                    let inputGain = (defaults.object(forKey: "audio.input.\(id).gain") as? Float) ?? 1
                    let mixGain = (defaults.object(forKey: "audio.mix.\(mix).gain") as? Float) ?? 1
                    hub?.feed?.push(
                        member: "input-\(id)", buffer: buffer,
                        gain: muted ? 0 : min(max(inputGain, 0), 1) * min(max(mixGain, 0), 1),
                        pan: (defaults.object(forKey: "audio.input.\(id).pan") as? Float) ?? 0)
                }
            } else if !shouldFeed, let token = feedConsumerTokens.removeValue(forKey: id) {
                audioInputs.source(forId: id)?.removeConsumer(token)
            }

            let routed = mixId(forInput: id)
            for (sendMix, sendGain) in channelSends("input:\(id)")
            where sendMix != routed && audio.mixes.entry(id: sendMix) != nil {
                let key = "input:\(id)|\(sendMix)"
                let wanted = feedHubs[sendMix] != nil && isLive(input: id)
                if wanted, sendFeedTokens[key] == nil,
                   let source = audioInputs.source(forId: id),
                   let sendHub = feedHubs[sendMix] {
                    let gain = sendGain
                    sendFeedTokens[key] = source.addConsumer { [weak sendHub] buffer, _, _ in
                        let defaults = UserDefaults.standard
                        let muted = defaults.bool(forKey: "audio.input.\(id).muted")
                            || defaults.bool(forKey: "audio.mix.\(sendMix).muted")
                        let inputGain = (defaults.object(
                            forKey: "audio.input.\(id).gain") as? Float) ?? 1
                        let mixGain = (defaults.object(
                            forKey: "audio.mix.\(sendMix).gain") as? Float) ?? 1
                        sendHub?.feed?.push(
                            member: "send-input-\(id)", buffer: buffer,
                            gain: muted ? 0 : min(max(inputGain, 0), 1) * gain
                                * min(max(mixGain, 0), 1),
                            pan: (defaults.object(forKey: "audio.input.\(id).pan") as? Float) ?? 0)
                    }
                } else if !wanted, let token = sendFeedTokens.removeValue(forKey: key) {
                    audioInputs.source(forId: id)?.removeConsumer(token)
                }
            }
        }

        for (key, token) in sendFeedTokens {
            let parts = key.split(separator: "|")
            guard parts.count == 2, parts[0].hasPrefix("input:") else { continue }
            let inputId = String(parts[0].dropFirst(6))
            let sendMix = String(parts[1])
            let stillWanted = feedHubs[sendMix] != nil && isLive(input: inputId)
                && channelSends("input:\(inputId)")[sendMix] != nil
                && mixId(forInput: inputId) != sendMix
            if !stillWanted {
                sendFeedTokens.removeValue(forKey: key)
                audioInputs.source(forId: inputId)?.removeConsumer(token)
            }
        }
    }

    private var sendFeedTokens: [String: UUID] = [:]

    private var feedConsumerTokens: [String: UUID] = [:]
    private var syncingFeeds = false

    func channelSends(_ channel: String) -> [String: Float] {
        guard let data = UserDefaults.standard.data(forKey: "audio.channel.\(channel).sends"),
              let stored = try? JSONDecoder().decode([String: Float].self, from: data)
        else { return [:] }
        return stored
    }

    func setChannelSend(_ channel: String, mixId: String, gain: Float?) {
        var sends = channelSends(channel)
        sends[mixId] = gain.map { min(max($0, 0), 1) }
        if let data = try? JSONEncoder().encode(sends) {
            UserDefaults.standard.set(data, forKey: "audio.channel.\(channel).sends")
        }
        if let gain, let playthrough = channelSendPlaythroughs["\(channel)|\(mixId)"] {
            playthrough.gain = min(max(gain, 0), 1) * audio.mixGain(mixId)
        }
        syncMixFeeds()
    }

    private var channelSendPlaythroughs: [String: AudioInputPlaythrough] = [:]
    private var channelSendTokens: [String: UUID] = [:]

    private func reconcileChannelSends() {
        var needed: [String: (channel: String, mixId: String, gain: Float)] = [:]

        for entry in audioInputs.entries where isLive(input: entry.id) {
            let routed = mixId(forInput: entry.id)
            for (mixId, gain) in channelSends("input:\(entry.id)")
            where mixId != routed && audio.mixes.entry(id: mixId) != nil {
                needed["input:\(entry.id)|\(mixId)"] = ("input:\(entry.id)", mixId, gain)
            }
        }
        for player in audio.players {
            guard let playlistID = player.playlistID else { continue }
            let routed = audio.playlistMixId(playlistID) ?? AudioMixInventory.mainID
            for (mixId, gain) in channelSends("playlist:\(playlistID)")
            where mixId != routed && audio.mixes.entry(id: mixId) != nil {
                needed["playlist:\(playlistID)|\(mixId)"] = ("playlist:\(playlistID)", mixId, gain)
            }
        }

        for (mixId, gain) in channelSends("video")
        where mixId != audio.mediaMixId && audio.mixes.entry(id: mixId) != nil {
            needed["video|\(mixId)"] = ("video", mixId, gain)
        }
        for key in Set(channelSendPlaythroughs.keys).subtracting(needed.keys) {
            if let token = channelSendTokens.removeValue(forKey: key) {
                let channel = String(key.split(separator: "|")[0])
                if channel.hasPrefix("input:") {
                    audioInputs.source(forId: String(channel.dropFirst(6)))?
                        .removeConsumer(token)
                }
            }
            channelSendPlaythroughs.removeValue(forKey: key)?.stop()
        }
        for (key, send) in needed {
            let mix = audio.mixes.entry(id: send.mixId) ?? audio.mixes.main
            if let playthrough = channelSendPlaythroughs[key] {
                applyOutput(mix.outputIds.first, to: playthrough)
                applySendLevels(send, to: playthrough)
                continue
            }
            let playthrough = AudioInputPlaythrough()
            guard (try? playthrough.start()) != nil else { continue }
            applyOutput(mix.outputIds.first, to: playthrough)
            applySendLevels(send, to: playthrough)
            channelSendPlaythroughs[key] = playthrough
            if send.channel.hasPrefix("input:"),
               let source = audioInputs.source(forId: String(send.channel.dropFirst(6))) {
                channelSendTokens[key] = source.addConsumer { [weak playthrough] buffer, _, _ in
                    playthrough?.push(buffer)
                }
            }

        }

        let videoSinks = channelSendPlaythroughs.compactMap { key, playthrough in
            key.hasPrefix("video|") ? playthrough : nil
        }
        var videoHubPushes: [(hub: FeedHub, gain: Float, mixId: String)] = []
        for (sendMix, sendGain) in channelSends("video")
        where sendMix != audio.mediaMixId {
            if let sendHub = feedHubs[sendMix] {
                videoHubPushes.append((sendHub, sendGain, sendMix))
            }
        }

        let metering = meteringRefCount > 0
        if videoSinks.isEmpty, videoHubPushes.isEmpty, !metering {
            audio.setVideoAudioConsumer(nil)
        } else {
            let pushes = videoHubPushes
            audio.setVideoAudioConsumer { [videoLevels] buffer in
                if metering {
                    let sides = AudioLevel.measureSides(buffer)
                    videoLevels.withLock { $0.fold(left: sides.left, right: sides.right) }
                }

                RealtimeAudioCallback.scope {
                    for sink in videoSinks { sink.push(buffer) }
                    for push in pushes {
                        let defaults = UserDefaults.standard
                        let muted = defaults.bool(forKey: "audio.media.muted")
                            || defaults.bool(forKey: "audio.mix.\(push.mixId).muted")
                        let videoGain = (defaults.object(
                            forKey: "audio.media.gain") as? Float) ?? 1
                        let mixGain = (defaults.object(
                            forKey: "audio.mix.\(push.mixId).gain") as? Float) ?? 1
                        push.hub.feed?.push(
                            member: "send-video", buffer: buffer,
                            gain: muted ? 0 : min(max(videoGain, 0), 1) * push.gain
                                * min(max(mixGain, 0), 1))
                    }
                }
            }
        }
    }

    private var sendPlaythroughs: [String: AudioInputPlaythrough] = [:]
    private var sendTokens: [String: UUID] = [:]

    private var sendDry: [String: Bool] = [:]

    nonisolated static func streamGain(mixId: String) -> Float {
        guard let stored = UserDefaults.standard.object(
            forKey: "audio.mix.\(mixId).streamGain") as? Float else { return 1 }
        return min(max(stored, 0), 1)
    }

    func streamGain(mixId: String) -> Float {
        Self.streamGain(mixId: mixId)
    }

    func setStreamGain(_ gain: Float, mixId: String) {
        UserDefaults.standard.set(
            min(max(gain, 0), 1), forKey: "audio.mix.\(mixId).streamGain")
    }

    func sendLevel(mixId: String, outputId: String) -> Float {
        guard let stored = UserDefaults.standard.object(
            forKey: "audio.mix.\(mixId).send.\(outputId).gain") as? Float else { return 1 }
        return min(max(stored, 0), 1)
    }

    func setSendLevel(_ level: Float, mixId: String, outputId: String) {
        UserDefaults.standard.set(
            min(max(level, 0), 1), forKey: "audio.mix.\(mixId).send.\(outputId).gain")
        sendPlaythroughs["\(mixId)|\(outputId)"]?.gain = min(max(level, 0), 1)
    }

    private func reconcileOutputSends() {
        var needed: [String: (mixId: String, outputId: String)] = [:]
        for mix in audio.mixes.entries where mix.outputIds.count > 1 {
            guard mixHasActiveMembers(mix) else { continue }
            for outputId in mix.outputIds.dropFirst() {
                needed["\(mix.id)|\(outputId)"] = (mix.id, outputId)
            }
        }
        for key in Set(sendPlaythroughs.keys).subtracting(needed.keys) {
            let mixId = String(key.split(separator: "|")[0])
            if let token = sendTokens.removeValue(forKey: key) {
                removeFeedConsumer(mixId: mixId, token: token)
            }
            sendDry.removeValue(forKey: key)
            sendPlaythroughs.removeValue(forKey: key)?.stop()
        }
        for (key, send) in needed {

            let dry = tracksDeviceUID != nil && deviceUID(ofOutput: send.outputId) == tracksDeviceUID
            if let playthrough = sendPlaythroughs[key], sendDry[key] != dry, let token = sendTokens[key] {
                removeFeedConsumer(mixId: send.mixId, token: token)
                sendDry[key] = dry
                sendTokens[key] = addFeedConsumer(mixId: send.mixId, withoutTracks: dry) {
                    [weak playthrough] buffer, _, _ in
                    playthrough?.push(buffer)
                }
            }
            if let playthrough = sendPlaythroughs[key] {
                applyOutput(send.outputId, to: playthrough)
                playthrough.gain = sendLevel(mixId: send.mixId, outputId: send.outputId)
                    * AudioController.outputTrim(send.outputId)
                playthrough.isMuted = AudioController.outputMuted(send.outputId)
                    || AudioOutputInventory.shared.isDeviceless(send.outputId)
                continue
            }
            let playthrough = AudioInputPlaythrough()
            do {
                try playthrough.start()
            } catch {
                DiagnosticsStore.shared.note("mixer", detail: "send start failed: \(error)")
                continue
            }
            applyOutput(send.outputId, to: playthrough)
            playthrough.gain = sendLevel(mixId: send.mixId, outputId: send.outputId)
            playthrough.isMuted = AudioController.outputMuted(send.outputId)
                || AudioOutputInventory.shared.isDeviceless(send.outputId)
            sendPlaythroughs[key] = playthrough
            sendDry[key] = dry
            sendTokens[key] = addFeedConsumer(mixId: send.mixId, withoutTracks: dry) {
                [weak playthrough] buffer, _, _ in
                playthrough?.push(buffer)
            }
        }
    }

    private func applySendLevels(
        _ send: (channel: String, mixId: String, gain: Float),
        to playthrough: AudioInputPlaythrough
    ) {
        var channelGain: Float = 1
        var channelMuted = false
        var channelPan: Float = 0
        if send.channel.hasPrefix("input:") {
            let inputId = String(send.channel.dropFirst(6))
            channelGain = gain(forInput: inputId)
            channelMuted = isMuted(input: inputId)

            channelPan = pan(forInput: inputId)
        } else if send.channel == "video" {
            channelGain = audio.mediaAudioGain
            channelMuted = audio.mediaAudioMuted
        }
        playthrough.gain = channelGain * send.gain * audio.mixGain(send.mixId)
        playthrough.pan = channelPan

        let outputIds = audio.mixes.entry(id: send.mixId)?.outputIds ?? []
        playthrough.isMuted = channelMuted || audio.mixMuted(send.mixId)
            || AudioMixInventory.isVirtual(outputIds)
            || AudioOutputInventory.shared.isDeviceless(outputIds.first)
    }

    private func mixHasActiveMembers(_ mix: AudioMixInventory.Entry) -> Bool {
        tracksReach.contains(mix.id)
            || audio.players.contains { $0.targetKey == mix.id }
            || audioInputs.entries.contains {
                mixId(forInput: $0.id) == mix.id && isLive(input: $0.id)
            }
    }

    private func mixName(_ id: String) -> String {
        audio.mixes.entry(id: id)?.name ?? id
    }

    func setMetering(_ enabled: Bool) {
        meteringRefCount += enabled ? 1 : -1
        meteringRefCount = max(0, meteringRefCount)
        let shouldMeter = meteringRefCount > 0
        for player in audio.players {
            player.engine.setMetering(shouldMeter)
        }

        reconcileChannelSends()
        if shouldMeter {
            attachInputMeters()
        } else {
            detachInputMeters()
            displayLevels = [:]
            busLevels = [:]
            playerLevels = [:]
            outputLevels = [:]
            lastMeterTick = nil
        }
    }

    private func attachInputMeters() {
        for entry in audioInputs.entries where meterTokens[entry.id] == nil {
            guard let source = audioInputs.source(forId: entry.id) else { continue }
            let id = entry.id
            meterTokens[id] = source.addConsumer { [inputLevels] buffer, _, _ in
                let sides = AudioLevel.measureSides(buffer)
                inputLevels.withLock { $0[id, default: LevelWindow()].fold(left: sides.left, right: sides.right) }
            }
        }
    }

    private func detachInputMeters() {
        for (id, token) in meterTokens {
            audioInputs.source(forId: id)?.removeConsumer(token)
        }
        meterTokens = [:]
        inputLevels.withLock { $0 = [:] }
    }

    func refreshMeters() {
        let now = Date()
        let elapsed = lastMeterTick.map { now.timeIntervalSince($0) } ?? 0
        lastMeterTick = now

        attachInputMeters()
        if meteringRefCount > 0 {
            for player in audio.players { player.engine.setMetering(true) }
        }
        let silence: [AudioLevel.Reading] = [(0, 0), (0, 0)]
        let raw = inputLevels.withLock { windows -> [String: [AudioLevel.Reading]] in
            let taken = windows.mapValues(\.sides)
            windows = [:]
            return taken
        }

        func metered(_ held: [MeterBallistics]?, _ readings: [AudioLevel.Reading]) -> [MeterBallistics] {
            readings.enumerated().map { index, reading in
                var meter = held?.count == readings.count ? held![index] : MeterBallistics()
                meter.update(rms: reading.rms, peak: reading.peak, elapsed: elapsed)
                return meter
            }
        }
        let mixGain = { [audio] (id: String) in audio.mixMuted(id) ? 0 : audio.mixGain(id) }

        var nextDisplayLevels = displayLevels
        var nextBusLevels = busLevels

        var nextOutputLevels: [String: [MeterBallistics]] = [:]
        var deviceRaw: [String: AudioLevel.Reading] = [:]
        for entry in audioInputs.entries {
            let sides = isLive(input: entry.id) ? raw[entry.id] ?? silence : silence

            nextDisplayLevels[entry.id] = metered(
                nextDisplayLevels[entry.id], entry.monoChannel == nil ? sides : [AudioLevel.mono(sides)])

            if let uid = entry.uid, !uid.isEmpty {
                let level = AudioLevel.louder(sides)
                let held = deviceRaw[uid] ?? (0, 0)
                deviceRaw[uid] = (max(held.rms, level.rms), max(held.peak, level.peak))
            }
        }
        for uid in Set(audioInputs.entries.compactMap(\.uid)) where !uid.isEmpty {
            nextDisplayLevels["device:\(uid)"] = metered(nextDisplayLevels["device:\(uid)"], [deviceRaw[uid] ?? (0, 0)])
        }

        var mixRaw: [String: [AudioLevel.Reading]] = [:]
        func land(_ landing: [String: [AudioLevel.Reading]]) {
            for (mixId, sides) in landing {
                mixRaw[mixId] = AudioLevel.combine(mixRaw[mixId] ?? silence, adding: sides)
            }
        }

        var nextPlayerLevels: [String: [MeterBallistics]] = [:]
        for player in audio.players {
            let levels = player.engine.takeMeterLevels()
            land([player.targetKey: levels.post.sides])
            nextPlayerLevels[player.targetKey] = metered(playerLevels[player.targetKey], levels.source.sides)
        }
        playerLevels = nextPlayerLevels
        for entry in audioInputs.entries where isLive(input: entry.id) {
            let id = entry.id
            guard !isMuted(input: id) else { continue }
            land(AudioLevel.channelLanding(
                sides: raw[id] ?? silence, channelGain: gain(forInput: id), pan: pan(forInput: id),
                routedMix: mixId(forInput: id),
                sends: channelSends("input:\(id)").filter { audio.mixes.entry(id: $0.key) != nil },
                mixGain: mixGain))
        }

        let video = videoLevels.withLock { window in
            defer { window = LevelWindow() }
            return window.sides
        }
        nextDisplayLevels[Self.videoMeterKey] = metered(nextDisplayLevels[Self.videoMeterKey], video)
        land(AudioLevel.channelLanding(
            sides: video,
            channelGain: audio.mediaAudioMuted ? 0 : audio.mediaAudioGain,
            routedMix: audio.mediaMixId,
            sends: channelSends("video").filter { audio.mixes.entry(id: $0.key) != nil },
            mixGain: mixGain))

        if let tracks, let channels = tracks.model?.trackChannels, !channels.isEmpty {
            let levels = tracks.meters
            let trim = TracksController.trimMuted ? 0 : TracksController.trim
            var loudest: AudioLevel.Reading = (0, 0)
            for channel in channels {
                let sides = levels[channel.id] ?? silence
                let source = channel.mono == true ? [AudioLevel.mono(sides)] : sides
                nextDisplayLevels["track:\(channel.id)"] = metered(nextDisplayLevels["track:\(channel.id)"], source)
                let channelGain = TracksController.muted(channel.id) ? 0 : TracksController.gain(channel.id) * trim
                let level = AudioLevel.louder(source)
                loudest = (max(loudest.rms, level.rms * channelGain), max(loudest.peak, level.peak * channelGain))
                land(AudioLevel.channelLanding(
                    sides: source, channelGain: channelGain, pan: TracksController.pan(channel.id),
                    routedMix: TracksController.mixId(channel).flatMap { audio.mixes.entry(id: $0) != nil ? $0 : nil },
                    sends: channelSends("track:\(channel.id)").filter { audio.mixes.entry(id: $0.key) != nil },
                    mixGain: mixGain))
            }
            nextDisplayLevels[Self.tracksMeterKey] = metered(nextDisplayLevels[Self.tracksMeterKey], [loudest])
        }
        displayLevels = nextDisplayLevels
        for key in Set(audio.mixes.entries.map(\.id)).union(mixRaw.keys) {
            nextBusLevels[key] = metered(nextBusLevels[key], mixRaw[key] ?? silence)
        }
        busLevels = nextBusLevels

        let outputs = AudioOutputInventory.shared
        let landing = audio.mixes.entries.map { mix in
            (level: mixRaw[mix.id] ?? silence,
             sends: mix.outputIds.enumerated().compactMap { index, outputId in
                 outputs.entry(id: outputId) == nil
                     ? nil
                     : (outputId: outputId,
                        gain: (index == 0 ? 1 : sendLevel(mixId: mix.id, outputId: outputId))
                            * AudioController.outputTrim(outputId))
             })
        }
        let outputRaw = AudioLevel.outputLevels(landing)
        var devices: [String: [(sides: [AudioLevel.Reading], channels: [Int])]] = [:]
        for output in outputs.entries {
            let silent = AudioController.outputMuted(output.id) || output.isDeviceless
            let sides = silent ? silence : outputRaw[output.id] ?? silence

            nextOutputLevels[output.id] = metered(
                outputLevels[output.id], output.monoChannel == nil ? sides : [AudioLevel.mono(sides)])
            if let uid = output.deviceUID, !output.isDeviceless {
                let channels = output.monoChannel.map { [$0] } ?? [output.channelOffset, output.channelOffset + 1]
                devices[uid, default: []].append((sides, channels))
            }
        }

        for (uid, members) in devices {
            let bridge = AudioLevel.deviceChannels(members).sorted { $0.key < $1.key }.map(\.value)
            nextOutputLevels["device:\(uid)"] = metered(outputLevels["device:\(uid)"], bridge)
        }
        outputLevels = nextOutputLevels
    }
}
