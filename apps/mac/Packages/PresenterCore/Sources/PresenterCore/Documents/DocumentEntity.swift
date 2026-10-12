import Foundation

public enum DocumentKind: String, CaseIterable, Sendable {
    case presentation
    case service
    case theme
    case media
    case audio
    case playlist
    case overlay
    case outputPreset
    case alertPreset
    case streamRecordPreset
    case streamDestination
    case actionCombo
    case scheduleTrigger
    case schedulerBoard
    case controlBoard
    case confidenceLayout
    case groupPalette
    case signageBoard
    case effectPresetBoard
    case animationPresetBoard
    case midiDevice
    case importLedger
    case serviceLinkRules
    case note
    case stationSettings
    case slideBuildingSettings
    case font
    case workspaceSettings

    public var opensInEditor: Bool {
        switch self {
        case .presentation, .theme, .overlay, .confidenceLayout, .media, .audio, .note:
            true
        default:
            false
        }
    }

    var directoryName: String {
        switch self {
        case .presentation: "presentations"
        case .service: "services"
        case .theme: "themes"
        case .media: "media"
        case .audio: "audio"
        case .playlist: "playlists"
        case .overlay: "overlays"
        case .outputPreset: "output-presets"
        case .alertPreset: "alert-presets"
        case .streamRecordPreset: "stream-presets"
        case .streamDestination: "stream-destinations"
        case .actionCombo: "action-combos"
        case .scheduleTrigger: "schedule-triggers"
        case .schedulerBoard: "scheduler"
        case .controlBoard: "control-boards"
        case .confidenceLayout: "confidence-layouts"
        case .groupPalette: "groups"
        case .signageBoard: "signage"
        case .effectPresetBoard: "effect-presets"
        case .animationPresetBoard: "animation-presets"
        case .midiDevice: "midi-devices"
        case .importLedger: "import-ledger"
        case .serviceLinkRules: "service-link-rules"
        case .note: "notes"
        case .stationSettings: "station-settings"
        case .slideBuildingSettings: "slide-building-settings"

        case .font: "font-files"
        case .workspaceSettings: "workspace-settings"
        }
    }
}

public protocol DocumentEntity: Codable, Equatable, Sendable, Identifiable where ID == String {
    static var documentKind: DocumentKind { get }
    var id: String { get }

    var name: String { get }

    var indexSubkind: String { get }

    var indexText: String { get }

    var indexCCLI: IndexCCLI { get }

    var indexFolderId: String { get }

    var indexOrigin: String { get }
}

public struct IndexCCLI: Equatable, Sendable {
    public var number: Int?
    public var title: String?
    public static let none = IndexCCLI(number: nil, title: nil)
    public init(number: Int?, title: String?) {
        self.number = number
        self.title = title
    }
}

public extension DocumentEntity {
    var indexSubkind: String { "" }
    var indexText: String { "" }
    var indexCCLI: IndexCCLI { .none }
    var indexFolderId: String { (self as? any TeamFolderedEntity)?.folderId ?? "" }
    var indexOrigin: String { "" }
}

extension Presentation: DocumentEntity {
    public static var documentKind: DocumentKind { .presentation }

    public var indexSubkind: String { folder ?? "" }
    public var indexCCLI: IndexCCLI { IndexCCLI(number: ccli?.songNumber, title: ccli?.songTitle) }
    public var indexOrigin: String { originLabel ?? "" }

    public var indexText: String {
        slides.flatMap { $0.objects.map(\.text) }.filter { !$0.isEmpty }.joined(separator: " ")
    }
}

extension Service: DocumentEntity {
    public static var documentKind: DocumentKind { .service }

    public var indexSubkind: String { serviceDate }
}

extension Theme: DocumentEntity {
    public static var documentKind: DocumentKind { .theme }
}

extension Overlay: DocumentEntity {
    public static var documentKind: DocumentKind { .overlay }

    public var indexSubkind: String { folder ?? "" }
    public var indexText: String {
        objects.map(\.text).filter { !$0.isEmpty }.joined(separator: " ")
    }
}

extension OutputPreset: DocumentEntity {
    public static var documentKind: DocumentKind { .outputPreset }
}

extension AlertPreset: DocumentEntity {
    public static var documentKind: DocumentKind { .alertPreset }
    public var indexText: String { message }
}

extension StreamRecordPreset: DocumentEntity {
    public static var documentKind: DocumentKind { .streamRecordPreset }

    public var indexText: String { destinations.map(\.name).joined(separator: " ") }
}

extension StreamDestination: DocumentEntity {
    public static var documentKind: DocumentKind { .streamDestination }

    public var indexText: String { [linkedTargetName ?? "", url].joined(separator: " ") }
}

extension ActionCombo: DocumentEntity {
    public static var documentKind: DocumentKind { .actionCombo }
}

extension ScheduleTrigger: DocumentEntity {
    public static var documentKind: DocumentKind { .scheduleTrigger }
    public var indexText: String { notes ?? "" }
}

extension SchedulerBoard: DocumentEntity {
    public static var documentKind: DocumentKind { .schedulerBoard }

    public var name: String { "Scheduler Board" }
}

public extension SchedulerBoard {

    static let wellKnownID = "scheduler-board"
}

extension ControlBoard: DocumentEntity {
    public static var documentKind: DocumentKind { .controlBoard }

    public var name: String { "Control Board" }
}

public extension ControlBoard {

    static let comboBoardID = "combo-board"
    static let alertBoardID = "alert-board"
    static let streamBoardID = "stream-board"
}

extension GroupPalette: DocumentEntity {
    public static var documentKind: DocumentKind { .groupPalette }

    public var name: String { "Group Palette" }
}

public extension GroupPalette {

    static let wellKnownID = "group-palette"
}

extension ImportLedger: DocumentEntity {
    public static var documentKind: DocumentKind { .importLedger }

    public var name: String { "Import Ledger" }
}

public extension ImportLedger {

    static let wellKnownID = "import-ledger"
}

extension ServiceLinkRules: DocumentEntity {
    public static var documentKind: DocumentKind { .serviceLinkRules }

    public var name: String { "Service Link Rules" }
}

public extension ServiceLinkRules {

    static let wellKnownID = "service-link-rules"

    static let teamID = "service-link-rules-team"
}

extension EffectPresetBoard: DocumentEntity {
    public static var documentKind: DocumentKind { .effectPresetBoard }

    public var name: String { "Effect Presets" }
}

public extension EffectPresetBoard {

    static let wellKnownID = "effect-presets"
}

extension AnimationPresetBoard: DocumentEntity {
    public static var documentKind: DocumentKind { .animationPresetBoard }

    public var name: String { "Animation Presets" }
}

public extension AnimationPresetBoard {

    static let wellKnownID = "animation-preset-board"
}

extension MIDIDevice: DocumentEntity {
    public static var documentKind: DocumentKind { .midiDevice }
}

extension SignageBoard: DocumentEntity {
    public static var documentKind: DocumentKind { .signageBoard }

    public var name: String { "Digital Signage" }
}

public extension SignageBoard {

    static let wellKnownID = "signage-board"
}

extension ConfidenceLayout: DocumentEntity {
    public static var documentKind: DocumentKind { .confidenceLayout }

    public var indexSubkind: String { folder ?? "" }
    public var indexText: String {
        objects.map(\.text).filter { !$0.isEmpty }.joined(separator: " ")
    }
}

extension NoteDocument: DocumentEntity {
    public static var documentKind: DocumentKind { .note }

    public var indexSubkind: String { folder ?? "" }

    public var indexText: String { body?.plainText ?? "" }
}

extension StationSettings: DocumentEntity {
    public static var documentKind: DocumentKind { .stationSettings }

    public var name: String { "Station Settings" }
}

public extension StationSettings {

    static let wellKnownID = "station-settings"
}

extension SlideBuildingSettings: DocumentEntity {
    public static var documentKind: DocumentKind { .slideBuildingSettings }

    public var name: String { "Slide Building Settings" }
}

extension WorkspaceSettings: DocumentEntity {
    public static var documentKind: DocumentKind { .workspaceSettings }

    public var name: String { "Workspace Settings" }
}

public extension WorkspaceSettings {

    static let wellKnownID = "workspace-settings"
}

extension FontFile: DocumentEntity {
    public static var documentKind: DocumentKind { .font }

    public var name: String { family }
}

public extension SlideBuildingSettings {

    static let wellKnownID = "slide-building-settings"
}

extension MediaItem: DocumentEntity {
    public static var documentKind: DocumentKind { .media }

    public var indexSubkind: String { folder ?? "" }
    public var indexText: String { fileName }
}

extension AudioItem: DocumentEntity {
    public static var documentKind: DocumentKind { .audio }

    public var indexSubkind: String { folder ?? "" }
    public var indexText: String { fileName }
}

extension Playlist: DocumentEntity {
    public static var documentKind: DocumentKind { .playlist }

    public var indexSubkind: String { effectiveKind.rawValue }
}

public extension Playlist {

    var effectiveKind: PlaylistKind {
        if let playlistKind { return playlistKind }
        switch entries.first?.refKind {
        case .media: return .media
        case .audio, .none: return .audio
        }
    }
}
