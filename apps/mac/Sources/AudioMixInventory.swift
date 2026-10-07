import AudioEngine
import Foundation
import Observation

@MainActor
@Observable
final class AudioMixInventory {
    static let shared = AudioMixInventory()

    nonisolated static let mainID = "main"

    nonisolated static let noOutputID = "none"

    nonisolated static let defaultOutputID = "default"

    struct Entry: Codable, Identifiable, Equatable {
        var id: String
        var name: String

        var outputIds: [String]

        var legacyDeviceUID: String?
        var legacyChannelOffset: Int?

        var isMain: Bool { id == AudioMixInventory.mainID }

        enum CodingKeys: String, CodingKey {
            case id, name, outputIds
            case legacyDeviceUID = "deviceUID"
            case legacyChannelOffset = "channelOffset"
        }

        init(id: String = UUID().uuidString, name: String, outputIds: [String] = []) {
            self.id = id
            self.name = name
            self.outputIds = outputIds
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
            name = try container.decode(String.self, forKey: .name)
            outputIds = try container.decodeIfPresent([String].self, forKey: .outputIds) ?? []
            legacyDeviceUID = try container.decodeIfPresent(String.self, forKey: .legacyDeviceUID)
            legacyChannelOffset = try container.decodeIfPresent(Int.self, forKey: .legacyChannelOffset)
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encode(name, forKey: .name)
            try container.encode(outputIds, forKey: .outputIds)
        }
    }

    private(set) var entries: [Entry] = []
    private static let defaultsKey = "audio.mixes"

    var onEntriesChanged: (() -> Void)?

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let stored = try? JSONDecoder().decode([Entry].self, from: data),
           stored.contains(where: \.isMain) {
            entries = stored

            var migrated = false
            for index in entries.indices where entries[index].outputIds.isEmpty {
                if entries[index].legacyDeviceUID != nil
                    || (entries[index].legacyChannelOffset ?? 0) > 0 {
                    let output = AudioOutputInventory.shared.ensure(
                        deviceUID: entries[index].legacyDeviceUID,
                        channelOffset: entries[index].legacyChannelOffset ?? 0)
                    entries[index].outputIds = [output.id]
                    migrated = true
                }
            }
            if migrated { persistOnly() }
        } else {
            entries = [Entry(id: Self.mainID, name: "Main")]
            migrateLegacyRouting()
            persistOnly()
        }
    }

    private func migrateLegacyRouting() {
        let defaults = UserDefaults.standard
        if let appDevice = defaults.string(forKey: "audio.outputDeviceUID"),
           let index = entries.firstIndex(where: \.isMain) {
            let output = AudioOutputInventory.shared.ensure(
                deviceUID: appDevice, channelOffset: 0)
            entries[index].outputIds = [output.id]
        }
        for (key, value) in defaults.dictionaryRepresentation() {
            guard key.hasPrefix("audio.playlist."), key.hasSuffix(".deviceUID"),
                  let uid = value as? String, !uid.isEmpty else { continue }
            let playlistID = String(key.dropFirst("audio.playlist.".count)
                .dropLast(".deviceUID".count))
            let offset = defaults.integer(forKey: "audio.playlist.\(playlistID).channelOffset")
            let output = AudioOutputInventory.shared.ensure(
                deviceUID: uid, channelOffset: offset)
            let mix = entries.first { $0.outputIds == [output.id] } ?? {
                let created = Entry(name: output.name, outputIds: [output.id])
                entries.append(created)
                return created
            }()
            defaults.set(mix.id, forKey: "audio.playlist.\(playlistID).mixId")
        }
    }

    func entry(id: String) -> Entry? {
        entries.first { $0.id == id }
    }

    var main: Entry {
        entry(id: Self.mainID) ?? Entry(id: Self.mainID, name: "Main")
    }

    @discardableResult
    func create(name: String? = nil) -> Entry {
        let existing = Set(entries.map(\.name))
        var number = entries.count
        while existing.contains("Mix \(number)") { number += 1 }
        let entry = Entry(name: name ?? "Mix \(number)")
        entries.append(entry)
        persist()
        return entry
    }

    func rename(id: String, to name: String) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        entries[index].name = trimmed
        persist()
    }

    func primaryToken(mixId: String) -> String {
        entry(id: mixId)?.outputIds.first ?? Self.defaultOutputID
    }

    func setPrimary(mixId: String, token: String) {
        guard let index = entries.firstIndex(where: { $0.id == mixId }) else { return }
        let sends = Array(entries[index].outputIds.dropFirst()).filter { $0 != token }
        if token == Self.noOutputID {
            entries[index].outputIds = [Self.noOutputID]
        } else if token == Self.defaultOutputID {
            entries[index].outputIds = sends.isEmpty ? [] : [Self.defaultOutputID] + sends
        } else {
            entries[index].outputIds = [token] + sends
        }
        persist()
    }

    func toggleSecondary(mixId: String, outputId: String) {
        guard let index = entries.firstIndex(where: { $0.id == mixId }) else { return }
        var ids = entries[index].outputIds
        if ids.first == Self.noOutputID { ids = [] }
        if ids.isEmpty { ids = [Self.defaultOutputID] }
        if let at = ids.dropFirst().firstIndex(of: outputId) {
            ids.remove(at: at)
        } else if ids.first != outputId {
            ids.append(outputId)
        }
        if ids == [Self.defaultOutputID] { ids = [] }
        entries[index].outputIds = ids
        persist()
    }

    nonisolated static func isVirtual(_ outputIds: [String]) -> Bool {
        outputIds.first == noOutputID
    }

    func remove(_ entry: Entry) {
        guard !entry.isMain else { return }
        entries.removeAll { $0.id == entry.id }
        persist()
    }

    private func persist() {
        persistOnly()
        onEntriesChanged?()
    }

    private func persistOnly() {
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }
}
