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

    static let aliases: [(name: String, role: Role, words: [[String]])] = [
        ("Click", .click, [["click"], ["clk"], ["metronome"], ["count", "in"], ["countin"]]),
        ("Guide", .guide, [["guide"], ["cues"], ["cue"], ["vocal", "cues"], ["vox", "cues"]]),
        ("Drums", .music, [["drums"], ["drum"], ["kit"]]),
        ("Percussion", .music, [["percussion"], ["perc"], ["percs"]]),
        ("Bass", .music, [["bass"]]),
        ("Keys", .music, [["keys"], ["key"], ["piano"], ["rhodes"], ["wurli"], ["organ"]]),
        ("Synth", .music, [["synth"], ["synths"], ["lead"]]),
        ("Pads", .music, [["pads"], ["pad"]]),
        ("Electric Guitar", .music, [["electric", "guitar"], ["eg"], ["electric"], ["egtr"]]),
        ("Acoustic Guitar", .music, [["acoustic", "guitar"], ["ag"], ["acoustic"], ["agtr"]]),
        ("Vocals", .music, [["bgv"], ["bgvs"], ["vocals"], ["vox"], ["choir"]]),
        ("Strings", .music, [["strings"], ["orchestra"], ["orch"]]),
        ("Track", .music, [["track"], ["tracks"], ["loops"], ["loop"], ["stereo"]]),
    ]

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
            guard aliases.contains(where: { $0.words.contains([stem]) }) else { return (words, nil) }
            words[words.count - 1] = stem
        }
        return (words, Int(digits))
    }

    static func alias(_ name: String) -> (name: String, role: Role)? {
        let words = numbered(name).words
        func position(_ phrase: [String]) -> Int? {
            guard !phrase.isEmpty, phrase.count <= words.count else { return nil }
            return (0 ... words.count - phrase.count).first { Array(words[$0 ..< $0 + phrase.count]) == phrase }
        }
        let found = aliases.compactMap { alias in
            alias.words.compactMap(position).min().map { (alias: alias, at: $0) }
        }
        let pick = found.first { $0.alias.role != .music } ?? found.min { $0.at < $1.at }
        return pick.map { ($0.alias.name, $0.alias.role) }
    }

    public static func role(forName name: String) -> Role {
        alias(name)?.role ?? .music
    }

    public static func channel(forFileName fileName: String, in channels: [TrackChannel]) -> TrackChannel? {
        let file = numbered(fileName)
        let number = file.number ?? 1
        let sameNumber = channels.filter { (numbered($0.name).number ?? 1) == number }
        var best: (channel: TrackChannel, length: Int)?
        for channel in sameNumber {
            for phrase in [numbered(channel.name).words] + (channel.matchNames ?? []).map(Self.words)
            where contains(file.words, phrase) {
                if phrase.count > best?.length ?? 0 { best = (channel, phrase.count) }
            }
        }
        if let best { return best.channel }
        guard let alias = alias(fileName) else { return nil }
        return sameNumber.first { Self.alias($0.name)?.name == alias.name }
    }

    public static func assign(
        fileNames: [String], to channels: [TrackChannel], newID: () -> String = { UUID().uuidString }
    ) -> (channels: [TrackChannel], assignments: [String: String]) {
        var channels = channels
        var assignments: [String: String] = [:]
        var used: Set<String> = []
        for fileName in fileNames {
            let matched = channel(forFileName: fileName, in: channels)
            if let matched, !used.contains(matched.id) {
                assignments[fileName] = matched.id
                used.insert(matched.id)
                continue
            }
            let alias = alias(fileName)
            let file = numbered(fileName)
            let base = alias?.name ?? file.words.map(\.capitalized).joined(separator: " ")
            let role = alias?.role ?? .music
            var number = file.number
            var channel: TrackChannel?
            if matched != nil {

                number = (number ?? 1) + 1
                while true {
                    let name = "\(base) \(number!)"
                    if let existing = channels.first(where: { $0.name == name }) {
                        if !used.contains(existing.id) { channel = existing; break }
                        number! += 1
                    } else {
                        break
                    }
                }
            }
            let chosen = channel ?? {
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
}

public struct TimelineStemImport: Equatable, Sendable {
    public var fileName: String
    public var audioID: String
    public var seconds: Double?

    public init(fileName: String, audioID: String, seconds: Double?) {
        self.fileName = fileName; self.audioID = audioID; self.seconds = seconds
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
        return result.channels.filter { made in !channels.contains { $0.id == made.id } }
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
