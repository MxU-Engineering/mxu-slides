import CoreMIDI
import PresenterCore
import RenderEngine
import SlideScene
import SwiftUI

@MainActor
final class ActionRouter {
    private unowned let model: AppModel
    private unowned let controls: ServiceControls
    private unowned let presets: OutputPresetsController

    private static let maxDepth = 4

    private var presentationFireDepth = 0

    init(
        model: AppModel, controls: ServiceControls, presets: OutputPresetsController,
        confidenceMonitor: ConfidenceMonitorController? = nil,
        signage: SignageController? = nil
    ) {
        self.model = model
        self.controls = controls
        self.presets = presets
        self.confidenceMonitor = confidenceMonitor
        self.signage = signage
    }

    private let confidenceMonitor: ConfidenceMonitorController?

    private let signage: SignageController?

    var timerChoices: [(id: String, name: String)] {
        controls.timers.timers.map { ($0.id, $0.name) }
    }

    var confidenceScreenChoices: [(id: String, name: String)] {
        (confidenceMonitor?.confidenceScreens ?? []).map { ($0.id.uuidString, $0.name) }
    }

    func applyPresetSwitches(for slide: Slide, contextID: String?) {
        guard let presetID = resolvedPresetID(for: slide, contextID: contextID),
              presets.activePresetID != presetID
        else { return }
        presets.activate(presetID)
    }

    func slideDidFire(_ slide: Slide, contextID: String?) {
        guard let actions = slide.actions, !actions.isEmpty else { return }
        let protected = SlideSceneBuilder.protectedLayers(for: slide, mediaLayer: mediaLayer)
        let effective = SlideSceneBuilder.fireActions(for: slide, protected: protected)
        if effective.count < actions.count {
            DiagnosticsStore.shared.note(
                "actions.clear.skippedOwnLayer", detail: slide.name)
        }
        guard !effective.isEmpty else { return }
        execute(
            effective, depth: 0, visited: [], skippingPresetSwitches: true,
            protected: protected)
    }

    private func mediaLayer(_ mediaID: String) -> LayerKind? {
        model.media(mediaID).map { SlideSceneBuilder.layerKind(CueMedia.dropped(for: $0).layer) }
    }

    func applyPresetSwitches(forMedia item: MediaItem, contextID: String?) {
        guard let presetID = resolvedPresetID(actions: item.actions, contextID: contextID),
              presets.activePresetID != presetID
        else { return }
        presets.activate(presetID)
    }

    func mediaDidFire(_ item: MediaItem, on layer: LayerKind) {
        guard let actions = item.actions, !actions.isEmpty else { return }
        let effective = SlideSceneBuilder.fireActions(forMedia: item, on: layer)
        if effective.count < actions.count {
            DiagnosticsStore.shared.note(
                "actions.clear.skippedOwnLayer", detail: item.name)
        }
        guard !effective.isEmpty else { return }
        execute(
            effective, depth: 0, visited: [], skippingPresetSwitches: true,
            protected: [layer])
    }

    private func resolvedPresetID(for slide: Slide, contextID: String?) -> String? {
        resolvedPresetID(actions: slide.actions, contextID: contextID)
    }

    private func resolvedPresetID(actions: [SlideAction]?, contextID: String?) -> String? {
        var result = itemPresetID(contextID: contextID)
        func scan(_ actions: [SlideAction], depth: Int, visited: Set<String>) {

            for action in actions where !SlideSceneBuilder.waitsBeforeFiring(action) {
                switch action.kind {
                case .switchOutputPreset:
                    if let id = action.presetId, !id.isEmpty, presets.preset(id) != nil {
                        result = id
                    }
                case .fireCombo:
                    guard let comboID = action.comboId,
                          depth < Self.maxDepth, !visited.contains(comboID),
                          let combo = try? model.actionCombo(comboID)
                    else { continue }
                    scan(combo.actions, depth: depth + 1, visited: visited.union([comboID]))
                default:
                    break
                }
            }
        }
        scan(actions ?? [], depth: 0, visited: [])
        return result
    }

    private var chipRoutingCache: [String: (listVersion: Int, presetsVersion: Int, fills: Int, declared: String?)] = [:]

    private var chipLooksCache: [String: (presetsVersion: Int, looks: [OutputPresetsController.SlideThemeLook])] = [:]

    struct OverrideLook: Identifiable {
        var id: String
        var targetIds: [String]
        var theme: Theme
        var folder: String?
    }

    func activeOverrideLooks() -> [OverrideLook] {
        guard let presetID = presets.activePresetID else { return [] }
        return overrideLooks(forPreset: presetID)
    }

    func declaredPresetID(actions: [SlideAction]?) -> String? {
        resolvedPresetID(actions: actions, contextID: nil)
    }

    func overrideLooks(forPreset presetID: String) -> [OverrideLook] {
        guard let preset = presets.preset(presetID) else { return [] }
        var looks: [OverrideLook] = []
        for assignment in preset.assignments {
            guard let themeID = assignment.slideThemeId, !themeID.isEmpty else { continue }
            let key = OutputPresetsController.lookKey(
                themeID: themeID, folder: assignment.slideThemeFolder, slideID: assignment.slideThemeSlideId)
            if let index = looks.firstIndex(where: { $0.id == key }) {
                looks[index].targetIds.append(assignment.targetId)
                continue
            }
            guard let theme = model.theme(themeID) else { continue }
            looks.append(OverrideLook(
                id: key, targetIds: [assignment.targetId],
                theme: theme.scoped(toSlideFolder: assignment.slideThemeFolder).scoped(toSlideID: assignment.slideThemeSlideId),
                folder: (assignment.slideThemeFolder?.isEmpty ?? true) ? nil : assignment.slideThemeFolder))
        }
        return looks
    }

    func predictedOverrideThemes(for slide: Slide, contextID: String?) -> [Theme] {
        guard let presetID = predictedPresetID(for: slide, contextID: contextID) else { return [] }
        return overrideThemes(forPreset: presetID)
    }

    func predictedOverrideLooks(for slide: Slide, contextID: String?) -> [OverrideLook] {
        guard let presetID = predictedPresetID(for: slide, contextID: contextID) else { return [] }
        return overrideLooks(forPreset: presetID)
    }

    private func predictedPresetID(for slide: Slide, contextID: String?) -> String? {
        let key = slide.id + "|" + (contextID ?? "")
        let fills = model.fillVersion(of: .actionCombo) + model.fillVersion(of: .service)
        let declared: String?
        if let hit = chipRoutingCache[key],
           hit.listVersion == model.listVersion, hit.presetsVersion == presets.version, hit.fills == fills {
            declared = hit.declared
        } else {
            declared = resolvedPresetID(for: slide, contextID: contextID)
            chipRoutingCache[key] = (model.listVersion, presets.version, fills, declared)
        }
        return declared ?? presets.activePresetID
    }

    func overrideThemes(forPreset presetID: String) -> [Theme] {
        let looks: [OutputPresetsController.SlideThemeLook]
        if let hit = chipLooksCache[presetID], hit.presetsVersion == presets.version {
            looks = hit.looks
        } else {
            looks = presets.slideThemeLooks(presetID)
            chipLooksCache[presetID] = (presets.version, looks)
        }
        return looks.compactMap {
            model.theme($0.themeID)?
                .scoped(toSlideFolder: $0.folder)
                .scoped(toSlideID: $0.slideID)
        }
    }

    func fire(comboID: String) {
        guard let combo = try? model.actionCombo(comboID) else {
            DiagnosticsStore.shared.note("actions.combo.missing", detail: comboID)
            return
        }
        model.markUsed(comboID)
        execute(combo.actions, depth: 1, visited: [comboID])
    }

    func execute(_ actions: [SlideAction]) {
        execute(actions, depth: 0, visited: [])
    }

    private var startupRan = false

    func runStartupCombos() async {
        guard !startupRan else { return }
        startupRan = true
        try? await Task.sleep(for: .seconds(2))

        await model.resident.ready([.actionCombo])
        let startup = model.resident.actionCombos.values
            .filter { $0.runOnStartup == true }
            .sorted { ($0.name, $0.id) < ($1.name, $1.id) }
        for combo in startup {
            DiagnosticsStore.shared.note("actions.startup", detail: combo.name)
            execute(combo.actions, depth: 1, visited: [combo.id])
        }
    }

    private func itemPresetID(contextID: String?) -> String? {
        guard let contextID,
              let serviceID = model.currentServiceID,
              let service = try? model.service(serviceID),
              let item = service.items.first(where: { $0.id == contextID }),
              let presetID = item.outputPresetId, !presetID.isEmpty
        else { return nil }
        return presetID
    }

    private func execute(
        _ actions: [SlideAction], depth: Int, visited: Set<String>,
        skippingPresetSwitches: Bool = false, protected: Set<LayerKind> = []
    ) {
        let schedule = SlideSceneBuilder.delaySchedule(actions)
        for action in schedule.immediate {
            perform(
                action, depth: depth, visited: visited,
                skippingPresetSwitches: skippingPresetSwitches, protected: protected)
        }
        for batch in schedule.delayed {
            scheduleDelayed(
                batch.actions, after: batch.delay, depth: depth, visited: visited)
        }
    }

    private var pendingDelayed: [Int: Task<Void, Never>] = [:]
    private var pendingTokensByActionID: [String: Int] = [:]
    private var nextDelayToken = 0

    private func scheduleDelayed(
        _ batch: [SlideAction], after delay: Double, depth: Int, visited: Set<String>
    ) {
        for action in batch {
            if let token = pendingTokensByActionID[action.id] {
                pendingDelayed[token]?.cancel()
                pendingDelayed[token] = nil
            }
        }
        nextDelayToken += 1
        let token = nextDelayToken
        for action in batch { pendingTokensByActionID[action.id] = token }

        let ripe = batch.map { action in
            var step = action
            step.delaySeconds = nil
            return step
        }
        DiagnosticsStore.shared.note(
            "actions.delayed.scheduled",
            detail: "\(batch.count) step(s) in \(delay)s")
        pendingDelayed[token] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.forgetDelayed(token: token)
            DiagnosticsStore.shared.note(
                "actions.delayed.fired",
                detail: ripe.map(\.kind.rawValue).joined(separator: ","))
            self.execute(ripe, depth: depth, visited: visited)
        }
    }

    private func forgetDelayed(token: Int) {
        pendingDelayed[token] = nil
        for (id, entry) in pendingTokensByActionID where entry == token {
            pendingTokensByActionID[id] = nil
        }
    }

    func cancelPendingDelayedActions() {
        guard !pendingDelayed.isEmpty else { return }
        DiagnosticsStore.shared.note(
            "actions.delayed.cancelled", detail: "\(pendingDelayed.count) batch(es)")
        for task in pendingDelayed.values { task.cancel() }
        pendingDelayed = [:]
        pendingTokensByActionID = [:]
    }

    private func perform(
        _ action: SlideAction, depth: Int, visited: Set<String>,
        skippingPresetSwitches: Bool = false, protected: Set<LayerKind> = []
    ) {
        performNow(action, depth: depth, visited: visited, skippingPresetSwitches: skippingPresetSwitches, protected: protected)
    }

    private func performNow(
        _ action: SlideAction, depth: Int, visited: Set<String>,
        skippingPresetSwitches: Bool, protected: Set<LayerKind>
    ) {
        switch action.kind {
        case .clearLayer:
            guard let layer = action.layer.flatMap(LayerKind.init(rawValue:)) else {
                return miss(action, "layer")
            }

            if protected.contains(layer) {
                DiagnosticsStore.shared.note(
                    "actions.clear.skippedOwnLayer", detail: layer.rawValue)
                return
            }
            controls.clear(layer: layer)
        case .clearAll:
            if !protected.isEmpty {
                DiagnosticsStore.shared.note(
                    "actions.clear.allScoped",
                    detail: protected.map(\.rawValue).sorted().joined(separator: ","))
            }
            controls.clearAll(protecting: protected, cancelsPendingActions: false)
        case .clearAudio:
            controls.clear(function: .audio)
        case .clearSignage:
            controls.clear(function: .signage)
        case .switchOutputPreset:

            guard !skippingPresetSwitches else { return }
            guard let presetID = action.presetId, !presetID.isEmpty,
                  presets.preset(presetID) != nil
            else {
                return miss(action, "presetId")
            }

            if presets.activePresetID != presetID {
                controls.switchPreset(incomingOverrides: overrideThemes(forPreset: presetID)) { [weak self] in
                    self?.presets.activate(presetID)
                }
            }
        case .fireMedia:
            guard let mediaID = action.mediaId,
                  let item = model.media(mediaID)
            else { return miss(action, "mediaId") }
            controls.fire(mediaItem: item)
        case .fireAlert:
            guard let alertID = action.alertId,
                  let preset = try? model.alertPreset(alertID)
            else { return miss(action, "alertId") }
            controls.fire(alertPreset: preset)
        case .dismissAlert:
            controls.dismissAlert()
        case .timerStart:
            guard let timerID = action.timerId else { return miss(action, "timerId") }
            controls.timers.start(id: timerID)
        case .timerPause:
            guard let timerID = action.timerId else { return miss(action, "timerId") }
            controls.timers.pause(id: timerID)
        case .timerReset:
            guard let timerID = action.timerId else { return miss(action, "timerId") }
            controls.timers.reset(id: timerID)
        case .timerConfigure:
            guard let timerID = action.timerId else { return miss(action, "timerId") }
            controls.timers.configure(
                id: timerID,
                mode: action.timerMode.map { mode in
                    switch mode {
                    case .countdown: .countdown
                    case .countdownToTime: .countdownToTime
                    case .countUp: .countUp
                    }
                },
                durationSeconds: action.timerDurationSeconds,
                hour: action.timerHour, minute: action.timerMinute
            )
        case .midiOut:
            switch MIDIOutTarget.resolve(
                deviceId: action.midiDeviceId, items: MIDIDeviceInventory.shared.items
            ) {
            case .settingsSelection:
                MIDIOutService.shared.send(
                    kind: action.midiKind ?? .noteOn,
                    channel: action.midiChannel ?? 1,
                    number: action.midiNumber ?? 0,
                    value: action.midiValue ?? 127
                )
            case .device(let uid):
                MIDIOutService.shared.send(
                    kind: action.midiKind ?? .noteOn,
                    channel: action.midiChannel ?? 1,
                    number: action.midiNumber ?? 0,
                    value: action.midiValue ?? 127,
                    toDestination: uid
                )
            case .skip(let reason):
                DiagnosticsStore.shared.note(
                    "actions.skipped", detail: "midiOut \(reason)")
            }
        case .fireCombo:
            guard let comboID = action.comboId, !comboID.isEmpty else {
                return miss(action, "comboId")
            }
            guard depth < Self.maxDepth, !visited.contains(comboID) else {
                DiagnosticsStore.shared.note(
                    "actions.combo.cycle", detail: "\(comboID) depth=\(depth)")
                return
            }
            guard let combo = try? model.actionCombo(comboID) else {
                return miss(action, "comboId")
            }
            execute(
                combo.actions, depth: depth + 1, visited: visited.union([comboID]),
                skippingPresetSwitches: skippingPresetSwitches, protected: protected)
        case .captureStart:
            guard let presetID = action.capturePresetId, !presetID.isEmpty,
                  (try? model.streamPreset(presetID)) != nil
            else { return miss(action, "capturePresetId") }

            controls.startCapture(presetID: presetID)
        case .captureStop:
            if let presetID = action.capturePresetId, !presetID.isEmpty {
                controls.endAll(presetID: presetID)
            } else {
                controls.endAllCapture()
            }
        case .firePresentation:
            guard let presentationID = action.presentationId else {
                return miss(action, "presentationId")
            }

            guard let presentation = model.presentation(presentationID) else {
                return miss(action, model.presentationExists(presentationID)
                    ? "presentation still decoding" : "presentationId")
            }
            let slides = SlideSceneBuilder.arrangedSlides(
                for: presentation, arrangementId: nil)
            let index = action.slideIndex ?? 0
            guard slides.indices.contains(index) else {
                return miss(action, "slideIndex")
            }
            guard presentationFireDepth < Self.maxDepth else {
                DiagnosticsStore.shared.note(
                    "actions.presentation.cycle",
                    detail: "\(presentationID) depth=\(presentationFireDepth)")
                return
            }
            presentationFireDepth += 1
            defer { presentationFireDepth -= 1 }
            controls.fire(slide: slides[index], in: presentation)
        case .setConfidenceLayout:
            guard let confidenceMonitor else { return miss(action, "confidenceMonitor") }

            confidenceMonitor.apply(
                layoutID: action.confidenceLayoutId,
                toScreen: action.confidenceScreenId.flatMap(UUID.init(uuidString:))
            )
        case .fireOverlay:
            guard let overlayID = action.overlayId,
                  let overlay = model.overlay(overlayID)
            else { return miss(action, "overlayId") }
            controls.fire(overlay: overlay)
        case .dismissOverlay:
            if let overlayID = action.overlayId, !overlayID.isEmpty {
                controls.dismissOverlay(id: overlayID)
            } else {
                controls.dismissAllOverlays()
            }
        case .fireLiveInput:
            let layer = action.layer.flatMap(LayerKind.init(rawValue:)) ?? .videoInput
            if let itemID = action.liveInputId, !itemID.isEmpty {

                controls.fire(liveInputId: itemID, on: layer)
            } else if let sourceID = action.inputSourceId, !sourceID.isEmpty {

                controls.fire(
                    liveInputKind: action.inputSourceKind ?? .camera,
                    sourceId: sourceID,
                    on: layer
                )
            } else {
                return miss(action, "liveInputId")
            }
        case .enableAudioInput, .disableAudioInput:

            guard let inputID = action.audioInputId, !inputID.isEmpty else {
                return miss(action, "audioInputId")
            }
            if action.kind == .enableAudioInput {
                controls.mixer.enableInput(id: inputID)
            } else {
                controls.mixer.disableInput(id: inputID)
            }
        case .setSignage:
            guard let signage else { return miss(action, "signage") }
            guard let channelID = action.signageId, !channelID.isEmpty else {
                return miss(action, "signageId")
            }

            signage.assign(playlistID: action.playlistId, toSignage: channelID)
        case .setScreenSource:
            guard let signage else { return miss(action, "signage") }
            guard let raw = action.screenId, let screenID = UUID(uuidString: raw) else {
                return miss(action, "screenId")
            }

            signage.setSource(action.signageId, forScreen: screenID)
        case .fireAudio:

            guard let itemID = action.audioItemId, !itemID.isEmpty,
                  let item = model.audio(itemID)
            else { return miss(action, "audioItemId") }
            controls.fire(audioItem: item, repeatOverride: action.audioRepeat)
        case .fireAudioPlaylist:

            guard let playlistID = action.playlistId, !playlistID.isEmpty,
                  let playlist = try? model.playlist(playlistID),
                  playlist.effectiveKind == .audio
            else { return miss(action, "playlistId") }

            controls.fire(
                playlist: playlist, startAt: action.audioEntryId,
                repeatOverride: action.audioRepeat
            )
        }
    }

    private func miss(_ action: SlideAction, _ field: String) {
        DiagnosticsStore.shared.note(
            "actions.skipped", detail: "\(action.kind.rawValue) missing \(field)")
    }
}

final class MIDIOutService: @unchecked Sendable {
    static let shared = MIDIOutService()

    private var client = MIDIClientRef()
    private var port = MIDIPortRef()
    private var ready = false

    private var targetUIDs: Set<Int32>?
    private var targetsLoaded = false
    private let lock = NSLock()

    private init() {}

    func setTargets(_ uids: Set<Int32>?) {
        lock.lock()
        targetUIDs = uids
        targetsLoaded = true
        lock.unlock()
    }

    func send(
        kind: MIDIMessageKind, channel: Int, number: Int, value: Int,
        toDestination explicitUID: Int32? = nil
    ) {
        lock.lock()
        defer { lock.unlock() }
        if !ready {
            guard MIDIClientCreate("MxU Slides" as CFString, nil, nil, &client) == noErr,
                  MIDIOutputPortCreate(client, "MxU Slides Out" as CFString, &port) == noErr
            else { return }
            ready = true
        }
        if !targetsLoaded {

            targetUIDs = MIDIDeviceStore.loadCachedTargets()
            targetsLoaded = true
        }
        if explicitUID == nil, let targets = targetUIDs, targets.isEmpty { return }
        let status: UInt8 = (kind == .controlChange ? 0xB0 : 0x90)
            | UInt8((max(1, min(16, channel)) - 1) & 0x0F)
        let data: [UInt8] = [status, UInt8(number & 0x7F), UInt8(value & 0x7F)]
        var packetList = MIDIPacketList()
        let packet = MIDIPacketListInit(&packetList)
        _ = MIDIPacketListAdd(
            &packetList, MemoryLayout<MIDIPacketList>.size, packet, 0, data.count, data)
        for index in 0..<MIDIGetNumberOfDestinations() {
            let destination = MIDIGetDestination(index)
            if explicitUID != nil || targetUIDs != nil {
                var uid: Int32 = 0
                guard MIDIObjectGetIntegerProperty(
                    destination, kMIDIPropertyUniqueID, &uid) == noErr
                else { continue }
                if let explicitUID {
                    guard uid == explicitUID else { continue }
                } else if let targets = targetUIDs {
                    guard targets.contains(uid) else { continue }
                }
            }
            MIDISend(port, destination, &packetList)
        }
    }
}

private struct ActionRouterKey: EnvironmentKey {
    static let defaultValue: ActionRouter? = nil
}

extension EnvironmentValues {
    var actionRouter: ActionRouter? {
        get { self[ActionRouterKey.self] }
        set { self[ActionRouterKey.self] = newValue }
    }
}
