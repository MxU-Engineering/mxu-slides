import Foundation

public enum FollowReplay {
    public static func replays(_ event: APIFireEvent) -> Bool {
        event.cause == nil && ![.role, .capture, .quit].contains(event.kind)
    }

    public static func command(for slide: APIFireSlideCommand) -> APIFireSlideCommand {
        var slide = slide
        if slide.serviceItemId != nil, slide.serviceItemId == slide.presentationId {
            slide.serviceItemId = nil
        }
        return slide
    }

    public static func catchUp(booth: APIShowStatus, here: APIShowStatus) -> [APIFireEvent] {
        var events: [APIFireEvent] = []
        if booth.liveSlide == nil, here.liveSlide != nil {
            events.append(APIFireEvent(kind: .clear, clear: APIClearCommand(function: "slides")))
        }
        for layer in here.mediaLayers.keys.sorted() where booth.mediaLayers[layer] == nil {
            events.append(APIFireEvent(kind: .clear, clear: APIClearCommand(layer: layer)))
        }
        let boothOverlays = Set(booth.overlays.map(\.id))
        let hereOverlays = Set(here.overlays.map(\.id))
        for id in hereOverlays.subtracting(boothOverlays).sorted() {
            events.append(APIFireEvent(kind: .dismissOverlay, id: id))
        }
        for (layer, content) in booth.mediaLayers.sorted(by: { $0.key < $1.key }) where here.mediaLayers[layer]?.mediaId != content.mediaId {
            events.append(APIFireEvent(kind: .media, id: content.mediaId))
        }
        for overlay in booth.overlays where !hereOverlays.contains(overlay.id) {
            events.append(APIFireEvent(kind: .overlay, id: overlay.id))
        }
        return events
    }

    @MainActor
    public static func apply(_ event: APIFireEvent, to bridge: any LocalAPIBridge) async throws {
        switch event.kind {
        case .slide:
            if let slide = event.slide { try await bridge.fireSlide(command(for: slide)) }
        case .step: try await bridge.advance(steps: event.steps ?? 1, settled: event.settled ?? false)
        case .clear: if let clear = event.clear { try bridge.clear(clear) }
        case .clearAll: bridge.clearAll()
        case .media: if let id = event.id { try bridge.fireMedia(id: id) }
        case .overlay: if let id = event.id { try bridge.fireOverlay(id: id) }
        case .dismissOverlay: try bridge.dismissOverlay(id: event.id ?? "")
        case .alert: if let alert = event.alert { try bridge.fireAlert(alert) }
        case .dismissAlert: bridge.dismissAlert()
        case .timer: if let id = event.id, let timer = event.timer { try bridge.timerAction(id: id, action: timer) }
        case .combo: if let id = event.id { try bridge.fireActionCombo(id: id) }
        case .outputPreset: try bridge.activateOutputPreset(id: event.id)
        case .lock: if let locked = event.locked { await bridge.setLock(APILockCommand(locked: locked)) }
        case .audioItem: if let id = event.id { try bridge.fireAudioItem(id: id) }
        case .audioPlaylist: if let id = event.id { try bridge.fireAudioPlaylist(id: id, startAtEntryId: event.entryId) }
        case .stopAudio: try bridge.stopAudio(event.audioStop ?? APIAudioStopCommand())
        case .audioTransport: if let transport = event.audioTransport { try bridge.audioTransport(transport) }
        case .mediaTransport:
            if let id = event.id, let transport = event.mediaTransport { try bridge.mediaTransport(id: id, command: transport) }
        case .role, .capture, .quit: break
        }
    }
}

public struct FollowStandby: Sendable {
    public var show: APIShowStatus
    public var transport: [APITransportRow]
    public var audio: APIAudioStatus?
    public var at: Date

    public init(show: APIShowStatus, transport: [APITransportRow], audio: APIAudioStatus?, at: Date) {
        self.show = show
        self.transport = transport
        self.audio = audio
        self.at = at
    }

    public static func showsAnything(_ show: APIShowStatus, audio: APIAudioStatus) -> Bool {
        show.liveSlide != nil || !show.mediaLayers.isEmpty || !show.overlays.isEmpty || audio.buses.contains(where: \.playing)
    }

    public static func position(_ position: Double, duration: Double?, playing: Bool, looping: Bool, from at: Date, to now: Date) -> Double {
        guard playing else { return position }
        let moved = position + max(0, now.timeIntervalSince(at))
        guard let duration, duration > 0 else { return moved }
        return looping ? moved.truncatingRemainder(dividingBy: duration) : min(moved, duration)
    }

    public func takeover(here: APIShowStatus, now: Date) -> [APIFireEvent] {
        var events = FollowReplay.catchUp(booth: show, here: here)
        if let live = show.liveSlide {
            events.append(APIFireEvent(kind: .slide, slide: APIFireSlideCommand(
                presentationId: live.presentationId, slideId: live.slideId,
                serviceItemId: live.serviceItemId, occurrence: live.occurrence)))
        }
        for row in transport {
            let at = Self.position(row.position, duration: row.duration, playing: row.playing, looping: row.looping, from: self.at, to: now)
            events.append(APIFireEvent(kind: .mediaTransport, id: row.mediaId, mediaTransport: APIMediaTransportCommand(action: "seek", position: at)))
            if !row.playing {
                events.append(APIFireEvent(kind: .mediaTransport, id: row.mediaId, mediaTransport: APIMediaTransportCommand(action: "pause")))
            }
        }
        for bus in audio?.buses ?? [] where bus.playing && bus.playlistId == nil {
            guard let item = bus.audioItemId else { continue }
            events.append(APIFireEvent(kind: .audioItem, id: item))
            if let position = bus.position {
                let at = Self.position(position, duration: bus.duration, playing: true, looping: false, from: self.at, to: now)
                events.append(APIFireEvent(kind: .audioTransport, audioTransport: APIAudioTransportCommand(action: "seek", position: at)))
            }
        }
        return events
    }
}

public final class FollowPairing: @unchecked Sendable {
    public static let maxAttempts = 5

    private let lock = NSLock()
    private var code: String
    private var misses = 0

    public init(code: String = FollowPairing.newCode()) {
        self.code = code
    }

    public static func newCode() -> String {
        String(format: "%04d", Int.random(in: 0...9999))
    }

    public var current: String? {
        lock.lock()
        defer { lock.unlock() }
        return misses < Self.maxAttempts ? code : nil
    }

    @discardableResult
    public func refresh() -> String {
        lock.lock()
        defer { lock.unlock() }
        code = Self.newCode()
        misses = 0
        return code
    }

    public func answer(_ body: Data, teamHexId: String?, tokens: APITokenStore) -> APIHandlerResponse {
        guard let request = try? JSONDecoder().decode(APIFollowPairRequest.self, from: body) else {
            return .json(APIError.badRequest("Send code, teamHexId, stationHexId and name."), status: 400)
        }
        guard let teamHexId, request.teamHexId == teamHexId else {
            return .json(APIError(status: 403, code: "other_team", message: "That computer isn't on this team."), status: 403)
        }
        lock.lock()
        let matched = misses < Self.maxAttempts && request.code == code
        if !matched { misses += 1 }
        lock.unlock()
        guard matched else {
            return .json(APIError(status: 403, code: "wrong_code", message: "That code doesn't match. Check the code this computer shows."), status: 403)
        }

        let name = FollowPresence.prefix + request.name
        for old in tokens.all where old.name == name { tokens.revoke(id: old.id) }
        let minted = tokens.create(name: name, scope: .control)
        return .json(APIFollowPairResponse(token: minted.secret))
    }
}

public final class FollowPresence: @unchecked Sendable {

    public static let prefix = "Backup: "

    public static func backupName(_ tokenName: String) -> String? {
        tokenName.hasPrefix(prefix) ? String(tokenName.dropFirst(prefix.count)) : nil
    }

    private let lostAfter: Duration
    private let changed: @Sendable (Set<String>) -> Void
    private let lock = NSLock()
    private var heard: [String: UUID] = [:]

    public init(lostAfter: Duration = .seconds(4), changed: @escaping @Sendable (Set<String>) -> Void) {
        self.lostAfter = lostAfter
        self.changed = changed
    }

    public func heard(tokenName: String) {
        guard let name = Self.backupName(tokenName) else { return }
        let mark = UUID()
        lock.lock()
        let isNew = heard[name] == nil
        heard[name] = mark
        let names = Set(heard.keys)
        lock.unlock()
        if isNew { changed(names) }
        Task { [weak self, lostAfter] in
            try? await Task.sleep(for: lostAfter)
            self?.expire(name, mark)
        }
    }

    private func expire(_ name: String, _ mark: UUID) {
        lock.lock()
        guard heard[name] == mark else { return lock.unlock() }
        heard[name] = nil
        let names = Set(heard.keys)
        lock.unlock()
        changed(names)
    }
}

public struct APIFollowPairRequest: Codable, Sendable, Equatable {
    public var code: String
    public var teamHexId: String
    public var stationHexId: String
    public var name: String

    public init(code: String, teamHexId: String, stationHexId: String, name: String) {
        self.code = code
        self.teamHexId = teamHexId
        self.stationHexId = stationHexId
        self.name = name
    }
}

public struct APIFollowPairResponse: Codable, Sendable, Equatable {
    public var token: String
}

public enum FollowHold {

    public static let prefix = "/v1/follow"

    public static func error(for route: APIRoute, following name: String) -> APIError? {
        route.scope == .view || route.path.hasPrefix(prefix) ? nil : APIError(
            status: 409, code: "backing_up",
            message: "\(name) is in charge. This computer answers again once it takes over.")
    }
}

public struct APIFollowRoleCommand: Codable, Sendable, Equatable {
    public var term: Int
    public var inCharge: String

    public var name: String

    public init(term: Int, inCharge: String, name: String) {
        self.term = term
        self.inCharge = inCharge
        self.name = name
    }
}

public struct APIFollowStatus: Codable, Sendable, Equatable {

    public var role: String

    public var name: String?

    public var health: String?
    public var term: Int?

    public var streamPresetId: String?

    public var launch: String?

    public init(role: String, name: String? = nil, health: String? = nil, term: Int? = nil, streamPresetId: String? = nil, launch: String? = nil) {
        self.launch = launch
        self.role = role
        self.name = name
        self.health = health
        self.term = term
        self.streamPresetId = streamPresetId
    }
}

public enum FollowFiles {

    public struct Item: Codable, Sendable, Equatable {
        public var kind: String
        public var id: String
        public var heads: [String]
        public var file: String?
        public var ext: String?

        public var area: String?

        public init(kind: String, id: String, heads: [String], file: String? = nil, ext: String? = nil, area: String? = nil) {
            self.kind = kind
            self.id = id
            self.heads = heads
            self.file = file
            self.ext = ext
            self.area = area
        }
    }

    public struct List: Codable, Sendable, Equatable {
        public var items: [Item]
        public init(items: [Item]) { self.items = items }
    }

    public struct Document: Codable, Sendable, Equatable {

        public var bytes: Data
        public init(bytes: Data) { self.bytes = bytes }
    }

    public static func wanted(_ items: [Item], heads: [String: [String]], filesHere: Set<String>) -> (documents: [Item], files: [String]) {
        let documents = items.filter { heads["\($0.kind)/\($0.id)"] != $0.heads }
        return (documents, Set(items.compactMap(\.file)).subtracting(filesHere).sorted())
    }

    public static func gone(copied: Set<String>, booth: [Item]) -> [String] {
        copied.subtracting(booth.map { "\($0.kind)/\($0.id)" }).sorted()
    }

    public static func isHash(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }
}
