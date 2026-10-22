import Compression
import Foundation

public enum SongMaps {

    public struct Locator: Equatable, Sendable {
        public var beats: Double
        public var name: String
    }

    public struct TempoPoint: Equatable, Sendable {
        public var beat: Double
        public var bpm: Double
    }

    public struct AbletonSet: Equatable, Sendable {
        public var locators: [Locator]
        public var tempo: [TempoPoint]
    }

    public static func abletonSet(_ data: Data) -> AbletonSet? {
        let xml = data.starts(with: [0x1F, 0x8B]) ? gunzip(data) : data
        guard let xml else { return nil }
        let reader = AbletonReader()
        let parser = XMLParser(data: xml)
        parser.delegate = reader
        guard parser.parse() else { return nil }
        var tempo = reader.tempo.sorted { $0.beat < $1.beat }
        if tempo.isEmpty, let manual = reader.manualTempo { tempo = [TempoPoint(beat: 0, bpm: manual)] }
        return AbletonSet(locators: reader.locators.sorted { $0.beats < $1.beats }, tempo: tempo)
    }

    private final class AbletonReader: NSObject, XMLParserDelegate {
        var locators: [Locator] = []
        var tempo: [TempoPoint] = []
        var manualTempo: Double?
        private var path: [String] = []
        private var time: Double?
        private var name: String?

        func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String] = [:]) {
            path.append(element)
            let value = attributes["Value"]
            if path.suffix(2) == ["Locator", "Time"] { time = value.flatMap(Double.init) }
            if path.suffix(2) == ["Locator", "Name"] { name = value }

            if path.contains("MasterTrack"), path.contains("Tempo") {
                if element == "FloatEvent", let beat = attributes["Time"].flatMap(Double.init),
                   let bpm = attributes["Value"].flatMap(Double.init) {
                    tempo.append(TempoPoint(beat: max(beat, 0), bpm: bpm))
                }
                if element == "Manual", path.suffix(2) == ["Tempo", "Manual"] { manualTempo = value.flatMap(Double.init) }
            }
        }

        func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
            if element == "Locator", let time, let name { locators.append(Locator(beats: time, name: name)) }
            if element == "Locator" { time = nil; name = nil }
            path.removeLast()
        }
    }

    static func gunzip(_ data: Data) -> Data? {
        let bytes = [UInt8](data)
        guard bytes.count > 18, bytes[0] == 0x1F, bytes[1] == 0x8B, bytes[2] == 8 else { return nil }
        let flags = bytes[3]
        var index = 10
        if flags & 4 != 0 { index += 2 + Int(bytes[index]) + Int(bytes[index + 1]) << 8 }
        if flags & 8 != 0 { while index < bytes.count, bytes[index] != 0 { index += 1 }; index += 1 }
        if flags & 16 != 0 { while index < bytes.count, bytes[index] != 0 { index += 1 }; index += 1 }
        if flags & 2 != 0 { index += 2 }
        guard index < bytes.count - 8 else { return nil }
        let stream = Array(bytes[index ..< bytes.count - 8])
        let size = Int(bytes[bytes.count - 4]) | Int(bytes[bytes.count - 3]) << 8
            | Int(bytes[bytes.count - 2]) << 16 | Int(bytes[bytes.count - 1]) << 24
        var out = [UInt8](repeating: 0, count: max(size, 1))
        let written = compression_decode_buffer(&out, out.count, stream, stream.count, nil, COMPRESSION_ZLIB)
        guard written == size else { return nil }
        return Data(out)
    }

    public static func seconds(beats: Double, tempo: [TempoPoint], bpm fallback: Double) -> Double {
        guard !tempo.isEmpty else { return beats * 60 / fallback }
        var seconds = 0.0
        var beat = 0.0
        var bpm = tempo[0].bpm
        for point in tempo {

            guard point.beat > beat else { bpm = point.bpm; continue }
            let end = min(point.beat, beats)
            seconds += span(from: beat, bpm, to: end, bpm + (point.bpm - bpm) * (end - beat) / (point.beat - beat))
            if point.beat >= beats { return seconds }
            beat = point.beat
            bpm = point.bpm
        }

        if let last = tempo.last { bpm = last.bpm }
        return seconds + (beats - beat) * 60 / bpm
    }

    private static func span(from a: Double, _ v0: Double, to b: Double, _ v1: Double) -> Double {
        let beats = b - a
        guard beats > 0 else { return 0 }
        if abs(v1 - v0) < 1e-9 { return beats * 60 / v0 }
        return 60 * beats / (v1 - v0) * log(v1 / v0)
    }

    public static func bpm(folderName: String) -> Double? {
        guard let match = folderName.lowercased().firstMatch(of: /([0-9]+(?:\.[0-9]+)?)\s*bpm/) else { return nil }
        return Double(match.1)
    }

    public static func sections(
        from set: AbletonSet, bpm: Double, offset: Double = 0, recordingEnd: Double? = nil,
        newID: () -> String = { UUID().uuidString }
    ) -> [AudioSection] {
        var sections: [AudioSection] = []
        for locator in set.locators {
            let start = offset + seconds(beats: locator.beats, tempo: set.tempo, bpm: bpm)
            if let recordingEnd, start >= recordingEnd - PresentationTimelines.frame { continue }
            if let last = sections.last, abs(last.start - start) < 0.001 { continue }
            sections.append(AudioSection(id: newID(), name: locator.name, start: start))
        }
        return sections
    }

    static func key(_ name: String) -> String {
        name.lowercased().split { !$0.isLetter && !$0.isNumber }.joined(separator: " ")
    }

    public static func linked(_ sections: [AudioSection], to slideSections: [PresentationSection]) -> [AudioSection] {
        let byKey = Dictionary(slideSections.map { (key($0.name), $0.id) }, uniquingKeysWith: { first, _ in first })
        return sections.map { section in
            guard section.sectionId == nil else { return section }
            var linked = section
            let name = key(section.name)
            linked.sectionId = byKey[name]
                ?? byKey[name.replacing(/\s*[0-9]+$/, with: "")]
            return linked
        }
    }

    public static func recordingEnd(_ map: SongMap) -> Double {
        let ends = map.recording.filter(TimelineClips.isClip).map { PresentationTimelines.end(of: $0, in: map.recording) }
        return ends.filter(\.isFinite).max() ?? map.sections.last?.start ?? 0
    }

    public static func assignments(_ map: SongMap, blocks: [TimelinePlayedBlock]) -> [(sectionId: String?, occurrence: Int, audio: [Int])] {
        let sections = map.sections.sorted { $0.start < $1.start }
        var used = Set<Int>()
        var result: [(sectionId: String?, occurrence: Int, audio: [Int])] = []
        let lead = Array(sections.prefix { $0.sectionId == nil }.indices)
        if !lead.isEmpty, lead.count < sections.count {
            result.append((nil, 0, lead))
            used.formUnion(lead)
        }
        var pointer = lead.count
        var seen: [String: Int] = [:]
        for (index, block) in blocks.enumerated() {
            guard let id = block.sectionId else { continue }
            let occurrence = seen[id, default: 0]
            seen[id] = occurrence + 1
            let wanted = { (i: Int) in !used.contains(i) && sections[i].sectionId == id }
            guard let first = (pointer ..< sections.count).first(where: wanted) ?? (0 ..< pointer).first(where: wanted) else {
                result.append((id, occurrence, []))
                continue
            }
            let nextIsSame = index + 1 < blocks.count && blocks[index + 1].sectionId == id
            var taken = [first]
            var next = first + 1
            while next < sections.count, !used.contains(next),
                  sections[next].sectionId == nil || (sections[next].sectionId == id && !nextIsSame) {
                taken.append(next)
                next += 1
            }
            used.formUnion(taken)
            pointer = next
            result.append((id, occurrence, taken))
        }
        return result
    }

    public static func layout(_ map: SongMap, blocks: [TimelinePlayedBlock]) -> [SongMapBlock] {
        let sections = map.sections.sorted { $0.start < $1.start }
        let end = recordingEnd(map)
        var cursor = 0.0
        return assignments(map, blocks: blocks).map { block in
            let span = block.audio.first.map { first in
                (sections[first].start, block.audio.last.map { $0 + 1 < sections.count ? sections[$0 + 1].start : end } ?? end)
            }
            let length = span.map { max($0.1 - $0.0, 0) } ?? 0
            defer { cursor += length }
            return SongMapBlock(
                sectionId: block.sectionId, occurrence: block.occurrence, start: cursor, length: length,
                audioSectionIds: block.audio.map { sections[$0].id })
        }
    }

    public static func missing(_ map: SongMap, blocks: [TimelinePlayedBlock], names: [String: String]) -> [String] {
        let all = assignments(map, blocks: blocks)
        let counts = Dictionary(all.map { ($0.sectionId ?? "", 1) }, uniquingKeysWith: +)
        return all.filter { $0.audio.isEmpty }.compactMap { block in
            guard let id = block.sectionId else { return nil }
            let name = names[id] ?? "A section"
            return (counts[id] ?? 1) > 1 ? "\(name) (\(ordinal(block.occurrence + 1)) time)" : name
        }
    }

    static func ordinal(_ n: Int) -> String {
        let suffix = (11 ... 13).contains(n % 100) ? "th" : [1: "st", 2: "nd", 3: "rd"][n % 10] ?? "th"
        return "\(n)\(suffix)"
    }

    public static func laidOut(
        _ map: SongMap, blocks: [TimelinePlayedBlock], timeline: PresentationTimeline,
        newID: () -> String = { UUID().uuidString }
    ) -> PresentationTimeline? {

        guard map.sections.contains(where: { $0.sectionId != nil }) else { return nil }
        let layout = layout(map, blocks: blocks)
        if let stored = timeline.mapLayout, stored == layout { return nil }
        let sections = Dictionary(map.sections.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let previous = timeline.mapLayout ?? []
        var cues: [TimelineCue] = []
        for block in layout {
            if let old = previous.first(where: {
                $0.sectionId == block.sectionId && $0.occurrence == block.occurrence
                    && $0.audioSectionIds == block.audioSectionIds && abs($0.length - block.length) < 0.0005
            }) {
                let shift = block.start - old.start
                cues += timeline.cues.filter { $0.at >= old.start - 0.0005 && $0.at < old.start + max(old.length, 0.001) - 0.0005 }
                    .map { var cue = $0; cue.at += shift; return cue }
                continue
            }
            guard let first = block.audioSectionIds.first.flatMap({ sections[$0] }), block.length > 0 else { continue }
            let range = first.start ... first.start + block.length
            let cut = TimelineClips.copied(map.recording, range: range, all: map.recording)
            for var cue in cut {

                if !cue.isBlock, cue.at >= block.length - 0.0005 { continue }
                cue.id = newID()
                cue.at = PresentationTimelines.snappedToFrameIfClose(cue.at + block.start)
                if cue.kind == .slide, cue.sectionId == block.sectionId { cue.sectionOccurrence = block.occurrence == 0 ? nil : block.occurrence }
                cues.append(cue)
            }
        }
        let oldEnd = previous.last.map { $0.start + $0.length } ?? .infinity
        let newEnd = layout.last.map { $0.start + $0.length } ?? 0
        cues += timeline.cues.filter { $0.at >= oldEnd }.map { var cue = $0; cue.at += newEnd - oldEnd; return cue }
        var laid = timeline
        laid.cues = cues.sorted { $0.at < $1.at }
        laid.mapLayout = layout
        laid.length = nil
        return laid
    }
}

public extension SongMaps {

    static func recordingTime(_ time: Double, map: SongMap, layout: [SongMapBlock]?) -> Double {
        guard let layout, !layout.isEmpty else { return time }
        let sections = Dictionary(map.sections.map { ($0.id, $0.start) }, uniquingKeysWith: { a, _ in a })
        let block = layout.last { $0.start <= time && $0.length > 0 } ?? layout.first { $0.length > 0 }
        guard let block, let start = block.audioSectionIds.first.flatMap({ sections[$0] }) else { return time }
        return start + min(max(time - block.start, 0), block.length)
    }

    static func adding(_ name: String, at start: Double, to map: SongMap, slideSections: [PresentationSection], id: String = UUID().uuidString) -> SongMap {
        var map = map
        map.sections.append(contentsOf: linked([AudioSection(id: id, name: name, start: max(0, start))], to: slideSections))
        map.sections.sort { $0.start < $1.start }
        return map
    }
}

extension PresentationTimelines {

    static func snappedToFrameIfClose(_ seconds: Double) -> Double {
        let snapped = snappedToFrame(seconds)
        return abs(snapped - seconds) < 1e-6 ? snapped : seconds
    }
}
