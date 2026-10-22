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
        fileNames: [String], to channels: [TrackChannel], taken: Set<String> = [],
        newID: () -> String = { UUID().uuidString }
    ) -> (channels: [TrackChannel], assignments: [String: String]) {
        var channels = channels
        var assignments: [String: String] = [:]
        var used = taken
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
                channels.insert(made, at: insertionIndex(for: made, in: channels))
                return made
            }()
            assignments[fileName] = chosen.id
            used.insert(chosen.id)
        }
        return (channels, assignments)
    }

    public static func insertionIndex(for channel: TrackChannel, in channels: [TrackChannel]) -> Int {
        func rank(_ channel: TrackChannel) -> Int { Family.allCases.firstIndex(of: family(of: channel)) ?? 0 }
        let mine = rank(channel)
        return channels.firstIndex {
            rank($0) > mine || (rank($0) == mine && $0.name.localizedStandardCompare(channel.name) == .orderedDescending)
        } ?? channels.count
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

    public var channelId: String?

    public init(fileName: String, audioID: String, seconds: Double?, channels: Int? = nil, channelId: String? = nil) {
        self.fileName = fileName; self.audioID = audioID; self.seconds = seconds; self.channels = channels
        self.channelId = channelId
    }
}

public extension TimelineTracks {

    static func place(
        _ stems: [TimelineStemImport], at: Double, channel: String? = nil, channels: [TrackChannel],
        into cues: inout [TimelineCue], newID: () -> String = { UUID().uuidString }
    ) -> [TrackChannel] {

        let known = Set(channels.map(\.id))
        var kept: [String: String] = [:]
        for stem in stems { if let id = stem.channelId, known.contains(id) { kept[stem.fileName] = id } }
        var result = assign(
            fileNames: stems.map(\.fileName).filter { kept[$0] == nil }, to: channels,
            taken: Set(kept.values), newID: newID)
        result.assignments.merge(kept) { _, keep in keep }
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

    enum Family: String, CaseIterable, Sendable {
        case click = "Click", guide = "Guide", drums = "Drums", percussion = "Percussion", bass = "Bass"
        case electricGuitars = "Electric Guitars", acousticGuitars = "Acoustic Guitars", keys = "Keys"
        case synths = "Synths & Pads", vocals = "Vocals", strings = "Strings", other = "Other"

        public var name: String { rawValue }
    }

    internal static let familyWords: [(family: Family, phrases: [[String]])] = [
        (.keys, [["electric", "piano"], ["keys"], ["key"], ["piano"], ["organ"], ["rhodes"], ["wurli"],
                 ["wurlitzer"], ["mellotron"], ["ep"], ["b3"], ["clav"]]),
        (.drums, [["drums"], ["drum"], ["kit"], ["kick"], ["snare"], ["toms"], ["overheads"]]),
        (.percussion, [["percussion"], ["perc"], ["percs"], ["shaker"], ["tambourine"], ["tamb"], ["loops"],
                       ["loop"], ["conga"], ["congas"]]),
        (.electricGuitars, [["electric", "guitar"], ["lead", "guitar"], ["eg"], ["egtr"], ["electric"],
                            ["guitar"], ["gtr"]]),
        (.acousticGuitars, [["acoustic", "guitar"], ["acoustic"], ["ag"], ["agtr"]]),
        (.synths, [["synth"], ["synths"], ["pad"], ["pads"], ["lead"], ["arp"], ["atmos"], ["ambient"], ["swell"]]),
        (.vocals, [["lead", "vocal"], ["lead", "vocals"], ["background", "vocals"], ["vocals"], ["vocal"],
                   ["vox"], ["bgv"], ["bgvs"], ["choir"]]),
        (.strings, [["strings"], ["string"], ["orchestra"], ["orch"], ["brass"], ["horns"], ["cello"], ["violin"]]),
    ]

    static func family(of channel: TrackChannel) -> Family {
        switch channel.trackRole {
        case .click: return .click
        case .guide: return .guide
        case .music: break
        }
        let words = numbered(channel.name).words
        if words.contains("bass") { return .bass }
        var best: (family: Family, at: Int, length: Int)?
        for (family, phrases) in familyWords {
            for phrase in phrases {
                guard let at = position(phrase, in: words) else { continue }
                if best.map({ at < $0.at || (at == $0.at && phrase.count > $0.length) }) ?? true {
                    best = (family, at, phrase.count)
                }
            }
        }
        return best?.family ?? .other
    }

    private static func position(_ phrase: [String], in words: [String]) -> Int? {
        guard !phrase.isEmpty, phrase.count <= words.count else { return nil }
        return (0 ... words.count - phrase.count).first { Array(words[$0 ..< $0 + phrase.count]) == phrase }
    }

    static func rows(channels: [TrackChannel], cues: [TimelineCue], added: Set<String>) -> [TrackChannel] {
        let used = Set(stems(cues).compactMap(\.trackChannelId))
        let shown = used.union(added)
        let lost = used.subtracting(channels.map(\.id)).sorted().map { TrackChannel(id: $0, name: "Removed channel") }
        return channels.filter { shown.contains($0.id) } + lost
    }
}

public extension TimelineTracks {

    static func shownMixes(
        _ mixes: [(id: String, folderId: String?)], folders: [String], buses: Set<String>, tracksOn: Bool
    ) -> (mixes: Set<String>, folders: Set<String>) {
        guard !tracksOn else { return (Set(mixes.map(\.id)), Set(folders)) }
        let shown = mixes.filter { !buses.contains($0.id) }
        let kept = folders.filter { folder in
            let members = mixes.filter { $0.folderId == folder }
            return members.isEmpty || shown.contains { $0.folderId == folder }
        }
        return (Set(shown.map(\.id)), Set(kept))
    }
}

public extension TimelineTracks {

    static func patchPlan(
        _ families: [Family] = Family.allCases, start: Int, deviceChannels: Int
    ) -> [(family: Family, channel: Int)] {
        families.enumerated().compactMap { index, family in
            let channel = start + index
            return channel >= 0 && channel < deviceChannels ? (family, channel) : nil
        }
    }
}

public extension TimelineTracks {

    static let layoutSizes = [2, 3, 4, 8, 16]

    static func layout(outputs: Int) -> [Family: [Int]] {
        let music = Family.allCases.filter { $0 != .click && $0 != .guide }
        switch outputs {
        case 2:
            return Dictionary(uniqueKeysWithValues: [(.click, [0]), (.guide, [0])] + music.map { ($0, [1]) })
        case 3:
            return Dictionary(uniqueKeysWithValues: [(.click, [0]), (.guide, [0])] + music.map { ($0, [1, 2]) })
        case 4:
            return Dictionary(uniqueKeysWithValues: [(.click, [0]), (.guide, [1])] + music.map { ($0, [2, 3]) })
        case 8:
            return [.click: [0], .guide: [1], .drums: [2], .percussion: [2], .bass: [3], .electricGuitars: [4],
                    .acousticGuitars: [4], .keys: [5], .synths: [6, 7], .vocals: [6, 7], .strings: [6, 7], .other: [6, 7]]
        case 16:
            return [.click: [0], .guide: [1], .drums: [2], .percussion: [3], .bass: [4], .electricGuitars: [5],
                    .acousticGuitars: [6], .keys: [7, 8], .synths: [9, 10], .vocals: [11], .strings: [12, 13], .other: [14]]
        default:
            return [:]
        }
    }

    static func layoutRows(outputs: Int) -> [(channels: [Int], families: [Family])] {
        let layout = layout(outputs: outputs)
        var rows: [(channels: [Int], families: [Family])] = []
        for family in Family.allCases {
            guard let channels = layout[family] else { continue }
            if let index = rows.firstIndex(where: { $0.channels == channels }) {
                rows[index].families.append(family)
            } else {
                rows.append((channels, [family]))
            }
        }
        return rows.sorted { $0.channels[0] < $1.channels[0] }
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
