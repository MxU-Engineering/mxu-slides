import Foundation

public enum SettingsLayout {
    public struct Page: Equatable, Sendable {

        public let id: String
        public let rows: [String]
    }

    public static let pages: [Page] = [
        Page(id: "account", rows: ["account.session", "station.name", "station.room", "station.campus"]),
        Page(id: "general", rows: ["appearance.scheme", "updates.automatic"]),
        Page(id: "sync", rows: ["account.documentSync", "station.offline", "sync.duringServices", "station.workspaceLinks"]),
        Page(id: "present", rows: [
            "present.slideTransition", "present.mediaTransition", "present.clearAllAudio", "present.emptyRepeatsOnce",
            "audio.fadeEnabled", "audio.fadeSeconds", "account.autoSwitchServiceTimes",
            "present.continuous", "present.slidesAcross", "present.roundedCorners", "present.transparencyGrid",
            "present.scopedBackgrounds", "present.layouts", "present.runOnly",
        ]),
        Page(id: "edit", rows: ["present.defaultAnimations", "account.messageNotesTheme", "account.messageNotesReview", "groups.palette"]),
        Page(id: "screens", rows: ["screens.configuration", "screens.outputPresets", "present.nextSkipsBlanks"]),
        Page(id: "avInputs", rows: ["avInputs.cameras", "avInputs.audio", "avInputs.outputs"]),
        Page(id: "streamRecord", rows: ["streamRecord.pane"]),
        Page(id: "midi", rows: ["midi.devices", "midi.map"]),
        Page(id: "keyboard", rows: []),
        Page(id: "api", rows: [
            "station.enabled", "station.remote", "network.ndi",
            "api.enabled", "api.port", "api.address", "api.tokens", "api.docs",
        ]),
    ]

    public static let movedPages: [String: String] = [
        "appearance": "general",
        "updates": "general",
        "groups": "edit",
        "audio": "present",
    ]

    public static func page(ofRow id: String) -> String? {
        pages.first { $0.rows.contains(id) }?.id
    }

    public static func pageID(forStored id: String) -> String {
        movedPages[id] ?? id
    }

    public static func order(ofRow id: String) -> Int {
        for (pageIndex, page) in pages.enumerated() {
            if let rowIndex = page.rows.firstIndex(of: id) {
                return pageIndex * 1000 + rowIndex
            }
        }
        return Int.max
    }
}
