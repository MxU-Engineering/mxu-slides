import Foundation

public enum SyncOwedLogic {

    public static func isOwed(entry: SyncLedger.Entry?, recordedHeads: [String]?) -> Bool {
        if let entry {
            entry.pending || (recordedHeads.map { $0 != entry.lastPushedHeads } ?? false)
        } else {
            false
        }
    }

    public static func owed(
        entries: [SyncLedger.Key: SyncLedger.Entry], recordedHeads: [SyncLedger.Key: [String]],
        namespace: (SyncLedger.Key) -> SyncScope?
    ) -> [SyncLedger.Key] {
        entries
            .filter { isOwed(entry: $0.value, recordedHeads: recordedHeads[$0.key]) && namespace($0.key) != nil }
            .map(\.key)
            .sorted { ($0.kind.rawValue, $0.id) < ($1.kind.rawValue, $1.id) }
    }
}

public enum SyncOwedPass {
    public enum Verdict: Equatable, Sendable {

        case skip(String)

        case paused
        case run
    }

    public static func verdict(
        identityAllows: @autoclosure () -> Bool,
        signedIn: @autoclosure () -> Bool,
        rateLimited: @autoclosure () -> Bool,
        paused: @autoclosure () -> Bool
    ) -> Verdict {
        if !identityAllows() {
            .skip("identity")
        } else if !signedIn() {
            .skip("signed out")
        } else if rateLimited() {
            .skip("rate limited")
        } else if paused() {
            .paused
        } else {
            .run
        }
    }

    public static func due(
        _ owed: [SyncLedger.Key], waiting: Set<SyncLedger.Key>, busy: Set<SyncLedger.Key>, allowed: (SyncLedger.Key) -> Bool
    ) -> [SyncLedger.Key] {
        owed.filter { !waiting.contains($0) && !busy.contains($0) && allowed($0) }
    }
}

public struct SyncRefreshCoalescer: Equatable, Sendable {
    public private(set) var running = false
    public private(set) var owed = false

    public static let safetyNetInterval: TimeInterval = 60

    public init() {}

    public mutating func request() -> Bool {
        if running {
            owed = true
            return false
        } else {
            running = true
            return true
        }
    }

    public mutating func finish() -> Bool {
        if owed {
            owed = false
            return true
        } else {
            running = false
            return false
        }
    }

    public func safetyNetDue(lastFinished: Date?, now: Date) -> Bool {
        !running && (lastFinished.map { now.timeIntervalSince($0) >= Self.safetyNetInterval } ?? true)
    }
}
