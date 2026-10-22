import Foundation

public enum TimelineTracks {
    public static let lanePrefix = "track:"

    public static func lane(for channelId: String) -> String { lanePrefix + channelId }

    public enum Role: String, Sendable, CaseIterable {
        case music, click, guide
    }

    public static func stems(_ cues: [TimelineCue]) -> [TimelineCue] {
        cues.filter { $0.trackChannelId != nil && $0.mediaId != nil }.sorted { $0.at < $1.at }
    }

    public static func group(of cue: TimelineCue, in cues: [TimelineCue]) -> [TimelineCue] {
        guard cue.trackChannelId != nil else { return [cue] }
        return stems(cues).filter { abs($0.at - cue.at) < PresentationTimelines.frame / 2 }
    }

    static let roleWords: [(role: Role, words: [[String]])] = [
        (.click, [["click"], ["clk"], ["metronome"], ["count", "in"], ["countin"]]),
        (.guide, [["guide"], ["cues"], ["cue"], ["vocal", "cues"], ["vox", "cues"]]),
    ]

    static let wholeNames: [[String]: String] = [
        ["click", "track"]: "Click", ["click"]: "Click", ["clk"]: "Click", ["metronome"]: "Click",
        ["guide"]: "Guide", ["cues"]: "Guide", ["cue"]: "Guide", ["vocal", "cues"]: "Guide", ["vox", "cues"]: "Guide",
    ]

    static let shortWords: [String: String] = [
        "eg": "Electric Guitar", "egtr": "Electric Guitar", "ag": "Acoustic Guitar", "agtr": "Acoustic Guitar",
        "gtr": "Guitar", "bgv": "Background Vocals", "bgvs": "Background Vocals", "perc": "Percussion",
        "percs": "Percussion", "clk": "Click",
    ]

    static let stemWords: Set<String> = Set(shortWords.keys).union([
        "click", "guide", "keys", "key", "piano", "organ", "synth", "synths", "pad", "pads", "bass",
        "drums", "drum", "strings", "track", "tracks", "vox", "loop", "loops",
    ])

    static func words(_ name: String) -> [String] {
        let stem = (name as NSString).deletingPathExtension.lowercased()
        var words = stem.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        if let first = words.first, first.allSatisfy(\.isNumber) { words.removeFirst() }
        return words
    }

    private static func contains(_ words: [String], _ phrase: [String]) -> Bool {
        guard !phrase.isEmpty, phrase.count <= words.count else { return false }
        return (0 ... words.count - phrase.count).contains { Array(words[$0 ..< $0 + phrase.count]) == phrase }
    }

    static func numbered(_ name: String) -> (words: [String], number: Int?) {
        var words = words(name)
        guard let last = words.last else { return (words, nil) }
        let digits = String(last.reversed().prefix { $0.isNumber }.reversed())
        guard !digits.isEmpty else { return (words, nil) }
        if digits.count == last.count {
            guard words.count > 1 else { return (words, nil) }
            words.removeLast()
        } else {
            let stem = String(last.dropLast(digits.count))
            guard stemWords.contains(stem) else { return (words, nil) }
            words[words.count - 1] = stem
        }
        return (words, Int(digits))
    }

    static func canonical(_ name: [String]) -> (name: String, key: [String]) {
        let spelled = wholeNames[name] ?? name.map { shortWords[$0] ?? $0.capitalized }.joined(separator: " ")
        return (spelled, words(spelled))
    }

    public static func role(forName name: String) -> Role {
        let words = numbered(name).words
        return roleWords.first { $0.words.contains { contains(words, $0) } }?.role ?? .music
    }

    public static func channel(forFileName fileName: String, in channels: [TrackChannel]) -> TrackChannel? {
        let file = numbered(fileName)
        return channel(words: file.words, number: file.number, in: channels)
    }

    static func channel(words: [String], number: Int?, in channels: [TrackChannel]) -> TrackChannel? {
        let key = canonical(words).key
        let same = channels.filter { (numbered($0.name).number ?? 1) == (number ?? 1) }
        if let named = same.first(where: { canonical(numbered($0.name).words).key == key }) { return named }
        var best: (channel: TrackChannel, length: Int)?
        for channel in same {
            for phrase in (channel.matchNames ?? []).map(Self.words) where contains(words, phrase) {
                if phrase.count > best?.length ?? 0 { best = (channel, phrase.count) }
            }
        }
        return best?.channel
    }

    public static func assign(
        fileNames: [String], to channels: [TrackChannel], newID: () -> String = { UUID().uuidString }
    ) -> (channels: [TrackChannel], assignments: [String: String]) {
        var channels = channels
        var assignments: [String: String] = [:]
        var used: Set<String> = []
        let split = fileNames.map(numbered)
        let prefix = fileNames.count > 1 ? commonPrefix(split.map(\.words)) : 0
        for (index, fileName) in fileNames.enumerated() {
            let words = Array(split[index].words.dropFirst(prefix))
            let matched = channel(words: words, number: split[index].number, in: channels)
            if let matched, !used.contains(matched.id) {
                assignments[fileName] = matched.id
                used.insert(matched.id)
                continue
            }
            let base = canonical(words).name
            let role = role(forName: fileName)
            var number = split[index].number
            var reuse: TrackChannel?
            if matched != nil {

                number = (number ?? 1) + 1
                while let existing = channels.first(where: { $0.name == "\(base) \(number!)" }) {
                    if !used.contains(existing.id) { reuse = existing; break }
                    number! += 1
                }
            }
            let chosen = reuse ?? {
                let name = number.map { "\(base) \($0)" } ?? base
                let made = TrackChannel(
                    id: newID(), name: name.trimmingCharacters(in: .whitespaces).isEmpty ? "Track" : name,
                    role: role == .music ? nil : role.rawValue)
                channels.append(made)
                return made
            }()
            assignments[fileName] = chosen.id
            used.insert(chosen.id)
        }
        return (channels, assignments)
    }

    private static func commonPrefix(_ names: [[String]]) -> Int {
        guard let first = names.first, let shortest = names.map(\.count).min(), shortest > 1 else { return 0 }
        var count = 0
        while count < shortest - 1, names.allSatisfy({ $0[count] == first[count] }) { count += 1 }
        return count
    }
}

public struct TimelineStemImport: Equatable, Sendable {
    public var fileName: String
    public var audioID: String
    public var seconds: Double?

    public var channels: Int?

    public init(fileName: String, audioID: String, seconds: Double?, channels: Int? = nil) {
        self.fileName = fileName; self.audioID = audioID; self.seconds = seconds; self.channels = channels
    }
}

public extension TimelineTracks {

    static func place(
        _ stems: [TimelineStemImport], at: Double, channel: String? = nil, channels: [TrackChannel],
        into cues: inout [TimelineCue], newID: () -> String = { UUID().uuidString }
    ) -> [TrackChannel] {
        var result = assign(fileNames: stems.map(\.fileName), to: channels, newID: newID)
        if let channel, stems.count == 1 {
            result = (channels, [stems[0].fileName: channel])
        }
        let at = PresentationTimelines.snappedToFrame(max(0, at))
        for stem in stems {
            guard let id = result.assignments[stem.fileName] else { continue }
            let lane = lane(for: id)
            cues.removeAll { $0.lane == lane && abs($0.at - at) < PresentationTimelines.frame / 2 }
            cues.append(TimelineCue(id: newID(), lane: lane, at: at, duration: stem.seconds, mediaId: stem.audioID))
        }

        return result.channels.filter { made in !channels.contains { $0.id == made.id } }.map { made in
            var made = made
            let files = stems.filter { result.assignments[$0.fileName] == made.id }
            if !files.isEmpty, files.allSatisfy({ $0.channels == 1 }) { made.mono = true }
            return made
        }
    }
}

public extension TimelineTracks {

    static func rows(channels: [TrackChannel], cues: [TimelineCue], added: Set<String>) -> [TrackChannel] {
        let used = Set(stems(cues).compactMap(\.trackChannelId))
        let shown = used.union(added)
        let lost = used.subtracting(channels.map(\.id)).sorted().map { TrackChannel(id: $0, name: "Removed channel") }
        return channels.filter { shown.contains($0.id) } + lost
    }
}

public extension TrackChannel {
    var trackRole: TimelineTracks.Role { role.flatMap(TimelineTracks.Role.init(rawValue:)) ?? .music }
}

public extension TimelineCue {

    var trackChannelId: String? {
        lane.hasPrefix(TimelineTracks.lanePrefix) ? String(lane.dropFirst(TimelineTracks.lanePrefix.count)) : nil
    }

    var isBlock: Bool { kind?.isBlock ?? (trackChannelId != nil) }
}
