import Foundation

public enum SongTransitions {
    public enum Kind: String, CaseIterable, Sendable {
        case stop, fade, overlap, crossfade
    }

    public static let defaultSeconds = 5.0

    public static func kind(_ transition: SongTransition?) -> Kind {
        transition.flatMap { Kind(rawValue: $0.kind) } ?? .stop
    }

    public static func length(_ transition: SongTransition?, lastSection: Double? = nil, nextFirstSection: Double? = nil) -> Double {
        if let seconds = transition?.seconds, seconds > 0 { return seconds }
        guard kind(transition) == .overlap else { return defaultSeconds }
        return ([defaultSeconds] + [lastSection, nextFirstSection].compactMap { $0 }.filter { $0 > 0 }).min()!
    }

    public static func manualCrossfade(_ transition: SongTransition?) -> Double {
        transition?.seconds.flatMap { $0 > 0 ? $0 : nil } ?? defaultSeconds
    }

    public struct Plan: Equatable, Sendable {
        public var kind: Kind

        public var nextAt: Double

        public var fadeFrom: Double?
        public var fadeSeconds: Double

        public var fadeInSeconds: Double

        public var end: Double
    }

    public static func plan(_ kind: Kind, end: Double, length: Double) -> Plan? {
        let length = min(max(length, 0), max(end, 0))
        switch kind {
        case .stop:
            return nil
        case .fade:
            return Plan(kind: kind, nextAt: end, fadeFrom: end - length, fadeSeconds: length, fadeInSeconds: 0, end: end)
        case .overlap:
            return Plan(kind: kind, nextAt: end - length, fadeFrom: nil, fadeSeconds: 0, fadeInSeconds: 0, end: end)
        case .crossfade:
            return Plan(kind: kind, nextAt: end - length, fadeFrom: end - length, fadeSeconds: length, fadeInSeconds: length, end: end)
        }
    }

    public static func manualPlan(at position: Double, seconds: Double) -> Plan {
        Plan(kind: .crossfade, nextAt: position, fadeFrom: position, fadeSeconds: seconds, fadeInSeconds: seconds, end: position + seconds)
    }

    public static func landing(_ plan: Plan, at position: Double) -> Plan? {
        let first = min(plan.nextAt, plan.fadeFrom ?? plan.nextAt)
        guard position >= first else { return nil }
        let left = max(plan.end - position, 0)
        var started = plan
        started.nextAt = max(plan.nextAt, position)
        if plan.fadeFrom != nil {
            started.fadeFrom = position
            started.fadeSeconds = left
        }
        if plan.fadeInSeconds > 0 { started.fadeInSeconds = max(plan.end - started.nextAt, 0) }
        return started
    }

    public static func due(_ plan: Plan, from: Double, to: Double) -> Bool {
        from < plan.nextAt && to >= plan.nextAt
    }

    public static func arms(_ kind: Kind, ownClock: Bool, recording: Bool, held: Bool) -> Bool {
        kind != .stop && ownClock && !recording && !held
    }
}
