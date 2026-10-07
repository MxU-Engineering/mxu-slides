import Foundation

public struct KeyChord: Codable, Hashable, Sendable {
    public var key: String
    public var command: Bool?
    public var option: Bool?
    public var control: Bool?
    public var shift: Bool?

    public init(
        _ key: String, command: Bool = false, option: Bool = false,
        control: Bool = false, shift: Bool = false
    ) {
        self.key = KeyChord.normalizeToken(key)
        self.command = command ? true : nil
        self.option = option ? true : nil
        self.control = control ? true : nil
        self.shift = shift ? true : nil
    }

    public var hasCommand: Bool { command ?? false }
    public var hasOption: Bool { option ?? false }
    public var hasControl: Bool { control ?? false }
    public var hasShift: Bool { shift ?? false }

    public var isBare: Bool { !hasCommand && !hasOption && !hasControl && !hasShift }

    public func matches(_ other: KeyChord) -> Bool {
        KeyChord.normalizeToken(key) == KeyChord.normalizeToken(other.key)
            && hasCommand == other.hasCommand && hasOption == other.hasOption
            && hasControl == other.hasControl && hasShift == other.hasShift
    }

    public static func normalizeToken(_ raw: String) -> String {
        let token = raw.lowercased()
        switch token {
        case "esc": return "escape"
        case "enter": return "return"
        case "backspace": return "delete"
        default: return token
        }
    }

    public var display: String {
        var text = ""
        if hasControl { text += "⌃" }
        if hasOption { text += "⌥" }
        if hasShift { text += "⇧" }
        if hasCommand { text += "⌘" }
        return text + KeyChord.capLabel(for: key)
    }

    public static func capLabel(for token: String) -> String {
        switch normalizeToken(token) {
        case "left": return "←"
        case "right": return "→"
        case "up": return "↑"
        case "down": return "↓"
        case "space": return "Space"
        case "return": return "⏎"
        case "escape": return "⎋"
        case "delete": return "⌫"
        case "tab": return "⇥"
        case let t where t.hasPrefix("f") && Int(t.dropFirst()) != nil:
            return t.uppercased()
        case let t: return t.uppercased()
        }
    }
}

public enum KeyCommandGroup: String, CaseIterable, Sendable {
    case showControl
    case clears
    case video
    case createLibrary
    case editor
    case application

    public var displayName: String {
        switch self {
        case .showControl: "Show Control"
        case .clears: "Clear Layers"
        case .video: "Video"
        case .createLibrary: "Create & Library"
        case .editor: "Editor"
        case .application: "Application"
        }
    }
}

public enum KeyCommandScope: String, Sendable {
    case present
    case editor
    case anywhere

    public var displayName: String {
        switch self {
        case .present: "Present"
        case .editor: "Editor"
        case .anywhere: "Anywhere"
        }
    }
}

public enum KeyCommand: String, Codable, CaseIterable, Sendable {
    case nextSlide
    case previousSlide
    case goToSlide
    case nextServiceItem
    case previousServiceItem
    case clearAll
    case clearSlides
    case clearMedia
    case clearOverlays
    case clearAudio
    case clearAlerts
    case clearSignage
    case videoPlayPause
    case videoGoToBeginning
    case newPresentation
    case newSlide
    case newService
    case newOverlay
    case newTheme
    case findInLibrary
    case boldSelection
    case italicSelection
    case underlineSelection
    case modePresent
    case modeEdit
    case modeScheduler
    case toggleSidebar
    case toggleRightPanels
    case openKeyboardSettings

    public var defaultChords: [KeyChord] {
        switch self {
        case .nextSlide: [KeyChord("right"), KeyChord("space"), KeyChord("return")]
        case .previousSlide: [KeyChord("left")]
        case .goToSlide: []
        case .nextServiceItem: []
        case .previousServiceItem: []
        case .clearAll: [KeyChord("f1")]
        case .clearSlides: [KeyChord("f2")]
        case .clearMedia: [KeyChord("f3")]
        case .clearOverlays: [KeyChord("f4")]
        case .clearAudio: [KeyChord("f5")]
        case .clearAlerts: [KeyChord("f6")]
        case .clearSignage: [KeyChord("f7")]
        case .videoPlayPause: []
        case .videoGoToBeginning: []
        case .newPresentation: [KeyChord("n", command: true)]
        case .newSlide: [KeyChord("n", command: true, shift: true)]
        case .newService: []
        case .newOverlay: []
        case .newTheme: []
        case .findInLibrary: [KeyChord("f", command: true)]
        case .boldSelection: [KeyChord("b", command: true)]
        case .italicSelection: [KeyChord("i", command: true)]
        case .underlineSelection: [KeyChord("u", command: true)]
        case .modePresent: [KeyChord("1", command: true)]
        case .modeEdit: [KeyChord("2", command: true)]
        case .modeScheduler: [KeyChord("3", command: true)]
        case .toggleSidebar: [KeyChord("s", command: true, control: true)]
        case .toggleRightPanels: [KeyChord("r", command: true, control: true)]
        case .openKeyboardSettings: [KeyChord("k", option: true)]
        }
    }

    public var group: KeyCommandGroup {
        switch self {
        case .nextSlide, .previousSlide, .goToSlide,
             .nextServiceItem, .previousServiceItem:
            .showControl
        case .clearAll, .clearSlides, .clearMedia, .clearOverlays, .clearAudio,
             .clearAlerts, .clearSignage:
            .clears
        case .videoPlayPause, .videoGoToBeginning:
            .video
        case .newPresentation, .newSlide, .newService, .newOverlay, .newTheme,
             .findInLibrary:
            .createLibrary
        case .boldSelection, .italicSelection, .underlineSelection:
            .editor
        case .modePresent, .modeEdit, .modeScheduler, .toggleSidebar,
             .toggleRightPanels, .openKeyboardSettings:
            .application
        }
    }

    public var scope: KeyCommandScope {
        switch self {
        case .nextSlide, .previousSlide, .goToSlide,
             .nextServiceItem, .previousServiceItem, .videoPlayPause,
             .videoGoToBeginning,
             .clearAll, .clearSlides, .clearMedia, .clearOverlays, .clearAudio,
             .clearAlerts, .clearSignage:
            .present
        case .boldSelection, .italicSelection, .underlineSelection:
            .editor
        case .newPresentation, .newSlide, .newService, .newOverlay, .newTheme,
             .findInLibrary, .modePresent, .modeEdit, .modeScheduler,
             .toggleSidebar, .toggleRightPanels, .openKeyboardSettings:
            .anywhere
        }
    }

    public var runsInRunOnly: Bool {
        switch self {
        case .nextSlide, .previousSlide, .goToSlide,
             .nextServiceItem, .previousServiceItem,
             .clearAll, .clearSlides, .clearMedia, .clearOverlays, .clearAudio,
             .clearAlerts, .clearSignage,
             .videoPlayPause, .videoGoToBeginning,
             .modePresent, .toggleSidebar, .toggleRightPanels,
             .openKeyboardSettings:
            true
        case .newPresentation, .newSlide, .newService, .newOverlay, .newTheme,
             .findInLibrary,
             .boldSelection, .italicSelection, .underlineSelection,
             .modeEdit, .modeScheduler:
            false
        }
    }

    public var fixedKeyDescription: String? {
        switch self {
        case .goToSlide: "0–9 then ⏎"
        default: nil
        }
    }

    public var displayName: String {
        switch self {
        case .nextSlide: "Next Slide"
        case .previousSlide: "Previous Slide"
        case .goToSlide: "Go to Slide"
        case .nextServiceItem: "Next Service Item"
        case .previousServiceItem: "Previous Service Item"
        case .clearAll: "Clear All"
        case .clearSlides: "Clear Slides"
        case .clearMedia: "Clear Media"
        case .clearOverlays: "Clear Overlays"
        case .clearAudio: "Clear Music"
        case .clearAlerts: "Clear Alerts"
        case .clearSignage: "Clear Signage"
        case .videoPlayPause: "Play/Pause Video"
        case .videoGoToBeginning: "Video to Beginning"
        case .newPresentation: "New Presentation"
        case .newSlide: "New Slide"
        case .newService: "New Service"
        case .newOverlay: "New Overlay"
        case .newTheme: "New Theme"
        case .findInLibrary: "Find in Library"
        case .boldSelection: "Bold"
        case .italicSelection: "Italic"
        case .underlineSelection: "Underline"
        case .modePresent: "Go to Present"
        case .modeEdit: "Go to Edit"
        case .modeScheduler: "Go to Scheduler"
        case .toggleSidebar: "Toggle Sidebar"
        case .toggleRightPanels: "Toggle Right Panels"
        case .openKeyboardSettings: "Open Keyboard Settings"
        }
    }
}

public enum GeneratedKeyKind: String, CaseIterable, Sendable {
    case combo
    case outputPreset = "preset"
    case overlayToggle = "overlay"
    case timerStart = "timerstart"
    case timerPause = "timerpause"
    case timerReset = "timerreset"
    case settingsPage = "settings"
    case preview

    public var prefix: String { rawValue + "." }

    public var runsInRunOnly: Bool {
        switch self {
        case .combo, .overlayToggle, .timerStart, .timerPause, .timerReset,
             .settingsPage, .preview:
            true
        case .outputPreset:
            false
        }
    }

    public var scope: KeyCommandScope {
        switch self {
        case .settingsPage, .preview: .anywhere
        default: .present
        }
    }
}

public struct GeneratedKey: Equatable, Hashable, Sendable {
    public var kind: GeneratedKeyKind
    public var id: String

    public init(_ kind: GeneratedKeyKind, _ id: String) {
        self.kind = kind
        self.id = id
    }

    public var mapKey: String { kind.prefix + id }

    public static func parse(_ mapKey: String) -> GeneratedKey? {
        for kind in GeneratedKeyKind.allCases where mapKey.hasPrefix(kind.prefix) {
            return GeneratedKey(kind, String(mapKey.dropFirst(kind.prefix.count)))
        }
        return nil
    }
}

public enum KeyBindingTarget: Equatable, Sendable {
    case command(KeyCommand)
    case generated(GeneratedKey)

    public var runsInRunOnly: Bool {
        switch self {
        case .command(let command): command.runsInRunOnly
        case .generated(let key): key.kind.runsInRunOnly
        }
    }
}

public struct KeyCommandMap: Codable, Equatable, Sendable {
    public static let comboPrefix = "combo."

    public var chords: [String: KeyChord?]

    public init(chords: [String: KeyChord?] = [:]) {
        self.chords = chords
    }

    public func chords(for command: KeyCommand) -> [KeyChord] {
        guard let entry = chords[command.rawValue] else { return command.defaultChords }
        return entry.map { [$0] } ?? []
    }

    public func isCustomized(_ command: KeyCommand) -> Bool {
        chords[command.rawValue] != nil
    }

    public mutating func setChord(_ chord: KeyChord?, for command: KeyCommand) {
        if let chord, command.defaultChords.count == 1,
           command.defaultChords[0].matches(chord) {
            chords.removeValue(forKey: command.rawValue)
        } else if chord == nil, command.defaultChords.isEmpty {
            chords.removeValue(forKey: command.rawValue)
        } else {
            chords[command.rawValue] = .some(chord)
        }
    }

    public mutating func resetToDefault(_ command: KeyCommand) {
        chords.removeValue(forKey: command.rawValue)
    }

    public func chord(for key: GeneratedKey) -> KeyChord? {
        chords[key.mapKey] ?? nil
    }

    public mutating func setChord(_ chord: KeyChord?, for key: GeneratedKey) {
        if let chord {
            chords[key.mapKey] = .some(chord)
        } else {
            chords.removeValue(forKey: key.mapKey)
        }
    }

    public func boundIDs(_ kind: GeneratedKeyKind) -> [String] {
        chords.keys.filter { $0.hasPrefix(kind.prefix) }
            .map { String($0.dropFirst(kind.prefix.count)) }
            .sorted()
    }

    public var boundGeneratedKeys: [GeneratedKey] {
        chords.keys.sorted().compactMap { key in
            guard let parsed = GeneratedKey.parse(key), chords[key] != nil,
                  chords[key]! != nil else { return nil }
            return parsed
        }
    }

    public func chord(forComboID id: String) -> KeyChord? {
        chord(for: GeneratedKey(.combo, id))
    }

    public mutating func setChord(_ chord: KeyChord?, forComboID id: String) {
        setChord(chord, for: GeneratedKey(.combo, id))
    }

    public var boundComboIDs: [String] { boundIDs(.combo) }

    public func resolve(
        chord: KeyChord, activeScopes: Set<KeyCommandScope>
    ) -> KeyBindingTarget? {
        var anywhereMatch: KeyBindingTarget?
        for command in KeyCommand.allCases {

            let active = command.scope == .anywhere || activeScopes.contains(command.scope)
            guard active, chords(for: command).contains(where: { $0.matches(chord) })
            else { continue }
            if command.scope == .anywhere {
                if anywhereMatch == nil { anywhereMatch = .command(command) }
            } else {
                return .command(command)
            }
        }
        for key in boundGeneratedKeys {
            let active = key.kind.scope == .anywhere || activeScopes.contains(key.kind.scope)
            guard active, self.chord(for: key)?.matches(chord) == true else { continue }
            if key.kind.scope == .anywhere {
                if anywhereMatch == nil { anywhereMatch = .generated(key) }
            } else {
                return .generated(key)
            }
        }
        return anywhereMatch
    }

    public func conflictedKeys() -> Set<String> {
        struct Bound {
            let mapKey: String
            let chord: KeyChord
            let scope: KeyCommandScope
        }
        var bound: [Bound] = []
        for command in KeyCommand.allCases {
            for chord in chords(for: command) {
                bound.append(Bound(
                    mapKey: command.rawValue, chord: chord, scope: command.scope))
            }
        }
        for key in boundGeneratedKeys {
            if let chord = chord(for: key) {
                bound.append(Bound(
                    mapKey: key.mapKey, chord: chord, scope: key.kind.scope))
            }
        }
        var conflicted: Set<String> = []
        for (index, a) in bound.enumerated() {
            for b in bound[(index + 1)...] where a.chord.matches(b.chord) {
                let scopesMeet = a.scope == b.scope
                    || a.scope == .anywhere || b.scope == .anywhere
                if scopesMeet {
                    conflicted.insert(a.mapKey)
                    conflicted.insert(b.mapKey)
                }
            }
        }
        return conflicted
    }
}

extension GroupPalette {

    public static let defaultHotKeys: [String: String] = [
        "verse": "a", "verse1": "a", "verse2": "s", "verse3": "d",
        "verse4": "f", "verse5": "g", "verse6": "h",
        "chorus": "c", "chorus1": "c", "chorus2": "x", "chorus3": "z",
        "bridge": "b", "bridge1": "b", "bridge2": "n", "bridge3": "m",
        "prechorus": "p", "tag": "t", "intro": "i", "ending": "e", "outro": "o",
    ]

    public static func effectiveHotKey(for group: GroupDefinition) -> String? {
        if let stored = group.hotKey {
            return stored.isEmpty ? nil : stored.lowercased()
        }
        return defaultHotKeys[normalizedName(group.name)]
    }

    public mutating func fillUnsetHotKeys(imported: [String: String]) {
        for index in groups.indices {
            guard groups[index].hotKey == nil else { continue }
            let name = GroupPalette.normalizedName(groups[index].name)
            guard let letter = imported[name]?.lowercased(), letter.count == 1,
                  letter.first?.isLetter == true else { continue }
            if GroupPalette.defaultHotKeys[name] == letter { continue }
            groups[index].hotKey = letter
        }
    }

    public var hotKeyTargets: [String: [String]] {
        var table: [String: [String]] = [:]
        var seen: Set<String> = []
        for group in groups {
            let key = GroupPalette.normalizedName(group.name)
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            guard let hotKey = GroupPalette.effectiveHotKey(for: group) else { continue }
            table[hotKey, default: []].append(key)
        }
        return table
    }
}
