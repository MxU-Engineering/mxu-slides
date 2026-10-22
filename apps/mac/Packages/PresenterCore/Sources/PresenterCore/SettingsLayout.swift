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
        Page(id: "account", sections: [
            Section(nil, ["account.session"]),
            Section("This computer", ["station.name", "station.room", "station.campus"]),
        ]),
        Page(id: "general", sections: [
            Section(nil, ["appearance.scheme", "updates.automatic"]),
        ]),
        Page(id: "sync", sections: [
            Section(nil, ["account.documentSync", "station.offline"]),
            Section(nil, ["sync.duringServices"]),
            Section(nil, ["station.workspaceLinks"]),
        ]),
        Page(id: "present", sections: [
            Section("Transitions", ["present.slideTransition", "present.mediaTransition"]),
            Section(nil, ["present.clearAllAudio"]),

            Section("While presenting", [
                "present.emptyRepeatsOnce", "audio.fadeEnabled", "audio.fadeSeconds", "account.autoSwitchServiceTimes",
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
            Section("Message notes", ["account.messageNotesTheme", "account.messageNotesReview"]),
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

            Section("Timecode", ["timecode.follow", "timecode.input", "timecode.signal", "timecode.offset"]),
        ]),
        Page(id: "keyboard", sections: []),
        Page(id: "api", sections: [
            Section("MxU dashboards", ["station.enabled", "station.remote"]),
            Section(nil, ["network.ndi"]),
            Section("Local API", ["api.enabled", "api.port", "api.address", "api.tokens", "api.docs"]),
        ]),
    ]

    public static let movedPages: [String: String] = [
        "appearance": "general",
        "updates": "general",
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

    public enum Scope: Equatable, Sendable {

        case team

        case setup

        case linked(WorkspaceLinkSetting)
    }

    public static let scopes: [String: Scope] = [
        "present.defaultAnimations": .team,
        "account.messageNotesTheme": .team,
        "groups.palette": .team,
        "present.slideTransition": .setup,
        "present.mediaTransition": .setup,
        "present.clearAllAudio": .setup,
        "present.nextSkipsBlanks": .setup,
        "audio.fadeEnabled": .setup,
        "audio.fadeSeconds": .setup,
        "midi.map": .setup,
        "screens.configuration": .linked(.screens),
        "screens.outputPresets": .linked(.outputPresets),
    ]

    public enum Tag: Equatable, Sendable {
        case team

        case sharedOnSetup(others: Int)

        case sharedWith(String)

        case from(String)

        case namesFrom(String)

        public var words: String {
            switch self {
            case .team: "Team"
            case .sharedOnSetup(let others): "Shared with \(others) other computer\(others == 1 ? "" : "s")"
            case .sharedWith(let name): "Shared with \(name)"
            case .from(let name): "From \(name)"
            case .namesFrom(let name): "Names from \(name)"
            }
        }

        public var help: String {
            switch self {
            case .team: "A change here reaches every computer on your team."
            case .sharedOnSetup: "Computers running this setup share it."
            case .sharedWith(let name): "A change on either this computer or \(name) changes both."
            case .from(let name): "Only \(name) can change these."
            case .namesFrom(let name): "The list comes from \(name); what each one does is this computer's own."
            }
        }
    }

    public static func tag(
        forRow id: String, otherComputersOnTeam: Int, othersOnThisSetup: Int,
        link: (mode: WorkspaceLinkMode, source: String)? = nil, followedBy: [String] = []
    ) -> Tag? {
        let shared: Tag? = othersOnThisSetup > 0 ? .sharedOnSetup(others: othersOnThisSetup) : nil
        switch scopes[id] {
        case .team?:
            return otherComputersOnTeam > 0 ? .team : nil
        case .setup?:
            return shared
        case .linked?:
            switch link?.mode {
            case .twoWay?: return link.map { .sharedWith($0.source) }
            case .oneWay?: return link.map { .from($0.source) }
            case .namesOnly?: return link.map { .namesFrom($0.source) }
            case .thisWorkspaceOnly?, nil:
                return followedBy.first.map { .sharedWith(followedBy.count == 1 ? $0 : "\(followedBy.count) computers") } ?? shared
            }
        case nil:
            return nil
        }
    }
}
