import Foundation

public struct TimecodeRecording: Equatable, Sendable {
    public var itemID: String

    public var start: Int?

    public var started = false

    public init(itemID: String, start: Int?) {
        self.itemID = itemID
        self.start = start
    }

    public enum Mode: Equatable, Sendable {

        case ownClock

        case timecode(start: Int?)
    }

    public static func mode(
        timeline: PresentationTimeline?, start: Int? = nil, hasInput: Bool, follows: Bool
    ) -> Mode {
        guard hasInput, follows else { return .ownClock }
        guard let timeline else { return .timecode(start: nil) }
        return timeline.timecodeEnabled ? .timecode(start: start ?? timeline.timecodeStart) : .ownClock
    }

    public static func start(from label: TimecodeLabel) -> Int {
        (label.hours * 3600 + label.minutes * 60) * PresentationTimelines.framesPerSecond
    }

    public enum Step: Equatable, Sendable {
        case none

        case begin(start: Int, at: Double)

        case end
    }

    public func step(_ reading: TimecodeClock.Reading) -> Step {
        guard reading.live else {
            return started && (reading.state == .stopped || reading.state == .noInput) ? .end : .none
        }
        guard !started, let seconds = reading.position, let rate = reading.rate,
              let start = start ?? reading.label.map(Self.start(from:))
        else { return .none }
        let position = seconds - rate.seconds(rate.label(startFrames: start))
        return position >= 0 ? .begin(start: start, at: position) : .none
    }

    public func songs(_ songs: [TimecodeFollow.Song]) -> [TimecodeFollow.Song] {
        songs.filter { $0.itemID == itemID }.map {
            var song = $0
            song.length = .greatestFiniteMagnitude
            return song
        }
    }
}
