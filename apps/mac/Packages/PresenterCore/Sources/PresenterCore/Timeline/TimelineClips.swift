import Foundation

public enum TimelineClips {

    public enum Shape: String, CaseIterable, Sendable {
        case linear, sCurve, equalPower, fast, slow

        public init(_ stored: String?) { self = stored.flatMap(Shape.init(rawValue:)) ?? .linear }

        public var title: String {
            switch self {
            case .linear: "Linear"
            case .sCurve: "S-Curve"
            case .equalPower: "Equal Power"
            case .fast: "Fast"
            case .slow: "Slow"
            }
        }
    }

    public static let edgeSeconds = 0.005

    static let sameTime = 0.5 / 96_000

    public static func isClip(_ cue: TimelineCue) -> Bool {
        (cue.kind == .audio || cue.trackChannelId != nil) && cue.mediaId != nil
    }

    public static func split(
        _ cue: TimelineCue, at time: Double, in cues: [TimelineCue], openEnd: Double? = nil,
        newID: () -> String = { UUID().uuidString }
    ) -> (left: TimelineCue, right: TimelineCue)? {
        guard cue.isBlock else { return nil }
        let time = PresentationTimelines.snappedToFrame(time)
        var end = PresentationTimelines.end(of: cue, in: cues)
        if !end.isFinite, let openEnd { end = openEnd }
        guard time > cue.at + sameTime, time < end - sameTime else { return nil }
        var left = cue, right = cue
        left.duration = time - cue.at
        left.fadeOut = nil
        right.id = newID()
        right.at = time
        right.duration = end.isFinite ? end - time : nil
        right.fadeIn = nil
        if isClip(cue) { right.inPoint = (cue.inPoint ?? 0) + (time - cue.at) }
        return (fitted(left), fitted(right))
    }

    public static func splitting(
        _ ids: Set<String>, at time: Double, in cues: [TimelineCue], newID: () -> String = { UUID().uuidString }
    ) -> [TimelineCue] {
        var result: [TimelineCue] = []
        for cue in cues {
            if ids.contains(cue.id), let pieces = split(cue, at: time, in: cues, newID: newID) {
                result += [pieces.left, pieces.right]
            } else {
                result.append(cue)
            }
        }
        return result
    }

    public static func trimmedStart(_ cue: TimelineCue, by seconds: Double, end: Double) -> TimelineCue {
        var trimmed = cue
        let earliest = max(0, cue.at - (cue.inPoint ?? 0))
        trimmed.at = min(max(earliest, PresentationTimelines.snappedToFrame(cue.at + seconds)), end - PresentationTimelines.frame)
        trimmed.inPoint = max(0, (cue.inPoint ?? 0) + (trimmed.at - cue.at))
        if trimmed.inPoint ?? 0 < sameTime { trimmed.inPoint = nil }
        trimmed.duration = end - trimmed.at
        return fitted(trimmed)
    }

    public static func fitted(_ cue: TimelineCue) -> TimelineCue {
        guard let duration = cue.duration else { return cue }
        var fitted = cue
        if let fadeIn = cue.fadeIn {
            fitted.fadeIn = fadeIn.seconds > 0 ? ClipFade(seconds: min(fadeIn.seconds, duration), shape: fadeIn.shape, midpoint: fadeIn.midpoint) : nil
        }
        if let fadeOut = cue.fadeOut {
            let room = duration - (fitted.fadeIn?.seconds ?? 0)
            fitted.fadeOut = fadeOut.seconds > 0 && room > 0
                ? ClipFade(seconds: min(fadeOut.seconds, room), shape: fadeOut.shape, midpoint: fadeOut.midpoint) : nil
        }
        return fitted
    }

    public static func defaultFadeSeconds(_ cue: TimelineCue) -> Double {
        min(1, (cue.duration ?? 3) / 3)
    }

    public static func overlap(_ a: TimelineCue, _ b: TimelineCue, in cues: [TimelineCue]) -> ClosedRange<Double>? {
        guard a.id != b.id, a.lane == b.lane, isClip(a), isClip(b) else { return nil }
        let (first, second) = a.at <= b.at ? (a, b) : (b, a)
        let end = min(PresentationTimelines.end(of: first, in: cues), PresentationTimelines.end(of: second, in: cues))
        guard end.isFinite, end - second.at > sameTime else { return nil }
        return second.at ... end
    }

    public static func overlapping(_ cue: TimelineCue, in cues: [TimelineCue]) -> [TimelineCue] {
        cues.filter { overlap(cue, $0, in: cues) != nil }.sorted { $0.at < $1.at }
    }

    public static func crossfaded(
        _ a: TimelineCue, _ b: TimelineCue, in cues: [TimelineCue], shape: Shape = .equalPower
    ) -> (left: TimelineCue, right: TimelineCue)? {
        guard let overlap = overlap(a, b, in: cues) else { return nil }
        var (left, right) = a.at <= b.at ? (a, b) : (b, a)
        let fade = ClipFade(seconds: overlap.upperBound - overlap.lowerBound, shape: shape.rawValue)

        let leftEnd = PresentationTimelines.end(of: left, in: cues)
        left.fadeOut = ClipFade(seconds: leftEnd - overlap.lowerBound, shape: shape.rawValue)
        right.fadeIn = fade
        return (fitted(left), fitted(right))
    }

    public static func edges(of cue: TimelineCue, in cues: [TimelineCue]) -> (start: Bool, end: Bool) {
        guard cue.edgeFades ?? true else { return (false, false) }
        let end = PresentationTimelines.end(of: cue, in: cues)
        let read = (cue.inPoint ?? 0) + (end - cue.at)
        let joinsNext = cues.contains {
            $0.id != cue.id && $0.lane == cue.lane && $0.mediaId == cue.mediaId && abs($0.at - end) < sameTime
                && abs(($0.inPoint ?? 0) - read) < sameTime
        }
        let joinsPrevious = cues.contains { other in
            guard other.id != cue.id, other.lane == cue.lane, other.mediaId == cue.mediaId else { return false }
            let otherEnd = PresentationTimelines.end(of: other, in: cues)
            return abs(otherEnd - cue.at) < sameTime
                && abs((other.inPoint ?? 0) + (otherEnd - other.at) - (cue.inPoint ?? 0)) < sameTime
        }
        return (!joinsPrevious, !joinsNext)
    }

    public static func copied(_ cues: [TimelineCue], range: ClosedRange<Double>? = nil, all: [TimelineCue]) -> [TimelineCue] {
        guard let range else {
            let start = cues.map(\.at).min() ?? 0
            return cues.map { var cue = $0; cue.at -= start; return cue }
        }
        var kept: [TimelineCue] = []
        for var cue in cues {
            let end = PresentationTimelines.end(of: cue, in: all)
            guard cue.isBlock else {
                if range.contains(cue.at) { cue.at -= range.lowerBound; kept.append(cue) }
                continue
            }
            guard cue.at < range.upperBound, end > range.lowerBound else { continue }
            if cue.at < range.lowerBound {
                cue = trimmedStartExactly(cue, to: range.lowerBound, end: end)
            }
            let cueEnd = cue.at + (cue.duration ?? (end - cue.at))
            if cueEnd > range.upperBound || !cueEnd.isFinite {
                cue.duration = range.upperBound - cue.at
                cue.fadeOut = nil
            }
            cue.at -= range.lowerBound
            kept.append(fitted(cue))
        }
        return kept
    }

    public static func pasted(
        _ clipboard: [TimelineCue], at time: Double, newID: () -> String = { UUID().uuidString }
    ) -> [TimelineCue] {
        clipboard.map { cue in
            var pasted = cue
            pasted.id = newID()
            pasted.at = PresentationTimelines.snappedToFrame(max(0, time) + cue.at)
            return pasted
        }
    }

    private static func trimmedStartExactly(_ cue: TimelineCue, to time: Double, end: Double) -> TimelineCue {
        var cut = cue
        if isClip(cue) { cut.inPoint = (cue.inPoint ?? 0) + (time - cue.at) }
        cut.at = time
        cut.duration = end.isFinite ? end - time : nil
        cut.fadeIn = nil
        return cut
    }

    public static func rippleDeleted(
        _ timeline: PresentationTimeline, range: ClosedRange<Double>, newID: () -> String = { UUID().uuidString }
    ) -> PresentationTimeline {
        let a = range.lowerBound, b = range.upperBound, cut = b - a
        guard cut > 0 else { return timeline }
        var result = timeline
        var cues: [TimelineCue] = []
        let all = timeline.cues
        for cue in all {
            guard cue.isBlock else {
                if cue.at >= b { var moved = cue; moved.at -= cut; cues.append(moved) }
                else if cue.at < a { cues.append(cue) }
                continue
            }

            let end = PresentationTimelines.end(of: cue, in: all)
            let open = cue.duration == nil
            if cue.at >= b {
                var moved = cue; moved.at -= cut; cues.append(moved)
            } else if end <= a && !(open && end.isInfinite) {
                cues.append(cue)
            } else if cue.at >= a && end <= b {
                continue
            } else if cue.at < a {

                var head = cue
                if !open || isClip(cue) { head.duration = a - cue.at; head.fadeOut = nil }
                if end > b {
                    if isClip(cue) {
                        var tail = trimmedStartExactly(cue, to: b, end: end)
                        tail.id = newID()
                        tail.at = a
                        tail.fadeOut = cue.fadeOut
                        cues += [fitted(head), fitted(tail)]
                        continue
                    }
                    head.duration = open ? nil : (end - cue.at) - cut
                    head.fadeOut = cue.fadeOut
                }
                cues.append(fitted(head))
            } else {

                var tail = isClip(cue) ? trimmedStartExactly(cue, to: b, end: end) : cue
                tail.at = a
                if !isClip(cue) { tail.duration = open ? nil : end - b }
                cues.append(fitted(tail))
            }
        }
        result.cues = cues
        if let length = timeline.length, length > a { result.length = length - (min(length, b) - a) }
        return result
    }
}
