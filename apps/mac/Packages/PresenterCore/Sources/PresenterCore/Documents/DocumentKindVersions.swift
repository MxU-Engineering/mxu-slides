import Observation

@Observable
public final class DocumentKindVersions {
    private var presentation = 0
    private var service = 0
    private var theme = 0
    private var media = 0
    private var audio = 0
    private var playlist = 0
    private var overlay = 0
    private var outputPreset = 0
    private var alertPreset = 0
    private var streamRecordPreset = 0
    private var actionCombo = 0
    private var scheduleTrigger = 0
    private var schedulerBoard = 0
    private var controlBoard = 0
    private var confidenceLayout = 0
    private var groupPalette = 0
    private var signageBoard = 0
    private var effectPresetBoard = 0
    private var animationPresetBoard = 0
    private var midiDevice = 0
    private var streamDestination = 0
    private var importLedger = 0
    private var serviceLinkRules = 0
    private var note = 0
    private var stationSettings = 0
    private var slideBuildingSettings = 0
    private var font = 0
    private var workspaceSettings = 0

    @ObservationIgnored private var unobserved: [DocumentKind: Int] = [:]

    public init() {}

    public func untracked(_ kind: DocumentKind) -> Int {
        unobserved[kind, default: 0]
    }

    public subscript(kind: DocumentKind) -> Int {
        switch kind {
        case .presentation: presentation
        case .service: service
        case .theme: theme
        case .media: media
        case .audio: audio
        case .playlist: playlist
        case .overlay: overlay
        case .outputPreset: outputPreset
        case .alertPreset: alertPreset
        case .streamRecordPreset: streamRecordPreset
        case .actionCombo: actionCombo
        case .scheduleTrigger: scheduleTrigger
        case .schedulerBoard: schedulerBoard
        case .controlBoard: controlBoard
        case .confidenceLayout: confidenceLayout
        case .groupPalette: groupPalette
        case .signageBoard: signageBoard
        case .effectPresetBoard: effectPresetBoard
        case .animationPresetBoard: animationPresetBoard
        case .midiDevice: midiDevice
        case .streamDestination: streamDestination
        case .importLedger: importLedger
        case .serviceLinkRules: serviceLinkRules
        case .note: note
        case .stationSettings: stationSettings
        case .slideBuildingSettings: slideBuildingSettings
        case .font: font
        case .workspaceSettings: workspaceSettings
        }
    }

    public func bump(_ kind: DocumentKind) {
        unobserved[kind, default: 0] += 1
        switch kind {
        case .presentation: presentation += 1
        case .service: service += 1
        case .theme: theme += 1
        case .media: media += 1
        case .audio: audio += 1
        case .playlist: playlist += 1
        case .overlay: overlay += 1
        case .outputPreset: outputPreset += 1
        case .alertPreset: alertPreset += 1
        case .streamRecordPreset: streamRecordPreset += 1
        case .actionCombo: actionCombo += 1
        case .scheduleTrigger: scheduleTrigger += 1
        case .schedulerBoard: schedulerBoard += 1
        case .controlBoard: controlBoard += 1
        case .confidenceLayout: confidenceLayout += 1
        case .groupPalette: groupPalette += 1
        case .signageBoard: signageBoard += 1
        case .effectPresetBoard: effectPresetBoard += 1
        case .animationPresetBoard: animationPresetBoard += 1
        case .midiDevice: midiDevice += 1
        case .streamDestination: streamDestination += 1
        case .importLedger: importLedger += 1
        case .serviceLinkRules: serviceLinkRules += 1
        case .note: note += 1
        case .stationSettings: stationSettings += 1
        case .slideBuildingSettings: slideBuildingSettings += 1
        case .font: font += 1
        case .workspaceSettings: workspaceSettings += 1
        }
    }

    public func bumpAll() {
        for kind in DocumentKind.allCases { bump(kind) }
    }
}
