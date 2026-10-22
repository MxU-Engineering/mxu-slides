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

    private var anchor: TimecodeHeard?

    private var candidate: TimecodeHeard?
    private var good = 0

    public init() {}

    public mutating func receive(_ frame: LTCFrame, rate: TimecodeRate, hostTime: Double) {
        receive(TimecodeHeard(ltc: frame, rate: rate, hostTime: hostTime))
    }

    public mutating func receive(_ next: TimecodeHeard) {
        let hostTime = next.hostTime
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

public enum TimecodeStation {
    public static let deviceKey = "timecode.deviceUID"

    public static let channelKey = "timecode.channel"

    public static let offsetKey = "timecode.offsetFrames"

    public static let followKey = "timecode.follow"

    public static let audioKey = "timecode.playsAudio"

    public static let sourceKey = "timecode.source"

    public static let midiSourceKey = "timecode.midiSourceUID"
    public static let keys = [deviceKey, channelKey, offsetKey, followKey, audioKey, sourceKey, midiSourceKey]
    public static let offsetRange = -30...30
}

public struct TimecodeFollow: Sendable {

    public struct Song: Equatable, Sendable {
        public var itemID: String

        public var startFrames: Int

        public var length: Double

        public var tail: Double

        public init(itemID: String, startFrames: Int, length: Double, tail: Double = 0) {
            self.itemID = itemID
            self.startFrames = startFrames
            self.length = length
            self.tail = tail
        }

        public init(itemID: String, timeline: PresentationTimeline, start: Int? = nil) {
            self.init(
                itemID: itemID, startFrames: start ?? timeline.timecodeStart,
                length: PresentationTimelines.length(timeline), tail: timeline.length == nil ? 1 : 0)
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
        let placed = songs.map { ($0, seconds - rate.seconds(rate.label(startFrames: $0.startFrames))) }
        return placed.first { $0.1 >= 0 && $0.1 < $0.0.length }
            ?? placed.first { $0.1 >= 0 && $0.1 < $0.0.length + $0.0.tail }
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

    public static func clashes(_ songs: [Song]) -> Set<String> {
        let windows = songs.map {
            PresentationTimelines.Window(
                id: $0.itemID, start: $0.startFrames, length: PresentationTimelines.frames(seconds: $0.length + $0.tail))
        }
        return Set(windows.filter { !PresentationTimelines.overlaps($0, in: windows).isEmpty }.map(\.id))
    }

    public struct CueRow: Equatable, Sendable {
        public var id: String

        public var timecode: String

        public var label: String
        public var at: Double
    }

    public static func cueRows(
        _ timeline: PresentationTimeline, start: Int? = nil, blocks: [TimelinePlayedBlock],
        sectionName: (String?) -> String
    ) -> [CueRow] {
        var starts: [Int] = []
        var index = 0
        for block in blocks {
            starts.append(index)
            index += block.slideIds.count
        }
        return timeline.cues.filter { $0.kind == .slide }.sorted { $0.at < $1.at }.compactMap { cue in
            guard let occurrence = PresentationTimelines.occurrence(of: cue, in: blocks),
                  let block = starts.lastIndex(where: { $0 <= occurrence }) else { return nil }
            let frames = (start ?? timeline.timecodeStart) + Int((cue.at * Double(PresentationTimelines.framesPerSecond)).rounded())
            return CueRow(
                id: cue.id, timecode: PresentationTimelines.timecode(frames: frames),
                label: "\(sectionName(blocks[block].sectionId)) · \(occurrence - starts[block] + 1)", at: cue.at)
        }
    }

    public static func underTimecode(
        _ effects: [PresentationTimelines.Effect], playsAudio: Bool = false
    ) -> [PresentationTimelines.Effect] {
        if playsAudio { return effects }
        return effects.filter {
            switch $0 {
            case .playAudio: false
            case .fire(let lane, _), .clear(let lane, _): lane != .audio
            case .showSlide, .runActions: true
            }
        }
    }

    public static func followedCues(_ cues: [TimelineCue], blocks: [TimelinePlayedBlock]) -> [TimelineCue] {
        guard !cues.contains(where: { $0.kind == .slide }),
              let anchor = PresentationTimelines.anchor(occurrence: 0, in: blocks) else { return cues }
        return [PresentationTimelines.slideCue(id: "timecode.firstSlide", at: 0, anchor: anchor)] + cues
    }

    public static let audioDrift = 0.5

    public static func audioSync(
        _ cues: [TimelineCue], at position: Double, playing: [String: Double]
    ) -> [PresentationTimelines.Effect] {
        let tracks = cues.filter { $0.kind == .audio && $0.contentId != nil }
        let held = tracks.filter {
            $0.at <= position && position < PresentationTimelines.end(of: $0, in: cues)
        }.max { $0.at < $1.at }
        var effects: [PresentationTimelines.Effect] = []
        for id in Set(tracks.compactMap(\.contentId)).sorted() where id != held?.contentId && playing[id] != nil {
            effects.append(.clear(lane: .audio, id: id))
        }
        if let held, let id = held.contentId {
            let due = position - held.at
            if let at = playing[id], abs(at - due) <= audioDrift {
                return effects
            }
            effects.append(.playAudio(id: id, from: due))
        }
        return effects
    }

    private static func enter(_ id: String, at position: Double) -> Command {
        position <= jump
            ? .play(itemID: id, from: -PresentationTimelines.frame, to: position)
            : .land(itemID: id, at: position)
    }
}
