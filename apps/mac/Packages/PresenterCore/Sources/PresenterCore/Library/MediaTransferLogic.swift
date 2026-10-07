import Foundation

public enum MediaTransferLogic {

    public static func prioritized(_ queue: [String], first: [String]) -> [String] {
        let queued = Set(queue)
        var seen: Set<String> = []
        let front = first.filter { queued.contains($0) && seen.insert($0).inserted }
        return front + queue.filter { !seen.contains($0) }
    }

    public struct Rate: Equatable, Sendable {
        public static let weight = 0.3
        public static let minimumGap: TimeInterval = 0.5

        public private(set) var bytesPerSecond: Double?
        private var last: (at: TimeInterval, bytes: Int64)?

        public init() {}

        public mutating func record(movedBytes: Int64, at: TimeInterval) {
            if let last {
                let gap = at - last.at
                if gap >= Self.minimumGap {
                    let sample = Double(max(0, movedBytes - last.bytes)) / gap
                    bytesPerSecond = bytesPerSecond.map { $0 * (1 - Self.weight) + sample * Self.weight } ?? sample
                    self.last = (at, movedBytes)
                }
            } else {
                self.last = (at, movedBytes)
            }
        }

        public mutating func reset() {
            bytesPerSecond = nil
            last = nil
        }

        public static func == (lhs: Rate, rhs: Rate) -> Bool {
            lhs.bytesPerSecond == rhs.bytesPerSecond && lhs.last?.at == rhs.last?.at && lhs.last?.bytes == rhs.last?.bytes
        }
    }

    public static func secondsLeft(remainingBytes: Int64, bytesPerSecond: Double?) -> TimeInterval? {
        if let rate = bytesPerSecond, rate > 1 {
            return Double(max(0, remainingBytes)) / rate
        } else {
            return nil
        }
    }

    public static func timeLeftLabel(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        if seconds < 60 {
            return "less than a minute"
        } else if minutes < 60 {
            return "about \(minutes) min"
        } else if minutes % 60 == 0 {
            return "about \(minutes / 60) h"
        } else {
            return "about \(minutes / 60) h \(minutes % 60) min"
        }
    }

    public static func sizeLabel(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    public static func placeLabel(_ place: Int) -> String {
        if place <= 1 {
            return "next"
        } else if (11...13).contains(place % 100) {
            return "\(place)th"
        } else {
            let suffix = [1: "st", 2: "nd", 3: "rd"][place % 10] ?? "th"
            return "\(place)\(suffix)"
        }
    }
}
