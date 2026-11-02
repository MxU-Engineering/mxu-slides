import Foundation

public struct SlidePresetChoice: Codable, Equatable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable { case outputPreset, actionCombo }
    public var kind: Kind
    public var id: String

    public init(kind: Kind, id: String) {
        self.kind = kind
        self.id = id
    }

    public static func preset(_ id: String) -> SlidePresetChoice { .init(kind: .outputPreset, id: id) }
    public static func combo(_ id: String) -> SlidePresetChoice { .init(kind: .actionCombo, id: id) }

    public func action() -> SlideAction {
        switch kind {
        case .outputPreset: SlideAction(id: UUID().uuidString, kind: .switchOutputPreset, presetId: id)
        case .actionCombo: SlideAction(id: UUID().uuidString, kind: .fireCombo, comboId: id)
        }
    }

    public func matches(_ action: SlideAction) -> Bool {
        switch kind {
        case .outputPreset: action.kind == .switchOutputPreset && action.presetId == id
        case .actionCombo: action.kind == .fireCombo && action.comboId == id
        }
    }
}

public enum BlankPlacement: String, Codable, Sendable, CaseIterable {
    case none
    case afterPassage
    case afterSlide
}

public struct SlideOptions: Codable, Equatable, Sendable {
    public enum ScriptureSplit: String, Codable, Sendable, CaseIterable {
        case fitToBox, oneVerse
    }

    public var revealPoints = false
    public var scriptureSplit = ScriptureSplit.fitToBox
    public var verseNumbers = true

    public var blanksBetweenVerses = false

    public var keepUnderlines = true

    public var parenthesesToNotes = true

    public var ownTypes: [OwnType] = []

    public var pictureScale = MediaScaleMode.scaleAndBlur

    public var videoEnd = VideoEnd.next

    public var picturesTogether = false

    public enum VideoEnd: String, Codable, Sendable, CaseIterable {
        case next, stop, loop, fadeToBlack, fadeToClear

        public var title: String {
            switch self {
            case .next: "Go to next slide"
            case .stop: "Stop"
            case .loop: "Loop"
            case .fadeToBlack: "Fade to black"
            case .fadeToClear: "Fade to clear"
            }
        }
    }

    public struct OwnType: Codable, Equatable, Sendable, Identifiable {
        public enum Split: String, Codable, Sendable, CaseIterable {
            case fitToBox, paragraph, line

            public var title: String {
                switch self {
                case .fitToBox: "Fit to box"
                case .paragraph: "One paragraph per slide"
                case .line: "One line per slide"
                }
            }
        }

        public var name: String
        public var split = Split.fitToBox

        public var reveal = false

        public var id: String { name }

        public init(name: String, split: Split = .fitToBox, reveal: Bool = false) {
            self.name = name
            self.split = split
            self.reveal = reveal
        }

        private enum CodingKeys: String, CodingKey { case name, split, reveal }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try container.decode(String.self, forKey: .name)
            split = (try? container.decodeIfPresent(Split.self, forKey: .split)) ?? .fitToBox
            reveal = try container.decodeIfPresent(Bool.self, forKey: .reveal) ?? false
        }
    }

    public init() {}

    public func ownType(named name: String?) -> OwnType? {
        guard let name else { return nil }
        return ownTypes.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    private enum CodingKeys: String, CodingKey {
        case revealPoints, scriptureSplit, verseNumbers, blanksBetweenVerses, keepUnderlines, parenthesesToNotes, ownTypes
        case pictureScale, videoEnd, picturesTogether
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = SlideOptions()
        revealPoints = try container.decodeIfPresent(Bool.self, forKey: .revealPoints) ?? defaults.revealPoints
        scriptureSplit = (try? container.decodeIfPresent(ScriptureSplit.self, forKey: .scriptureSplit)) ?? defaults.scriptureSplit
        verseNumbers = try container.decodeIfPresent(Bool.self, forKey: .verseNumbers) ?? defaults.verseNumbers
        blanksBetweenVerses = try container.decodeIfPresent(Bool.self, forKey: .blanksBetweenVerses) ?? defaults.blanksBetweenVerses
        keepUnderlines = try container.decodeIfPresent(Bool.self, forKey: .keepUnderlines) ?? defaults.keepUnderlines
        parenthesesToNotes = try container.decodeIfPresent(Bool.self, forKey: .parenthesesToNotes) ?? defaults.parenthesesToNotes
        ownTypes = try container.decodeIfPresent([OwnType].self, forKey: .ownTypes) ?? []
        pictureScale = (try? container.decodeIfPresent(MediaScaleMode.self, forKey: .pictureScale)) ?? defaults.pictureScale
        videoEnd = (try? container.decodeIfPresent(VideoEnd.self, forKey: .videoEnd)) ?? defaults.videoEnd
        picturesTogether = try container.decodeIfPresent(Bool.self, forKey: .picturesTogether) ?? defaults.picturesTogether
    }
}

public struct SlideDesignMap: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var themeId: String
        public var themeSlideName: String

        public init(themeId: String, themeSlideName: String) {
            self.themeId = themeId
            self.themeSlideName = themeSlideName
        }
    }

    public var entries: [String: Entry]

    public var presets: [String: SlidePresetChoice]

    public var otherPreset: SlidePresetChoice?
    public var blanks: BlankPlacement
    public var options: SlideOptions

    public init(
        entries: [String: Entry] = [:], presets: [String: SlidePresetChoice] = [:],
        otherPreset: SlidePresetChoice? = nil, blanks: BlankPlacement = .none, options: SlideOptions = SlideOptions()
    ) {
        self.entries = entries
        self.presets = presets
        self.otherPreset = otherPreset
        self.blanks = blanks
        self.options = options
    }

    private enum CodingKeys: String, CodingKey { case entries, presets, otherPreset, blanks, blankPreset, options }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        entries = try container.decodeIfPresent([String: Entry].self, forKey: .entries) ?? [:]
        presets = try container.decodeIfPresent([String: SlidePresetChoice].self, forKey: .presets) ?? [:]
        otherPreset = try container.decodeIfPresent(SlidePresetChoice.self, forKey: .otherPreset)
        blanks = try container.decodeIfPresent(BlankPlacement.self, forKey: .blanks) ?? .none
        options = try container.decodeIfPresent(SlideOptions.self, forKey: .options) ?? SlideOptions()
        if presets[SlideKind.blank.rawValue] == nil,
           let old = try container.decodeIfPresent(SlidePresetChoice.self, forKey: .blankPreset) {
            presets[SlideKind.blank.rawValue] = old
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(entries, forKey: .entries)
        try container.encode(presets, forKey: .presets)
        try container.encodeIfPresent(otherPreset, forKey: .otherPreset)
        try container.encode(blanks, forKey: .blanks)
        try container.encode(options, forKey: .options)
    }

    public func entry(for kind: SlideKind) -> Entry? { entry(forType: kind.rawValue) }

    public mutating func set(_ entry: Entry?, for kind: SlideKind) {
        set(entry, forType: kind.rawValue)
    }

    public func preset(for kind: SlideKind) -> SlidePresetChoice? { preset(forType: kind.rawValue) }

    public func ownPreset(for kind: SlideKind) -> SlidePresetChoice? { ownPreset(forType: kind.rawValue) }

    public mutating func setPreset(_ preset: SlidePresetChoice?, for kind: SlideKind) {
        setPreset(preset, forType: kind.rawValue)
    }

    public func entry(forType type: String) -> Entry? { entries[type] }

    public mutating func set(_ entry: Entry?, forType type: String) { entries[type] = entry }

    public func preset(forType type: String) -> SlidePresetChoice? { presets[type] ?? otherPreset }

    public func ownPreset(forType type: String) -> SlidePresetChoice? { presets[type] }

    public mutating func setPreset(_ preset: SlidePresetChoice?, forType type: String) { presets[type] = preset }

    public func canAddOwnType(named name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty && SlideKind(rawValue: trimmed.lowercased()) == nil && options.ownType(named: trimmed) == nil
    }

    public mutating func renameOwnType(_ old: String, to new: String) {
        guard let index = options.ownTypes.firstIndex(where: { $0.name == old }) else { return }
        options.ownTypes[index].name = new
        entries[new] = entries.removeValue(forKey: old)
        presets[new] = presets.removeValue(forKey: old)
    }

    public mutating func removeOwnType(named name: String) {
        options.ownTypes.removeAll { $0.name == name }
        entries[name] = nil
        presets[name] = nil
    }

    public static let kinds: [SlideKind] = [.title, .points, .scripture, .quote, .lyrics, .picture, .video, .blank]

    public static func decode(_ data: Data?) -> SlideDesignMap {
        guard let data, let map = try? JSONDecoder().decode(SlideDesignMap.self, from: data) else { return SlideDesignMap() }
        return map
    }

    public func encoded() -> Data {
        (try? JSONEncoder().encode(self)) ?? Data()
    }
}
