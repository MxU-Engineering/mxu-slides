import AVFoundation
import AudioEngine
import Foundation
import Observation

final class AudioInputSource: @unchecked Sendable {
    typealias Consumer = @Sendable (AVAudioPCMBuffer, AVAudioTime, Double) -> Void

    private let lock = NSLock()
    private var _deviceUID: String
    private var _channels: InputChannelSelection
    private var consumers: [UUID: Consumer] = [:]
    private var hub: AudioInputHub?
    private var tapToken: UUID?

    private let delayLine = AudioDelayLine()

    init(deviceUID: String, channels: InputChannelSelection = .default) {
        _deviceUID = deviceUID
        _channels = channels
    }

    var deviceUID: String { lock.withLock { _deviceUID } }
    var isRunning: Bool { lock.withLock { hub != nil } }

    func start() throws {
        try lock.withLock { try startLocked() }
    }

    func reassign(deviceUID: String, channels: InputChannelSelection) throws {
        try lock.withLock {
            let previousUID = _deviceUID
            _deviceUID = deviceUID
            _channels = channels
            guard let hub, let tapToken else { return }
            if deviceUID == previousUID {
                hub.updateTap(tapToken, channels: channels)
                return
            }
            hub.removeTap(tapToken)
            AudioInputHubPool.shared.release(deviceUID: previousUID)
            self.hub = nil
            self.tapToken = nil
            try startLocked()
        }
    }

    private func startLocked() throws {
        guard hub == nil else { return }
        let hub = try AudioInputHubPool.shared.acquire(deviceUID: _deviceUID)
        self.hub = hub
        tapToken = hub.addTap(channels: _channels) { [weak self] buffer, when, host in
            guard let self else { return }

            self.delayLine.process(buffer)
            let sinks = self.lock.withLock { Array(self.consumers.values) }

            for sink in sinks { sink(buffer, when, host) }
        }
    }

    func suspend() {
        lock.withLock {
            if let hub, let tapToken { hub.removeTap(tapToken) }
            if hub != nil {
                AudioInputHubPool.shared.release(deviceUID: _deviceUID)
            }
            hub = nil
            tapToken = nil
        }
    }

    func stop() {
        lock.withLock {
            if let hub, let tapToken { hub.removeTap(tapToken) }
            if hub != nil {
                AudioInputHubPool.shared.release(deviceUID: _deviceUID)
            }
            hub = nil
            tapToken = nil
            consumers.removeAll()
        }
    }

    func setDelay(milliseconds: Double) {
        delayLine.delayMilliseconds = milliseconds
    }

    func addConsumer(_ consumer: @escaping Consumer) -> UUID {
        let token = UUID()
        lock.withLock { consumers[token] = consumer }
        return token
    }

    func removeConsumer(_ token: UUID) {
        lock.withLock { _ = consumers.removeValue(forKey: token) }

    }
}

@MainActor
@Observable
final class AudioInputInventory {
    static let shared = AudioInputInventory()

    struct Entry: Codable, Identifiable, Equatable {

        var id: String
        var name: String

        var uid: String?

        var channelOffset: Int?
        var monoChannel: Int?

        var delayMs: Int?

        var isAssigned: Bool { uid?.isEmpty == false }

        var channels: InputChannelSelection {
            if let monoChannel { return .mono(channel: monoChannel) }
            return .stereoPair(offset: channelOffset ?? 0)
        }

        init(
            id: String = UUID().uuidString, name: String, uid: String? = nil,
            channelOffset: Int? = nil, monoChannel: Int? = nil
        ) {
            self.id = id
            self.name = name
            self.uid = uid
            self.channelOffset = channelOffset
            self.monoChannel = monoChannel
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
            name = try container.decode(String.self, forKey: .name)
            uid = try container.decodeIfPresent(String.self, forKey: .uid)
            channelOffset = try container.decodeIfPresent(Int.self, forKey: .channelOffset)
            monoChannel = try container.decodeIfPresent(Int.self, forKey: .monoChannel)
            delayMs = try container.decodeIfPresent(Int.self, forKey: .delayMs)
        }
    }

    private(set) var entries: [Entry] = []

    private var sources: [String: AudioInputSource] = [:]
    private static let defaultsKey = "audioInputs.inventory"

    var onEntriesChanged: (() -> Void)?

    private var deviceListener: AudioDeviceList.ListenerToken?
    private var hotplugReconcilePending = false

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let stored = try? JSONDecoder().decode([Entry].self, from: data) {
            entries = stored

            persist()
        }
    }

    func entry(id: String) -> Entry? {
        entries.first { $0.id == id }
    }

    func name(forId id: String) -> String? {
        entry(id: id)?.name
    }

    func name(forUid uid: String) -> String? {
        legacyEntry(forUid: uid)?.name
    }

    func source(forId id: String) -> AudioInputSource? {
        sources[id]
    }

    func source(forUid uid: String) -> AudioInputSource? {
        guard let entry = legacyEntry(forUid: uid) else { return nil }
        return sources[entry.id]
    }

    private func legacyEntry(forUid uid: String) -> Entry? {
        let matches = entries.filter { $0.uid == uid }
        return matches.first { $0.channels == .stereoPair(offset: 0) } ?? matches.first
    }

    func warmUp() {
        startHotplugWatch()
        guard entries.contains(where: \.isAssigned) else { return }
        withMicrophonePermission { [weak self] granted in
            guard granted, let self else { return }
            for entry in self.entries where entry.isAssigned { self.start(entry) }
        }
    }

    @discardableResult
    func create(name: String, uid: String? = nil) -> Entry {
        let entry = Entry(name: name, uid: uid)
        entries.append(entry)
        persist()
        if entry.isAssigned {
            withMicrophonePermission { [weak self] granted in
                guard granted else { return }
                self?.start(entry)
            }
        }
        return entry
    }

    @discardableResult
    func createBatch(
        uid: String, deviceName: String, selections: [InputChannelSelection]
    ) -> [Entry] {
        guard !selections.isEmpty else { return [] }
        var created: [Entry] = []
        for selection in selections {
            let custom = AudioChannelNameStore.shared.entryName(uid: uid, selection: selection)
            let entry: Entry = switch selection {
            case .stereoPair(let offset):
                Entry(
                    name: custom ?? "\(deviceName) \(offset + 1)-\(offset + 2)",
                    uid: uid, channelOffset: offset)
            case .mono(let channel):
                Entry(
                    name: custom ?? "\(deviceName) Mono \(channel + 1)",
                    uid: uid, monoChannel: channel)
            }
            entries.append(entry)
            created.append(entry)
        }
        persist()
        withMicrophonePermission { [weak self] granted in
            guard granted, let self else { return }
            for entry in created { self.start(entry) }
        }
        return created
    }

    func rename(id: String, to name: String) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        entries[index].name = trimmed

        if let uid = entries[index].uid, !uid.isEmpty {
            let channel = switch entries[index].channels {
            case .mono(let channel): channel
            case .stereoPair(let offset): offset
            }
            AudioChannelNameStore.shared.setName(trimmed, uid: uid, channel: channel)
        }
        persist()
    }

    func assignDevice(id: String, uid: String?) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].uid = uid
        persist()
        guard let uid, !uid.isEmpty else {
            sources.removeValue(forKey: id)?.stop()
            return
        }
        if let source = sources[id] {
            do {
                try source.reassign(deviceUID: uid, channels: entries[index].channels)
            } catch {
                DiagnosticsStore.shared.note(
                    "input.audio", detail: "reassign failed for \(entries[index].name): \(error)")
            }
        } else {
            let entry = entries[index]
            withMicrophonePermission { [weak self] granted in
                guard granted else { return }
                self?.start(entry)
            }
        }
    }

    func setDelay(id: String, milliseconds: Int) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        let clamped = max(0, min(milliseconds, 2000))
        entries[index].delayMs = clamped == 0 ? nil : clamped
        persist()
        sources[id]?.setDelay(milliseconds: Double(clamped))
        DiagnosticsStore.shared.note(
            "input.audio", detail: "delay \(clamped)ms: \(entries[index].name)")
    }

    func assignChannels(id: String, channelOffset: Int?, monoChannel: Int?) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].channelOffset = channelOffset
        entries[index].monoChannel = monoChannel
        persist()
        guard let uid = entries[index].uid, !uid.isEmpty,
              let source = sources[id] else { return }
        do {
            try source.reassign(deviceUID: uid, channels: entries[index].channels)
        } catch {
            DiagnosticsStore.shared.note(
                "input.audio",
                detail: "channel change failed for \(entries[index].name): \(error)")
        }
    }

    func remove(_ entry: Entry) {
        entries.removeAll { $0.id == entry.id }
        persist()
        sources.removeValue(forKey: entry.id)?.stop()
    }

    private func withMicrophonePermission(_ then: @escaping @MainActor (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            then(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                Task { @MainActor in
                    if !granted {
                        DiagnosticsStore.shared.note(
                            "input.audio", detail: "microphone permission declined")
                    }
                    then(granted)
                }
            }
        case .denied, .restricted:
            DiagnosticsStore.shared.note(
                "input.audio",
                detail: "microphone permission denied — enable in System Settings › Privacy › Microphone")
            then(false)
        @unknown default:
            then(false)
        }
    }

    private func start(_ entry: Entry) {
        guard sources[entry.id] == nil, let uid = entry.uid, !uid.isEmpty else { return }
        let source = AudioInputSource(deviceUID: uid, channels: entry.channels)
        source.setDelay(milliseconds: Double(entry.delayMs ?? 0))
        do {
            try source.start()
            sources[entry.id] = source

            DiagnosticsStore.shared.note(
                "input.audio",
                detail: "warm: \(entry.name) (\(AudioInputHubPool.shared.hubCount) hubs)")
        } catch {
            DiagnosticsStore.shared.note(
                "input.audio", detail: "warm-up failed for \(entry.name): \(error)")
        }
    }

    private func startHotplugWatch() {
        guard deviceListener == nil else { return }
        deviceListener = AudioDeviceList.listenForChanges { [weak self] in
            Task { @MainActor in self?.scheduleHotplugReconcile() }
        }
    }

    private func scheduleHotplugReconcile() {
        guard !hotplugReconcilePending else { return }
        hotplugReconcilePending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            Task { @MainActor in
                let inventory = AudioInputInventory.shared
                inventory.hotplugReconcilePending = false
                inventory.reconcileHotplug()
            }
        }
    }

    private func reconcileHotplug() {
        for entry in entries where entry.isAssigned {
            guard let uid = entry.uid else { continue }
            let present = AudioDeviceList.inputDevice(uid: uid) != nil
            guard let source = sources[entry.id] else {

                if present {
                    withMicrophonePermission { [weak self] granted in
                        guard granted, let self else { return }
                        self.start(entry)
                        self.onEntriesChanged?()
                    }
                }
                continue
            }
            switch InputHotplug.decide(
                devicePresent: present, captureLive: source.isRunning) {
            case .suspend:
                source.suspend()
                DiagnosticsStore.shared.note(
                    "input.audio",
                    detail: "device unplugged: \(entry.name) — holding for replug")
            case .start:
                do {
                    try source.start()
                    DiagnosticsStore.shared.note(
                        "input.audio", detail: "device returned: \(entry.name)")

                    onEntriesChanged?()
                } catch {
                    DiagnosticsStore.shared.note(
                        "input.audio",
                        detail: "reconnect failed for \(entry.name): \(error)")
                }
            case .none:
                break
            }
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
        onEntriesChanged?()
    }
}
