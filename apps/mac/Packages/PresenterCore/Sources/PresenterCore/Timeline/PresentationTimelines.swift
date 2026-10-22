import Foundation

public struct TimelinePlayedBlock: Equatable, Sendable {
    public var sectionId: String?
    public var slideIds: [String]

    public init(sectionId: String?, slideIds: [String]) {
        self.sectionId = sectionId
        self.slideIds = slideIds
    }
}

public struct TimelineSlideAnchor: Equatable, Sendable {
    public var sectionId: String?
    public var sectionOccurrence: Int
    public var slideId: String

    public init(sectionId: String?, sectionOccurrence: Int, slideId: String) {
        self.sectionId = sectionId
        self.sectionOccurrence = sectionOccurrence
        self.slideId = slideId
    }
}

public enum PresentationTimelines {

    public static let framesPerSecond = 30
    public static let frame = 1.0 / Double(framesPerSecond)

    public static func timeline(for arrangementId: String?, in presentation: Presentation) -> PresentationTimeline? {
        let wanted = arrangementId.flatMap { $0.isEmpty ? nil : $0 }
        return presentation.timelines?.first { ($0.arrangementId.flatMap { $0.isEmpty ? nil : $0 }) == wanted }
    }

    public static func replacing(_ timeline: PresentationTimeline, in timelines: [PresentationTimeline]?) -> [PresentationTimeline] {
        var all = timelines ?? []
        if let index = all.firstIndex(where: { $0.id == timeline.id }) {
            all[index] = timeline
        } else {
            all.append(timeline)
        }
        return all
    }

    public static func anchor(occurrence: Int, in blocks: [TimelinePlayedBlock]) -> TimelineSlideAnchor? {
        var index = 0
        var seen: [String?: Int] = [:]
        for block in blocks {
            let sectionOccurrence = seen[block.sectionId, default: 0]
            seen[block.sectionId] = sectionOccurrence + 1
            if occurrence < index + block.slideIds.count {
                guard occurrence >= index else { return nil }
                return TimelineSlideAnchor(
                    sectionId: block.sectionId, sectionOccurrence: sectionOccurrence,
                    slideId: block.slideIds[occurrence - index])
            }
            index += block.slideIds.count
        }
        return nil
    }

    public static func occurrence(of cue: TimelineCue, in blocks: [TimelinePlayedBlock]) -> Int? {
        guard cue.lane == .slides, let slideId = cue.slideId else { return nil }
        let wanted = cue.sectionOccurrence ?? 0
        var index = 0
        var seen: [String?: Int] = [:]
        for block in blocks {
            let sectionOccurrence = seen[block.sectionId, default: 0]
            seen[block.sectionId] = sectionOccurrence + 1
            if block.sectionId == cue.sectionId, sectionOccurrence == wanted {
                return block.slideIds.firstIndex(of: slideId).map { index + $0 }
            }
            index += block.slideIds.count
        }
        return nil
    }

    public static func slideCue(id: String, at: Double, anchor: TimelineSlideAnchor) -> TimelineCue {
        TimelineCue(
            id: id, lane: .slides, at: at, sectionId: anchor.sectionId,
            sectionOccurrence: anchor.sectionOccurrence, slideId: anchor.slideId)
    }

    public static func isBlock(_ lane: TimelineLane) -> Bool {
        switch lane {
        case .slides, .actions: false
        case .overlays, .foregroundVideos, .background, .audio: true
        }
    }

    public static func end(of cue: TimelineCue, in cues: [TimelineCue]) -> Double {
        guard isBlock(cue.lane) else { return cue.at }
        if let duration = cue.duration { return cue.at + max(duration, 0) }
        return cues.filter { $0.lane == cue.lane && $0.id != cue.id && $0.at > cue.at }.map(\.at).min() ?? .infinity
    }

    public static func contentEnd(_ cues: [TimelineCue]) -> Double {
        cues.map { cue in
            let end = end(of: cue, in: cues)
            return end.isFinite ? end : cue.at
        }.max() ?? 0
    }

    public static func length(_ timeline: PresentationTimeline) -> Double {
        timeline.length ?? contentEnd(timeline.cues)
    }

    public struct SectionSpan: Equatable, Sendable {
        public var block: Int
        public var sectionId: String?
        public var start: Double
        public var end: Double
    }

    public static func sectionSpans(_ cues: [TimelineCue], blocks: [TimelinePlayedBlock], length: Double) -> [SectionSpan] {
        var starts: [Int] = []
        var index = 0
        for block in blocks {
            starts.append(index)
            index += block.slideIds.count
        }
        var spans: [SectionSpan] = []
        for cue in cues.sorted(by: { $0.at < $1.at }) {
            guard let occurrence = occurrence(of: cue, in: blocks),
                  let block = starts.lastIndex(where: { $0 <= occurrence }) else { continue }
            if spans.last?.block == block { continue }
            if !spans.isEmpty { spans[spans.count - 1].end = cue.at }
            spans.append(SectionSpan(block: block, sectionId: blocks[block].sectionId, start: cue.at, end: max(length, cue.at)))
        }
        return spans
    }

    public struct Live: Equatable, Sendable {
        public var mediaIds: Set<String>
        public var overlayIds: Set<String>

        public init(mediaIds: Set<String> = [], overlayIds: Set<String> = []) {
            self.mediaIds = mediaIds
            self.overlayIds = overlayIds
        }
    }

    public enum Effect: Equatable, Sendable {

        case showSlide(occurrence: Int, actions: Bool)
        case fireOverlay(id: String)

        case clearOverlay(id: String)
        case fireMedia(id: String, lane: TimelineLane)

        case runActions(cueId: String)
    }

    public static func crossing(
        _ cues: [TimelineCue], blocks: [TimelinePlayedBlock], from: Double, to: Double, live: Live
    ) -> [Effect] {
        guard to > from else { return [] }
        let crossed: (Double) -> Bool = { $0 > from && $0 <= to }
        var timed: [(time: Double, order: Int, effect: Effect)] = []
        var lastSlide: (at: Double, occurrence: Int)?
        var liveMedia = live.mediaIds
        for cue in cues.sorted(by: { $0.at < $1.at }) {
            switch cue.lane {
            case .slides:
                if crossed(cue.at), let occurrence = occurrence(of: cue, in: blocks) {
                    lastSlide = (cue.at, occurrence)
                }
            case .overlays:
                guard let id = cue.overlayId else { continue }
                if crossed(cue.at) { timed.append((cue.at, 1, .fireOverlay(id: id))) }
                let end = end(of: cue, in: cues)
                if crossed(end) { timed.append((end, 0, .clearOverlay(id: id))) }
            case .foregroundVideos:
                if crossed(cue.at), let id = cue.mediaId {
                    timed.append((cue.at, 1, .fireMedia(id: id, lane: .foregroundVideos)))
                }
            case .background:

                if crossed(cue.at), let id = cue.mediaId, !liveMedia.contains(id) {
                    liveMedia.insert(id)
                    timed.append((cue.at, 1, .fireMedia(id: id, lane: .background)))
                }
            case .actions:
                if crossed(cue.at) { timed.append((cue.at, 1, .runActions(cueId: cue.id))) }
            case .audio:

                continue
            }
        }
        if let lastSlide {
            timed.append((lastSlide.at, 1, .showSlide(occurrence: lastSlide.occurrence, actions: true)))
        }
        return timed.enumerated()
            .sorted { ($0.element.time, $0.element.order, $0.offset) < ($1.element.time, $1.element.order, $1.offset) }
            .map(\.element.effect)
    }

    public static func landing(
        _ cues: [TimelineCue], blocks: [TimelinePlayedBlock], at position: Double, live: Live
    ) -> [Effect] {
        var effects: [Effect] = []
        let holds: (TimelineCue) -> Bool = { $0.at <= position && position < end(of: $0, in: cues) }

        let slide = cues
            .filter { $0.lane == .slides && $0.at <= position }
            .sorted { $0.at < $1.at }
            .compactMap { occurrence(of: $0, in: blocks) }
            .last
        if let slide { effects.append(.showSlide(occurrence: slide, actions: false)) }
        let overlays = cues.filter { $0.lane == .overlays && $0.overlayId != nil }
        let holding = Set(overlays.filter(holds).compactMap(\.overlayId))
        for id in Set(overlays.compactMap(\.overlayId)).sorted() where !holding.contains(id) && live.overlayIds.contains(id) {
            effects.append(.clearOverlay(id: id))
        }
        for cue in overlays.sorted(by: { $0.at < $1.at }) where holds(cue) {
            if let id = cue.overlayId, !live.overlayIds.contains(id), !effects.contains(.fireOverlay(id: id)) {
                effects.append(.fireOverlay(id: id))
            }
        }
        for lane in [TimelineLane.foregroundVideos, .background] {
            let held = cues.filter { $0.lane == lane && holds($0) }.max { $0.at < $1.at }
            if let id = held?.mediaId, !live.mediaIds.contains(id) {
                effects.append(.fireMedia(id: id, lane: lane))
            }
        }
        return effects
    }

    public static func recording(_ cues: [TimelineCue], from start: Double) -> [TimelineCue] {
        cues.filter { $0.lane != .slides || $0.at < start - frame / 2 }
    }

    public static func recorded(_ cue: TimelineCue, into cues: [TimelineCue]) -> [TimelineCue] {
        var next = cues.filter { !($0.lane == .slides && abs($0.at - cue.at) < frame) }
        next.append(cue)
        return next.sorted { $0.at < $1.at }
    }

    public static func moved(_ cue: TimelineCue, by seconds: Double) -> TimelineCue {
        var moved = cue
        moved.at = max(0, snappedToFrame(cue.at + seconds))
        return moved
    }

    public static func edited(
        _ cue: TimelineCue, in cues: [TimelineCue], mode: TimelineBlockEdit.Mode, by seconds: Double
    ) -> TimelineCue {
        guard isBlock(cue.lane), mode != .move else { return moved(cue, by: seconds) }
        let end = end(of: cue, in: cues)
        guard end.isFinite else { return mode == .trim ? moved(cue, by: seconds) : cue }
        var edited = cue
        switch mode {
        case .stretch:
            edited.duration = max(snappedToFrame(end - cue.at + seconds), frame)
        case .trim:
            edited.at = min(max(0, snappedToFrame(cue.at + seconds)), end - frame)
            edited.duration = snappedToFrame(end - edited.at)
        case .move:
            break
        }
        return edited
    }

    public static func snappedToFrame(_ seconds: Double) -> Double {
        (seconds * Double(framesPerSecond)).rounded() / Double(framesPerSecond)
    }

    public static func timecode(frames: Int) -> String {
        let total = max(frames, 0)
        let fps = framesPerSecond
        let seconds = total / fps
        return String(format: "%02d:%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60, total % fps)
    }

    public static func frames(timecode: String) -> Int? {
        let parts = timecode.trimmingCharacters(in: .whitespaces)
            .split(whereSeparator: { $0 == ":" || $0 == ";" || $0 == "." })
            .map { Int($0) }
        guard (3...4).contains(parts.count), parts.allSatisfy({ ($0 ?? -1) >= 0 }) else { return nil }
        let values = parts.compactMap { $0 }
        let frames = values.count == 4 ? values[3] : 0
        guard values[1] < 60, values[2] < 60, frames < framesPerSecond else { return nil }
        return ((values[0] * 60 + values[1]) * 60 + values[2]) * framesPerSecond + frames
    }

    public static func frames(seconds: Double) -> Int {
        Int((seconds * Double(framesPerSecond)).rounded(.up))
    }

    public struct Window: Equatable, Sendable {
        public var id: String
        public var start: Int
        public var length: Int

        public init(id: String, start: Int, length: Int) {
            self.id = id
            self.start = start
            self.length = max(length, 1)
        }

        public var end: Int { start + length }

        public func overlaps(_ other: Window) -> Bool {
            start < other.end && other.start < end
        }
    }

    public static func overlaps(_ window: Window, in others: [Window]) -> [Window] {
        others.filter { $0.id != window.id && window.overlaps($0) }
    }

    public static func suggestedStart(length: Int, avoiding others: [Window], id: String = "") -> Int {
        let hour = 3600 * framesPerSecond
        let others = others.filter { $0.id != id }
        for start in stride(from: hour, to: 24 * hour, by: hour)
        where overlaps(Window(id: id, start: start, length: length), in: others).isEmpty {
            return start
        }
        let block = 600 * framesPerSecond
        let after = others.map(\.end).max() ?? 0
        return (after + block - 1) / block * block
    }
}
