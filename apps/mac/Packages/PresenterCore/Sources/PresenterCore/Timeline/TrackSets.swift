import Foundation

public enum TrackSets {

    public struct Download: Equatable, Sendable {
        public var song: String?
        public var key: String?
        public var tempo: Double?
    }

    public static func download(fromFolder name: String) -> Download {
        let parts = name.split(separator: "-").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count >= 3,
              let last = parts.last, last.lowercased().hasSuffix("bpm"),
              let tempo = Double(last.dropLast(3)),
              isKey(parts[parts.count - 2])
        else { return Download(song: nil, key: nil, tempo: nil) }
        return Download(song: parts[0], key: parts[parts.count - 2], tempo: tempo)
    }

    static func isKey(_ text: String) -> Bool {
        guard let first = text.first, "ABCDEFG".contains(first) else { return false }
        let rest = text.dropFirst()
        return ["", "#", "b", "m", "#m", "bm"].contains(String(rest))
    }

    public static func download(forFiles paths: [String]) -> Download {
        for path in paths {
            var folder = (path as NSString).deletingLastPathComponent
            for _ in 0 ..< 2 {
                let found = download(fromFolder: (folder as NSString).lastPathComponent)
                if found.key != nil { return found }
                folder = (folder as NSString).deletingLastPathComponent
            }
        }
        return Download(song: nil, key: nil, tempo: nil)
    }

    public static func name(song: String, key: String?, tempo: Double?) -> String {
        let tempoText = tempo.map { $0.rounded() == $0 ? "\(Int($0)) bpm" : String(format: "%g bpm", $0) }
        let details = [key, tempoText].compactMap { $0 }
        return details.isEmpty ? song : "\(song) — \(details.joined(separator: ", "))"
    }

    public static func stemIDs(_ sets: some Sequence<TrackSet>) -> Set<String> {
        Set(sets.flatMap { $0.stems.map(\.audioId) })
    }

    public static func existing(withStems audioIDs: [String], in sets: some Sequence<TrackSet>) -> TrackSet? {
        let wanted = Set(audioIDs)
        return sets.first { Set($0.stems.map(\.audioId)) == wanted }
    }
}
