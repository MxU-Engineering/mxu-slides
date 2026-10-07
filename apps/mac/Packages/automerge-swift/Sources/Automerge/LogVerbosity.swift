public enum LogVerbosity: Int, Comparable, Equatable, Sendable {

    public nonisolated static func < (lhs: LogVerbosity, rhs: LogVerbosity) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    case errorOnly = 3

    case debug = 6

    case tracing = 8

    public nonisolated func canDebug() -> Bool {
        self >= LogVerbosity.debug
    }

    public nonisolated func canTrace() -> Bool {
        self >= LogVerbosity.debug
    }
}
