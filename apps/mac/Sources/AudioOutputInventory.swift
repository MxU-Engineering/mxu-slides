import AudioEngine
import Foundation
import Observation

@MainActor
@Observable
final class AudioOutputInventory {
    static let shared = AudioOutputInventory()

    nonisolated static let noDeviceUID = "none"

    struct Entry: Codable, Identifiable, Equatable {
        var id: String
        var name: String

        var deviceUID: String?

        var channelOffset: Int

        var delayMs: Int?

        var isDeviceless: Bool { deviceUID == AudioOutputInventory.noDeviceUID }

        init(
            id: String = UUID().uuidString, name: String,
            deviceUID: String? = nil, channelOffset: Int = 0,
            delayMs: Int? = nil
        ) {
            self.id = id
            self.name = name
            self.deviceUID = deviceUID
            self.channelOffset = channelOffset
            self.delayMs = delayMs
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
            name = try container.decode(String.self, forKey: .name)
            deviceUID = try container.decodeIfPresent(String.self, forKey: .deviceUID)
            channelOffset = try container.decodeIfPresent(Int.self, forKey: .channelOffset) ?? 0
            delayMs = try container.decodeIfPresent(Int.self, forKey: .delayMs)
        }
    }

    private(set) var entries: [Entry] = []
    private static let defaultsKey = "audio.outputs"
    var onEntriesChanged: (() -> Void)?

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let stored = try? JSONDecoder().decode([Entry].self, from: data),
           !stored.isEmpty {
            entries = stored
        } else {

            entries = [Entry(name: "Main Output")]
            persistOnly()
        }
    }

    func entry(id: String) -> Entry? {
        entries.first { $0.id == id }
    }

    func isDeviceless(_ id: String?) -> Bool {
        guard let id else { return false }
        return entry(id: id)?.isDeviceless == true
    }

    func entry(deviceUID: String?, channelOffset: Int) -> Entry? {
        entries.first { $0.deviceUID == deviceUID && $0.channelOffset == channelOffset }
    }

    @discardableResult
    func ensure(deviceUID: String?, channelOffset: Int) -> Entry {
        if let existing = entry(deviceUID: deviceUID, channelOffset: channelOffset) {
            return existing
        }
        let deviceName = deviceUID.flatMap { uid in
            AudioDeviceList.outputDevices().first { $0.uid == uid }?.name
        }
        let base = deviceName ?? (deviceUID == nil ? "Main Output" : "Output")
        let name = channelOffset > 0
            ? "\(base) \(channelOffset + 1)-\(channelOffset + 2)" : base
        let created = Entry(name: name, deviceUID: deviceUID, channelOffset: channelOffset)
        entries.append(created)
        persist()
        return created
    }

    @discardableResult
    func create(name: String? = nil) -> Entry {
        let existing = Set(entries.map(\.name))
        var number = entries.count + 1
        while existing.contains("Output \(number)") { number += 1 }
        let entry = Entry(name: name ?? "Output \(number)")
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

    func assignDevice(id: String, deviceUID: String?, channelOffset: Int) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].deviceUID = deviceUID
        entries[index].channelOffset = max(0, channelOffset)
        persist()
    }

    func setDelay(id: String, milliseconds: Int) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        let clamped = max(0, min(milliseconds, 2000))
        entries[index].delayMs = clamped == 0 ? nil : clamped
        persist()
    }

    func remove(_ entry: Entry) {
        guard entries.count > 1 else { return }  
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
