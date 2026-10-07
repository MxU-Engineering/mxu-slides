import Foundation
import Observation
import OutputEngine
import PresenterCore
import RenderEngine

@MainActor
@Observable
final class OutputPresetsController {
    private let appModel: AppModel
    private let outputs: OutputManager

    private weak var controls: ServiceControls?

    private(set) var version = 0
    private(set) var activePresetID: String?

    private var applyRetryTask: Task<Void, Never>?

    static let activeKey = "activeOutputPresetID"

    static let broadcastFeedLayers: [String] = [
        LayerKind.slide.rawValue, LayerKind.overlays.rawValue,
    ]

    init(appModel: AppModel, outputs: OutputManager, controls: ServiceControls? = nil) {
        self.appModel = appModel
        self.outputs = outputs
        self.controls = controls
        activePresetID = UserDefaults.standard.string(forKey: Self.activeKey)
        applyActivePreset()
        armThemeMutationWatch()
    }

    private func armThemeMutationWatch() {
        withObservationTracking {
            _ = appModel.version(of: .theme)
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.applyActivePreset()
                self.armThemeMutationWatch()
            }
        }
    }

    var presets: [LibraryIndex.Entry] {
        _ = version

        _ = appModel.listVersion
        _ = appModel.version(of: .outputPreset)
        return appModel.entries(of: .outputPreset)
    }

    var themes: [LibraryIndex.Entry] {
        _ = appModel.version(of: .theme)
        return appModel.entries(of: .theme)
    }

    func preset(_ id: String) -> OutputPreset? {
        appModel.resident.outputPresets.value(id)
    }

    struct SlideThemeLook: Hashable {
        var themeID: String
        var folder: String?
        var slideID: String?
    }

    func slideThemeLooks(_ presetID: String) -> [SlideThemeLook] {
        guard let preset = preset(presetID) else { return [] }
        var looks: [SlideThemeLook] = []
        var seen: Set<SlideThemeLook> = []
        for assignment in preset.assignments {
            guard let themeID = assignment.slideThemeId, !themeID.isEmpty else { continue }
            func blank(_ value: String?) -> String? { (value?.isEmpty ?? true) ? nil : value }
            let look = SlideThemeLook(
                themeID: themeID,
                folder: blank(assignment.slideThemeFolder),
                slideID: blank(assignment.slideThemeSlideId)
            )
            guard seen.insert(look).inserted else { continue }
            looks.append(look)
        }
        return looks
    }

    func activate(_ id: String?) {
        activePresetID = id
        UserDefaults.standard.set(id, forKey: Self.activeKey)
        applyActivePreset()
    }

    func applyActivePreset() {
        applyRetryTask?.cancel()
        applyRetryTask = nil
        let table = appModel.resident.outputPresets
        if let id = activePresetID, let preset = preset(id) {
            let waiting = Self.slideThemeIDs(of: preset).filter { themeID in
                if case .afterFill = appModel.resident.themes.fireRead(themeID) { true } else { false }
            }
            if waiting.isEmpty {
                route(preset)
            } else {
                DiagnosticsStore.shared.note("presets.routing", detail: "active preset's themes wait for the library")
                applyRetryTask = Task { @MainActor [weak self] in
                    await self?.appModel.themesFilled(waiting)
                    if let self, !Task.isCancelled, let preset = self.preset(id) {
                        self.route(preset)
                    }
                }
            }
        } else if activePresetID != nil, !table.isCovered {
            DiagnosticsStore.shared.note("presets.routing", detail: "active preset waits for the library to open")
            applyRetryTask = Task { @MainActor [weak self] in
                await table.ready()
                if !Task.isCancelled {
                    self?.applyActivePreset()
                }
            }
        } else {
            if let id = activePresetID {
                DiagnosticsStore.shared.note("presets.routing", detail: "active preset \(id) is not in the library — every layer routes")
            }
            outputs.setLayerRouting([:])
            outputs.setSlideThemeRouting([:])
            controls?.setSlideThemeOverrides([:])
            applyMaskActivation(nil)
        }
    }

    private static func slideThemeIDs(of preset: OutputPreset) -> [String] {
        preset.assignments.compactMap(\.slideThemeId).filter { !$0.isEmpty }
    }

    private func route(_ preset: OutputPreset) {
        var routing: [String: Set<String>] = [:]
        for assignment in preset.assignments {
            routing[assignment.targetId] = Set(assignment.enabledLayers)
        }
        outputs.setLayerRouting(routing)

        var themeRouting: [String: String] = [:]
        var overrides: [String: Theme] = [:]
        for assignment in preset.assignments {
            guard let themeID = assignment.slideThemeId, !themeID.isEmpty else { continue }
            let key = Self.lookKey(
                themeID: themeID, folder: assignment.slideThemeFolder,
                slideID: assignment.slideThemeSlideId
            )
            if overrides[key] == nil {

                guard let theme = appModel.theme(themeID) else {
                    DiagnosticsStore.shared.note(
                        "presets.slideTheme.missing", detail: themeID)
                    continue
                }
                if let folder = assignment.slideThemeFolder, !folder.isEmpty,
                   !theme.hasSlideFolder(folder) {
                    DiagnosticsStore.shared.note(
                        "presets.slideTheme.folderMissing", detail: "\(themeID) › \(folder)")
                }
                if let slideID = assignment.slideThemeSlideId, !slideID.isEmpty,
                   !theme.hasSlide(id: slideID) {
                    DiagnosticsStore.shared.note(
                        "presets.slideTheme.slideMissing", detail: "\(themeID) › \(slideID)")
                }

                overrides[key] = theme
                    .scoped(toSlideFolder: assignment.slideThemeFolder)
                    .scoped(toSlideID: assignment.slideThemeSlideId)
            }
            themeRouting[assignment.targetId] = key
        }
        outputs.setSlideThemeRouting(themeRouting)
        controls?.setSlideThemeOverrides(overrides)
        applyMaskActivation(preset)
    }

    static func lookKey(themeID: String, folder: String?, slideID: String?) -> String {
        var key = themeID
        if let folder, !folder.isEmpty { key += "#\(folder)" }
        if let slideID, !slideID.isEmpty { key += "##\(slideID)" }
        return key
    }

    private func applyMaskActivation(_ preset: OutputPreset?) {
        var activated: [UUID: Set<UUID>] = [:]
        if let preset {
            for assignment in preset.assignments {
                guard let ids = assignment.maskIds, !ids.isEmpty,
                      let screenID = UUID(uuidString: assignment.targetId)
                else { continue }
                activated[screenID, default: []]
                    .formUnion(ids.compactMap(UUID.init(uuidString:)))
            }
        }
        for screen in outputs.placeholderScreens {
            outputs.setActiveMaskIDs(activated[screen.id] ?? [], forScreen: screen.id)
        }
    }

    @discardableResult
    func createPreset(fromBroadcastTemplate: Bool) -> String? {
        let id = UUID().uuidString
        var assignments: [OutputAssignment] = []
        if fromBroadcastTemplate {
            for display in outputs.displays {
                assignments.append(OutputAssignment(
                    targetKind: .display, targetId: display.uuid,
                    enabledLayers: Self.broadcastFeedLayers
                ))
            }
            for screen in outputs.placeholderScreens {
                assignments.append(OutputAssignment(
                    targetKind: .placeholderScreen, targetId: screen.id.uuidString,
                    enabledLayers: Self.broadcastFeedLayers
                ))
            }
        }
        let preset = OutputPreset(
            id: id,
            name: fromBroadcastTemplate ? "Broadcast Feed" : "Untitled Preset",
            assignments: assignments
        )
        appModel.client.create(preset)
        version += 1
        return id
    }

    @discardableResult
    private func write(_ id: String, _ mutate: @escaping @Sendable (inout OutputPreset) -> Void) -> Bool {
        if preset(id) != nil {
            appModel.client.modify(OutputPreset.self, id: id, mutate)
            version += 1
            return true
        } else {
            return false
        }
    }

    @discardableResult
    func duplicatePreset(_ id: String) -> String? {
        guard var value = preset(id)
        else { return nil }
        value.id = UUID().uuidString
        value.name += " Copy"
        appModel.client.create(value)
        version += 1
        return value.id
    }

    func deletePreset(_ id: String) {
        appModel.client.delete(kind: .outputPreset, id: id)
        if activePresetID == id { activate(nil) }
        version += 1
    }

    func renamePreset(_ id: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            write(id) { $0.name = trimmed }
        }
    }

    func enabledLayers(presetID: String, targetId: String) -> Set<String>? {
        guard let preset = preset(presetID),
              let assignment = preset.assignments.first(where: { $0.targetId == targetId })
        else { return nil }
        return Set(assignment.enabledLayers)
    }

    func toggleLayer(
        presetID: String, targetKind: OutputTargetKind, targetId: String, layer: String
    ) {
        guard write(presetID, { preset in
            var assignment = preset.assignments.first { $0.targetId == targetId }
                ?? OutputAssignment(
                    targetKind: targetKind, targetId: targetId,
                    enabledLayers: LayerKind.allCases.map(\.rawValue)
                )
            var layers = Set(assignment.enabledLayers)
            if layers.contains(layer) { layers.remove(layer) } else { layers.insert(layer) }

            assignment.enabledLayers = layers.sorted()
            preset.assignments.removeAll { $0.targetId == targetId }
            preset.assignments.append(assignment)
        }) else { return }
        if presetID == activePresetID { applyActivePreset() }
    }

    func slideThemeId(presetID: String, targetId: String) -> String? {
        guard let preset = preset(presetID),
              let assignment = preset.assignments.first(where: { $0.targetId == targetId }),
              let themeID = assignment.slideThemeId, !themeID.isEmpty
        else { return nil }
        return themeID
    }

    func setSlideTheme(
        presetID: String, targetKind: OutputTargetKind, targetId: String,
        themeId: String?, folder: String? = nil, slideId: String? = nil
    ) {
        guard write(presetID, { preset in
            var assignment = preset.assignments.first { $0.targetId == targetId }
                ?? OutputAssignment(
                    targetKind: targetKind, targetId: targetId,
                    enabledLayers: LayerKind.allCases.map(\.rawValue).sorted()
                )
            assignment.slideThemeId = (themeId?.isEmpty ?? true) ? nil : themeId

            func scoped(_ value: String?) -> String? {
                assignment.slideThemeId == nil ? nil : ((value?.isEmpty ?? true) ? nil : value)
            }
            assignment.slideThemeFolder = scoped(folder)
            assignment.slideThemeSlideId = scoped(slideId)
            preset.assignments.removeAll { $0.targetId == targetId }
            preset.assignments.append(assignment)
        }) else { return }
        if presetID == activePresetID { applyActivePreset() }
    }

    func slideThemeFolder(presetID: String, targetId: String) -> String? {
        guard let preset = preset(presetID),
              let assignment = preset.assignments.first(where: { $0.targetId == targetId }),
              let folder = assignment.slideThemeFolder, !folder.isEmpty
        else { return nil }
        return folder
    }

    func slideThemeSlideId(presetID: String, targetId: String) -> String? {
        guard let preset = preset(presetID),
              let assignment = preset.assignments.first(where: { $0.targetId == targetId }),
              let slideID = assignment.slideThemeSlideId, !slideID.isEmpty
        else { return nil }
        return slideID
    }

    func slideFolders(themeID: String) -> [String] {
        appModel.theme(themeID)?.slideFolders ?? []
    }

    func themeValue(_ themeID: String) -> Theme? {
        appModel.theme(themeID)
    }

    var model: AppModel { appModel }

    func maskIds(presetID: String, targetId: String) -> Set<UUID> {
        guard let preset = preset(presetID),
              let assignment = preset.assignments.first(where: { $0.targetId == targetId }),
              let ids = assignment.maskIds
        else { return [] }
        return Set(ids.compactMap(UUID.init(uuidString:)))
    }

    func toggleMask(
        presetID: String, targetKind: OutputTargetKind, targetId: String, maskId: UUID
    ) {
        guard write(presetID, { preset in
            var assignment = preset.assignments.first { $0.targetId == targetId }
                ?? OutputAssignment(
                    targetKind: targetKind, targetId: targetId,
                    enabledLayers: LayerKind.allCases.map(\.rawValue).sorted()
                )
            var ids = Set((assignment.maskIds ?? []).compactMap(UUID.init(uuidString:)))
            if ids.contains(maskId) { ids.remove(maskId) } else { ids.insert(maskId) }
            assignment.maskIds = ids.isEmpty ? nil : ids.map(\.uuidString).sorted()
            preset.assignments.removeAll { $0.targetId == targetId }
            preset.assignments.append(assignment)
        }) else { return }
        if presetID == activePresetID { applyActivePreset() }
    }

    func clearAssignment(presetID: String, targetId: String) {
        guard write(presetID, { $0.assignments.removeAll { $0.targetId == targetId } }) else { return }
        if presetID == activePresetID { applyActivePreset() }
    }
}
