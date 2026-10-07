import Foundation

public enum BackupSection: String, Codable, CaseIterable, Sendable {

    case presentations, media, mediaFiles, themes, overlays, alerts
    case confidenceLayouts, combos, playlists, services, schedules, notes

    case outputPresets, streaming, midiDevices, controlBoards, groups
    case presetBoards, signage, fonts, settings

    public enum Column: Sendable { case content, setup }

    public var column: Column {
        switch self {
        case .presentations, .media, .mediaFiles, .themes, .overlays, .alerts,
             .confidenceLayouts, .combos, .playlists, .services, .schedules, .notes:
            .content
        case .outputPresets, .streaming, .midiDevices, .controlBoards, .groups,
             .presetBoards, .signage, .fonts, .settings:
            .setup
        }
    }

    public var title: String {
        switch self {
        case .presentations: "Presentations"
        case .media: "Media & audio library"
        case .mediaFiles: "Include the media files"
        case .themes: "Themes"
        case .overlays: "Overlays"
        case .alerts: "Alerts"
        case .confidenceLayouts: "Confidence layouts"
        case .combos: "Action combos"
        case .playlists: "Playlists"
        case .services: "Services"
        case .schedules: "Scheduler"
        case .notes: "Notes"
        case .outputPresets: "Output presets"
        case .streaming: "Stream & record presets"
        case .midiDevices: "MIDI devices"
        case .controlBoards: "Control boards"
        case .groups: "Groups & hot keys"
        case .presetBoards: "Effect & animation presets"
        case .signage: "Signage channels"
        case .fonts: "Imported fonts"
        case .settings: "App settings"
        }
    }

    public static func section(for kind: DocumentKind) -> BackupSection {
        switch kind {
        case .presentation, .importLedger: .presentations
        case .media, .audio: .media
        case .theme: .themes
        case .overlay: .overlays
        case .alertPreset: .alerts
        case .confidenceLayout: .confidenceLayouts
        case .actionCombo: .combos
        case .playlist: .playlists
        case .service, .serviceLinkRules: .services
        case .scheduleTrigger, .schedulerBoard: .schedules
        case .note: .notes
        case .outputPreset: .outputPresets
        case .streamRecordPreset, .streamDestination: .streaming
        case .midiDevice: .midiDevices
        case .controlBoard: .controlBoards
        case .groupPalette: .groups
        case .effectPresetBoard, .animationPresetBoard: .presetBoards
        case .signageBoard: .signage
        case .stationSettings, .slideBuildingSettings, .workspaceSettings: .settings
        case .font: .fonts
        }
    }
}

public enum BackupConflictPolicy: String, Codable, CaseIterable, Sendable {

    case merge

    case keepMine

    case replace

    public var displayName: String {
        switch self {
        case .merge: "Merge — keep edits from both"
        case .keepMine: "Keep mine — only add what's missing"
        case .replace: "Replace with the backup's copy"
        }
    }
}

public struct BackupImportOptions: Codable, Equatable, Sendable {
    public var policy: BackupConflictPolicy = .merge
    public var excluded: Set<BackupSection> = []

    public init() {}

    public func includes(_ section: BackupSection) -> Bool {
        !excluded.contains(section) && (section != .mediaFiles || !excluded.contains(.media))
    }
}

public struct BackupScan: Sendable {
    public let manifest: BackupBundle.Manifest
    public let counts: [BackupSection: Int]

    public func count(_ section: BackupSection) -> Int {
        counts[section] ?? 0
    }
}

public struct BackupProgress: Sendable, Equatable {
    public var phase: String
    public var detail: String
    public var completed: Int
    public var total: Int?

    public init(phase: String, detail: String = "", completed: Int = 0, total: Int? = nil) {
        self.phase = phase
        self.detail = detail
        self.completed = completed
        self.total = total
    }
}

public typealias BackupProgressHandler = @MainActor @Sendable (BackupProgress) -> Void

public struct BackupRestoreResult: Sendable {
    public let manifest: BackupBundle.Manifest
    public var added: [BackupSection: Int] = [:]
    public var merged = 0
    public var replaced = 0
    public var kept = 0
    public var mediaFilesCopied = 0
    public var fontsCopied = 0
    public var settingsStaged = 0
    public var warnings: [String] = []

    public var documentsLanded: Int {
        added.values.reduce(0, +) + merged + replaced
    }
}
