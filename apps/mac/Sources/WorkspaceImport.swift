import AppKit
import Foundation
import PresenterCore
import ProImport
import RenderEngine
import SlideScene

@MainActor
struct WorkspaceImportRunner {
    let model: AppModel
    let render: RenderContext
    let controls: ServiceControls
    let confidenceMonitor: ConfidenceMonitorController?
    let presets: OutputPresetsController?

    var inlineHost: ((ImportActivityModel?) -> Void)?

    func present() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose a ProPresenter show directory (it contains Libraries, Themes, and Configuration)"
        panel.prompt = "Import Workspace"
        if let showDirectory = ProPresenterImporter.proPresenterShowDirectory() {
            panel.directoryURL = showDirectory
        }
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                await preflight(showDirectory: url)
            }
        }
    }

    private static let optionsDefaultsKey = "import.workspace.options"

    static func loadOptions() -> WorkspaceImportOptions {
        guard let data = UserDefaults.standard.data(forKey: optionsDefaultsKey),
              let stored = try? JSONDecoder().decode(WorkspaceImportOptions.self, from: data)
        else { return WorkspaceImportOptions() }
        return stored
    }

    static func saveOptions(_ options: WorkspaceImportOptions) {
        if let data = try? JSONEncoder().encode(options) {
            UserDefaults.standard.set(data, forKey: optionsDefaultsKey)
        }
    }

    func preflight(showDirectory: URL) async {
        guard let importer = try? await ProWorkspaceImporter(client: model.client) else { return }
        let activity = ImportActivityModel(title: "Import ProPresenter Workspace")
        if let inlineHost {
            inlineHost(activity)
        } else {
            ImportActivityWindow.present(activity)
        }
        activity.phase = "Scanning\u{2026}"
        let scan = importer.scan(showDirectory: showDirectory)
        activity.requestOptions(scan: scan, options: Self.loadOptions()) { confirmed in
            guard let confirmed else {
                if let inlineHost {
                    inlineHost(nil)
                } else {
                    ImportActivityWindow.dismiss()
                }
                return
            }
            Self.saveOptions(confirmed)
            Task { @MainActor in
                await run(
                    importer: importer, activity: activity,
                    showDirectory: showDirectory, options: confirmed)
            }
        }
    }

    func run(
        importer: ProWorkspaceImporter, activity: ImportActivityModel,
        showDirectory: URL, options: WorkspaceImportOptions
    ) async {
        let result = await importer.importWorkspace(
            showDirectory: showDirectory,

            existingTimers: controls.timers.timers.map { ProTimerSeed(id: $0.id, name: $0.name) },

            existingInputs: VideoInputInventory.shared.entries.map {
                ProInputSeed(id: $0.id, name: $0.name, sourceId: $0.sourceId)
            },
            options: options
        ) { progress in
            activity.apply(progress)
        }
        activity.phase = "Finishing…"

        let refreshExisting = options.policy == .replace

        for plan in result.timerPlans where options.timers {
            if !refreshExisting, controls.timers.timers.contains(where: { $0.id == plan.newID }) {
                continue
            }
            switch plan.mode {
            case .countdown(let seconds):
                controls.timers.importTimer(id: plan.newID, name: plan.name, mode: .countdown, durationSeconds: seconds)
            case .countdownToTime(let hour, let minute):
                controls.timers.importTimer(
                    id: plan.newID, name: plan.name, mode: .countdownToTime,
                    targetTime: TimersController.nextOccurrence(hour: hour, minute: minute)
                )
            case .countUp(let limit):
                controls.timers.importTimer(id: plan.newID, name: plan.name, mode: .countUp, durationSeconds: limit)
            }
        }

        var inputsImported = 0
        if options.videoInputs {
            for plan in result.inputPlans where VideoInputInventory.shared.importEntry(
                id: plan.newID, name: plan.name, kind: plan.kind, sourceId: plan.sourceId
            ) {
                inputsImported += 1
            }
        }

        var screenIDsByProUUID: [String: UUID] = [:]
        var addedScreenIDs: Set<UUID> = []
        var screensAdded = 0
        if options.screens {
            for planned in result.screenPlan.screens {
                if let existing = render.outputs.placeholderScreens.first(where: { $0.name == planned.name }) {
                    screenIDsByProUUID[planned.proUUID] = existing.id
                    continue
                }
                guard let screen = render.outputs.addPlaceholderScreen(
                    name: planned.name, width: planned.width, height: planned.height
                ) else { continue }
                if planned.isConfidence {
                    render.outputs.setRole(.confidence, forScreen: screen.id)
                }
                screenIDsByProUUID[planned.proUUID] = screen.id
                addedScreenIDs.insert(screen.id)
                screensAdded += 1
            }
        }
        func mayConfigure(_ screenID: UUID) -> Bool {
            refreshExisting || addedScreenIDs.contains(screenID)
        }

        if options.screenCorrections {
            for planned in result.screenPlan.screens {
                guard let correction = planned.correction,
                      let screenID = screenIDsByProUUID[planned.proUUID],
                      mayConfigure(screenID) else { continue }
                render.outputs.setAdjustments(outputAdjustments(from: correction), forScreen: screenID)
            }
        }

        for planned in result.screenPlan.screens
        where options.screenSlices && !planned.slices.isEmpty {
            guard let screenID = screenIDsByProUUID[planned.proUUID],
                  mayConfigure(screenID) else { continue }
            for slice in render.outputs.screenSlices[screenID] ?? [] {
                NDIScreenOutputs.shared.disable(screenID: slice.id)
                DeckLinkScreenOutputs.shared.disable(screenID: slice.id)
                render.outputs.removeSlice(id: slice.id)
            }
            for planSlice in planned.slices {
                guard let created = render.outputs.addSlice(
                    toScreen: screenID, name: planSlice.name,
                    sourceRect: CGRect(
                        x: planSlice.x, y: planSlice.y,
                        width: planSlice.width, height: planSlice.height)
                ) else { continue }
                var adjustments = planSlice.correction
                    .map(outputAdjustments(from:)) ?? OutputAdjustments()
                func blend(_ plan: ProScreenPlan.EdgeBlendPlan?) -> OutputEdgeBlend? {
                    plan.map {
                        OutputEdgeBlend(
                            width: $0.width, curve: $0.curve,
                            intensity: $0.intensity, blackLift: $0.blackLift)
                    }
                }
                adjustments.blendLeft = blend(planSlice.blendLeft)
                adjustments.blendRight = blend(planSlice.blendRight)
                adjustments.blendTop = blend(planSlice.blendTop)
                adjustments.blendBottom = blend(planSlice.blendBottom)
                if adjustments != OutputAdjustments() {
                    render.outputs.setAdjustments(adjustments, forScreen: created.id)
                }
            }
        }

        var maskIDsByScreenAndProUUID: [UUID: [String: [UUID]]] = [:]
        let maskPlansByProUUID = Dictionary(
            result.screenPlan.masks.map { ($0.proUUID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        for plan in result.lookPlans where options.screenMasks {
            for screenLook in plan.screenLooks {
                guard let maskUUID = screenLook.maskProUUID,
                      let maskPlan = maskPlansByProUUID[maskUUID],
                      let screenID = screenIDsByProUUID[screenLook.proScreenUUID],
                      mayConfigure(screenID),
                      maskIDsByScreenAndProUUID[screenID]?[maskUUID] == nil
                else { continue }
                let imported = outputMasks(from: maskPlan)
                guard !imported.isEmpty else { continue }
                var library = render.outputs.masks(forScreen: screenID)
                library.removeAll { existing in
                    imported.contains { $0.name == existing.name }
                }
                library.append(contentsOf: imported)
                render.outputs.setMasks(library, forScreen: screenID)
                maskIDsByScreenAndProUUID[screenID, default: [:]][maskUUID] =
                    imported.map(\.id)
            }
        }

        if options.stageAssignments {
            for assignment in result.screenPlan.stageAssignments {
                guard let screenID = screenIDsByProUUID[assignment.screenProUUID],
                      mayConfigure(screenID) else { continue }
                confidenceMonitor?.setLayout(assignment.layoutID, forScreen: screenID)
            }
        }

        var looksImported = 0
        var looksKept = 0
        for plan in result.lookPlans where options.looks {
            if !refreshExisting,
               (try? await model.client.exists(kind: .outputPreset, id: plan.proUUID)) == true {
                looksKept += 1
                continue
            }
            let assignments = plan.screenLooks.compactMap { screenLook -> OutputAssignment? in
                guard let screenID = screenIDsByProUUID[screenLook.proScreenUUID] else { return nil }

                let maskIds = screenLook.maskProUUID
                    .flatMap { maskIDsByScreenAndProUUID[screenID]?[$0] }
                    .map { ids in ids.map(\.uuidString).sorted() }
                return OutputAssignment(
                    targetKind: .placeholderScreen,
                    targetId: screenID.uuidString,
                    enabledLayers: screenLook.enabledLayers,

                    slideThemeId: screenLook.slideThemeId,
                    maskIds: maskIds
                )
            }
            let preset = OutputPreset(id: plan.proUUID, name: plan.name, assignments: assignments)

            if (try? await model.client.replace(preset).value) != nil { looksImported += 1 }
        }

        if !result.midiDevicesImported.isEmpty {
            MIDIDeviceInventory.shared.reload()
        }

        if options.groupHotKeys {
            var merged = result.groupHotKeys
            for summary in result.presentations {
                merged.merge(summary.groupHotKeys) { first, _ in first }
            }
            await model.applyImportedGroupHotKeys(merged, policy: options.policy)
        }

        await model.client.settled()
        model.noteExternalMutation()
        model.noteImportReplacedDocuments()

        model.adoptFallbackServiceIfNeeded()
        summarize(
            result, screensAdded: screensAdded, looksImported: looksImported,
            looksKept: looksKept, inputsImported: inputsImported, into: activity
        )
    }

    private func outputAdjustments(
        from correction: ProScreenPlan.OutputCorrection
    ) -> OutputAdjustments {
        var adjustments = OutputAdjustments()
        func point(_ offset: ProScreenPlan.OutputCorrection.Offset?) -> CGPoint? {
            offset.map { CGPoint(x: $0.x, y: $0.y) }
        }
        adjustments.topLeft = point(correction.topLeft)
        adjustments.topRight = point(correction.topRight)
        adjustments.bottomLeft = point(correction.bottomLeft)
        adjustments.bottomRight = point(correction.bottomRight)
        func value(_ raw: Double) -> Double? { raw == 0 ? nil : raw }
        adjustments.brightness = value(correction.brightness)
        adjustments.contrast = value(correction.contrast)
        adjustments.gamma = value(correction.gamma)
        adjustments.blackLevel = value(correction.blackLevel)
        adjustments.redLevel = value(correction.redLevel)
        adjustments.greenLevel = value(correction.greenLevel)
        adjustments.blueLevel = value(correction.blueLevel)
        adjustments.rotationDegrees = value(correction.rotationDegrees)
        return adjustments
    }

    private func outputMasks(from plan: ProScreenPlan.MaskPlan) -> [OutputMask] {
        plan.shapes.enumerated().compactMap { index, shape -> OutputMask? in
            let frame = CGRect(
                x: shape.x, y: shape.y, width: shape.width, height: shape.height)
            guard frame.width > 0, frame.height > 0 else { return nil }
            let kind = ShapeKind(rawValue: shape.shapeKind) ?? .rectangle
            guard let framePath = ShapeOutlineSVG.pathData(
                shapeKind: kind,
                frame: frame.size,
                cornerRadius: shape.cornerRadius,
                customPathData: shape.pathData,
                placement: .edgeOutside
            ) else { return nil }
            guard let parsed = PathAnchorCodec.parse(framePath, in: frame),
                  let canvasPath = PathAnchorCodec.encodeAbsolute(
                      anchors: parsed.anchors, closed: true)
            else { return nil }
            let name = plan.shapes.count > 1
                ? "\(plan.name) \(index + 1)" : plan.name
            return OutputMask(
                name: name, pathData: canvasPath, mode: .out, alwaysOn: false)
        }
    }

    private func summarize(
        _ result: ProWorkspaceImporter.Result, screensAdded: Int, looksImported: Int,
        looksKept: Int, inputsImported: Int, into activity: ImportActivityModel
    ) {
        let imported = result.presentations.filter { $0.presentationID != nil && $0.skipped == nil }
        var lines: [String] = []
        lines.append("\(imported.count) presentations, \(result.mediaImported) media files")
        if result.mediaWithheld > 0 {
            lines.append("\(result.mediaWithheld) referenced media files left out (Include referenced media files was off)")
        }
        if !result.mediaFoldersImported.isEmpty {
            lines.append("\(result.mediaFoldersImported.count) media bin playlists → Folders: \(result.mediaFoldersImported.joined(separator: ", "))")
        }

        if result.skippedExisting > 0 {
            lines.append("\(result.skippedExisting) already here — kept yours (only adding new)")
        }
        if !result.skippedEdited.isEmpty {
            lines.append("\(result.skippedEdited.count) kept — edited here since import")
        }
        if looksKept > 0 {
            lines.append("\(looksKept) looks kept — already set up here")
        }
        if !result.themesImported.isEmpty { lines.append("\(result.themesImported.count) themes: \(result.themesImported.joined(separator: ", "))") }
        if !result.overlaysImported.isEmpty { lines.append("\(result.overlaysImported.count) props → Overlays") }
        if !result.alertsImported.isEmpty { lines.append("\(result.alertsImported.count) messages → Alerts") }
        if !result.layoutsImported.isEmpty { lines.append("\(result.layoutsImported.count) stage layouts → Confidence Layouts") }
        if !result.combosImported.isEmpty { lines.append("\(result.combosImported.count) macros → Action Combos") }
        if !result.timerPlans.isEmpty { lines.append("\(result.timerPlans.count) timers") }
        if inputsImported > 0 { lines.append("\(inputsImported) video inputs") }
        if !result.midiDevicesImported.isEmpty { lines.append("\(result.midiDevicesImported.count) MIDI devices: \(result.midiDevicesImported.joined(separator: ", "))") }
        if screensAdded > 0 { lines.append("\(screensAdded) screens (with roles and stage layout assignments)") }
        if looksImported > 0 { lines.append("\(looksImported) looks → Output Presets") }
        if !result.servicesImported.isEmpty { lines.append("\(result.servicesImported.count) playlists → Services: \(result.servicesImported.joined(separator: ", "))") }
        if !result.schedulesImported.isEmpty { lines.append("\(result.schedulesImported.count) calendar events → Scheduler: \(result.schedulesImported.joined(separator: ", "))") }

        var warnings = result.warnings + result.presentations.flatMap { summary in
            summary.presentationID == nil ? summary.warnings.map { "\(summary.name): \($0)" } : []
        }
        if !result.skippedEdited.isEmpty {
            warnings.append(
                "Edited here since import, kept yours: \(result.skippedEdited.joined(separator: ", ")). Run the import again with \u{201C}Replace with imported\u{201D} to overwrite them.")
        }
        activity.finish(summaryLines: lines, warnings: warnings)

        model.noteImportSummary("Workspace import: \(imported.count) presentations, \(result.themesImported.count) themes, \(result.overlaysImported.count) overlays, \(result.alertsImported.count) alerts, \(result.layoutsImported.count) layouts, \(result.combosImported.count) combos, \(result.servicesImported.count) services")
    }
}
