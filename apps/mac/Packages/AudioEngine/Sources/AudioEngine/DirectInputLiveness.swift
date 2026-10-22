import Foundation

public struct DirectInputLiveness: Equatable, Sendable {

    public static let silentSeconds: Double = 3

    public enum FailureAction: Equatable, Sendable {

        case ignore
        case retry(note: Bool)
    }

    public var running = false
    public private(set) var isOpen = false
    public private(set) var retryPending = false
    public private(set) var lastArrivalAt: Double = -.infinity
    public private(set) var lastError: String?

    public init() {}

    public mutating func opened(at now: Double) {
        isOpen = true
        lastError = nil
        lastArrivalAt = now
    }

    public mutating func arrived(at now: Double) {
        lastArrivalAt = now
    }

    public mutating func opening() {
        isOpen = false
    }

    public mutating func stopped() {
        running = false
        isOpen = false
    }

    public mutating func failed(_ message: String, current: Bool) -> FailureAction {
        if running, current, !retryPending {
            isOpen = false
            retryPending = true
            let note = lastError != message
            lastError = message
            return .retry(note: note)
        } else {
            return .ignore
        }
    }

    public mutating func retrying() {
        retryPending = false
    }

    public func shouldReopen(at now: Double) -> Bool {
        running && isOpen && !retryPending && now - lastArrivalAt > Self.silentSeconds
    }
}
