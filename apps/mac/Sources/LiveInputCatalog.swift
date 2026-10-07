import AVFoundation
import Observation
import PresenterCore

@MainActor
enum LiveInputCatalog {
    struct Choice: Identifiable {

        let id: String
        let name: String
        var token: String { "item::\(id)" }
    }

    static var choices: [Choice] {
        VideoInputInventory.shared.entries.map { entry in
            Choice(id: entry.id, name: entry.name)
        }
    }

    static func selectionToken(
        liveInputId: String?, kind: CaptureSourceKind?, id: String?
    ) -> String {
        if let liveInputId, !liveInputId.isEmpty { return "item::\(liveInputId)" }
        guard let kind, let id, !id.isEmpty else { return "" }
        return "\(kind.rawValue)::\(id)"
    }

    static func liveInputId(for token: String) -> String? {
        guard token.hasPrefix("item::") else { return nil }
        let id = String(token.dropFirst("item::".count))
        return id.isEmpty ? nil : id
    }

    static func choice(for token: String) -> (kind: CaptureSourceKind, id: String)? {
        guard !token.isEmpty else { return nil }
        let parts = token.split(separator: ":", omittingEmptySubsequences: true)
        guard parts.count >= 2,
              let kind = CaptureSourceKind(rawValue: String(parts[0]))
        else { return nil }
        return (kind, parts.dropFirst().joined(separator: ":"))
    }

    static func legacyLabel(kind: CaptureSourceKind?, id: String?) -> String {
        guard let id, !id.isEmpty else { return "None" }
        if kind == .ndi { return "NDI: \(id)" }
        return AVCaptureDevice(uniqueID: id)?.localizedName ?? "Camera: \(id)"
    }
}

enum ScreenSourceToken {
    static func token(forScreenId id: String) -> String { "screen::\(id)" }

    static func screenId(for token: String) -> String? {
        guard token.hasPrefix("screen::") else { return nil }
        return String(token.dropFirst("screen::".count))
    }
}
