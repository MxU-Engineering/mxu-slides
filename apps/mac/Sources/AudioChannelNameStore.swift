import AudioEngine
import Foundation
import Observation

@MainActor
@Observable
final class AudioChannelNameStore {
    static let shared = AudioChannelNameStore()

    private var names: [String: [String: String]]
    private static let defaultsKey = "audio.inputChannelNames"

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let stored = try? JSONDecoder().decode([String: [String: String]].self, from: data) {
            names = stored
        } else {
            names = [:]
        }
    }

    func name(uid: String, channel: Int) -> String? {
        names[uid]?[String(channel)]
    }

    func setName(_ name: String, uid: String, channel: Int) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            names[uid]?.removeValue(forKey: String(channel))
            if names[uid]?.isEmpty == true { names.removeValue(forKey: uid) }
        } else {
            names[uid, default: [:]][String(channel)] = trimmed
        }
        if let data = try? JSONEncoder().encode(names) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }

    func entryName(uid: String, selection: InputChannelSelection) -> String? {
        switch selection {
        case .mono(let channel):
            name(uid: uid, channel: channel)
        case .stereoPair(let offset):
            name(uid: uid, channel: offset) ?? name(uid: uid, channel: offset + 1)
        }
    }

    func suffix(uid: String?, selection: InputChannelSelection) -> String {
        guard let uid, let name = entryName(uid: uid, selection: selection) else { return "" }
        return " \u{B7} \(name)"
    }
}
