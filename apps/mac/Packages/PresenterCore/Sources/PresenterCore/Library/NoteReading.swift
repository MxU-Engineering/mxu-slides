import Foundation

public enum NoteReading {
    public static func block(_ anchor: Int, from old: [NoteBlock], to new: [NoteBlock]) -> Int {
        let prefix = zip(old, new).prefix { $0 == $1 }.count
        guard anchor >= prefix else { return anchor }
        let room = min(old.count, new.count) - prefix
        let suffix = min(room, zip(old.reversed(), new.reversed()).prefix { $0 == $1 }.count)
        let moved = anchor >= old.count - suffix ? anchor + new.count - old.count : anchor
        return max(0, min(moved, new.count - 1))
    }

    public struct OutlineEntry: Equatable, Sendable, Identifiable {
        public var blockIndex: Int
        public var level: Int
        public var title: String
        public var id: Int { blockIndex }
    }

    public struct Match: Equatable, Sendable {
        public var blockIndex: Int
        public var offset: Int
    }

    public static func outline(_ body: NoteBody) -> [OutlineEntry] {
        body.blocks.enumerated().compactMap { index, block in
            guard block.type == .heading else { return nil }
            let title = text(of: block).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return nil }
            return OutlineEntry(blockIndex: index, level: block.level ?? 1, title: title)
        }
    }

    public static func text(of runs: [NoteRun]?) -> String {
        (runs ?? []).map(\.text).joined()
    }

    public static func text(of block: NoteBlock) -> String {
        switch block.type {
        case .heading, .paragraph:
            return text(of: block.runs)
        case .list, .taskList:
            return (block.items ?? []).map { item in
                ([text(of: item.runs)] + (item.blocks ?? []).map(text(of:))).joined(separator: "\n")
            }.joined(separator: "\n")
        case .quote:
            return (block.blocks ?? []).map(text(of:)).joined(separator: "\n")
        case .code, .unknown:
            return block.text ?? ""
        case .image:
            return block.alt ?? ""
        case .attachment:
            return block.filename ?? ""
        case .slideRef:
            return [block.slide?.presentationName, block.slide?.slideText].compactMap { $0 }.joined(separator: "\n")
        case .rule:
            return ""
        }
    }

    public static func matches(in body: NoteBody, query: String) -> [Match] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        var found: [Match] = []
        for (index, block) in body.blocks.enumerated() {
            let haystack = text(of: block)
            var searchRange = haystack.startIndex..<haystack.endIndex
            while let range = haystack.range(
                of: needle, options: [.caseInsensitive, .diacriticInsensitive], range: searchRange
            ) {
                found.append(Match(
                    blockIndex: index,
                    offset: haystack.distance(from: haystack.startIndex, to: range.lowerBound)))
                searchRange = range.upperBound..<haystack.endIndex
            }
        }
        return found
    }
}
