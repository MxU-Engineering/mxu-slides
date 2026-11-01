import Foundation

public enum FollowReplay {
    public static func replays(_ event: APIFireEvent) -> Bool {
        event.cause == nil && event.kind != .role && event.kind != .capture
    }

    public static func command(for slide: APIFireSlideCommand) -> APIFireSlideCommand {
        var slide = slide
        if slide.serviceItemId != nil, slide.serviceItemId == slide.presentationId {
            slide.serviceItemId = nil
        }
        return slide
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
        case .role, .capture: break
        }
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
        let minted = tokens.create(name: "Backup: \(request.name)", scope: .control)
        return .json(APIFollowPairResponse(token: minted.secret))
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

    public init(role: String, name: String? = nil, health: String? = nil, term: Int? = nil, streamPresetId: String? = nil) {
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

        public init(kind: String, id: String, heads: [String], file: String? = nil, ext: String? = nil) {
            self.kind = kind
            self.id = id
            self.heads = heads
            self.file = file
            self.ext = ext
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

    public static func isHash(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }
}
