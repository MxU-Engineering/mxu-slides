import Foundation

public struct PlatformHealthTracker: Sendable, Equatable {
    public enum Verdict: Equatable, Sendable {
        case healthy

        case degraded(issues: [String])

        case noData
    }

    public static let defaultGraceSeconds: TimeInterval = 90
    public static let defaultEscalationPolls = 3

    public let graceSeconds: TimeInterval
    public let escalationPolls: Int
    private var consecutiveNoData: [String: Int] = [:]
    private var settled: Set<String> = []
    private var verdicts: [String: Verdict] = [:]

    public init(
        graceSeconds: TimeInterval = PlatformHealthTracker.defaultGraceSeconds,
        escalationPolls: Int = PlatformHealthTracker.defaultEscalationPolls
    ) {
        self.graceSeconds = graceSeconds
        self.escalationPolls = escalationPolls
    }

    public func pollsHot(_ destinationID: String) -> Bool {
        !settled.contains(destinationID)
    }

    public func verdict(_ destinationID: String) -> Verdict? {
        verdicts[destinationID]
    }

    public mutating func record(
        _ destinationID: String, status: String, issues: [String], elapsed: TimeInterval
    ) {
        guard status != "unknown" else { return }
        switch status {
        case "noData":

            if !settled.contains(destinationID), elapsed < graceSeconds { return }
            settled.remove(destinationID)
            let count = (consecutiveNoData[destinationID] ?? 0) + 1
            consecutiveNoData[destinationID] = count
            if count >= escalationPolls { verdicts[destinationID] = .noData }
        case "bad":
            settled.remove(destinationID)
            consecutiveNoData[destinationID] = 0
            verdicts[destinationID] = .degraded(issues: issues)
        default:
            settled.insert(destinationID)
            consecutiveNoData[destinationID] = 0
            verdicts[destinationID] = .healthy
        }
    }

    public mutating func reset() {
        consecutiveNoData = [:]
        settled = []
        verdicts = [:]
    }
}

public enum StreamHealthRollup {
    public enum Tint: Equatable, Sendable { case none, green, amber, red }

    public struct Input: Equatable, Sendable {
        public var state: StreamSession.State
        public var verdict: PlatformHealthTracker.Verdict?
        public init(state: StreamSession.State, verdict: PlatformHealthTracker.Verdict? = nil) {
            self.state = state
            self.verdict = verdict
        }
    }

    public static func tint(_ inputs: [Input]) -> Tint {
        guard !inputs.isEmpty else { return .none }
        var tint = Tint.green
        for input in inputs {
            switch input.state {
            case .failed: return .red
            case .reconnecting, .connecting: tint = .amber
            case .publishing where input.verdict == .noData: tint = .amber
            default: break
            }
        }
        return tint
    }

    public static func word(_ inputs: [Input]) -> String {
        if inputs.contains(where: { if case .failed = $0.state { return true }; return false }) {
            return "STREAM FAILED"
        }
        if inputs.contains(where: { if case .reconnecting = $0.state { return true }; return false }) {
            return "RECONNECTING"
        }
        if inputs.contains(where: { $0.state == .connecting }) { return "CONNECTING" }
        if inputs.contains(where: { $0.state == .publishing && $0.verdict == .noData }) {
            return "NO DATA"
        }
        return "LIVE"
    }
}
