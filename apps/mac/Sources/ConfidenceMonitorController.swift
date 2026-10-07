import Foundation
import Observation
import OutputEngine
import PresenterCore
import SlideScene
import SwiftUI

@MainActor
@Observable
final class ConfidenceMonitorController {
    static let assignmentsKey = "confidence.screenLayouts"

    private(set) var assignments: [UUID: String] = [:]

    private(set) var previewLayoutChoices: [PreviewTargetLogic.Choice] = []

    private(set) var previewAspects: [String: Double] = [:]

    private var previewCounts: [String: Int] = [:]

    private let appModel: AppModel
    private let render: RenderContext
    private weak var controls: ServiceControls?

    init(appModel: AppModel, render: RenderContext, controls: ServiceControls) {
        self.appModel = appModel
        self.render = render
        self.controls = controls
        restore()
        refresh()
        armMutationWatch()
    }

    var confidenceScreens: [(id: UUID, name: String)] {
        render.outputs.placeholderScreens
            .filter { render.outputs.role(forScreen: $0.id) == .confidence }
            .map { ($0.id, $0.name) }
    }

    func setLayout(_ layoutID: String?, forScreen id: UUID) {
        guard assignments[id] != layoutID else { return }
        if let layoutID, !layoutID.isEmpty {
            assignments[id] = layoutID
        } else {
            assignments.removeValue(forKey: id)
        }
        persist()
        refresh()
    }

    func apply(layoutID: String?, toScreen screenID: UUID?) {
        let resolved = (layoutID?.isEmpty ?? true) ? nil : layoutID
        if let resolved, appModel.indexEntry(resolved) == nil {
            DiagnosticsStore.shared.note("confidence.layout.missing", detail: resolved)
            return
        }
        if let screenID {
            setLayout(resolved, forScreen: screenID)
        } else {
            for screen in render.outputs.placeholderScreens
            where render.outputs.role(forScreen: screen.id) == .confidence {
                setLayout(resolved, forScreen: screen.id)
            }
        }
    }

    func beginPreview(layoutID: String) {
        previewCounts[layoutID, default: 0] += 1
        if previewCounts[layoutID] == 1 {
            refresh()
        }
    }

    func endPreview(layoutID: String) {
        if let count = previewCounts[layoutID] {
            previewCounts[layoutID] = count > 1 ? count - 1 : nil
            if count == 1 {
                refresh()
            }
        }
    }

    func refresh() {
        var layouts: [UUID: ConfidenceLayout] = [:]
        var pruned = false
        for (screenID, layoutID) in assignments {
            if let layout = appModel.resident.confidenceLayouts.value(layoutID) {
                layouts[screenID] = layout
            } else if appModel.client.isReady, appModel.indexEntry(layoutID) == nil {

                assignments.removeValue(forKey: screenID)
                pruned = true
            }
        }
        render.confidenceLayoutsBox.value = layouts
        var wants: [String: Bool?] = [:]
        for layout in layouts.values {
            wants.merge(SlideSceneBuilder.mediaWants(for: layout.objects)) { first, _ in first }
        }
        controls?.setConfidenceMediaWants(wants)
        if pruned { persist() }
        refreshPreviews()
    }

    private func refreshPreviews() {
        previewLayoutChoices = appModel.entries(of: .confidenceLayout)
            .map { .init(id: PreviewTargetLogic.layoutTarget($0.id), name: $0.name) }
        var previews: [String: ConfidenceLayout] = [:]
        for layoutID in previewCounts.keys {
            if let layout = appModel.resident.confidenceLayouts.value(layoutID) {
                previews[layoutID] = layout
            }
        }
        render.previewLayoutsBox.value = previews
        previewAspects = previews.mapValues {
            PreviewTargetLogic.aspect(canvasWidth: $0.canvasWidth, canvasHeight: $0.canvasHeight)
        }
        var wants: [String: Bool?] = [:]
        for layout in previews.values {
            wants.merge(SlideSceneBuilder.mediaWants(for: layout.objects)) { first, _ in first }
        }
        controls?.setPreviewMediaWants(wants)
    }

    private func restore() {
        guard let stored = UserDefaults.standard.dictionary(forKey: Self.assignmentsKey)
            as? [String: String]
        else { return }
        for (key, layoutID) in stored {
            guard let screenID = UUID(uuidString: key) else { continue }
            assignments[screenID] = layoutID
        }
    }

    private func persist() {
        let stored = Dictionary(
            uniqueKeysWithValues: assignments.map { ($0.key.uuidString, $0.value) }
        )
        UserDefaults.standard.set(stored, forKey: Self.assignmentsKey)
    }

    private func armMutationWatch() {
        withObservationTracking {
            _ = appModel.version(of: .confidenceLayout)
            _ = appModel.fillVersion(of: .confidenceLayout)
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.refresh()
                self.armMutationWatch()
            }
        }
    }
}

private struct ConfidenceMonitorKey: EnvironmentKey {
    static let defaultValue: ConfidenceMonitorController? = nil
}

extension EnvironmentValues {
    var confidenceMonitor: ConfidenceMonitorController? {
        get { self[ConfidenceMonitorKey.self] }
        set { self[ConfidenceMonitorKey.self] = newValue }
    }
}
