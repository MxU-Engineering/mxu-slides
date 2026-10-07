import AVFoundation
import AudioEngine
import Foundation
import MediaEngine
import Observation
import PresenterCore
import RenderEngine
import SlideScene

@MainActor
@Observable
final class AudioPlayer {
    let engine = AudioEngine()
    private let appModel: AppModel
    private let blobs: BlobStore?
    private let transportFade: () -> TimeInterval

    private let defaultCrossfade: () -> TimeInterval

    private var queue: PlaylistQueue?
    private(set) var playlistID: String?
    private(set) var singleItemID: String?
    private(set) var currentEntryID: String?
    private(set) var currentTrackName: String?
    private(set) var isPlaying = false
    private(set) var elapsed: TimeInterval = 0
    private(set) var duration: TimeInterval = 0

    private var currentTrimStart: TimeInterval = 0
    private var crossfadeSeconds: TimeInterval = 0

    private var repeatOverride: Bool?

    private var crossfadeArmedEntryID: String?
    private var pollTimer: Timer?
    private var consecutiveSkips = 0

    private(set) var targetKey: String = ""

    var busGain: Float = 1
    var busMuted = false

    func applyMix(master: Float, globalMute: Bool, hardwareLive: Bool = true) {
        engine.masterVolume = master * busGain
        engine.isMuted = globalMute || busMuted
        engine.hardwareOutputEnabled = hardwareLive
    }

    var cue: CueAudio { CueAudio(playlistId: playlistID, audioItemId: singleItemID) }

    var displayName: String {
        if let playlistID {
            return appModel.indexEntry(playlistID)?.name ?? "Playlist"
        }
        return currentTrackName ?? "Music"
    }

    init(
        appModel: AppModel, blobs: BlobStore?,
        transportFade: @escaping () -> TimeInterval,
        defaultCrossfade: @escaping () -> TimeInterval
    ) {
        self.appModel = appModel
        self.blobs = blobs
        self.transportFade = transportFade
        self.defaultCrossfade = defaultCrossfade
        engine.onTrackPlayedToEnd = { [weak self] in
            Task { @MainActor in self?.trackPlayedToEnd() }
        }
    }

    func configureRouting(
        device: AudioOutputDevice?, channelOffset: Int, key: String, delayMs: Int = 0
    ) {
        targetKey = key
        try? engine.setOutputDevice(device, channelOffset: channelOffset)
        engine.outputDelayMilliseconds = Double(delayMs)
    }

    func play(playlist: Playlist, startAt entryID: String? = nil, repeatOverride: Bool? = nil) {
        if playlistID == playlist.id, entryID == nil, isPlaying {
            self.repeatOverride = repeatOverride
            refreshFromDocument()
            return
        }
        let isJumpWithinLive = playlistID == playlist.id && isPlaying
        self.repeatOverride = repeatOverride
        var queue = PlaylistQueue(
            entryIDs: playlist.entries.map(\.id),
            repeatBehavior: effectiveRepeat(for: playlist.playbackMode),
            shuffled: playlist.shuffle ?? false
        )
        queue.start(at: entryID)
        self.queue = queue
        playlistID = playlist.id
        singleItemID = nil
        crossfadeSeconds = PlaylistCrossfade.resolve(
            override: playlist.crossfadeSeconds, roomDefault: defaultCrossfade())
        crossfadeArmedEntryID = nil
        playCurrentEntry(
            crossfade: isJumpWithinLive ? crossfadeSeconds : 0,
            fadeIn: isJumpWithinLive ? 0 : transportFade()
        )
        startPolling()
    }

    func play(audioItem: AudioItem, repeatOverride: Bool? = nil) {
        queue = nil
        playlistID = nil
        singleItemID = audioItem.id
        self.repeatOverride = repeatOverride
        crossfadeSeconds = 0
        crossfadeArmedEntryID = nil
        currentEntryID = nil
        start(item: audioItem, crossfade: 0, fadeIn: transportFade())
        startPolling()
    }

    func stop() {
        engine.stop(fade: transportFade())
        defer { onTransportChanged?() }
        queue = nil
        repeatOverride = nil
        currentEntryID = nil
        currentTrackName = nil
        isPlaying = false
        elapsed = 0
        duration = 0
        crossfadeArmedEntryID = nil
        stopPolling()
    }

    func togglePlayPause() {
        guard currentTrackName != nil else {

            if queue != nil, playlistID != nil {
                queue?.start()
                playCurrentEntry(crossfade: 0, fadeIn: transportFade())
            }
            return
        }
        if isPlaying {
            engine.pause(fade: transportFade())
            isPlaying = false
        } else {
            engine.resume(fade: transportFade())
            isPlaying = true
        }
    }

    func next() {
        guard queue != nil else { return }
        crossfadeArmedEntryID = nil
        if queue?.next() != nil {
            playCurrentEntry(crossfade: crossfadeSeconds)
        } else {
            stopAtEndOfPass()
        }
    }

    func previous() {
        crossfadeArmedEntryID = nil
        guard queue != nil else {
            if let singleItemID, let item = appModel.audio(singleItemID) {
                start(item: item, crossfade: 0)
            }
            return
        }
        if elapsed > 3, currentEntryID != nil {
            playCurrentEntry(crossfade: 0)
            return
        }
        _ = queue?.previous()
        playCurrentEntry(crossfade: crossfadeSeconds)
    }

    func seek(to seconds: TimeInterval) {
        guard currentTrackName != nil, duration > 0 else { return }
        if let entryID = currentEntryID, crossfadeArmedEntryID == entryID,
           queue?.currentEntryID == entryID {
            crossfadeArmedEntryID = nil
        }
        engine.seek(to: seconds + currentTrimStart)
        isPlaying = engine.isPlaying
        refreshPosition()
    }

    func refreshFromDocument() {
        guard let playlistID,
              let playlist = try? appModel.playlist(playlistID)
        else { return }
        crossfadeSeconds = PlaylistCrossfade.resolve(
            override: playlist.crossfadeSeconds, roomDefault: defaultCrossfade())
        queue?.repeatBehavior = effectiveRepeat(for: playlist.playbackMode)
        if let shuffled = playlist.shuffle, shuffled != (queue?.isShuffled ?? false) {
            queue?.setShuffled(shuffled)
        }
        queue?.updateEntries(playlist.entries.map(\.id))
        if queue?.currentEntryID == nil, currentEntryID != nil {

            crossfadeArmedEntryID = currentEntryID
        }
    }

    var passPosition: (index: Int, count: Int)? {
        queue?.positionInPass
    }

    private func playCurrentEntry(crossfade: TimeInterval, fadeIn: TimeInterval = 0) {
        guard let entryID = queue?.currentEntryID else {
            stopAtEndOfPass()
            return
        }
        currentEntryID = entryID
        guard let item = audioItem(forEntry: entryID) else {

            skipUnplayable()
            return
        }
        start(item: item, crossfade: crossfade, fadeIn: fadeIn)
    }

    private func start(item: AudioItem, crossfade: TimeInterval, fadeIn: TimeInterval = 0) {
        guard let url = blobs?.url(forHash: item.fileHash) else {
            skipUnplayable()
            return
        }

        var trimStart = max(item.inPoint ?? 0, 0)
        var trimEnd = item.outPoint
        if let end = trimEnd, end <= trimStart {
            trimStart = 0
            trimEnd = nil
        }
        do {
            try engine.play(
                url: url, crossfade: crossfade, fadeIn: fadeIn,
                trimStart: trimStart, trimEnd: trimEnd
            )
            currentTrimStart = trimStart
            currentTrackName = item.name
            isPlaying = true
            refreshPosition()
        } catch {
            skipUnplayable()
        }
    }

    private func skipUnplayable() {
        consecutiveSkips += 1
        guard queue != nil, consecutiveSkips <= queueLength else {
            consecutiveSkips = 0
            stopAtEndOfPass()
            return
        }
        if queue?.next() != nil {
            playCurrentEntry(crossfade: 0)
        } else {
            consecutiveSkips = 0
            stopAtEndOfPass()
        }
    }

    private var queueLength: Int {
        playlistID.flatMap { try? appModel.playlist($0) }?.entries.count ?? 1
    }

    private func trackPlayedToEnd() {
        consecutiveSkips = 0

        if crossfadeArmedEntryID != nil, crossfadeArmedEntryID == currentEntryID {
            crossfadeArmedEntryID = nil
            if queue?.currentEntryID == nil { stopAtEndOfPass() }
            return
        }
        guard queue != nil else {

            if repeatOverride == true, let itemID = singleItemID,
               let item = appModel.audio(itemID) {
                start(item: item, crossfade: 0)
                return
            }
            isPlaying = false
            refreshPosition()
            return
        }
        if queue?.advanceAfterNaturalEnd() != nil {
            playCurrentEntry(crossfade: 0)
        } else {
            stopAtEndOfPass()
        }
    }

    private func stopAtEndOfPass() {
        engine.stop()
        isPlaying = false
        currentEntryID = nil
        currentTrackName = nil
        currentTrimStart = 0
        elapsed = 0
        duration = 0
    }

    private func startPolling() {
        guard pollTimer == nil else { return }

        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    var onTransportChanged: (() -> Void)?

    private func poll() {
        refreshPosition()
        onTransportChanged?()

        guard isPlaying, crossfadeSeconds > 0, queue != nil, duration > 0,
              let entryID = currentEntryID, crossfadeArmedEntryID != entryID,
              duration - elapsed <= crossfadeSeconds
        else { return }
        crossfadeArmedEntryID = entryID
        if queue?.advanceAfterNaturalEnd() != nil {
            playCurrentEntry(crossfade: min(crossfadeSeconds, max(0.1, duration - elapsed)))
        }

    }

    private func refreshPosition() {
        if let position = engine.position {
            elapsed = max(0, position.elapsed - currentTrimStart)
            duration = max(0, position.duration - currentTrimStart)
        }
    }

    private func audioItem(forEntry entryID: String) -> AudioItem? {
        guard let playlistID,
              let playlist = try? appModel.playlist(playlistID),
              let entry = playlist.entries.first(where: { $0.id == entryID }),
              entry.refKind == .audio
        else { return nil }
        return appModel.audio(entry.refId)
    }

    static func repeatBehavior(for mode: PlaybackMode) -> PlaylistQueue.RepeatBehavior {
        switch mode {
        case .playAll: .none
        case .loopPlaylist: .playlist
        case .loopSingle: .single
        }
    }

    private func effectiveRepeat(for mode: PlaybackMode) -> PlaylistQueue.RepeatBehavior {
        switch repeatOverride {
        case true?: .playlist
        case false?: .none
        case nil: Self.repeatBehavior(for: mode)
        }
    }
}

@MainActor
@Observable
final class AudioController {
    private let appModel: AppModel

    private let media: MediaEngine
    private let blobs: BlobStore?
    private(set) var players: [AudioPlayer] = []

    private(set) var outputDevices: [AudioOutputDevice] = []

    let mixes = AudioMixInventory.shared
    private var deviceListener: AudioDeviceList.ListenerToken?

    var onRoutingChanged: (() -> Void)?

    var fadeEnabled: Bool = UserDefaults.standard.object(forKey: "audio.fadeEnabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(fadeEnabled, forKey: "audio.fadeEnabled") }
    }
    var fadeSeconds: Double = UserDefaults.standard.object(forKey: "audio.fadeSeconds") as? Double ?? 1.5 {
        didSet { UserDefaults.standard.set(fadeSeconds, forKey: "audio.fadeSeconds") }
    }
    private var transportFade: TimeInterval { fadeEnabled ? max(0, fadeSeconds) : 0 }

    var crossfadeSeconds: Double = AudioController.storedRoomCrossfade() {
        didSet {
            UserDefaults.standard.set(crossfadeSeconds, forKey: "audio.crossfadeSeconds")
            playlistDocumentChanged()
        }
    }

    static func storedRoomCrossfade() -> Double {
        UserDefaults.standard.object(forKey: "audio.crossfadeSeconds") as? Double
            ?? PlaylistCrossfade.defaultSeconds
    }

    private var storedMasterVolume: Float = 1
    private var storedMuted = false

    var mediaAudioGain: Float {
        get { storedMediaGain }
        set {
            storedMediaGain = min(max(newValue, 0), 1)
            UserDefaults.standard.set(storedMediaGain, forKey: "audio.media.gain")
            applyMediaGain()
        }
    }

    var mediaAudioMuted: Bool {
        get { storedMediaMuted }
        set {
            storedMediaMuted = newValue
            UserDefaults.standard.set(storedMediaMuted, forKey: "audio.media.muted")
            applyMediaGain()
        }
    }

    private var storedMediaGain: Float = 1
    private var storedMediaMuted = false

    private(set) var mediaMixId: String = UserDefaults.standard.string(
        forKey: "audio.media.mixId") ?? AudioMixInventory.mainID

    func setMediaMix(_ mixId: String) {
        mediaMixId = mixId
        if mixId == AudioMixInventory.mainID {
            UserDefaults.standard.removeObject(forKey: "audio.media.mixId")
        } else {
            UserDefaults.standard.set(mixId, forKey: "audio.media.mixId")
        }
        applyDefaultRoutingToMedia()
        applyMediaGain()
        onRoutingChanged?()
    }

    func setVideoAudioConsumer(_ consumer: (@Sendable (AVAudioPCMBuffer) -> Void)?) {
        media.setVideoAudioConsumer(consumer)
    }

    private func applyMediaGain() {
        let mixID = mediaMixId
        let outputIds = mixes.entry(id: mixID)?.outputIds ?? []
        if AudioMixInventory.isVirtual(outputIds)
            || AudioOutputInventory.shared.isDeviceless(outputIds.first) {
            media.setAudioVolume(0)
            return
        }
        let outputId = outputIds.first
        let muted = storedMediaMuted || mixMuted(mixID) || Self.outputMuted(outputId)
        media.setAudioVolume(
            muted ? 0 : storedMediaGain * mixGain(mixID) * Self.outputTrim(outputId))
    }

    init(appModel: AppModel, media: MediaEngine) {
        self.appModel = appModel
        self.media = media
        self.blobs = try? BlobStore(libraryRoot: appModel.client.rootURL)
        outputDevices = AudioDeviceList.outputDevices()
        if let gain = UserDefaults.standard.object(forKey: "audio.media.gain") as? Float {
            storedMediaGain = min(max(gain, 0), 1)
        }
        storedMediaMuted = UserDefaults.standard.bool(forKey: "audio.media.muted")
        applyMediaGain()
        applyDefaultRoutingToMedia()
        deviceListener = AudioDeviceList.listenForChanges { [weak self] in
            Task { @MainActor in self?.deviceListChanged() }
        }
        mixes.onEntriesChanged = { [weak self] in
            guard let self else { return }
            self.reapplyAllRouting()
            self.reapplyAllMixLevels()
            self.onRoutingChanged?()
        }
        AudioOutputInventory.shared.onEntriesChanged = { [weak self] in
            guard let self else { return }
            self.reapplyAllRouting()

            self.reapplyAllMixLevels()
            self.onRoutingChanged?()
        }
        armPlaylistWatch()
    }

    private func armPlaylistWatch() {
        withObservationTracking {
            _ = appModel.version(of: .playlist)

            _ = appModel.fillVersion(of: .playlist)
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.playlistDocumentChanged()
                self.armPlaylistWatch()
            }
        }
    }

    func play(
        playlist: Playlist, startAt entryID: String? = nil, repeatOverride: Bool? = nil
    ) -> [CueAudio] {
        if let existing = player(forPlaylist: playlist.id) {
            existing.play(playlist: playlist, startAt: entryID, repeatOverride: repeatOverride)
            return []
        }
        let routing = resolveRouting(forPlaylist: playlist.id)
        let replaced = claimTarget(routing.key)
        let player = makePlayer(routing: routing)
        player.busGain = persistedGain(forPlaylist: playlist.id)
        player.busMuted = persistedMuted(forPlaylist: playlist.id)
        applyLevels(to: player)
        player.play(playlist: playlist, startAt: entryID, repeatOverride: repeatOverride)
        players.append(player)
        onPlayersChanged?()
        onTransportChanged?()
        return replaced
    }

    func play(audioItem: AudioItem, repeatOverride: Bool? = nil) -> [CueAudio] {
        let routing = defaultRouting()
        if let existing = players.first(where: { $0.targetKey == routing.key }),
           existing.singleItemID != nil {
            existing.play(audioItem: audioItem, repeatOverride: repeatOverride)
            return []
        }
        let replaced = claimTarget(routing.key)
        let player = makePlayer(routing: routing)

        applyLevels(to: player)
        player.play(audioItem: audioItem, repeatOverride: repeatOverride)
        players.append(player)
        onPlayersChanged?()
        onTransportChanged?()
        return replaced
    }

    func stop() {
        for player in players { player.stop() }
        players = []
        onPlayersChanged?()
        onTransportChanged?()
    }

    func stop(playlistID: String) -> CueAudio? {
        stopPlayer { $0.playlistID == playlistID }
    }

    func stop(audioItemID: String) -> CueAudio? {
        stopPlayer { $0.singleItemID == audioItemID }
    }

    private func stopPlayer(where match: (AudioPlayer) -> Bool) -> CueAudio? {
        guard let player = players.first(where: match) else { return nil }
        player.stop()
        players.removeAll { $0 === player }
        onPlayersChanged?()
        onTransportChanged?()
        return player.cue
    }

    func player(forPlaylist id: String) -> AudioPlayer? {
        players.first { $0.playlistID == id }
    }

    func player(forAudioItem id: String) -> AudioPlayer? {
        players.first { $0.singleItemID == id }
    }

    func playlistDocumentChanged() {
        for player in players { player.refreshFromDocument() }
    }

    var masterVolume: Float {
        get { storedMasterVolume }
        set {
            storedMasterVolume = newValue
            reapplyAllMixLevels()
        }
    }

    var isMuted: Bool {
        get { storedMuted }
        set {
            storedMuted = newValue
            reapplyAllMixLevels()
        }
    }

    func setGain(_ gain: Float, for player: AudioPlayer) {
        player.busGain = min(max(gain, 0), 1)
        applyLevels(to: player)
        if let playlistID = player.playlistID {
            UserDefaults.standard.set(player.busGain, forKey: "audio.playlist.\(playlistID).gain")
        }
    }

    func setMuted(_ muted: Bool, for player: AudioPlayer) {
        player.busMuted = muted
        applyLevels(to: player)
        if let playlistID = player.playlistID {
            UserDefaults.standard.set(muted, forKey: "audio.playlist.\(playlistID).muted")
        }
    }

    func mixGain(_ mixID: String) -> Float {
        guard let stored = UserDefaults.standard.object(
            forKey: "audio.mix.\(mixID).gain") as? Float else { return 1 }
        return min(max(stored, 0), 1)
    }

    func setMixGain(_ gain: Float, mixID: String) {
        UserDefaults.standard.set(min(max(gain, 0), 1), forKey: "audio.mix.\(mixID).gain")
        reapplyAllMixLevels()
        onMixLevelsChanged?()
    }

    func mixMuted(_ mixID: String) -> Bool {
        UserDefaults.standard.bool(forKey: "audio.mix.\(mixID).muted")
    }

    func setMixMuted(_ muted: Bool, mixID: String) {
        UserDefaults.standard.set(muted, forKey: "audio.mix.\(mixID).muted")
        reapplyAllMixLevels()
        onMixLevelsChanged?()
    }

    var onMixLevelsChanged: (() -> Void)?

    var onPlayersChanged: (() -> Void)?

    var onTransportChanged: (() -> Void)?

    var nowPlayingTransport: (name: String, elapsed: Double, duration: Double, isPlaying: Bool)? {
        let candidate = players.first(where: \.isPlaying)
            ?? players.first { $0.currentTrackName != nil }
        guard let candidate, let name = candidate.currentTrackName else { return nil }
        return (name, candidate.elapsed, candidate.duration, candidate.isPlaying)
    }

    private func applyLevels(to player: AudioPlayer) {
        let mixID = player.targetKey
        let outputIds = mixes.entry(id: mixID)?.outputIds ?? []

        let hardwareLive = !(AudioMixInventory.isVirtual(outputIds)
            || AudioOutputInventory.shared.isDeviceless(outputIds.first))
        let outputId = outputIds.first
        player.applyMix(
            master: storedMasterVolume * mixGain(mixID) * Self.outputTrim(outputId),
            globalMute: storedMuted || mixMuted(mixID) || Self.outputMuted(outputId),
            hardwareLive: hardwareLive)
    }

    func reapplyAllMixLevels() {
        for player in players { applyLevels(to: player) }
        applyMediaGain()
    }

    nonisolated static func outputTrim(_ outputId: String?) -> Float {
        guard let outputId, let stored = UserDefaults.standard.object(
            forKey: "audio.output.\(outputId).gain") as? Float else { return 1 }
        return min(max(stored, 0), 1)
    }

    nonisolated static func outputMuted(_ outputId: String?) -> Bool {
        guard let outputId else { return false }
        return outputMuteSetting(outputId) || monitorSilencedOutputs.value.contains(outputId)
    }

    nonisolated static func outputMuteSetting(_ outputId: String) -> Bool {
        UserDefaults.standard.bool(forKey: "audio.output.\(outputId).muted")
    }

    nonisolated static let monitorSilencedOutputs = Locked<Set<String>>([])

    private func persistedGain(forPlaylist id: String) -> Float {
        guard let stored = UserDefaults.standard.object(
            forKey: "audio.playlist.\(id).gain") as? Float else { return 1 }
        return min(max(stored, 0), 1)
    }

    private func persistedMuted(forPlaylist id: String) -> Bool {
        UserDefaults.standard.bool(forKey: "audio.playlist.\(id).muted")
    }

    func playlistMixId(_ playlistID: String) -> String? {
        UserDefaults.standard.string(forKey: "audio.playlist.\(playlistID).mixId")
    }

    func setPlaylistMix(_ playlistID: String, mixId: String?) {
        let key = "audio.playlist.\(playlistID).mixId"
        if let mixId, mixId != AudioMixInventory.mainID {
            UserDefaults.standard.set(mixId, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
        reapplyAllRouting()
        reapplyAllMixLevels()
        onRoutingChanged?()
    }

    private struct Routing {
        let device: AudioOutputDevice?
        let channelOffset: Int

        let key: String

        let delayMs: Int
    }

    private func routing(forMix mixID: String) -> Routing {
        let mix = mixes.entry(id: mixID) ?? mixes.main

        let output = mix.outputIds.first.flatMap {
            AudioOutputInventory.shared.entry(id: $0)
        }
        let device = output?.deviceUID.flatMap { uid in
            outputDevices.first { $0.uid == uid }
        }
        let offset = output?.channelOffset ?? 0
        let clamped = (offset >= 0 && offset + 1 < max(2, device?.channelCount ?? 2))
            ? offset : 0
        return Routing(
            device: device, channelOffset: clamped, key: mix.id,
            delayMs: output?.delayMs ?? 0)
    }

    private func defaultRouting() -> Routing {
        routing(forMix: AudioMixInventory.mainID)
    }

    private func resolveRouting(forPlaylist playlistID: String) -> Routing {
        routing(forMix: playlistMixId(playlistID) ?? AudioMixInventory.mainID)
    }

    private func claimTarget(_ key: String) -> [CueAudio] {
        let holders = players.filter { $0.targetKey == key }
        for holder in holders { holder.stop() }
        players.removeAll { $0.targetKey == key }
        return holders.map(\.cue)
    }

    private func makePlayer(routing: Routing) -> AudioPlayer {
        let player = AudioPlayer(
            appModel: appModel, blobs: blobs,
            transportFade: { [weak self] in self?.transportFade ?? 0 },
            defaultCrossfade: { [weak self] in self?.crossfadeSeconds ?? PlaylistCrossfade.defaultSeconds }
        )
        player.configureRouting(
            device: routing.device, channelOffset: routing.channelOffset, key: routing.key,
            delayMs: routing.delayMs
        )
        applyLevels(to: player)
        player.onTransportChanged = { [weak self] in self?.onTransportChanged?() }
        return player
    }

    private func reapplyAllRouting() {
        for player in players {
            let routing = player.playlistID.map { resolveRouting(forPlaylist: $0) }
                ?? defaultRouting()
            player.configureRouting(
                device: routing.device, channelOffset: routing.channelOffset, key: routing.key,
                delayMs: routing.delayMs
            )
        }
        applyDefaultRoutingToMedia()
    }

    private func applyDefaultRoutingToMedia() {
        let routing = routing(forMix: mediaMixId)
        media.setAudioOutputDevice(uid: routing.device?.uid)
        media.setAudioOutputDelay(milliseconds: routing.delayMs)
    }

    private func deviceListChanged() {
        outputDevices = AudioDeviceList.outputDevices()

        reapplyAllRouting()
        onRoutingChanged?()
    }
}

extension AudioPlayer: Identifiable {}
