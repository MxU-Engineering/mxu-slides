import Foundation

public struct MainPassMeter: Sendable {
    public static let bucketEdgesMS: [Double] = [16, 50, 100, 250]
    public static let lineThresholdMS = 100.0
    public static let linesPerMinute = 20

    public private(set) var over: [Int]
    private var lines = PerfLineLimiter(perMinute: MainPassMeter.linesPerMinute)

    public init() {
        over = Array(repeating: 0, count: Self.bucketEdgesMS.count)
    }

    public struct Line: Sendable, Equatable {
        public var ms: Double
        public var opens: MainPassOpens
        public var sqlStatements: Int
        public var dropped: Int

        public func detail(mode: String) -> String {
            let openMS = Double(opens.total.components.seconds) * 1000
                + Double(opens.total.components.attoseconds) / 1e15
            let opensPart = opens.count == 0
                ? "opens none"
                : String(format: "opens %@ %.1f ms", opens.breakdown, openMS)
            let line = String(format: "%@ %.0f ms, %@, sql %d", mode, ms, opensPart, sqlStatements)
            return PerfLineLimiter.annotate(line, dropped: dropped)
        }
    }

    public mutating func finish(ms: Double, opens: MainPassOpens, sqlStatements: Int, now: Double) -> Line? {
        for (index, edge) in Self.bucketEdgesMS.enumerated() where ms > edge {
            over[index] += 1
        }
        var line: Line?
        if ms >= Self.lineThresholdMS, let dropped = lines.admit("pass", now: now) {
            line = Line(ms: ms, opens: opens, sqlStatements: sqlStatements, dropped: dropped)
        }
        return line
    }

    public mutating func drainPulse() -> String {
        let parts = zip(Self.bucketEdgesMS, over).map { edge, count in ">\(Int(edge)):\(count)" }
        over = Array(repeating: 0, count: Self.bucketEdgesMS.count)
        return "passes " + parts.joined(separator: " ")
    }
}
