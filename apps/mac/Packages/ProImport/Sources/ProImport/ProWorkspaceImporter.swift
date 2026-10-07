import Foundation
import PresenterCore
import SwiftProtobuf

@MainActor
public struct ProWorkspaceImporter {


    private let client: LibraryClient
    private let documents: ProPresenterImporter
    private let resolver: ImportMediaResolver

    public init(client: LibraryClient) async throws {
        self.client = client
        documents = try ProPresenterImporter(client: client)
        resolver = try await ImportMediaResolver(client: client)
    }

    public func scan(showDirectory: URL) -> WorkspaceScan {
        var scan = WorkspaceScan()
        let config = showDirectory.appendingPathComponent("Configuration")
        if let timersDoc: RVData_TimersDocument = decode(config.appendingPathComponent("Timers")) {
            scan.timers = ProWorkspaceMapper.mapTimers(timersDoc).count
        }
        let workspace: RVData_ProPresenterWorkspace? = decode(config.appendingPathComponent("Workspace"))
        if let workspace {
            scan.videoInputs = workspace.videoInputs.count
            scan.screens = ProWorkspaceMapper.mapScreens(workspace).plan.screens.count
            scan.looks = ProWorkspaceMapper.mapLooks(workspace).looks.count
        }
        let themesDir = showDirectory.appendingPathComponent("Themes")
        scan.themes = ((try? FileManager.default.contentsOfDirectory(
            at: themesDir, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .count
        let librariesDir = showDirectory.appendingPathComponent("Libraries")
        if let libraryDirs = try? FileManager.default.contentsOfDirectory(
            at: librariesDir, includingPropertiesForKeys: [.isDirectoryKey]) {
            let importable = libraryDirs
                .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
                .filter { $0.lastPathComponent != "LibraryData" }
            scan.presentations = documents.countDocuments(at: importable)
        }
        for file in ["Media", "Audio"] {
            if let doc: RVData_PlaylistDocument = decode(showDirectory.appendingPathComponent("Playlists/\(file)")) {
                scan.media += ProPlaylistMapper.mapMediaBinFolders(doc).folders.count
            }
        }
        if let propsDoc: RVData_PropDocument = decode(config.appendingPathComponent("Props")) {
            scan.props = ProWorkspaceMapper.mapProps(propsDoc).count
        }
        if let messagesDoc: RVData_MessageDocument = decode(config.appendingPathComponent("Messages")) {
            scan.messages = ProWorkspaceMapper.mapMessages(messagesDoc).count
        }
        if let stageDoc: RVData_Stage.Document = decode(config.appendingPathComponent("Stage")) {
            var inputs = ProInputPlanBook()
            scan.stageLayouts = ProWorkspaceMapper.mapStageLayouts(
                stageDoc, timerIDsByProUUID: [:], timerIDsByName: [:], inputs: &inputs
            ).count
        }
        if let macrosDoc: RVData_MacrosDocument = decode(config.appendingPathComponent("Macros")) {
            var inputs = ProInputPlanBook()
            scan.macros = ProWorkspaceMapper.mapMacros(
                macrosDoc, timerIDsByProUUID: [:], timerIDsByName: [:], inputs: &inputs
            ).count
        }
        if let calendarDoc: RVData_Calendar = decode(config.appendingPathComponent("Calendar")) {
            scan.calendarEvents = ProWorkspaceMapper.mapCalendar(
                calendarDoc, timerIDsByProUUID: [:], timerIDsByName: [:]
            ).count
        }
        if let data = try? Data(contentsOf: config.appendingPathComponent("CommunicationDevices")) {
            scan.midiDevices = ProWorkspaceMapper.mapCommunicationDevices(data).devices.count
        }
        if let groupsDoc: RVData_ProGroupsDocument = decode(config.appendingPathComponent("Groups")) {
            scan.groupHotKeys = groupsDoc.groups.count {
                $0.hasHotKey && ProDocumentMapper.hotKeyLetter($0.hotKey.code) != nil
            }
        }
        let playlistsDir = showDirectory.appendingPathComponent("Playlists")
        scan.playlists = ((try? FileManager.default.contentsOfDirectory(
            at: playlistsDir, includingPropertiesForKeys: [.isRegularFileKey])) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .count
        return scan
    }

    public func importWorkspace(
        showDirectory: URL,
        existingTimers: [ProTimerSeed] = [],
        existingInputs: [ProInputSeed] = [],
        options: WorkspaceImportOptions = WorkspaceImportOptions(),
        progress: ProImportProgressHandler? = nil
    ) async -> Result {
        var result = Result()
        let config = showDirectory.appendingPathComponent("Configuration")

        let writer = await ImportWriter(client: client, policy: options.policy)
        defer {
            writer.saveLedger()
        }

        progress?(ProImportProgress(phase: "Timers"))
        var timerIDsByProUUID: [String: String] = [:]
        var timerIDsByName: [String: String] = [:]
        if let timersDoc: RVData_TimersDocument = decode(config.appendingPathComponent("Timers")) {
            result.timerPlans = ProWorkspaceMapper.mapTimers(timersDoc, existing: existingTimers)
            for plan in result.timerPlans {
                timerIDsByProUUID[plan.proUUID] = plan.newID
                timerIDsByName[plan.name.lowercased()] = plan.newID
            }
        }

        var inputBook = ProInputPlanBook()
        inputBook.seed(existingInputs)
        let workspace: RVData_ProPresenterWorkspace? = decode(config.appendingPathComponent("Workspace"))
        if let workspace {
            for input in workspace.videoInputs {
                inputBook.registerWorkspaceInput(
                    uuid: input.uuid.string,
                    name: input.userDescription,
                    device: input.videoInputDevice
                )
            }
        }

        var themeIDsByName: [String: String] = [:]
        let themesDir = showDirectory.appendingPathComponent("Themes")
        if options.themes,
           let themeDirs = try? FileManager.default.contentsOfDirectory(at: themesDir, includingPropertiesForKeys: [.isDirectoryKey]) {
            let sorted = themeDirs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
            for (index, themeDir) in sorted.enumerated() {
                let themeFile = themeDir.appendingPathComponent("Theme")
                guard let doc: RVData_Template.Document = decode(themeFile) else { continue }
                let name = themeDir.lastPathComponent
                progress?(ProImportProgress(phase: "Themes", detail: name, completed: index, total: sorted.count))
                var mapped = ProWorkspaceMapper.mapTheme(doc, name: name)

                themeIDsByName[name.lowercased()] = mapped.theme.id
                if await writer.check(Theme.self, id: mapped.theme.id, label: "theme \"\(name)\"") != nil {
                    continue 
                }
                let resolution = await resolver.resolve(mapped.mediaWants, sourceFileURL: themeFile, showDirectory: showDirectory)
                result.mediaImported += resolution.imported
                mapped.theme.slides = mapped.theme.slides.map { slides in
                    slides.map { replacingMediaIDs(in: $0, with: resolution.idMap) }
                }
                if await writer.write(mapped.theme, label: "theme \"\(name)\"", warnings: &result.warnings) {
                    result.themesImported.append(name)
                }
                prefix(mapped.warnings + resolution.warnings, with: "theme \"\(name)\"", into: &result.warnings)
            }
        }

        let librariesDir = showDirectory.appendingPathComponent("Libraries")
        if options.presentations,
           let libraryDirs = try? FileManager.default.contentsOfDirectory(at: librariesDir, includingPropertiesForKeys: [.isDirectoryKey]) {
            let importable = libraryDirs
                .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
                .filter { $0.lastPathComponent != "LibraryData" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            let totalDocuments = documents.countDocuments(at: importable)
            var completedDocuments = 0
            for libraryDir in importable {
                let folder = importable.count > 1
                    ? "ProPresenter Import/\(libraryDir.lastPathComponent)"
                    : "ProPresenter Import"
                let summaries = await documents.importItems(
                    at: [libraryDir], folder: folder, resolver: resolver,
                    timerIDsByProUUID: timerIDsByProUUID,
                    timerIDsByName: timerIDsByName,
                    writer: writer,
                    importMedia: options.presentationMedia,
                    onDocument: { url in
                        progress?(ProImportProgress(
                            phase: "Presentations",
                            detail: url.deletingPathExtension().lastPathComponent,
                            completed: completedDocuments, total: totalDocuments))
                        completedDocuments += 1
                    })
                result.presentations.append(contentsOf: summaries)
                result.mediaImported += summaries.reduce(0) { $0 + $1.mediaImported }
                result.mediaWithheld += summaries.reduce(0) { $0 + $1.mediaWithheld }
            }
        }

        progress?(ProImportProgress(phase: "Props"))
        if options.overlays, let propsDoc: RVData_PropDocument = decode(config.appendingPathComponent("Props")) {
            for var mapped in ProWorkspaceMapper.mapProps(propsDoc) {
                if await writer.check(
                    Overlay.self, id: mapped.overlay.id,
                    label: "prop \"\(mapped.overlay.name)\"") != nil {
                    continue
                }
                let resolution = await resolver.resolve(mapped.mediaWants, sourceFileURL: config.appendingPathComponent("Props"), showDirectory: showDirectory)
                result.mediaImported += resolution.imported
                mapped.overlay.objects = replacingMediaIDs(in: mapped.overlay.objects, with: resolution.idMap)
                if await writer.write(mapped.overlay, label: "prop \"\(mapped.overlay.name)\"", warnings: &result.warnings) {
                    result.overlaysImported.append(mapped.overlay.name)
                }
                prefix(mapped.warnings + resolution.warnings, with: "prop \"\(mapped.overlay.name)\"", into: &result.warnings)
            }
        }

        progress?(ProImportProgress(phase: "Messages"))
        if options.alerts, let messagesDoc: RVData_MessageDocument = decode(config.appendingPathComponent("Messages")) {
            for mapped in ProWorkspaceMapper.mapMessages(messagesDoc) {
                var preset = mapped.preset
                if let themeName = mapped.templateThemeName {
                    if let themeID = themeIDsByName[themeName.lowercased()] {
                        preset.themeId = themeID
                        await ensureAlertsSlide(inTheme: themeID, sourceSlideName: mapped.templateSlideName, warnings: &result.warnings)
                    } else {
                        result.warnings.append("message \"\(preset.name)\": its Pro7 template theme \"\(themeName)\" was not found — the alert uses the built-in banner")
                    }
                }
                if await writer.check(AlertPreset.self, id: preset.id, label: "message \"\(preset.name)\"") == nil,
                   await writer.write(preset, label: "message \"\(preset.name)\"", warnings: &result.warnings) {
                    result.alertsImported.append(preset.name)
                }
                prefix(mapped.warnings, with: "message \"\(preset.name)\"", into: &result.warnings)
            }
        }

        progress?(ProImportProgress(phase: "Stage layouts"))
        if options.confidenceLayouts, let stageDoc: RVData_Stage.Document = decode(config.appendingPathComponent("Stage")) {
            let mappedLayouts = ProWorkspaceMapper.mapStageLayouts(
                stageDoc,
                timerIDsByProUUID: timerIDsByProUUID,
                timerIDsByName: timerIDsByName,
                inputs: &inputBook
            )
            for var mapped in mappedLayouts {
                if await writer.check(
                    ConfidenceLayout.self, id: mapped.layout.id,
                    label: "stage layout \"\(mapped.layout.name)\"") != nil {
                    continue
                }
                let resolution = await resolver.resolve(mapped.mediaWants, sourceFileURL: config.appendingPathComponent("Stage"), showDirectory: showDirectory)
                result.mediaImported += resolution.imported
                mapped.layout.objects = replacingMediaIDs(in: mapped.layout.objects, with: resolution.idMap)
                if await writer.write(mapped.layout, label: "stage layout \"\(mapped.layout.name)\"", warnings: &result.warnings) {
                    result.layoutsImported.append(mapped.layout.name)
                }
                prefix(mapped.warnings + resolution.warnings, with: "stage layout \"\(mapped.layout.name)\"", into: &result.warnings)
            }
        }

        progress?(ProImportProgress(phase: "Macros"))
        if options.combos, let macrosDoc: RVData_MacrosDocument = decode(config.appendingPathComponent("Macros")) {
            var importedComboIDs = Set<String>()
            for mapped in ProWorkspaceMapper.mapMacros(
                macrosDoc, timerIDsByProUUID: timerIDsByProUUID,
                timerIDsByName: timerIDsByName, inputs: &inputBook
            ) {
                if await writer.check(
                    ActionCombo.self, id: mapped.combo.id,
                    label: "macro \"\(mapped.combo.name)\"") != nil {
                    continue
                }
                let resolution = await resolver.resolve(mapped.mediaWants, sourceFileURL: config.appendingPathComponent("Macros"), showDirectory: showDirectory)
                result.mediaImported += resolution.imported
                let combo = ProWorkspaceMapper.replacingMediaIDs(mapped.combo, with: resolution.idMap)
                if combo.actions.count < mapped.combo.actions.count {
                    result.warnings.append("macro \"\(combo.name)\": a fire-media step lost its file and was dropped")
                }
                if await writer.write(combo, label: "macro \"\(combo.name)\"", warnings: &result.warnings) {
                    result.combosImported.append(combo.name)
                    importedComboIDs.insert(combo.id)
                }
                prefix(mapped.warnings + resolution.warnings, with: "macro \"\(combo.name)\"", into: &result.warnings)
            }
            await applyMacroCollections(macrosDoc, importedComboIDs: importedComboIDs, warnings: &result.warnings)
        }

        progress?(ProImportProgress(phase: "Calendar"))
        if options.schedules, let calendarDoc: RVData_Calendar = decode(config.appendingPathComponent("Calendar")) {
            var importedTriggerIDs: [String] = []
            for mapped in ProWorkspaceMapper.mapCalendar(
                calendarDoc, timerIDsByProUUID: timerIDsByProUUID, timerIDsByName: timerIDsByName
            ) {
                if await writer.check(
                    ScheduleTrigger.self, id: mapped.trigger.id,
                    label: "calendar event \"\(mapped.trigger.name)\"") == nil,
                    await writer.write(mapped.trigger, label: "calendar event \"\(mapped.trigger.name)\"", warnings: &result.warnings) {
                    result.schedulesImported.append(mapped.trigger.name)
                    importedTriggerIDs.append(mapped.trigger.id)
                }
                prefix(mapped.warnings, with: "calendar event \"\(mapped.trigger.name)\"", into: &result.warnings)
            }
            await applySchedulerFolder(triggerIDs: importedTriggerIDs, warnings: &result.warnings)
            if !calendarDoc.active, !importedTriggerIDs.isEmpty {
                result.warnings.append("the Pro calendar was turned off; its triggers imported enabled, pause them in the Scheduler if needed")
            }
        }

        progress?(ProImportProgress(phase: "MIDI devices"))

        if options.midiDevices,
           let data = try? Data(contentsOf: config.appendingPathComponent("CommunicationDevices")) {
            let mapped = ProWorkspaceMapper.mapCommunicationDevices(data)
            for device in mapped.devices {
                if await writer.check(MIDIDevice.self, id: device.id, label: "MIDI device \"\(device.name)\"") == nil,
                   await writer.write(device, label: "MIDI device \"\(device.name)\"", warnings: &result.warnings) {
                    result.midiDevicesImported.append(device.name)
                }
            }
            result.warnings.append(contentsOf: mapped.warnings)
        }

        progress?(ProImportProgress(phase: "Screens & looks"))
        if let workspace {
            let screens = ProWorkspaceMapper.mapScreens(workspace)
            result.screenPlan = screens.plan
            result.warnings.append(contentsOf: screens.warnings)
            let looks = ProWorkspaceMapper.mapLooks(workspace)
            result.lookPlans = looks.looks
            result.liveLookUUID = looks.liveLookUUID
            result.warnings.append(contentsOf: looks.warnings)

            for lookIndex in result.lookPlans.indices {
                for screenIndex in result.lookPlans[lookIndex].screenLooks.indices {
                    guard let name = result.lookPlans[lookIndex]
                        .screenLooks[screenIndex].slideThemeName else { continue }
                    if let themeID = themeIDsByName[name.lowercased()] {
                        result.lookPlans[lookIndex]
                            .screenLooks[screenIndex].slideThemeId = themeID
                    } else {
                        result.warnings.append(
                            "look \"\(result.lookPlans[lookIndex].name)\": its slide-layer theme \"\(name)\" is not among the imported themes and was dropped"
                        )
                    }
                }
            }
        }

        progress?(ProImportProgress(phase: "Playlists"))
        if options.playlists {
            let playlists = await importPlaylists(
                showDirectory: showDirectory, presentations: result.presentations,
                writer: writer)
            result.servicesImported = playlists.services
            result.mediaImported += playlists.mediaImported
            result.warnings.append(contentsOf: playlists.warnings)
        }

        if options.media {
            let outcome = await importMediaBinFolders(showDirectory: showDirectory, progress: progress)
            result.mediaImported += outcome.mediaImported
            result.mediaFoldersImported = outcome.folders
            result.warnings.append(contentsOf: outcome.warnings)
        }

        if options.groupHotKeys,
           let groupsDoc: RVData_ProGroupsDocument = decode(config.appendingPathComponent("Groups")) {
            for group in groupsDoc.groups where group.hasHotKey && !group.name.isEmpty {
                guard let letter = ProDocumentMapper.hotKeyLetter(group.hotKey.code) else { continue }
                let key = GroupPalette.normalizedName(group.name)
                if result.groupHotKeys[key] == nil { result.groupHotKeys[key] = letter }
            }
        }

        result.inputPlans = inputBook.plans
        result.skippedExisting = writer.skippedExisting
        result.skippedEdited = writer.skippedEdited
        return result
    }

    private struct MediaBinOutcome {
        var folders: [String] = []
        var mediaImported = 0
        var warnings: [String] = []
    }

    private func importMediaBinFolders(
        showDirectory: URL, progress: ProImportProgressHandler?
    ) async -> MediaBinOutcome {
        var outcome = MediaBinOutcome()
        let playlistsDir = showDirectory.appendingPathComponent("Playlists")
        for file in ["Media", "Audio"] {
            let playlistFile = playlistsDir.appendingPathComponent(file)
            if let doc: RVData_PlaylistDocument = decode(playlistFile) {
                let mapped = ProPlaylistMapper.mapMediaBinFolders(doc)
                outcome.warnings.append(contentsOf: mapped.warnings)
                for (index, folder) in mapped.folders.enumerated() {
                    progress?(ProImportProgress(
                        phase: "Media", detail: folder.path,
                        completed: index, total: mapped.folders.count))
                    let wants = mapped.mediaWants.filter { folder.wantIDs.contains($0.placeholderID) }
                    let resolution = await resolver.resolve(
                        wants, sourceFileURL: playlistFile, showDirectory: showDirectory)
                    outcome.mediaImported += resolution.imported
                    prefix(resolution.warnings, with: "media playlist \"\(folder.path)\"", into: &outcome.warnings)
                    let libraryFolder = "ProPresenter Import/\(folder.path)"
                    for id in folder.wantIDs.compactMap({ resolution.idMap[$0] }) {
                        await fileMedia(id: id, isAudio: resolution.audioIDs.contains(id), into: libraryFolder)
                    }
                    outcome.folders.append(folder.path)
                }
            }
        }
        return outcome
    }

    private func fileMedia(id: String, isAudio: Bool, into folder: String) async {
        if isAudio {
            if let item = try? await client.loadValue(AudioItem.self, id: id), item.folder == nil {
                _ = await client.modify(AudioItem.self, id: id) { if $0.folder == nil { $0.folder = folder } }.result
            }
        } else if let item = try? await client.loadValue(MediaItem.self, id: id), item.folder == nil {
            _ = await client.modify(MediaItem.self, id: id) { if $0.folder == nil { $0.folder = folder } }.result
        }
    }

    private struct PlaylistImportOutcome {
        var services: [String] = []
        var mediaImported = 0
        var warnings: [String] = []
    }

    private func importPlaylists(
        showDirectory: URL,
        presentations: [ProPresenterImporter.DocumentSummary],
        writer: ImportWriter
    ) async -> PlaylistImportOutcome {
        var outcome = PlaylistImportOutcome()
        let playlistsDir = showDirectory.appendingPathComponent("Playlists")

        var byAbsolutePath: [String: String] = [:]
        var byRelativePath: [String: String] = [:]
        let showPath = showDirectory.standardizedFileURL.path
        for summary in presentations {
            guard let id = summary.presentationID else { continue }
            let absolute = summary.sourceURL.standardizedFileURL.path
            byAbsolutePath[absolute] = id
            if absolute.hasPrefix(showPath + "/") {
                byRelativePath[String(absolute.dropFirst(showPath.count + 1))] = id
            }
        }
        func resolvePresentation(_ ref: ProPlaylistPresentationRef) -> String? {
            if let absolute = ref.absolutePath {
                let standardized = URL(fileURLWithPath: absolute).standardizedFileURL.path
                if let id = byAbsolutePath[standardized] { return id }
                if let range = standardized.range(of: "/Libraries/") {
                    let relative = "Libraries/" + standardized[range.upperBound...]
                    if let id = byRelativePath[relative] { return id }
                }
            }
            if let relative = ref.relativePath, let id = byRelativePath[relative] { return id }
            return nil
        }

        if !FileManager.default.fileExists(atPath: playlistsDir.path) {
            outcome.warnings.append("the workspace has no Playlists folder, so no services or playlists imported")
        }

        let libraryFile = playlistsDir.appendingPathComponent("Library")
        let libraryDoc: RVData_PlaylistDocument? = decode(libraryFile)
        if libraryDoc == nil, FileManager.default.fileExists(atPath: playlistsDir.path) {
            let reason = FileManager.default.fileExists(atPath: libraryFile.path)
                ? "the Playlists/Library document could not be read"
                : "the workspace has no Playlists/Library document"
            outcome.warnings.append("\(reason), so no services imported")
        }
        if let doc = libraryDoc {
            let mapped = ProPlaylistMapper.mapPresentationPlaylists(doc, resolvePresentation: resolvePresentation)

            let resolution = await resolver.resolve(
                mapped.mediaWants, sourceFileURL: libraryFile, showDirectory: showDirectory)
            outcome.mediaImported += resolution.imported
            for mappedService in mapped.services {
                let (service, dropped) = ProPlaylistMapper.replacingMediaIDs(
                    mappedService.service, with: resolution.idMap, audioIDs: resolution.audioIDs)
                if await writer.check(Service.self, id: service.id, label: "playlist \"\(service.name)\"") == nil,
                   await writer.write(service, label: "playlist \"\(service.name)\"", warnings: &outcome.warnings) {
                    outcome.services.append(service.name)
                }
                prefix(mappedService.warnings + dropped, with: "playlist \"\(service.name)\"", into: &outcome.warnings)
            }
            outcome.warnings.append(contentsOf: resolution.warnings)
        }

        return outcome
    }

    private func decode<Message: SwiftProtobuf.Message>(_ url: URL) -> Message? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? Message(serializedBytes: data)
    }

    private func prefix(_ new: [String], with label: String, into warnings: inout [String]) {
        for warning in new where !warning.hasPrefix(label) {
            warnings.append("\(label): \(warning)")
        }
        for warning in new where warning.hasPrefix(label) {
            warnings.append(warning)
        }
    }

    private func applyMacroCollections(
        _ doc: RVData_MacrosDocument,
        importedComboIDs: Set<String>,
        warnings: inout [String]
    ) async {
        let collections: [(name: String, memberIDs: [String])] = doc.macroCollections.compactMap { collection in
            var members = collection.items.compactMap { item -> String? in
                guard case .macroID(let id)? = item.itemType else { return nil }
                return id.string.lowercased()
            }
            members += collection.macros.map { $0.uuid.string.lowercased() }
            members = members.filter { importedComboIDs.contains($0) }
            guard !members.isEmpty else { return nil }
            return (collection.name.isEmpty ? "Macros" : collection.name, members)
        }
        guard !collections.isEmpty else { return }
        do {

            let comboIDs = try await client.settledSnapshot().entries(of: .actionCombo).map(\.id)
            let folders = collections.map { (name: $0.name, memberIDs: $0.memberIDs) }
            _ = try await client.modify(
                ControlBoard.self, id: ControlBoard.comboBoardID,
                orMake: { ControlBoard(id: ControlBoard.comboBoardID, nodes: [], folders: []) }
            ) { board in

                board.reconcile(withItemIDs: comboIDs)
                for collection in folders {
                    let folderID = board.folders.first { $0.name == collection.name }?.id
                        ?? board.addFolder(named: collection.name)
                    for member in collection.memberIDs {
                        board.moveItem(id: member, intoFolder: folderID)
                    }
                }
            }.value
        } catch {
            warnings.append("macro collections could not become combo folders: \(error.localizedDescription)")
        }
    }

    private func applySchedulerFolder(triggerIDs: [String], warnings: inout [String]) async {
        guard !triggerIDs.isEmpty else { return }
        do {
            let allIDs = try await client.settledSnapshot().entries(of: .scheduleTrigger).map(\.id)
            _ = try await client.modify(
                SchedulerBoard.self, id: SchedulerBoard.wellKnownID,
                orMake: { SchedulerBoard(id: SchedulerBoard.wellKnownID, nodes: [], folders: []) }
            ) { board in
                board.reconcile(withTriggerIDs: allIDs)
                let folderID = board.folders.first { $0.name == "ProPresenter Calendar" }?.id
                    ?? board.addFolder(named: "ProPresenter Calendar")
                for id in triggerIDs {
                    board.moveTrigger(id: id, intoFolder: folderID)
                }
            }.value
        } catch {
            warnings.append("calendar events could not join a scheduler folder: \(error.localizedDescription)")
        }
    }

    private func ensureAlertsSlide(inTheme themeID: String, sourceSlideName: String?, warnings: inout [String]) async {
        let slideID = UUID().uuidString
        if var theme = try? await client.loadValue(Theme.self, id: themeID),
           Self.addAlertsSlide(to: &theme, sourceSlideName: sourceSlideName, id: slideID) {

            let written = await client.modify(Theme.self, id: themeID) {
                Self.addAlertsSlide(to: &$0, sourceSlideName: sourceSlideName, id: slideID)
            }.result
            if case .failure(let error) = written {
                warnings.append("theme could not gain an Alerts slide: \(error.localizedDescription)")
            }
        }
    }

    @discardableResult
    private nonisolated static func addAlertsSlide(to theme: inout Theme, sourceSlideName: String?, id: String) -> Bool {
        let slides = theme.slides ?? []
        let source = sourceSlideName.flatMap { name in
            slides.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        } ?? slides.first
        if !slides.contains(where: { $0.name.caseInsensitiveCompare("Alerts") == .orderedSame }), var alertsSlide = source {
            alertsSlide.id = id
            alertsSlide.name = "Alerts"
            theme.slides = slides + [alertsSlide]
            return true
        } else {
            return false
        }
    }

    private func replacingMediaIDs(in slide: Slide, with map: [String: String]) -> Slide {
        var slide = slide
        slide.objects = replacingMediaIDs(in: slide.objects, with: map)
        return slide
    }

    private func replacingMediaIDs(in objects: [SlideObject], with map: [String: String]) -> [SlideObject] {

        let carrier = Presentation(
            id: "carrier", name: "", presentationKind: .deck, themeId: "",
            slides: [Slide(id: "carrier", name: "", objects: objects)]
        )
        return ProDocumentMapper.replacingMediaIDs(carrier, with: map).slides[0].objects
    }
}
