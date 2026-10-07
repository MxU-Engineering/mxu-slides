import Foundation

public struct BodyStormMeter: Sendable {
    public static let stormSeconds = 2
    public static let linesPerMinute = 6

    public struct Storm: Sendable, Equatable {
        public var view: Int

        public var perSecond: Int

        public var seconds: Int
        public var dropped: Int
    }

    private let limits: [Int]
    private var counts: [Int]
    private var overSeconds: [Int]
    private var reported: [Bool]

    private var peaks: [Int]

    private var sinceMark: [Int]
    private var second = Int.min
    private var lines = PerfLineLimiter(perMinute: BodyStormMeter.linesPerMinute)

    public init(limits: [Int]) {
        self.limits = limits
        counts = Array(repeating: 0, count: limits.count)
        overSeconds = counts
        reported = Array(repeating: false, count: limits.count)
        peaks = counts
        sinceMark = counts
    }

    public mutating func tick(_ view: Int, now: Double) -> Storm? {
        var storm: Storm?
        let current = Int(now.rounded(.down))
        if current != second {
            storm = close(upTo: current, now: now)
        }
        counts[view] += 1
        sinceMark[view] += 1
        return storm
    }

    public mutating func drainMark(names: [String]) -> String {
        let parts = sinceMark.indices.filter { sinceMark[$0] > 0 }.map { "\(names[$0]) \(sinceMark[$0])" }
        for view in sinceMark.indices { sinceMark[view] = 0 }
        return parts.isEmpty ? "bodies none" : "bodies " + parts.joined(separator: " ")
    }

    public mutating func drainPulse(names: [String]) -> String {
        let parts = peaks.indices.filter { peaks[$0] > 0 }.map { "\(names[$0]) \(peaks[$0])" }
        for view in peaks.indices { peaks[view] = 0 }
        return parts.isEmpty ? "bodies peak/s none" : "bodies peak/s " + parts.joined(separator: " ")
    }

    private mutating func close(upTo current: Int, now: Double) -> Storm? {
        var storm: Storm?
        let gap = current != second &+ 1
        for view in counts.indices {
            peaks[view] = max(peaks[view], counts[view])
            if counts[view] > limits[view] {
                overSeconds[view] += 1
            } else {
                overSeconds[view] = 0
                reported[view] = false
            }
            if storm == nil, overSeconds[view] >= Self.stormSeconds, !reported[view] {
                reported[view] = true
                if let dropped = lines.admit("storm", now: now) {
                    storm = Storm(view: view, perSecond: counts[view], seconds: overSeconds[view], dropped: dropped)
                }
            }
            if gap {
                overSeconds[view] = 0
                reported[view] = false
            }
            counts[view] = 0
        }
        second = current
        return storm
    }
}
