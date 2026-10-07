import Foundation

public struct SyncIdentity: Equatable, Sendable {
    public var serverHost: String
    public var teamHexId: String?
    public var teamName: String

    public init(serverHost: String, teamHexId: String?, teamName: String) {
        self.serverHost = serverHost
        self.teamHexId = teamHexId
        self.teamName = teamName
    }

    public enum Verdict: Equatable, Sendable {

        case adopt

        case match(upgrade: Bool)
        case mismatch
    }

    public static func verdict(stored: SyncIdentity?, current: SyncIdentity) -> Verdict {
        guard let stored else { return .adopt }
        guard stored.serverHost == current.serverHost else { return .mismatch }
        if let a = stored.teamHexId, let b = current.teamHexId { return a == b ? .match(upgrade: false) : .mismatch }
        guard stored.teamName == current.teamName else { return .mismatch }
        return .match(upgrade: stored.teamHexId == nil && current.teamHexId != nil)
    }
}

public struct SyncRetryBudget: Sendable {
    public static let maxAttempts = 10
    public static let maxDelay: TimeInterval = 300

    private var failures: [String: (count: Int, next: Date)] = [:]

    public init() {}

    public func allowed(_ key: String, now: Date = Date()) -> Bool {
        guard let entry = failures[key] else { return true }
        return entry.count < Self.maxAttempts && now >= entry.next
    }

    public func exhausted(_ key: String) -> Bool {
        (failures[key]?.count ?? 0) >= Self.maxAttempts
    }

    public mutating func failed(_ key: String, now: Date = Date()) {
        let count = (failures[key]?.count ?? 0) + 1
        let delay = min(Self.maxDelay, pow(2, Double(count)))
        failures[key] = (count, now.addingTimeInterval(delay))
    }

    public mutating func succeeded(_ key: String) { failures[key] = nil }

    public mutating func reset(_ key: String? = nil) {
        if let key { failures[key] = nil } else { failures.removeAll() }
    }

    public var restingCount: Int { failures.values.filter { $0.count >= Self.maxAttempts }.count }
}
