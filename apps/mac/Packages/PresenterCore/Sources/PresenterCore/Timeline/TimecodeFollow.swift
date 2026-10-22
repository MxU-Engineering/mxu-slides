import Foundation

public struct TimecodeClock: Sendable {
    public enum State: Equatable, Sendable {
        case noInput, locking, locked, freewheel, stopped
    }

    public struct Reading: Equatable, Sendable {
        public var state: State

        public var position: Double?

        public var label: TimecodeLabel?
        public var rate: TimecodeRate?
        public var reverse: Bool

        public init(
            state: State, position: Double? = nil, label: TimecodeLabel? = nil, rate: TimecodeRate? = nil,
            reverse: Bool = false
        ) {
            self.state = state
            self.position = position
            self.label = label
            self.rate = rate
            self.reverse = reverse
        }

        public var live: Bool { state == .locked && !reverse }
    }

    public static let lockFrames = 3

    public static let dropout = 0.15

    public static let freewheel = 0.5

    private struct Mark: Sendable {
        var position: Double
        var hostTime: Double
        var label: TimecodeLabel
        var rate: TimecodeRate
        var reverse: Bool

        func position(at time: Double) -> Double {
            position + (time - hostTime) * (reverse ? -1 : 1)
        }

        func continues(_ next: Mark) -> Bool {
            next.reverse == reverse && next.rate.nominal == rate.nominal
                && abs(next.position - position(at: next.hostTime)) <= 1.5 / rate.actual
        }
    }

    private var anchor: Mark?

    private var candidate: Mark?
    private var good = 0

    public init() {}

    public mutating func receive(_ frame: LTCFrame, rate: TimecodeRate, hostTime: Double) {

        let next = Mark(
            position: rate.seconds(frame.label) + (frame.reverse ? 0 : 1 / rate.actual),
            hostTime: hostTime, label: frame.label, rate: rate, reverse: frame.reverse)
        guard let anchor, hostTime - anchor.hostTime <= Self.dropout + Self.freewheel else {

            self.anchor = next
            candidate = nil
            good = 1
            return
        }
        if anchor.continues(next) {
            self.anchor = next
            candidate = nil
            good += 1
        } else if let candidate, candidate.continues(next) {

            self.anchor = next
            self.candidate = nil
            good = good >= Self.lockFrames ? good : 2
        } else {
            candidate = next
        }
    }

    public func reading(at time: Double) -> Reading {
        guard let anchor else { return Reading(state: .noInput) }
        let since = time - anchor.hostTime
        let locked = good >= Self.lockFrames
        let state: State
        if since <= Self.dropout {
            state = locked ? .locked : .locking
        } else if since <= Self.dropout + Self.freewheel {
            state = locked ? .freewheel : .locking
        } else {
            state = locked ? .stopped : .noInput
        }

        let position = state == .stopped ? anchor.position : anchor.position(at: time)
        return Reading(
            state: state, position: state == .noInput ? nil : position, label: anchor.label, rate: anchor.rate,
            reverse: anchor.reverse)
    }
}

public struct TimecodeFollow: Sendable {

    public struct Song: Equatable, Sendable {
        public var itemID: String

        public var startFrames: Int

        public var length: Double

        public init(itemID: String, startFrames: Int, length: Double) {
            self.itemID = itemID
            self.startFrames = startFrames
            self.length = length
        }
    }

    public enum Command: Equatable, Sendable {

        case play(itemID: String, from: Double, to: Double)

        case land(itemID: String, at: Double)

        public var itemID: String {
            switch self {
            case .play(let id, _, _), .land(let id, _): id
            }
        }

        public var position: Double {
            switch self {
            case .play(_, _, let to): to
            case .land(_, let at): at
            }
        }
    }

    public static let jump = 1.0

    public static let stepBackFrames = 3

    public private(set) var itemID: String?
    public private(set) var position: Double?

    public init() {}

    public static func song(
        containing seconds: Double, rate: TimecodeRate, in songs: [Song]
    ) -> (song: Song, position: Double)? {
        for song in songs {
            let position = seconds - rate.seconds(rate.label(startFrames: song.startFrames))
            if position >= 0, position < song.length { return (song, position) }
        }
        return nil
    }

    public mutating func step(_ reading: TimecodeClock.Reading, songs: [Song]) -> Command? {
        guard reading.live, let seconds = reading.position, let rate = reading.rate,
              let (song, position) = Self.song(containing: seconds, rate: rate, in: songs)
        else { return nil }
        let id = song.itemID
        defer { itemID = id }
        guard id == itemID, let last = self.position else {

            self.position = position
            return Self.enter(id, at: position)
        }
        let delta = position - last
        if delta <= 0, -delta <= Double(Self.stepBackFrames) / rate.actual + 0.001 { return nil }
        self.position = position
        if delta > 0, delta <= Self.jump { return .play(itemID: id, from: last, to: position) }
        return Self.enter(id, at: position)
    }

    private static func enter(_ id: String, at position: Double) -> Command {
        position <= jump
            ? .play(itemID: id, from: -PresentationTimelines.frame, to: position)
            : .land(itemID: id, at: position)
    }
}
