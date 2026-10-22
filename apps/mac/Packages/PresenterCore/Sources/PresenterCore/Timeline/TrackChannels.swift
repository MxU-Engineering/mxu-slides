import Foundation

public extension TimelineTracks {

    static func channelIDs(in presentation: Presentation) -> Set<String> {
        Set((presentation.timelines ?? []).flatMap(\.cues).compactMap(\.trackChannelId))
    }

    static func listSubtitle(_ channel: TrackChannel) -> String {
        let width = channel.mono == true ? "Mono" : "Stereo"
        let family = family(of: channel).name
        let name = numbered(channel.name).words.joined(separator: " ")
        let said = !name.isEmpty && family.lowercased().hasPrefix(name)
        return said ? width : "\(family) mix · \(width)"
    }

    @MainActor static func takesFinderDrop(_ urls: [URL]) -> Bool {
        urls.contains { $0.hasDirectoryPath || MediaImporter.libraryKind(of: $0) == .audio }
    }

    static func adding(named name: String, to channels: inout [TrackChannel], id: String = UUID().uuidString) -> TrackChannel? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let role = role(forName: trimmed)
        let made = TrackChannel(id: id, name: trimmed, role: role == .music ? nil : role.rawValue)
        channels.insert(made, at: insertionIndex(for: made, in: channels))
        return made
    }

    static func move(
        _ id: String, before: String?, in channels: [TrackChannel]
    ) -> (from: Int, before: Int?, next: [TrackChannel])? {
        guard let from = channels.firstIndex(where: { $0.id == id }) else { return nil }
        let to: Int?
        if let before {
            guard let index = channels.firstIndex(where: { $0.id == before }) else { return nil }
            to = index
        } else {
            to = nil
        }
        let target = to ?? channels.count
        guard target != from, target != from + 1 else { return nil }
        var next = channels
        let moved = next.remove(at: from)
        next.insert(moved, at: target > from ? target - 1 : target)
        return (from, to, next)
    }

    static func dropping(_ id: String, at target: String, above: Bool, in channels: [TrackChannel]) -> (before: String?, Void)? {
        guard let to = channels.firstIndex(where: { $0.id == target }) else { return nil }
        let before = above ? target : (to + 1 < channels.count ? channels[to + 1].id : nil)
        return move(id, before: before, in: channels) == nil ? nil : (before, ())
    }

    static func edited(
        sends: [String: Float], route: String?, from old: TrackChannel, to new: TrackChannel,
        bus: (Family) -> String?, main: String
    ) -> (sends: [String: Float], route: String?) {
        var sends = sends
        var route = route
        let (was, now) = (family(of: old), family(of: new))
        if was != now, let from = bus(was), let level = sends[from], let to = bus(now) {
            sends[from] = nil
            sends[to] = max(sends[to] ?? 0, level)
        }
        if old.trackRole == .music, new.trackRole != .music {
            if sends[main] == nil { sends[main] = 0 }
            if route == main { route = "" }
        }
        return (sends, route)
    }
}

public extension TrackChannelList {

    @LibraryActor static func move(_ id: String, before: String?, on document: TypedDocument<TrackChannelList>) throws {
        guard let move = TimelineTracks.move(id, before: before, in: document.value.channels) else { return }
        var next = document.value
        next.channels = move.next
        try document.moveListElement(listAt: [AnyCodingKey("channels")], from: move.from, before: move.before, next: next)
    }
}
