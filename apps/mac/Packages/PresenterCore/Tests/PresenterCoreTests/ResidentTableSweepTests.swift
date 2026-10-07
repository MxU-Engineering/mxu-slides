import Foundation
import Testing

@testable import PresenterCore

@Suite struct ResidentTableSweepTests {
    private var appSources: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  
            .deletingLastPathComponent()  
            .deletingLastPathComponent()  
            .deletingLastPathComponent()  
            .deletingLastPathComponent()  
            .appendingPathComponent("Sources", isDirectory: true)
    }

    private func swiftFiles() throws -> [URL] {
        let all = FileManager.default.enumerator(
            at: appSources, includingPropertiesForKeys: nil
        )?.compactMap { $0 as? URL } ?? []
        let files = all.filter { $0.pathExtension == "swift" }
        try #require(!files.isEmpty, "app sources not found at \(appSources.path)")
        return files
    }

    private func source(_ name: String) throws -> String {
        try String(contentsOf: appSources.appendingPathComponent(name), encoding: .utf8)
    }

    private func body(of signature: String, in text: String) throws -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let start = try #require(lines.firstIndex { $0.contains(signature) }, "\(signature) expected")
        var depth = 0
        var started = false
        var cursor = start
        var collected: [String] = []
        while cursor < lines.count {
            collected.append(lines[cursor])
            for character in lines[cursor] {
                if character == "{" { depth += 1; started = true }
                if character == "}" { depth -= 1 }
            }
            if started, depth <= 0 { break }
            cursor += 1
        }
        return collected.joined(separator: "\n")
    }

    private let forbiddenSpellings = ["NowOrDecode", "OrFill(", "loadValueNow", "allowingMainThreadOpens"]

    private var coreSources: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  
            .deletingLastPathComponent()  
            .deletingLastPathComponent()  
            .appendingPathComponent("Sources/PresenterCore", isDirectory: true)
    }

    @Test func noSynchronousDecodeSpellingRemains() throws {
        let core = FileManager.default.enumerator(at: coreSources, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        try #require(!core.isEmpty, "core sources not found at \(coreSources.path)")
        var found: [String] = []
        for file in try swiftFiles() + core {
            let text = try String(contentsOf: file, encoding: .utf8)
            for spelling in forbiddenSpellings where text.contains(spelling) {
                found.append("\(file.lastPathComponent): \(spelling)")
            }
        }
        #expect(found.isEmpty, "read presentation(_:) / theme(_:), await decks.ready, or fill off main: \(found)")
    }

    @Test func theFillWaitIsTheDecksWait() throws {
        let model = try source("AppModel.swift")
        let wait = try body(of: "func presentationsFilled(_ ids: [String]) async", in: model)
        #expect(wait.contains("await decks.ready(ids)"))
        #expect(!wait.contains("loadValue") && !wait.contains("open("), "no synchronous fallback")
    }

    @Test func residentAccessorsNeverDecode() throws {
        let model = try source("AppModel.swift")
        let accessors = [
            "func theme(_ id: String) -> Theme?",
            "func presentation(_ id: String) -> Presentation?",
            "func heldPresentation(_ id: String) -> Presentation?",
            "func media(_ id: String) -> MediaItem?",
            "func audio(_ id: String) -> AudioItem?",
            "func service(_ id: String) throws -> Service",
            "func playlist(_ id: String) throws -> Playlist",
            "func overlay(_ id: String) -> Overlay?",
            "func alertPreset(_ id: String) throws -> AlertPreset",
            "func streamPreset(_ id: String) throws -> StreamRecordPreset",
            "func streamDestination(_ id: String) -> StreamDestination?",
            "func actionCombo(_ id: String) throws -> ActionCombo",
            "func scheduleTrigger(_ id: String) throws -> ScheduleTrigger",
            "var schedulerBoard: SchedulerBoard {",
            "var groupPalette: GroupPalette {",
            "var serviceLinkRules: ServiceLinkRules {",
            "var effectPresetBoard: EffectPresetBoard {",
            "var animationPresetBoard: AnimationPresetBoard {",
            "var signageBoard: SignageBoard {",
            "private func controlBoard(id: String, itemIDs: [String]) -> ControlBoard {",
            "func flaggedMediaCount() -> Int {",
            "func mediaSceneEffects(id: String)",
        ]
        for accessor in accessors {
            let text = try body(of: accessor, in: model)
            for token in ["library.open(", "store.load(", "library.index."] {
                #expect(!text.contains(token), "\(accessor) uses \(token))")
            }
        }
        #expect(!model.contains("func mediaItem("), "mediaItem decoded per call; read media(_:)")
        #expect(!model.contains("func audioItem("), "audioItem decoded per call; read audio(_:)")
        let read = try body(of: "func presentation(_ id: String) -> Presentation?", in: model)
        #expect(read.contains("decks.value(id)"), "the deck read is the held value (D8)")
        #expect(try body(of: "func themesFilled(_ ids: [String]) async", in: model).contains("client.loadValues(Theme.self"), "the fire path's theme wait reads off main")
    }

    @Test func theSchedulerTickReadsNoDocuments() throws {
        let scheduler = try source("SchedulerController.swift")
        let tick = try body(of: "private func tickTimerWatch()", in: scheduler)
        #expect(!tick.contains("model."), "the tick reads the sweep's watch list, not the model")
        let open = try body(of: "private func openTriggers()", in: scheduler)
        #expect(open.contains("model.residentScheduleTriggers"))
        #expect(scheduler.contains("await model.resident.ready([.scheduleTrigger, .schedulerBoard])"), "the first sweep waits for the tables")
    }

    @Test func launchWalksReadTables() throws {
        let router = try source("ActionRouter.swift")
        let startup = try body(of: "func runStartupCombos() async", in: router)
        #expect(startup.contains("model.resident.actionCombos.values"))
        #expect(startup.contains("await model.resident.ready([.actionCombo])"))
        let predicted = try body(of: "private func predictedPresetID(", in: router)
        #expect(predicted.contains("fillVersion(of: .actionCombo)"))
        #expect(!router.contains("library.open("), "router reads go through the tables")
    }

    @MainActor @Test func theResidentKindsAreTheSmallOnes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = ResidentLibrary(
            store: try DocumentStore(rootURL: root), epochs: DocumentKindVersions(), fills: DocumentKindVersions())
        let kinds = Set(library.all.map(\.kind))
        #expect(kinds == [
            .media, .audio, .theme, .service, .playlist, .overlay, .alertPreset,
            .streamRecordPreset, .streamDestination, .actionCombo, .scheduleTrigger,
            .confidenceLayout, .schedulerBoard, .controlBoard, .groupPalette,
            .signageBoard, .effectPresetBoard, .animationPresetBoard, .serviceLinkRules,
            .slideBuildingSettings, .outputPreset, .midiDevice,
        ])
        #expect(kinds.count == library.all.count)
    }

    @Test func theLiveSetAndTheLaunchStagesAreWired() throws {
        let model = try source("AppModel.swift")
        let current = try body(of: "var currentServiceID: String? =", in: model)
        #expect(current.contains("didSet") && current.contains("warmLiveSet()"))
        let opened = try body(of: "private func libraryOpened(rootURL root: URL)", in: model)
        #expect(opened.contains("warmResidency()") && !opened.contains("warmAll()"))
        let residency = try body(of: "private func warmResidency() async", in: model)
        #expect(residency.contains("resident.warmStaged(") && residency.contains("ResidentLibrary.launchStages("))
        #expect(residency.contains("\"residency.stages\""))
        let warm = try body(of: "func warmLiveSet()", in: model)
        #expect(warm.contains("decks.pin(ResidentDecks.liveSet("))
        #expect(try body(of: "private func noteLibraryWideMutation()", in: model).contains("warmLiveSet()"))
        #expect(try body(of: "private func land(_ change: DocumentChange)", in: model).contains("warmLiveSet()"))
        #expect(try source("ServiceControls.swift").contains("appModel.noteOnAirDeck(livePresentationID)"))
    }

    @Test func theFirePathReadsTheThemeTable() throws {
        let controls = try source("ServiceControls.swift")
        let fire = try body(of: "    func fire(", in: controls)
        #expect(fire.contains("appModel.resident.themes.fireRead(themeID)"))
        #expect(fire.contains("await self?.appModel.themesFilled([themeID])"))
        let alert = try body(of: "func fireAlert(", in: controls)
        #expect(alert.contains("appModel.resident.themes.fireRead(styling)"))
        #expect(alert.contains("await self?.appModel.themesFilled([styling])"))
        let presets = try source("OutputPresetsController.swift")
        let apply = try body(of: "func applyActivePreset()", in: presets)
        #expect(apply.contains("appModel.resident.themes.fireRead(themeID)"))
        #expect(apply.contains("await self?.appModel.themesFilled(waiting)"))
        #expect(try body(of: "private func route(_ preset: OutputPreset)", in: presets).contains("\"presets.slideTheme.missing\""))
    }

    private func enclosingFunction(of marker: String, in text: String) throws -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let hit = try #require(lines.firstIndex { $0.contains(marker) }, "\(marker) expected")
        let declaration = try #require(lines[...hit].last { $0.hasPrefix("    ") && !$0.hasPrefix("     ") && $0.contains("func ") })
        let name = declaration.components(separatedBy: "func ")[1]
        return String(name.prefix { $0 != "(" && $0 != "<" })
    }

    @Test func theLookedAtDecksWarmOnTheActorAndTheEditorChecksOut() throws {
        let model = try source("AppModel.swift")
        let warm = try enclosingFunction(of: "client.warm(Presentation.self, ids:", in: model)
        #expect(try body(of: "func presentation(_ id: String) -> Presentation?", in: model).contains("\(warm)("), "a surface's miss warms the deck")
        #expect(try body(of: "var selectedEntryID: String? {", in: model).contains("warmSelectedDeck()"))
        #expect(try body(of: "private func warmSelectedDeck()", in: model).contains("\(warm)("), "the selection warms the deck")
        #expect(try body(of: "func warmLiveSet()", in: model).contains("client.warmLive("), "the current service's decks stay warm")
        #expect(!(try body(of: "func noteEditorSave(", in: model)).contains("TypedDocument"), "the value only: no replica is handed over")
        let editor = try source("SlideEditorModel.swift")
        #expect(editor.contains("client.checkout("), "entry checks out the warm replica")
    }

    @Test func anEditorSaveIsOneChange() throws {
        let finish = try body(of: "private func finishMutation()", in: try source("SlideEditorModel.swift"))
        #expect(!finish.contains("noteExternalMutation"), "a kind-wide bump leaves every held document behind")
        for kind in [".presentation", ".theme", ".overlay", ".confidenceLayout"] {
            #expect(finish.contains("appModel.noteEditorSave(of: \(kind),"), "\(kind) saves as one change")
        }
        #expect(finish.contains("appModel.noteDecksRestyled()"), "a theme save restyles decks without changing one")
        let model = try source("AppModel.swift")
        #expect(try body(of: "func noteEditorSave(", in: model).contains("reseedCaches("), "the siblings carry over")
        #expect(try body(of: "func noteDecksRestyled()", in: model).contains("decks.carryOver()"))
    }

    @Test func aMissWritesAndJournalsAsAHit() throws {
        let model = try source("AppModel.swift")

        let slide = "presentationID: String, slideID: String, undoLabel: String?, _ mutate"
        for signature in [
            "_ id: String, scope: String = \"list\",", "presentationID: String, undoLabel: String?, _ mutate",
            "func updatePresentationField<", "func quickEditText(", "func renameSlide(",
            "private func slideWrite(", "private func restoreSlides(", "func addArrangement(_ presentationID: String, then select:",
        ] {
            #expect(try body(of: signature, in: model).contains("withDeck("), "\(signature) goes through withDeck")
        }
        let update = try body(of: slide, in: model)
        #expect(update.contains("slideWrite(") && update.contains("return presentationExists(presentationID)"), "a caller's synchronous answer is the index's")
        #expect(try body(of: "private func restoreSlides(", in: model).contains("-> MoveUndoJournal.Step"))
        #expect(try body(of: "private func journalSlideEdit(", in: model).contains("undoing:"))
        #expect(try body(of: "private func withDeck<", in: model).contains("journal.whileRestoring"), "a deferred restore stays inside the journal's scope")
        #expect(try source("ServiceContinuousView.swift").contains("model.addArrangement(presentation.id) { created in"))
        let bridge = try String(contentsOf: appSources.deletingLastPathComponent()
            .appendingPathComponent("Packages/LocalAPI/Sources/LocalAPI/APIBridge.swift"), encoding: .utf8)
        #expect(bridge.contains("func advance(steps: Int, settled: Bool) async throws"))
        for file in ["KeyboardShortcuts.swift", "MIDIInService.swift"] {
            #expect(try source(file).contains("bridge.advanceIgnoringErrors(steps: 1"), "\(file)")
        }
    }
}
