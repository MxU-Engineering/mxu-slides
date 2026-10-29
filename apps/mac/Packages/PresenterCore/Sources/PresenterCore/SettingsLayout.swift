import Foundation

public enum SettingsLayout {
    public struct Section: Equatable, Sendable {

        public let title: String?
        public let rows: [String]

        public init(_ title: String?, _ rows: [String]) {
            self.title = title
            self.rows = rows
        }
    }

    public struct Page: Equatable, Sendable {

        public let id: String
        public let sections: [Section]

        public var rows: [String] { sections.flatMap(\.rows) }
    }

    public static let pages: [Page] = [
        Page(id: "general", sections: [
            Section(nil, ["appearance.scheme"]),
        ]),
        Page(id: "present", sections: [
            Section("Transitions", ["present.slideTransition", "present.mediaTransition"]),
            Section(nil, ["present.clearAllAudio"]),

            Section("While presenting", [
                "present.emptyRepeatsOnce", "audio.fadeEnabled", "audio.fadeSeconds",
            ]),
            Section("Present view", [
                "present.continuous", "present.slidesAcross", "present.roundedCorners",
                "present.transparencyGrid", "present.scopedBackgrounds",
            ]),
            Section("Layouts", ["present.layouts"]),
            Section("Volunteers", ["present.runOnly", "present.volunteerTabs"]),
        ]),
        Page(id: "edit", sections: [
            Section("Editing", ["edit.hideSidebar"]),
            Section("Animations", ["present.defaultAnimations"]),
            Section(nil, ["groups.palette"]),
        ]),
        Page(id: "screens", sections: [
            Section("Screens", ["screens.configuration", "screens.outputPresets"]),
            Section("Confidence screens", ["present.nextSkipsBlanks"]),
        ]),
        Page(id: "avInputs", sections: [
            Section(nil, ["avInputs.cameras", "avInputs.audio", "avInputs.outputs"]),
        ]),
        Page(id: "streamRecord", sections: [Section(nil, ["streamRecord.pane"])]),
        Page(id: "midi", sections: [
            Section("MIDI", ["midi.devices", "midi.map"]),

            Section("Timecode", ["timecode.follow", "timecode.audio", "timecode.input", "timecode.signal", "timecode.offset"]),
        ]),
        Page(id: "keyboard", sections: []),
        Page(id: "bible", sections: [Section(nil, ["bible.apiBible"])]),
        Page(id: "api", sections: [
            Section(nil, ["network.ndi"]),
            Section("Local API", ["api.enabled", "api.port", "api.address", "api.tokens", "api.docs"]),
        ]),
    ]

    public static let movedPages: [String: String] = [
        "appearance": "general",
        "groups": "edit",
        "audio": "present",
    ]

    public static func page(id: String) -> Page? {
        pages.first { $0.id == id }
    }

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
