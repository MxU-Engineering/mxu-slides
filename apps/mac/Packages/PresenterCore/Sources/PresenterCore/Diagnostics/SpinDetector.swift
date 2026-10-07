import Foundation

public struct SpinDetector: Sendable {
    public static let busyShare = 0.8

    public static let endShare = 0.5
    public static let window = 3.0
    public static let slotSeconds = 0.1

    public static let spinsPerMinute = 2

    public struct Spin: Sendable, Equatable {

        public var since: Double

        public var share: Double

        public var quietFor: Double

        public var lasted: Double = 0

        public var peakShare: Double

        public var detail: String {
            let quiet = quietFor.isFinite ? String(format: "%.1f s", quietFor) : "launch"
            return String(format: "main busy %.0f%% for %.1f s, no input for %@", share * 100, SpinDetector.window, quiet)
        }

        public var endDetail: String {
            String(format: "lasted %.1f s, peak %.0f%% busy", lasted, peakShare * 100)
        }
    }

    public enum Event: Sendable, Equatable {
        case began(Spin, dropped: Int)
        case ended(Spin)
    }

    private static var slotCount: Int { Int((window / slotSeconds).rounded()) + 2 }

    private var busy: [Double]

    private var slotNumber: [Int]
    private var openPassStart: Double?
    private var lastInputAt = -Double.infinity
    private var current: Spin?
    private var lines = PerfLineLimiter(perMinute: SpinDetector.spinsPerMinute)

    public init() {
        busy = Array(repeating: 0, count: Self.slotCount)
        slotNumber = Array(repeating: Int.min, count: Self.slotCount)
    }

    public var isSpinning: Bool { current != nil }

    public mutating func passBegan(at time: Double) {
        openPassStart = time
    }

    public mutating func passEnded(at time: Double) {
        if let start = openPassStart {
            openPassStart = nil
            add(from: start, to: time)
        }
    }

    public mutating func input(at time: Double) {
        lastInputAt = max(lastInputAt, time)
    }

    public func share(at now: Double) -> Double {
        let from = now - Self.window
        let first = Self.slot(of: from)
        var total = 0.0
        for index in busy.indices where slotNumber[index] >= first {

            let start = Double(slotNumber[index]) * Self.slotSeconds
            let inside = min(1, max(0, (start + Self.slotSeconds - from) / Self.slotSeconds))
            total += slotNumber[index] == first ? busy[index] * inside : busy[index]
        }
        if let open = openPassStart {
            total += max(0, now - max(open, from))
        }
        return min(1, total / Self.window)
    }

    public mutating func evaluate(at now: Double) -> Event? {
        let share = share(at: now)
        if var spin = current {
            spin.peakShare = max(spin.peakShare, share)
            if share < Self.endShare {
                spin.lasted = now - spin.since
                current = nil
                return .ended(spin)
            } else {
                current = spin
                return nil
            }
        } else if share >= Self.busyShare, now - lastInputAt >= Self.window {
            let spin = Spin(since: now - Self.window, share: share, quietFor: now - lastInputAt, peakShare: share)
            current = spin
            return lines.admit("spin", now: now).map { .began(spin, dropped: $0) }
        } else {
            return nil
        }
    }

    private static func slot(of time: Double) -> Int {
        Int((time / slotSeconds).rounded(.down))
    }

    private mutating func add(from start: Double, to end: Double) {

        let from = max(start, end - Self.window)
        guard end > from else { return }
        for number in Self.slot(of: from)...Self.slot(of: end) {
            let slotStart = Double(number) * Self.slotSeconds
            let piece = min(end, slotStart + Self.slotSeconds) - max(from, slotStart)
            guard piece > 0 else { continue }
            let index = ((number % Self.slotCount) + Self.slotCount) % Self.slotCount
            if slotNumber[index] != number {
                slotNumber[index] = number
                busy[index] = 0
            }
            busy[index] += piece
        }
    }
}
