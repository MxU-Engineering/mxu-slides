import AppKit
import AVFoundation
import Foundation
import Observation
import PPTXImport
import PresenterCore
import ProImport
import RenderEngine
import SlideScene
import struct SwiftUI.Binding
import UniformTypeIdentifiers

typealias MediaTransition = Transition

enum LibrarySection: String, CaseIterable, Identifiable {
    case services = "Services"
    case presentations = "Presentations"
    case overlays = "Overlays"
    case media = "Media"
    case audio = "Audio"
    case themes = "Themes"
    case confidence = "Confidence"

    var id: String { rawValue }

    var kind: DocumentKind {
        switch self {
        case .services: .service
        case .presentations: .presentation
        case .overlays: .overlay
        case .media: .media
        case .audio: .audio
        case .themes: .theme
        case .confidence: .confidenceLayout
        }
    }

    var isBrowseOnly: Bool {
        self == .media || self == .audio
    }

    var playlistKind: PlaylistKind? {
        switch self {
        case .media: .media
        case .audio: .audio
        default: nil
        }
    }

    var displayName: String {
        switch self {
        case .presentations: "Slides"
        case .audio: "Music"
        default: rawValue
        }
    }

    static var libraryTabs: [LibrarySection] {
        allCases.filter { $0 != .services }
    }

    var systemImage: String {
        switch self {
        case .services: "calendar"
        case .presentations: "rectangle.on.rectangle"
        case .overlays: "rectangle.inset.filled.on.rectangle"
        case .media: "photo.on.rectangle.angled"
        case .audio: "waveform"
        case .themes: "paintpalette"
        case .confidence: "text.below.photo"
        }
    }
}

@MainActor
@Observable
final class AppModel {
    let client: LibraryClient
    let importer: MediaImporter?
    let transcodeQueue: TranscodeQueue?

    private(set) var blobs: BlobStore?

    private(set) var posterStore: MediaPosterStore?

    var selectedSection: LibrarySection = .presentations


    var selectedEntryID: String? {
        didSet {
            warmSelectedDeck()
            guard !syncingSelection else { return }
            syncingSelection = true
            selectedEntryIDs = selectedEntryID.map { [$0] } ?? []
            syncingSelection = false
        }
    }

    private(set) var selectedEntryIDs: Set<String> = []

    private var syncingSelection = false

    var protectEditorSelection = false

    var librarySelection: Set<String> {
        get { selectedEntryIDs }
        set {
            syncingSelection = true
            defer { syncingSelection = false }
            selectedEntryIDs = newValue
            if newValue.isEmpty {
                selectedEntryID = nil
            } else if newValue.count == 1 {
                selectedEntryID = newValue.first
            } else if selectedEntryID.map({ !newValue.contains($0) }) ?? true {

                selectedEntryID = newValue.first
            }

            if protectEditorSelection, !newValue.isEmpty, let anchor = selectedEntryID {
                retargetPresentReturn(entryID: anchor)
            }
        }
    }

    private var stashedEditorEntryID: String?

    var pendingEditorSlideID: String?

    var libraryFindPending = false

    func stashEditorSelection() {
        if let id = selectedEntryID { stashedEditorEntryID = id }
    }

    func restoreEditorSelection() {
        guard selectedEntryID == nil, let id = stashedEditorEntryID,
              let entry = libraryEntry(id)
        else { return }
        if let section = LibrarySection.allCases.first(where: { $0.kind == entry.kind }) {
            selectedSection = section
        }
        selectedEntryID = id
    }

    private var stashedPresentSelection: (section: LibrarySection, entryID: String?)?

    func stashPresentSelection() {
        guard stashedPresentSelection == nil else { return }
        stashedPresentSelection = (selectedSection, selectedEntryID)
    }

    func retargetPresentReturn(entryID: String?) {
        stashedPresentSelection = (selectedSection, entryID)
    }

    func restorePresentSelection() {
        defer { stashedPresentSelection = nil }
        guard let stash = stashedPresentSelection else {
            selectedEntryID = nil
            return
        }
        selectedSection = stash.section
        if let id = stash.entryID, libraryEntry(id) != nil {
            selectedEntryID = id
        } else {
            selectedEntryID = nil
        }
    }

    func openInEditor(entryID: String, slideID: String? = nil) {
        guard let entry = libraryEntry(entryID) else { return }

        if !protectEditorSelection { stashPresentSelection() }
        if let section = LibrarySection.allCases.first(where: { $0.kind == entry.kind }) {
            selectedSection = section
        }
        selectedEntryID = entryID
        pendingEditorSlideID = slideID
    }

    func openInPresent(entryID: String, presenting: Bool) {
        if let entry = libraryEntry(entryID) {
            if let section = LibrarySection.allCases.first(where: { $0.kind == entry.kind }) {
                selectedSection = section
            }
            if presenting {
                selectedEntryID = entryID
            } else {
                retargetPresentReturn(entryID: entryID)
            }
        }
    }

    func switchLibrarySection(_ section: LibrarySection) {
        selectedSection = section
        if !(protectEditorSelection && section.isBrowseOnly) {
            selectedEntryID = nil
        }
    }

    var currentServiceID: String? =
        UserDefaults.standard.string(forKey: "currentServiceID") {
        didSet {
            UserDefaults.standard.set(currentServiceID, forKey: "currentServiceID")
            claimRememberedVersion()
            warmLiveSet()
        }
    }

    @ObservationIgnored private var onAirDeckID: String?

    func warmLiveSet() {
        let service = currentServiceID.flatMap { try? self.service($0) }
        decks.pin(ResidentDecks.liveSet(runOfShow: service.map(runOfShow) ?? [], onAir: onAirDeckID))
        client.warmLive(decks.pinned)
    }

    func noteOnAirDeck(_ id: String?) {
        if id != onAirDeckID {
            onAirDeckID = id
            warmLiveSet()
        }
    }

    private func armLiveSetWatch() {
        withObservationTracking {
            _ = tableFills[.service]
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.warmLiveSet()
                self?.armLiveSetWatch()
            }
        }
    }

    func adoptFallbackServiceIfNeeded() {
        let resolves = currentServiceID
            .flatMap { libraryEntry($0) } != nil
        if !resolves {
            currentServiceID = entries(in: .services).first?.id
        }
    }

    private(set) var listVersion = 0

    private(set) var listingVersion = 0

    @ObservationIgnored private var appliedListing: IndexSnapshot?

    @ObservationIgnored let kindVersions = DocumentKindVersions()

    @ObservationIgnored let tableFills = DocumentKindVersions()

    @ObservationIgnored let resident: ResidentLibrary

    @ObservationIgnored let decks: ResidentDecks

    @ObservationIgnored let moveUndo = MoveUndoJournal()

    func version(of kind: DocumentKind) -> Int { kindVersions[kind] }

    func fillVersion(of kind: DocumentKind) -> Int { tableFills[kind] }

    private func noteMutation(_ kind: DocumentKind) {
        kindVersions.bump(kind)
        if listBumpsHeld > 0 {
            listBumpOwed = true
        } else {
            listVersion += 1
        }
    }

    @ObservationIgnored private var listBumpsHeld = 0
    @ObservationIgnored private var listBumpOwed = false

    private func coalescingListBumps<T>(_ body: () -> T) -> T {
        listBumpsHeld += 1
        let result = body()
        listBumpsHeld -= 1
        if listBumpsHeld == 0, listBumpOwed {
            listBumpOwed = false
            listVersion += 1
        }
        return result
    }

    private func noteLibraryWideMutation() {
        kindVersions.bumpAll()
        listVersion += 1
        listingVersion += 1
        decks.libraryWideBump()
        warmRequested = []
        warmLiveSet()
    }

    init() {
        let located = Self.libraryRoot()
        let root = located.url
        client = LibraryClient(rootURL: root)

        resident = ResidentLibrary(source: client.residentFillSource, epochs: kindVersions, fills: tableFills)
        decks = ResidentDecks(source: client.deckBundleSource, epochs: kindVersions, fills: tableFills, library: resident)
        importer = try? MediaImporter(client: client)
        transcodeQueue = try? TranscodeQueue(client: client)
        blobs = try? BlobStore(libraryRoot: root)

        FontActivator.activateStored(libraryRoot: root)
        posterStore = try? MediaPosterStore(libraryRoot: root)
        ThumbnailStore.shared.posterDisk = posterStore
        libraryOpenError = located.error
        client.readSide = self
        armLiveSetWatch()

        let opening = client.start { prepared in try Self.prepareLibrary(prepared, rootURL: root) }
        Task { [weak self] in
            do {
                try await opening.value
                self?.libraryOpened(rootURL: root)
            } catch {
                self?.libraryOpenError = error.localizedDescription
                DiagnosticsStore.shared.note("library.openFailed", detail: "\(error)")
            }
        }
    }

    private static func libraryRoot() -> (url: URL, error: String?) {
        do {
            let support = try FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            return (support.appendingPathComponent("MxU Slides/Library", isDirectory: true), nil)
        } catch {
            return (FileManager.default.temporaryDirectory.appendingPathComponent("MxU Slides/Library", isDirectory: true),
                    error.localizedDescription)
        }
    }

    private(set) var libraryOpenError: String?

    private(set) var isLibraryReady = false
    @ObservationIgnored private var readyWork: [() -> Void] = []

    @ObservationIgnored let batchObservers = LibraryBatchObservers()

    func whenLibraryReady(_ work: @escaping () -> Void) {
        if isLibraryReady {
            work()
        } else {
            readyWork.append(work)
        }
    }

    @LibraryActor private static func prepareLibrary(_ prepared: Library, rootURL root: URL) throws {
        try migrateSongsToLyricsFolder(prepared, rootURL: root)
        try migrateMediaObjectsToShapes(prepared, rootURL: root)
        try migrateAnimationVocabulary(prepared, rootURL: root)
        try migrateCrossfadeDefaults(prepared, rootURL: root)
        migrateStreamDestinations(prepared)
        try backfillContentIndex(prepared, rootURL: root)
        try backfillCCLIIndex(prepared, rootURL: root)
        try seedConfidenceStarters(prepared, rootURL: root)
        try seedChordsStarter(prepared, rootURL: root)
        try seedStarterPacks(prepared, rootURL: root)
        try seedUsageHistory(prepared, rootURL: root)
    }

    private func libraryOpened(rootURL root: URL) {
        noteLibraryWideMutation()

        sweepMediaPosters()
        needsOnboarding = Library.needsOnboarding(rootURL: root, snapshot: client.snapshot)

        Task { [weak self] in
            await self?.warmResidency()
        }
        isLibraryReady = true
        let work = readyWork
        readyWork = []
        for item in work { item() }
    }

    private func warmResidency() async {
        let stages = ResidentLibrary.launchStages(
            setup: { [weak self] in await self?.warmSetupThemes() },
            liveSet: { [weak self] in await self?.warmLiveSetFilled() }
        )
        await resident.warmStaged(stages) { timings in
            DiagnosticsStore.shared.note("residency.stages", detail: ResidencyStageTiming.detail(timings))
        }
    }

    private func warmSetupThemes() async {
        await resident.outputPresets.ready()
        let presetID = UserDefaults.standard.string(forKey: OutputPresetsController.activeKey)
        let preset = presetID.flatMap { resident.outputPresets.value($0) }
        await themesFilled(preset?.assignments.compactMap(\.slideThemeId) ?? [])
    }

    private func warmLiveSetFilled() async {
        warmLiveSet()
        _ = await decks.ready(Array(decks.pinned))
    }

    private(set) var needsOnboarding = false

    var welcomeShowing = false

    func restoreGettingStarted() {
        Task {
            do {
                try await client.restoreWelcomeDeck(serviceDate: Self.isoDate(.now))
                currentServiceID = WelcomeDeck.serviceID
                selectedSection = .presentations
                selectedEntryID = WelcomeDeck.presentationID
            } catch {
                DiagnosticsStore.shared.note("onboarding.restoreFailed", detail: "\(error)")
            }
        }
    }

    func finishOnboarding(includeGettingStarted: Bool) {
        if includeGettingStarted {
            restoreGettingStarted()
        }
        Library.markOnboarded(rootURL: client.rootURL)
        needsOnboarding = false
        DiagnosticsStore.shared.note("onboarding.finished", detail: "gettingStarted=\(includeGettingStarted)")
    }

    @LibraryActor private static func migrateSongsToLyricsFolder(_ prepared: Library, rootURL: URL) throws {
        let marker = rootURL.appendingPathComponent(".migrated-folders-v1")
        guard !FileManager.default.fileExists(atPath: marker.path) else { return }
        for id in try prepared.store.ids(of: .presentation) {
            let document = try prepared.open(Presentation.self, id: id)
            guard document.value.presentationKind == .song, document.value.folder == nil else { continue }
            try document.update { $0.folder = "Lyrics" }
            try prepared.save(document)
        }
        try prepared.rebuildIndex()
        FileManager.default.createFile(atPath: marker.path, contents: nil)
    }

    @LibraryActor private static func migrateMediaObjectsToShapes(_ prepared: Library, rootURL: URL) throws {
        let marker = rootURL.appendingPathComponent(".migrated-media-objects-v1")
        guard !FileManager.default.fileExists(atPath: marker.path) else { return }
        try prepared.normalizeMediaObjects()
        FileManager.default.createFile(atPath: marker.path, contents: nil)
    }

    @LibraryActor private static func migrateCrossfadeDefaults(_ prepared: Library, rootURL: URL) throws {
        let marker = rootURL.appendingPathComponent(".migrated-crossfade-default-v1")
        if !FileManager.default.fileExists(atPath: marker.path) {
            try prepared.migrateCrossfadeDefaults()
            FileManager.default.createFile(atPath: marker.path, contents: nil)
        }
    }

    @LibraryActor private static func migrateAnimationVocabulary(_ prepared: Library, rootURL: URL) throws {
        let marker = rootURL.appendingPathComponent(".migrated-animation-vocabulary-v1")
        guard !FileManager.default.fileExists(atPath: marker.path) else { return }
        try prepared.normalizeAnimationVocabulary()
        FileManager.default.createFile(atPath: marker.path, contents: nil)
    }

    @LibraryActor private static func migrateStreamDestinations(_ prepared: Library) {
        guard let result = try? prepared.migrateStreamDestinations() else { return }
        for sentence in result.dropped {
            DiagnosticsStore.shared.note("stream.destination.migrationDropped", detail: sentence)
        }
    }

    @LibraryActor private static func seedUsageHistory(_ prepared: Library, rootURL: URL) throws {
        let marker = rootURL.appendingPathComponent(".seeded-usage-from-services-v1")
        guard !FileManager.default.fileExists(atPath: marker.path) else { return }
        try prepared.seedUsageFromServices()
        FileManager.default.createFile(atPath: marker.path, contents: nil)
    }

    @LibraryActor private static func seedConfidenceStarters(_ prepared: Library, rootURL: URL) throws {
        let marker = rootURL.appendingPathComponent(".seeded-confidence-starters-v1")
        guard !FileManager.default.fileExists(atPath: marker.path) else { return }
        defer { FileManager.default.createFile(atPath: marker.path, contents: nil) }
        guard try prepared.store.ids(of: .confidenceLayout).isEmpty else { return }
        for template in ConfidenceLayoutTemplate.workspaceStarters {
            try prepared.create(template.make(name: template.starterName))
        }
    }

    @LibraryActor private static func seedStarterPacks(_ prepared: Library, rootURL: URL) throws {

        let earlier = (1...19).map { rootURL.appendingPathComponent(".seeded-starter-packs-v\($0)") }
        let recent = (20...22).map { rootURL.appendingPathComponent(".seeded-starter-packs-v\($0)") }
        let marker = rootURL.appendingPathComponent(".seeded-starter-packs-v23")
        guard !FileManager.default.fileExists(atPath: marker.path) else { return }
        defer { FileManager.default.createFile(atPath: marker.path, contents: nil) }
        let repairV1 = earlier.contains { FileManager.default.fileExists(atPath: $0.path) }
        let gentleRepair = recent.contains { FileManager.default.fileExists(atPath: $0.path) }
        let themes = Set(try prepared.store.ids(of: .theme))
        let overlays = Set(try prepared.store.ids(of: .overlay))
        for pack in StarterPack.allCases {
            let theme = pack.makeTheme()
            if !themes.contains(theme.id) {

                try prepared.create(theme, seed: .init(id: theme.id))
            } else if repairV1 {
                let document = try prepared.open(Theme.self, id: theme.id)
                _ = try document.update { $0.slides = theme.slides }
                try prepared.save(document)
            } else if gentleRepair {
                let document = try prepared.open(Theme.self, id: theme.id)
                let repaired = pack.pagingThirds(pack.addingLyricsDesigns(
                    to: (document.value.slides ?? []).filter { !StarterPack.isGenericPlaceholder($0) }))
                if repaired != document.value.slides {
                    _ = try document.update { $0.slides = repaired }
                    try prepared.save(document)
                }
            }
            if repairV1 {
                for id in pack.retiredThemeIDs where themes.contains(id) {
                    try prepared.delete(kind: .theme, id: id)
                }
            }
            for overlay in pack.makeOverlays() {
                if !overlays.contains(overlay.id) {
                    try prepared.create(overlay, seed: .init(id: overlay.id))
                } else if repairV1 {
                    let document = try prepared.open(Overlay.self, id: overlay.id)
                    _ = try document.update {
                        $0.name = overlay.name; $0.folder = overlay.folder
                        $0.objects = overlay.objects; $0.animationOrder = overlay.animationOrder
                    }
                    try prepared.save(document)
                }
            }
            if repairV1 {
                for item in StarterPack.retiredOverlayItems where overlays.contains(pack.overlayID(item)) {
                    try prepared.delete(kind: .overlay, id: pack.overlayID(item))
                }
            }
        }
    }

    @LibraryActor private static func seedChordsStarter(_ prepared: Library, rootURL: URL) throws {
        let marker = rootURL.appendingPathComponent(".seeded-confidence-starters-v2")
        guard !FileManager.default.fileExists(atPath: marker.path) else { return }
        defer { FileManager.default.createFile(atPath: marker.path, contents: nil) }
        let template = ConfidenceLayoutTemplate.currentOverNextChords
        let existing = try prepared.index.entries(of: .confidenceLayout).map(\.name)
        guard !existing.contains(template.starterName) else { return }
        try prepared.create(template.make(name: template.starterName))
    }

    @LibraryActor private static func backfillContentIndex(_ prepared: Library, rootURL: URL) throws {
        let marker = rootURL.appendingPathComponent(".reindexed-fts2")
        guard !FileManager.default.fileExists(atPath: marker.path) else { return }
        try prepared.rebuildIndex()
        FileManager.default.createFile(atPath: marker.path, contents: nil)
    }

    @LibraryActor private static func backfillCCLIIndex(_ prepared: Library, rootURL: URL) throws {
        let marker = rootURL.appendingPathComponent(".reindexed-ccli1")
        guard !FileManager.default.fileExists(atPath: marker.path) else { return }
        try prepared.rebuildIndex()
        FileManager.default.createFile(atPath: marker.path, contents: nil)
    }

    private var listedSnapshot: IndexSnapshot {
        _ = listingVersion
        return indexSnapshot
    }

    private var indexSnapshot: IndexSnapshot {
        client.snapshot
    }

    private static func inSectionOrder(_ entries: [LibraryIndex.Entry], _ section: LibrarySection) -> [LibraryIndex.Entry] {
        section == .services ? entries.sorted { $0.subkind > $1.subkind } : entries
    }

    func entries(in section: LibrarySection) -> [LibraryIndex.Entry] {
        Self.inSectionOrder(listedSnapshot.entries(of: section.kind), section)
    }

    func entries(of kind: DocumentKind) -> [LibraryIndex.Entry] {
        indexSnapshot.entries(of: kind)
    }

    func search(_ text: String) async -> [LibraryIndex.Hit] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? [] : ((try? await client.search(trimmed)) ?? [])
    }

    func entries(of kind: DocumentKind, subkind: String) -> [LibraryIndex.Entry] {
        indexSnapshot.entries(of: kind, subkind: subkind)
    }

    var upcomingOnly = false {
        didSet {
            listVersion += 1
            listingVersion += 1
            refreshUpcoming()
        }
    }

    private(set) var upcomingIds: Set<String> = []
    @ObservationIgnored private var upcomingTask: Task<Void, Never>?

    func isFiltered(_ section: LibrarySection) -> Bool {
        upcomingOnly && UpcomingUse.kinds.contains(section.kind)
    }

    private func refreshUpcoming() {
        upcomingTask?.cancel()
        guard upcomingOnly else { return }
        let services = UpcomingUse.services(indexSnapshot.entries(of: .service), today: .now)
        let snapshot = indexSnapshot
        upcomingTask = Task { [weak self, client] in
            guard let reader = try? await client.reader() else { return }
            let refs = await reader.loadValues(Service.self, ids: services, project: UpcomingUse.references(of:)).values
            let used = refs.values.reduce(into: Set(services)) { $0.formUnion($1) }
            let decks = used.filter { snapshot.entry(id: $0)?.kind == .presentation }
            let playlists = used.filter { snapshot.entry(id: $0)?.kind == .playlist }
            let deckMedia = await reader.loadValues(Presentation.self, ids: Array(decks), project: { Set(MediaReferences.ids(in: $0)) }).values
            let listMedia = await reader.loadValues(Playlist.self, ids: Array(playlists), project: { Set(MediaReferences.ids(in: $0)) }).values
            let all = (Array(deckMedia.values) + Array(listMedia.values)).reduce(into: used) { $0.formUnion($1) }
            if !Task.isCancelled, let self, self.upcomingIds != all {
                self.upcomingIds = all
                self.listVersion += 1
                self.listingVersion += 1
            }
        }
    }

    private(set) var librarySorts: [LibrarySection: LibrarySort] = Dictionary(uniqueKeysWithValues: LibrarySection.allCases.map { section in
        (section, UserDefaults.standard.string(forKey: LibrarySort.defaultsKey(section: section.rawValue)).flatMap(LibrarySort.init) ?? .name)
    })

    func setSort(_ sort: LibrarySort, for section: LibrarySection) {
        if librarySorts[section] != sort {
            librarySorts[section] = sort
            UserDefaults.standard.set(sort.rawValue, forKey: LibrarySort.defaultsKey(section: section.rawValue))
            listVersion += 1
            listingVersion += 1
        }
    }

    func area(_ kind: DocumentKind, _ id: String) -> LibraryArea {
        _ = listingVersion
        return indexSnapshot.area(kind: kind, id: id) ?? .default
    }

    func noteArea(_ area: LibraryArea, kind: DocumentKind, id: String) {
        client.setArea(area, of: [SyncLedger.Key(kind: kind, id: id)], origin: .landed)
    }

    func guessArea(_ area: LibraryArea, kind: DocumentKind, id: String) {
        client.setAreaIfAbsent(area, of: SyncLedger.Key(kind: kind, id: id))
    }

    @ObservationIgnored var viewedLibraryFolder: LibraryHome.Viewed?

    var libraryRevealID: String?

    var newPlacement: LibraryHome.Placement { .drive(viewing: viewedLibraryFolder) }

    @discardableResult
    func createInDrive<E: DocumentEntity>(_ value: E, folder: String? = nil) -> Task<LibraryBatch, any Error> {
        client.create(filed(value, folder: folder), area: LibraryHome.area(for: E.documentKind))
    }

    @discardableResult
    func createBeside<E: DocumentEntity>(_ value: E, original id: String) -> Task<LibraryBatch, any Error> {
        let kind = E.documentKind
        return client.create(value, area: LibraryHome.area(for: kind) == nil ? nil : area(kind, id))
    }

    private func filed<E: DocumentEntity>(_ value: E, folder: String?) -> E {
        if var foldered = value as? any TeamFolderedEntity,
           let path = LibraryHome.folder(for: E.documentKind, named: folder ?? foldered.folder, viewing: viewedLibraryFolder) {
            foldered.folder = path
            foldered.folderId = teamFolderTree.id(ofPath: path, library: E.documentKind)
            return (foldered as? E) ?? value
        } else {
            return value
        }
    }

    func browserEntries(in section: LibrarySection) -> [LibraryIndex.Entry] {
        let all = (librarySorts[section] ?? .name).ordered(Self.inSectionOrder(listedSnapshot.entries(of: section.kind), section))
        return !isFiltered(section) ? all : all.filter { showFiltersAdmit(id: $0.id, kind: $0.kind) }
    }

    func showFiltersAdmit(id: String, kind: DocumentKind) -> Bool {
        !(upcomingOnly && UpcomingUse.kinds.contains(kind)) || upcomingIds.contains(id)
    }

    func cloudSearch(_ text: String) -> [TeamCloudItem] {
        TeamDriveLogic.cloudMatches(teamCloudItems, query: text).filter { item in
            LibrarySection.libraryTabs.contains { $0.kind == item.kind } && showFiltersAdmit(id: item.id, kind: item.kind)
        }
    }

    var teamCloudItems: [TeamCloudItem] = []
    var teamFolderTree = TeamFolderTree.empty

    func isMediaMissing(mediaID id: String) -> Bool {
        guard let item = media(id) else { return false }
        return isMediaFileMissing(item)
    }

    func cloudItems(in section: LibrarySection, under prefix: [String] = []) -> [TeamCloudItem] {
        let path = prefix.joined(separator: "/")
        let upcoming = upcomingOnly && UpcomingUse.kinds.contains(section.kind)
        return teamCloudItems.filter {
            $0.kind == section.kind && TeamDriveLogic.isUnder($0.folder, prefix: path) && (!upcoming || upcomingIds.contains($0.id))
        }
    }

    func cloudItems(in section: LibrarySection, at prefix: [String]) -> [TeamCloudItem] {
        let path = prefix.joined(separator: "/")
        return cloudItems(in: section).filter { $0.folder == path }
    }

    func renameFolder(in section: LibrarySection, path: [String], to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty, !trimmed.contains("/"), let old = path.last, trimmed != old {
            refileFolder(in: section, from: path) { TeamDriveLogic.renamed(folder: $0, from: path, to: trimmed) }
            listVersion += 1
            listingVersion += 1
        }
    }

    private func refileFolder(in section: LibrarySection, from path: [String], to folder: (String) -> String) {
        let fromPath = path.joined(separator: "/")
        file(entries(in: section).filter { TeamDriveLogic.isUnder($0.subkind, prefix: fromPath) }.compactMap {
            refile($0, folder: folder($0.subkind), area: area($0.kind, $0.id))
        })
        pendingFolders[section.rawValue] = pendingFolders[section.rawValue]?.map {
            TeamDriveLogic.isUnder($0, prefix: fromPath) ? folder($0) : $0
        }
    }

    static let folderableSections: [LibrarySection] = [
        .presentations, .overlays, .media, .audio, .confidence,
    ]

    func folders(in section: LibrarySection) -> [String] {

        let empties = isFiltered(section) ? [] : pendingFolders[section.rawValue] ?? []
        return LibraryBrowseLogic.folders(
            items: browserEntries(in: section), cloudFolders: cloudItems(in: section).map(\.folder), empties: empties)
    }

    func driveFolders(in section: LibrarySection) -> [String] {
        LibraryBrowseLogic.folders(
            items: entries(in: section),
            cloudFolders: teamCloudItems.filter { $0.kind == section.kind }.map(\.folder),
            empties: pendingFolders[section.rawValue] ?? [])
    }

    func childFolders(in section: LibrarySection, under prefix: [String]) -> [(name: String, count: Int)] {

        LibraryBrowseLogic.childFolders(
            folders: folders(in: section),
            held: browserEntries(in: section).map(\.subkind) + cloudItems(in: section).map(\.folder),
            under: prefix)
    }

    func items(in section: LibrarySection, at prefix: [String]) -> [LibraryIndex.Entry] {
        let path = prefix.joined(separator: "/")
        return browserEntries(in: section).filter { $0.subkind == path }
    }

    func moveFolder(in section: LibrarySection, from: [String], into destination: [String]) {
        let fromPath = from.joined(separator: "/")
        let destPath = destination.joined(separator: "/")
        guard !from.isEmpty, destPath != fromPath, !destPath.hasPrefix(fromPath + "/") else { return }
        refileFolder(in: section, from: from) { TeamDriveLogic.rebased(folder: $0, from: from, into: destination) }
    }

    func entriesUnder(in section: LibrarySection, prefix: [String]) -> [LibraryIndex.Entry] {
        let path = prefix.joined(separator: "/")
        return browserEntries(in: section).filter { TeamDriveLogic.isUnder($0.subkind, prefix: path) }
    }

    func moveToFolder(_ entry: LibraryIndex.Entry, folder: String?) {
        file(entry, folder: folder, area: area(entry.kind, entry.id))
    }

    func file(_ entry: LibraryIndex.Entry, folder: String?, area: LibraryArea) {
        if let refile = refile(entry, folder: folder, area: area) {
            file([refile])
        }
    }

    func refile(_ entry: LibraryIndex.Entry, folder: String?, area: LibraryArea) -> LibraryRefile? {
        let value = folder?.isEmpty == true ? nil : folder
        let folderId = area == .team ? value.flatMap { teamFolderTree.id(ofPath: $0, library: entry.kind) } : nil
        return TeamFoldered.kinds.contains(entry.kind)
            ? LibraryRefile(kind: entry.kind, id: entry.id, folder: value, folderId: folderId) : nil
    }

    @discardableResult
    func file(_ refiles: [LibraryRefile]) -> Task<LibraryEngine.Refiled, any Error> {
        let filled = Dictionary(grouping: refiles, by: \.kind).mapValues { Set($0.compactMap(\.folder)) }
        for (key, folders) in pendingFolders {
            guard let done = LibrarySection(rawValue: key).flatMap({ filled[$0.kind] }), !done.isDisjoint(with: folders) else { continue }
            pendingFolders[key] = folders.filter { !done.contains($0) }
        }
        return coalescingListBumps { client.refile(refiles) }
    }

    private(set) var pendingFolders: [String: [String]] =
        (UserDefaults.standard.dictionary(forKey: "pendingLibraryFolders") as? [String: [String]]) ?? [:] {
        didSet { UserDefaults.standard.set(pendingFolders, forKey: "pendingLibraryFolders") }
    }

    func createFolder(_ name: String, in section: LibrarySection) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !folders(in: section).contains(trimmed) else { return }
        pendingFolders[section.rawValue, default: []].append(trimmed)
    }

    func markUsed(_ id: String) {
        client.touchUsage(id: id)
    }

    func addToPlaylist(_ playlistID: String, itemID: String) {
        guard let item = libraryEntry(itemID),
              let refKind: PlaylistRefKind = item.kind == .media ? .media
                  : item.kind == .audio ? .audio : nil
        else { return }
        let entry = PlaylistEntry(id: UUID().uuidString, refKind: refKind, refId: itemID)
        updatePlaylist(playlistID) { $0.entries.append(entry) }
        markUsed(itemID)
    }

    func insertIntoPlaylist(_ playlistID: String, itemID: String, at index: Int) {
        guard let item = libraryEntry(itemID),
              let refKind: PlaylistRefKind = item.kind == .media ? .media
                  : item.kind == .audio ? .audio : nil
        else { return }
        let entry = PlaylistEntry(id: UUID().uuidString, refKind: refKind, refId: itemID)
        updatePlaylist(playlistID) {
            $0.entries.insert(entry, at: min(max(index, 0), $0.entries.count))
        }
        markUsed(itemID)
    }

    func handlePlaylistDrop(
        _ playlistID: String, payloads: [String], beforeEntryID: String?
    ) -> Bool {
        guard let list = try? playlist(playlistID) else { return false }
        let accepted: PlaylistRefKind = (list.playlistKind ?? .audio) == .media ? .media : .audio
        var changed = false
        for payload in payloads {
            if payload.hasPrefix("pltrk::") {
                let parts = payload.components(separatedBy: "::")
                guard parts.count == 3, parts[1] == playlistID else { continue }
                let movingID = parts[2]
                guard movingID != beforeEntryID else { continue }
                updatePlaylist(playlistID) { list in
                    guard let from = list.entries.firstIndex(where: { $0.id == movingID })
                    else { return }
                    let entry = list.entries.remove(at: from)
                    let index = beforeEntryID.flatMap { id in
                        list.entries.firstIndex { $0.id == id }
                    } ?? list.entries.count
                    list.entries.insert(entry, at: min(index, list.entries.count))
                }
                changed = true
            } else if let ref = libraryEntry(payload),
                      (ref.kind == .audio && accepted == .audio)
                          || (ref.kind == .media && accepted == .media) {
                let index = beforeEntryID.flatMap { id in
                    (try? playlist(playlistID))?.entries.firstIndex { $0.id == id }
                } ?? ((try? playlist(playlistID))?.entries.count ?? 0)
                insertIntoPlaylist(playlistID, itemID: payload, at: index)
                changed = true
            }
        }
        return changed
    }

    func removePlaylistEntry(_ playlistID: String, entryID: String) {
        updatePlaylist(playlistID) { $0.entries.removeAll { $0.id == entryID } }
    }

    func movePlaylistEntries(_ playlistID: String, fromOffsets: IndexSet, toOffset: Int) {
        updatePlaylist(playlistID) { $0.entries.move(fromOffsets: fromOffsets, toOffset: toOffset) }
    }

    func flaggedMediaCount() -> Int {
        resident.media.values.filter { $0.fileStatus == .needsTranscode }.count
    }

    private var mediaEffectsCache: [String: [SceneEffect]] = [:]
    private var mediaEffectsCacheVersion = -1
    @ObservationIgnored private var mediaEffectsCacheFill = -1

    func mediaSceneEffects(id: String) -> [SceneEffect] {
        if mediaEffectsCacheVersion != kindVersions[.media] || mediaEffectsCacheFill != tableFills[.media] {
            mediaEffectsCache = [:]
            mediaEffectsCacheVersion = kindVersions[.media]
            mediaEffectsCacheFill = tableFills[.media]
        }
        if let hit = mediaEffectsCache[id] { return hit }
        let value = SlideSceneBuilder.sceneEffects(media(id)?.effects)
        mediaEffectsCache[id] = value
        return value
    }

    func audio(_ id: String) -> AudioItem? {
        resident.audio.value(id)
    }

    func replaceAudioFile(_ id: String, with url: URL) {
        guard let blobs, let hash = try? blobs.store(fileURL: url) else { return }
        let asset = AVURLAsset(url: url)
        Task { @MainActor in
            let duration = try? await asset.load(.duration).seconds
            modify(AudioItem.self, id: id) {
                $0.fileHash = hash
                $0.fileName = url.lastPathComponent
                $0.durationSeconds = duration
            }
        }
    }

    func playlist(_ id: String) throws -> Playlist {
        try Self.resident(resident.playlists.value(id), kind: .playlist, id: id)
    }

    @discardableResult
    func createEntity(in section: LibrarySection) -> String? {
        let id = UUID().uuidString
        switch section {
        case .presentations:
            return createPresentation(named: "Untitled Presentation")
        case .themes:
            createInDrive(Theme(
                id: id, name: "Untitled Theme", fontFamily: "Helvetica Neue",
                fontSize: 96, textColorHex: "#FFFFFF", backgroundColorHex: "#000000",
                slides: Theme.defaultSlides()
            ))
            return id
        case .overlays:
            createInDrive(Overlay(id: id, name: "Untitled Overlay", objects: []))
            return id
        case .confidence:

            var template = ConfidenceLayout.defaultTemplate(name: "Untitled Layout")
            template.id = id
            createInDrive(template)
            return id
        case .services:
            createInDrive(Service(
                id: id, name: "Untitled Service",
                serviceDate: Self.isoDate(.now), items: []
            ))
            return id
        case .media, .audio:
            return nil
        }
    }

    @discardableResult
    func createPresentation(named name: String) -> String? {
        let id = UUID().uuidString

        createInDrive(Presentation(
            id: id, name: name,
            presentationKind: .deck, themeId: "",
            slides: [Slide(id: UUID().uuidString, name: "", objects: [])]
        ))
        return id
    }

    @discardableResult
    func createConfidenceLayout(from template: ConfidenceLayoutTemplate) -> String? {
        let id = UUID().uuidString
        var layout = template.make(name: template.starterName)
        layout.id = id
        createInDrive(layout)
        return id
    }

    @discardableResult
    func createMultiView(
        from template: MultiViewTemplate, sources: [MultiViewTemplate.Source]
    ) -> String? {

        let layout = template.make(name: template.title, sources: sources)
        createInDrive(layout)
        return layout.id
    }

    @discardableResult
    func createLayout(_ layout: ConfidenceLayout, besideID: String) -> String? {
        createBeside(layout, original: besideID)
        return layout.id
    }

    nonisolated static func isoDate(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    @ObservationIgnored private var groupColorsCache: (epoch: Int, fill: Int, colors: [String: String])?

    func presentationExists(_ id: String) -> Bool {
        indexEntry(id) != nil
    }

    func presentation(_ id: String) -> Presentation? {
        if !id.isEmpty, decks.currentValue(id) == nil {
            requestWarm(id)
        }
        return decks.value(id)
    }

    @ObservationIgnored private var warmRequested: [String] = []

    private func requestWarm(_ id: String) {
        if !warmRequested.contains(id) {
            warmRequested.append(id)
            warmRequested.removeFirst(max(0, warmRequested.count - LibraryCacheLimits.standard.warmPerKind))
            client.warm(Presentation.self, ids: [id])
        }
    }

    private func warmSelectedDeck() {
        if let id = selectedEntryID, indexEntry(id)?.kind == .presentation {
            requestWarm(id)
        }
    }

    func noteEditorSave(of kind: DocumentKind, id: String, value: any DocumentEntity) {
        noteMutation(kind)
        reseedCaches(kind: kind, id: id, value: value)
    }

    func noteDecksRestyled() {
        noteMutation(.presentation)
        decks.carryOver()
        rekeyArrangedCache(dropping: nil)
    }

    func presentationsFilled(_ ids: [String]) async -> [String: Presentation] {
        await decks.ready(ids)
    }

    func heldPresentation(_ id: String) -> Presentation? {
        decks.fill([id])
        return decks.currentValue(id)
    }

    @discardableResult
    private func withDeck<T: Sendable>(
        _ id: String, _ body: @escaping @MainActor (Presentation?) -> T
    ) -> ResidentDecks.WriteTurn<T> {
        let journal = moveUndo
        let restoring = journal.isRestoring
        return decks.write(id) { deck in
            if restoring {
                journal.whileRestoring { body(deck) }
            } else {
                body(deck)
            }
        }
    }

    private static func undoStep(_ turn: ResidentDecks.WriteTurn<Bool>) -> MoveUndoJournal.Step {
        switch turn {
        case .now(let applied): .done(applied)
        case .later(let answer): .later(answer)
        }
    }

    func theme(_ id: String) -> Theme? {
        id.isEmpty ? nil : resident.themes.value(id)
    }

    func theme(for slide: Slide, in presentation: Presentation) -> Theme? {
        theme(presentation.themeId(for: slide))
    }

    func themesFilled(_ ids: [String]) async {
        let wanted = Array(Set(ids.filter { !$0.isEmpty && resident.themes.currentValue($0) == nil }))
        if !wanted.isEmpty, !resident.themes.isCovered {
            let epoch = kindVersions[.theme]
            let loaded = (try? await client.loadValues(Theme.self, ids: wanted, priority: .userInitiated))?.values ?? [:]
            if epoch == kindVersions[.theme] {
                for (id, value) in loaded {
                    resident.themes.seed(id: id, value: value)
                }
                tableFills.bump(.theme)
            } else {
                await resident.themes.ready()
            }
        }
    }

    func media(_ id: String) -> MediaItem? {
        resident.media.value(id)
    }

    static func resident<Value>(_ value: Value?, kind: DocumentKind, id: String) throws -> Value {
        if let value {
            return value
        } else {
            throw DocumentStore.StoreError.documentNotFound(kind: kind, id: id)
        }
    }

    @ObservationIgnored private var arrangedCache: [String: [Slide]] = [:]

    func arrangedSlides(_ presentation: Presentation, arrangementId: String?) -> [Slide] {
        let key = "\(presentation.id)|\(kindVersions[.presentation])|\(arrangementId ?? "")"
        if let hit = arrangedCache[key] { return hit }
        let slides = SlideSceneBuilder.arrangedSlides(
            for: presentation, arrangementId: arrangementId
        )
        if decks.currentValue(presentation.id) != nil {
            if arrangedCache.count > 64 { arrangedCache.removeAll() }
            arrangedCache[key] = slides
        }
        return slides
    }

    func entry(_ id: String) -> LibraryIndex.Entry? {
        _ = listVersion
        return indexSnapshot.entry(id: id) ?? pendingEntries[id]
    }

    func indexEntry(_ id: String) -> LibraryIndex.Entry? {
        indexSnapshot.entry(id: id) ?? pendingEntries[id]
    }

    func libraryEntry(_ id: String) -> LibraryIndex.Entry? {
        indexSnapshot.entry(id: id) ?? pendingEntries[id]
    }

    @ObservationIgnored private var pendingEntries: [String: LibraryIndex.Entry] = [:]

    func service(_ id: String) throws -> Service {
        let main = try mainService(id)
        return runningVersion(of: main).map { ServiceVersions.apply($0, to: main) } ?? main
    }

    func mainService(_ id: String) throws -> Service {
        try Self.resident(resident.services.value(id), kind: .service, id: id)
    }

    @ObservationIgnored let machineID: String = {
        if let id = UserDefaults.standard.string(forKey: "machine.id") { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: "machine.id")
        return id
    }()

    @ObservationIgnored var computerName: () -> String = { Host.current().localizedName ?? "This Mac" }

    var rememberedVersionName: String? = UserDefaults.standard.string(forKey: "serviceVersion.lastName") {
        didSet { UserDefaults.standard.set(rememberedVersionName, forKey: "serviceVersion.lastName") }
    }

    func runningVersion(of main: Service) -> ServiceVersion? {
        ServiceVersions.running(main, machineID: machineID, rememberedName: rememberedVersionName)
    }

    func runsVersion(_ serviceID: String) -> Bool {
        (try? mainService(serviceID)).flatMap(runningVersion(of:)) != nil
    }

    func chooseServiceVersion(_ serviceID: String, versionID: String?) {
        guard let main = try? mainService(serviceID) else { return }
        rememberedVersionName = versionID.flatMap { id in main.versions?.first { $0.id == id }?.name }
        let computer = ServiceVersionStation(id: machineID, name: computerName())
        modify(Service.self, id: serviceID) { ServiceVersions.choose(versionID, in: &$0, computer: computer) }
        warmLiveSet()
    }

    func createServiceVersion(_ serviceID: String, name: String) {
        let id = UUID().uuidString
        modify(Service.self, id: serviceID) { ServiceVersions.create(name: name, in: &$0, id: id) }
        chooseServiceVersion(serviceID, versionID: id)
    }

    func renameServiceVersion(_ serviceID: String, versionID: String, name: String) {
        if rememberedVersionName != nil, (try? mainService(serviceID))?.versions?.contains(where: { $0.id == versionID && $0.stations?.contains { $0.id == machineID } == true }) == true {
            rememberedVersionName = name
        }
        modify(Service.self, id: serviceID) { service in
            guard let index = service.versions?.firstIndex(where: { $0.id == versionID }) else { return }
            service.versions?[index].name = name
        }
    }

    func deleteServiceVersion(_ serviceID: String, versionID: String) {
        modify(Service.self, id: serviceID) { service in
            service.versions?.removeAll { $0.id == versionID }
            if service.versions?.isEmpty == true { service.versions = nil }
        }
        warmLiveSet()
    }

    func useMainForServiceItem(_ serviceID: String, itemID: String) {
        guard let versionID = (try? mainService(serviceID)).flatMap(runningVersion(of:))?.id else { return }
        modify(Service.self, id: serviceID) { ServiceVersions.useMain(itemID: itemID, versionID: versionID, in: &$0) }
    }

    func versionChangedItemIDs(_ serviceID: String) -> Set<String> {
        (try? mainService(serviceID)).flatMap(runningVersion(of:)).map(ServiceVersions.changedItemIDs) ?? []
    }

    private func claimRememberedVersion() {
        guard let serviceID = currentServiceID, let main = try? mainService(serviceID),
              let version = runningVersion(of: main),
              version.stations?.contains(where: { $0.id == machineID }) != true else { return }
        chooseServiceVersion(serviceID, versionID: version.id)
    }

    var onServiceEdited: ((String) -> Void)?

    func updateService(_ id: String, _ mutate: @escaping @Sendable (inout Service) -> Void) {
        let before = (try? service(id))?.items ?? []
        if let versionID = (try? mainService(id)).flatMap(runningVersion(of:))?.id {
            modify(Service.self, id: id) { ServiceVersions.edit(&$0, versionID: versionID, mutate) }
        } else {
            modify(Service.self, id: id, mutate)
        }
        let after = (try? service(id))?.items ?? []
        onServiceEdited?(id)

        moveUndo.registerReorder(
            label: "Move Service Item", before: before.map(\.id), after: after.map(\.id)
        ) { [weak self] order in
            guard let self, (libraryEntry(id)) != nil else { return false }
            updateService(id) { $0.items = ListOrder.apply(order, to: $0.items, id: \.id) }
            return true
        }

        if let removal = ListRemoval(before: before, after: after, id: \.id),
           removal.removed.allSatisfy({ $0.element.mxuItemHexId == nil }) {
            moveUndo.registerRemoval(
                label: removal.removed.count == 1 ? "Remove Service Item" : "Remove Service Items",
                removal: removal
            ) { [weak self] change in
                guard let self, (libraryEntry(id)) != nil else { return false }
                updateService(id) { change(&$0.items) }
                return true
            }
        }
    }

    @discardableResult
    func addServiceItem(_ serviceID: String, refID: String) -> Bool {
        if let ref = libraryEntry(refID), let kind = ServiceRunOrder.itemKind(adding: ref.kind) {
            let item = ServiceItem(id: UUID().uuidString, itemKind: kind, name: ref.name, refId: refID)
            updateService(serviceID) { $0.items.append(item) }
            markUsed(refID)
            return true
        } else {
            return false
        }
    }

    func addServiceHeader(_ serviceID: String, name: String) {
        let header = ServiceItem(id: UUID().uuidString, itemKind: .header, name: name, refId: "")
        updateService(serviceID) { $0.items.append(header) }
    }

    func removeServiceItem(_ serviceID: String, itemID: String) {
        updateService(serviceID) { $0.items.removeAll { $0.id == itemID } }
    }

    func runOfShow(_ service: Service) -> [ServiceItem] {
        ServiceRunOrder.visible(service.items, timeHexId: nil, order: nil)
    }

    func fireableItems(_ service: Service) -> [ServiceItem] {
        ServiceRunOrder.fireable(service.items, timeHexId: nil, order: nil)
    }

    @discardableResult
    func writeSyncedService(_ value: Service) -> Task<LibraryBatch, any Error>? {
        if let current = try? mainService(value.id), current == value {
            return nil
        } else {
            return modify(Service.self, id: value.id) { $0 = value }
        }
    }

    func setServiceItemHidden(_ serviceID: String, itemID: String, hidden: Bool) {
        updateService(serviceID) { service in
            guard let index = service.items.firstIndex(where: { $0.id == itemID }) else { return }
            service.items[index].hiddenInPresenter = hidden ? true : nil
        }
    }

    func moveServiceItems(_ serviceID: String, fromOffsets: IndexSet, toOffset: Int) {
        updateService(serviceID) { $0.items.move(fromOffsets: fromOffsets, toOffset: toOffset) }
    }

    func insertServiceItem(_ serviceID: String, refID: String, at index: Int) {
        guard let ref = libraryEntry(refID),
              let kind = ServiceRunOrder.itemKind(adding: ref.kind)
        else { return }
        let item = ServiceItem(id: UUID().uuidString, itemKind: kind, name: ref.name, refId: refID)
        updateService(serviceID) { $0.items.insert(item, at: min(max(index, 0), $0.items.count)) }
        markUsed(refID)
    }

    func addToCurrentService(_ entry: LibraryIndex.Entry) {
        guard let serviceID = currentServiceID else { return }
        addServiceItem(serviceID, refID: entry.id)
    }

    func setServiceHeaderColor(_ serviceID: String, itemID: String, colorHex: String?) {
        updateService(serviceID) {
            guard let index = $0.items.firstIndex(where: { $0.id == itemID }) else { return }
            $0.items[index].colorHex = colorHex
        }
    }

    func setServiceItemArrangement(_ serviceID: String, itemID: String, arrangementID: String?) {
        updateService(serviceID) {
            guard let index = $0.items.firstIndex(where: { $0.id == itemID }) else { return }
            $0.items[index].arrangementId = arrangementID
        }
    }

    func setServiceItemOutputPreset(_ serviceID: String, itemID: String, presetID: String?) {
        updateService(serviceID) {
            guard let index = $0.items.firstIndex(where: { $0.id == itemID }) else { return }
            $0.items[index].outputPresetId = presetID
        }
    }

    @discardableResult
    func updatePresentation(
        _ id: String, _ mutate: @escaping @Sendable (inout Presentation) -> Void
    ) -> Task<LibraryBatch, any Error> {
        updatePresentation(id, scope: "whole", value: mutate) { try $0.update(mutate) }
    }

    @discardableResult
    func updatePresentation(
        _ id: String, scope: String = "list",
        value: @escaping @Sendable (inout Presentation) throws -> Void,
        op: @escaping @LibraryActor @Sendable (TypedDocument<Presentation>) throws -> Void
    ) -> Task<LibraryBatch, any Error> {
        switch withDeck(id, { _ in self.writePresentation(id, scope: scope, value: value, op: op) }) {
        case .now(let written):
            return written
        case .later(let waiting):
            return Task { try await waiting.value.value }
        }
    }

    private func writePresentation(
        _ id: String, scope: String,
        value: @escaping @Sendable (inout Presentation) throws -> Void,
        op: @escaping @LibraryActor @Sendable (TypedDocument<Presentation>) throws -> Void
    ) -> Task<LibraryBatch, any Error> {
        let start = ContinuousClock.now
        let beforeSlides = decks.currentValue(id)?.slides ?? []
        let written = client.edit(Presentation.self, id: id, value: value, op: op)
        let afterSlides = decks.currentValue(id)?.slides ?? []
        let queued = ContinuousClock.now
        Task {
            let outcome = switch await written.result {
            case .success: "landed"
            case .failure(let error): "refused (\(error))"
            }
            DiagnosticsStore.shared.note(
                "presentation.write",
                detail: "\(scope) main=\(start.duration(to: queued)) actor=\(queued.duration(to: .now)) \(outcome)")
        }
        let before = SlideOrder(slides: beforeSlides)
        let after = SlideOrder(slides: afterSlides)

        let restore: (@escaping @Sendable (inout [Slide]) -> Void) -> Bool = { [weak self] change in
            if let self, presentationExists(id) {
                updatePresentation(id, value: { change(&$0.slides) }, op: { try $0.updateSlideList(change) })
                return true
            } else {
                return false
            }
        }
        if let removal = ListRemoval(before: beforeSlides, after: afterSlides, id: \.id) {
            moveUndo.registerRemoval(
                label: removal.removed.count == 1 ? "Delete Slide" : "Delete Slides",
                removal: removal, update: restore
            )
        } else if let insertion = ListInsertion(before: beforeSlides, after: afterSlides, id: \.id) {

            moveUndo.registerInsertion(
                label: insertion.added.count == 1 ? "Add Slide" : "Add Slides",
                insertion: insertion, update: restore
            )
        }

        if before != after, Set(before.ids) == Set(after.ids), before.ids.count == after.ids.count {
            let apply: (SlideOrder) -> Bool = { [weak self] order in
                if let self, presentationExists(id) {
                    updatePresentation(id, value: { $0.slides = order.apply(to: $0.slides) }, op: {
                        try $0.updateSlideList { $0 = order.apply(to: $0) }
                    })
                    return true
                } else {
                    return false
                }
            }
            moveUndo.registerMove(
                label: "Move Slide", undo: { apply(before) }, redo: { apply(after) }
            )
        }
        return written
    }

    @discardableResult
    func updateSlide(
        presentationID: String, slideID: String, undoLabel: String?, _ mutate: @escaping @Sendable (inout Slide) -> Void
    ) -> Bool {
        switch slideWrite(presentationID: presentationID, slideID: slideID, undoLabel: undoLabel, mutate) {
        case .now(let written):
            return written
        case .later:
            return presentationExists(presentationID)
        }
    }

    private func slideWrite(
        presentationID: String, slideID: String, undoLabel: String?, _ mutate: @escaping @Sendable (inout Slide) -> Void
    ) -> ResidentDecks.WriteTurn<Bool> {
        withDeck(presentationID) { held in
            let before = held?.slides.first { $0.id == slideID }
            if let before {
                var after = before
                mutate(&after)
                self.updatePresentation(presentationID, scope: "slide", value: { deck in
                    if let index = deck.slides.firstIndex(where: { $0.id == slideID }) {
                        mutate(&deck.slides[index])
                    }
                }, op: { try $0.updateSlide(id: slideID, mutate) })
                if let undoLabel, before != after {
                    self.journalSlideEdit(presentationID, label: undoLabel, before: [before], after: [after])
                }
            }
            return before != nil
        }
    }

    func updateSlides(
        presentationID: String, undoLabel: String?, _ mutate: @escaping @Sendable (inout Presentation) -> Void
    ) {

        withDeck(presentationID) { current in
            self.updatePresentation(presentationID, scope: "slides", value: mutate) { try $0.updateSlides(mutate) }
            if let undoLabel, let current {
                var next = current
                mutate(&next)

                let edited = current.slides.map(\.id) == next.slides.map(\.id)
                    ? current.slides.indices.filter { current.slides[$0] != next.slides[$0] } : []
                if !edited.isEmpty {
                    self.journalSlideEdit(
                        presentationID, label: undoLabel,
                        before: edited.map { current.slides[$0] }, after: edited.map { next.slides[$0] })
                }
            }
        }
    }

    func updatePresentationField<Field: Codable & Equatable & Sendable>(
        _ presentationID: String, _ keyPath: WritableKeyPath<Presentation, Field?> & Sendable, key: String,
        to value: Field?, undoLabel: String?
    ) {

        withDeck(presentationID) { [weak self] deck in
            if let self {
                let before = deck.map { $0[keyPath: keyPath] }
                updatePresentation(presentationID, scope: "field", value: { $0[keyPath: keyPath] = value }) {
                    try $0.updateField(keyPath, key: key, to: value)
                }
                if let undoLabel, let before, before != value {
                    let apply: (Field?) -> Bool = { [weak self] field in
                        if let self, presentationExists(presentationID) {
                            updatePresentation(presentationID, scope: "field", value: { $0[keyPath: keyPath] = field }) {
                                try $0.updateField(keyPath, key: key, to: field)
                            }
                            return true
                        } else {
                            return false
                        }
                    }
                    moveUndo.registerEdit(
                        key: "\(undoLabel):\(presentationID):\(key)", label: undoLabel,
                        undo: { apply(before) }, redo: { apply(value) }
                    )
                }
            }
        }
    }

    private func journalSlideEdit(_ presentationID: String, label: String, before: [Slide], after: [Slide]) {
        moveUndo.registerEdit(
            key: "\(label):\(presentationID):\(before.map(\.id).joined(separator: ","))", label: label,
            undoing: { [weak self] in self?.restoreSlides(presentationID, to: before) ?? .done(false) },
            redoing: { [weak self] in self?.restoreSlides(presentationID, to: after) ?? .done(false) }
        )
    }

    private func restoreSlides(_ presentationID: String, to slides: [Slide]) -> MoveUndoJournal.Step {
        Self.undoStep(withDeck(presentationID) { deck in
            let held = self.presentationExists(presentationID) ? deck : nil
            let applied = held.map { deck in slides.contains { slide in deck.slides.contains { $0.id == slide.id } } } ?? false
            if applied {
                let restore: @Sendable (inout Presentation) -> Void = { deck in
                    for slide in slides {
                        if let index = deck.slides.firstIndex(where: { $0.id == slide.id }) {
                            deck.slides[index] = slide
                        }
                    }
                }
                self.updatePresentation(presentationID, scope: "slides", value: restore) { try $0.updateSlides(restore) }
            }
            return applied
        })
    }

    func quickEditText(presentationID: String, slideID: String, objectID: String, text: String) {

        withDeck(presentationID) { deck in
            let oldText = deck?.slides.first { $0.id == slideID }?
                .objects.first { $0.id == objectID }?.text
            self.updateSlide(presentationID: presentationID, slideID: slideID, undoLabel: nil) { slide in
                if let object = slide.objects.firstIndex(where: { $0.id == objectID }) {
                    slide.objects[object].text = text
                }
            }
            if let oldText, oldText != text {
                let apply = self.slideFieldRestore(presentationID, slideID: slideID) { value, slide in
                    if let object = slide.objects.firstIndex(where: { $0.id == objectID }) {
                        slide.objects[object].text = value
                    }
                }
                self.moveUndo.registerEdit(
                    key: "quickEdit:\(presentationID):\(slideID):\(objectID)", label: "Edit Text",
                    undoing: { apply(oldText) }, redoing: { apply(text) }
                )
            }
        }
    }

    @discardableResult
    func setSlideBackground(presentationID: String, slideID: String, mediaID: String) -> Bool {
        guard let item = media(mediaID) else { return false }
        let media = CueMedia.droppedOnSlide(for: item)
        updateSlide(presentationID: presentationID, slideID: slideID, undoLabel: "Set Background") {
            $0.background = media
        }
        return true
    }

    func moveSlide(_ presentationID: String, slideID: String, beforeSlideID: String?) {
        updatePresentation(presentationID, value: { SlideBulkEdit.moveSlide(slideID, before: beforeSlideID, in: &$0) }) { document in
            let current = document.value
            var next = current
            SlideBulkEdit.moveSlide(slideID, before: beforeSlideID, in: &next)
            let before = beforeSlideID.flatMap { id in current.slides.firstIndex { $0.id == id } }
            try Self.commitSlideMove(slideID, before: before, current: current, next: next, on: document)
        }
    }

    func moveSlide(_ presentationID: String, slideID: String, afterSlideID: String) {
        updatePresentation(presentationID, value: { SlideBulkEdit.moveSlide(slideID, after: afterSlideID, in: &$0) }) { document in
            let current = document.value
            var next = current
            SlideBulkEdit.moveSlide(slideID, after: afterSlideID, in: &next)

            let before = current.slides.firstIndex { $0.id == afterSlideID }.map { $0 + 1 }
                .flatMap { $0 < current.slides.count ? $0 : nil }
            try Self.commitSlideMove(slideID, before: before, current: current, next: next, on: document)
        }
    }

    @LibraryActor private static func commitSlideMove(
        _ slideID: String, before: Int?, current: Presentation, next: Presentation,
        on document: TypedDocument<Presentation>
    ) throws {
        if let from = current.slides.firstIndex(where: { $0.id == slideID }),
           let moved = next.slides.first(where: { $0.id == slideID }) {
            let fields: [String: ScalarValue?] = moved.sectionId == current.slides[from].sectionId
                ? [:]
                : ["sectionId": moved.sectionId.map { .String($0) }]
            try document.moveListElement(
                listAt: [AnyCodingKey("slides")], from: from, before: before,
                settingOnMoved: fields, next: next)
        }
    }

    @discardableResult
    func copySlide(
        _ slideID: String, from sourceID: String, to destinationID: String,
        beforeSlideID: String? = nil, afterSlideID: String? = nil
    ) -> Bool {
        if sourceID != destinationID, presentationExists(destinationID) {
            let turn = withDeck(sourceID) { source in
                if let slide = source?.slides.first(where: { $0.id == slideID }) {
                    self.placeCopy(of: slide, from: sourceID, to: destinationID, beforeSlideID: beforeSlideID, afterSlideID: afterSlideID)
                    return true
                } else {
                    return false
                }
            }
            switch turn {
            case .now(let copied):
                return copied
            case .later:
                return presentationExists(sourceID)
            }
        } else {
            return false
        }
    }

    private func placeCopy(
        of slide: Slide, from sourceID: String, to destinationID: String, beforeSlideID: String?, afterSlideID: String?
    ) {
        let landing = slide.freshIDCopy()
        DropLatency.awaitingPaint = [landing.id]
        let place: @Sendable (inout Presentation) -> Void = { deck in
            if let afterSlideID {
                SlideBulkEdit.insertSlides([landing], after: afterSlideID, in: &deck)
            } else {
                SlideBulkEdit.insertSlides([landing], before: beforeSlideID, in: &deck)
            }
        }
        updatePresentation(destinationID, value: place) { document in
            var next = document.value
            place(&next)
            try Self.commitSlideInsert([landing.id], next: next, on: document)
        }

        DiagnosticsStore.shared.note(
            "grid.drop.crossDeck", detail: "copied \(sourceID) -> \(destinationID)")
    }

    func renameSlide(_ presentationID: String, slideID: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        withDeck(presentationID) { deck in
            let oldName = deck?.slides.first { $0.id == slideID }?.name
            _ = self.updateSlide(presentationID: presentationID, slideID: slideID, undoLabel: nil) { $0.name = trimmed }
            guard let oldName, oldName != trimmed else { return }
            let apply = self.slideFieldRestore(presentationID, slideID: slideID) { value, slide in slide.name = value }
            self.moveUndo.registerEdit(
                key: "slideName:\(presentationID):\(slideID)", label: "Rename Slide",
                undoing: { apply(oldName) }, redoing: { apply(trimmed) }
            )
        }
    }

    private func slideFieldRestore(
        _ presentationID: String, slideID: String,
        _ write: @escaping @Sendable (String, inout Slide) -> Void
    ) -> (String) -> MoveUndoJournal.Step {
        { [weak self] value in
            guard let self, libraryEntry(presentationID) != nil else { return .done(false) }
            return .done(updateSlide(presentationID: presentationID, slideID: slideID, undoLabel: nil) { write(value, &$0) })
        }
    }

    func insertSlide(_ presentationID: String, slide: Slide, afterSlideID: String?) {
        insertSlides(presentationID, slides: [slide], afterSlideID: afterSlideID)
    }

    func insertSlides(_ presentationID: String, slides: [Slide], afterSlideID: String?) {
        DropLatency.awaitingPaint = Set(slides.map(\.id))
        updatePresentation(presentationID, value: { SlideBulkEdit.insertSlides(slides, after: afterSlideID, in: &$0) }) { document in
            var next = document.value
            SlideBulkEdit.insertSlides(slides, after: afterSlideID, in: &next)
            try Self.commitSlideInsert(slides.map(\.id), next: next, on: document)
        }
    }

    @LibraryActor private static func commitSlideInsert(
        _ slideIDs: [String], next: Presentation, on document: TypedDocument<Presentation>
    ) throws {
        let landed = next.slides.filter { slideIDs.contains($0.id) }
        if let first = landed.first, let index = next.slides.firstIndex(where: { $0.id == first.id }) {
            try document.insertListElements(
                listAt: [AnyCodingKey("slides")], at: index, values: landed, next: next)
        }
    }

    func addArrangement(_ presentationID: String, then select: @escaping @MainActor (Arrangement) -> Void) {
        withDeck(presentationID) { presentation in
            if let presentation, let created = self.addArrangement(presentationID, seededFrom: presentation) {
                select(created)
            }
        }
    }

    @discardableResult
    private func addArrangement(_ presentationID: String, seededFrom presentation: Presentation) -> Arrangement? {
        var seen = Set<String>()
        var ordered: [String] = []
        for slide in presentation.slides {
            guard let sectionId = slide.sectionId, !sectionId.isEmpty,
                  !seen.contains(sectionId),
                  presentation.sections?.contains(where: { $0.id == sectionId }) == true
            else { continue }
            seen.insert(sectionId)
            ordered.append(sectionId)
        }
        guard !ordered.isEmpty else { return nil }
        let arrangement = Arrangement(
            id: UUID().uuidString,
            name: "Arrangement \((presentation.arrangements ?? []).count + 1)",
            sectionIds: ordered
        )
        updatePresentation(presentationID) {
            $0.arrangements = ($0.arrangements ?? []) + [arrangement]
        }
        return arrangement
    }

    func updateArrangement(
        _ presentationID: String, arrangementID: String,
        _ mutate: @escaping @Sendable (inout Arrangement) -> Void
    ) {
        updatePresentation(presentationID) { presentation in
            guard let index = presentation.arrangements?.firstIndex(where: { $0.id == arrangementID })
            else { return }
            mutate(&presentation.arrangements![index])
        }
    }

    func deleteArrangement(_ presentationID: String, arrangementID: String) {
        updatePresentation(presentationID) { presentation in
            presentation.arrangements?.removeAll { $0.id == arrangementID }
            if presentation.defaultArrangementId == arrangementID {
                presentation.defaultArrangementId = nil
            }
        }
    }

    func rename(_ entry: LibraryIndex.Entry, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        switch entry.kind {
        case .presentation: modify(Presentation.self, id: entry.id) { $0.name = trimmed }
        case .service: modify(Service.self, id: entry.id) { $0.name = trimmed }
        case .theme: modify(Theme.self, id: entry.id) { $0.name = trimmed }
        case .media: modify(MediaItem.self, id: entry.id) { $0.name = trimmed }
        case .audio: modify(AudioItem.self, id: entry.id) { $0.name = trimmed }
        case .playlist: modify(Playlist.self, id: entry.id) { $0.name = trimmed }
        case .overlay: modify(Overlay.self, id: entry.id) { $0.name = trimmed }
        case .outputPreset: modify(OutputPreset.self, id: entry.id) { $0.name = trimmed }
        case .alertPreset: modify(AlertPreset.self, id: entry.id) { $0.name = trimmed }
        case .streamRecordPreset:
            modify(StreamRecordPreset.self, id: entry.id) { $0.name = trimmed }
        case .actionCombo: modify(ActionCombo.self, id: entry.id) { $0.name = trimmed }
        case .scheduleTrigger: modify(ScheduleTrigger.self, id: entry.id) { $0.name = trimmed }
        case .confidenceLayout: modify(ConfidenceLayout.self, id: entry.id) { $0.name = trimmed }
        case .midiDevice: modify(MIDIDevice.self, id: entry.id) { $0.name = trimmed }
        case .streamDestination: modify(StreamDestination.self, id: entry.id) { $0.name = trimmed }
        case .note: return 
        case .schedulerBoard, .controlBoard, .groupPalette, .signageBoard, .effectPresetBoard, .animationPresetBoard, .importLedger, .serviceLinkRules, .stationSettings, .slideBuildingSettings, .font, .workspaceSettings: break 
        }

        let oldName = entry.name
        guard trimmed != oldName else { return }
        let apply: (String) -> Bool = { [weak self] value in
            guard let self, let current = libraryEntry(entry.id)
            else { return false }
            rename(current, to: value)
            return true
        }
        moveUndo.registerEdit(
            key: "rename:\(entry.id)", label: "Rename",
            undo: { apply(oldName) }, redo: { apply(trimmed) }
        )
    }

    func delete(_ entry: LibraryIndex.Entry) {
        delete([entry])
    }

    @discardableResult
    func evictLocally(kind: DocumentKind, id: String) -> Task<LibraryBatch, any Error> {
        if kind == .media, let item = media(id) { posterStore?.writeTombstone(item) }
        return client.delete(kind: kind, id: id, origin: .landed)
    }

    func removeBlobs(_ hashes: Set<String>) async -> Int {
        await resident.ready([.media, .audio])
        let named = Set(resident.media.values.map(\.fileHash) + resident.audio.values.map(\.fileHash))
        let removed = hashes.subtracting(named).reduce(0) {
            $0 + (((try? blobs?.remove(hash: $1)) ?? false) == true ? 1 : 0)
        }
        noteBlobsChanged()
        return removed
    }

    private(set) var blobsVersion = 0

    func noteBlobsChanged() {
        blobsVersion += 1
    }

    func delete(_ entries: [LibraryIndex.Entry]) {
        guard !entries.isEmpty else { return }
        for entry in entries {

            if entry.kind == .media, let item = media(entry.id) {
                posterStore?.writeTombstone(item)
            }
            client.delete(kind: entry.kind, id: entry.id)
        }

        Task {
            await client.settled()
            sweepMediaPosters()
        }
        let deleted = Set(entries.map(\.id))
        if let id = selectedEntryID, deleted.contains(id) {
            selectedEntryID = nil
        } else {
            selectedEntryIDs.subtract(deleted)
        }
    }

    func selectedEntries() -> [LibraryIndex.Entry] {
        selectedEntryIDs.compactMap { indexEntry($0) }
    }

    func fileURL(of entry: LibraryIndex.Entry) -> URL? {
        guard let blobs else { return nil }
        switch entry.kind {
        case .media:
            return media(entry.id).flatMap { blobs.url(forHash: $0.fileHash) }
        case .audio:
            return audio(entry.id).flatMap { blobs.url(forHash: $0.fileHash) }
        default:
            return nil
        }
    }

    func isMediaFileMissing(_ item: MediaItem) -> Bool {
        _ = blobsVersion
        guard let blobs else { return false }
        return blobs.url(forHash: item.fileHash) == nil
    }

    @concurrent
    nonisolated private static func mediaReferenceSets(
        reader: LibraryReader, priority: TaskPriority
    ) async -> [Set<String>] {
        func walk<E: DocumentEntity>(
            _ type: E.Type, _ collect: @escaping @Sendable (E) -> Set<String>
        ) async -> [Set<String>] {
            let ids = (try? await reader.ids(of: E.documentKind)) ?? []
            return await reader.loadValues(type, ids: ids, priority: priority, project: collect).values.values
                .filter { !$0.isEmpty }
        }
        var sets = await walk(Presentation.self) { MediaReferences.ids(in: $0) }
        sets += await walk(Overlay.self) { MediaReferences.ids(in: $0) }
        sets += await walk(Theme.self) { MediaReferences.ids(in: $0) }
        sets += await walk(ConfidenceLayout.self) { MediaReferences.ids(in: $0) }
        sets += await walk(Playlist.self) { MediaReferences.ids(in: $0) }
        sets += await walk(Service.self) { MediaReferences.ids(in: $0) }
        sets += await walk(ActionCombo.self) { MediaReferences.ids(in: $0) }
        sets += await walk(ScheduleTrigger.self) { MediaReferences.ids(in: $0) }
        return sets
    }

    func mediaReferenceDocumentCount(of ids: Set<String>) async -> Int {
        if !ids.isEmpty, let reader = try? await client.reader() {
            let sets = await Self.mediaReferenceSets(reader: reader, priority: .userInitiated)
            return sets.filter { !$0.isDisjoint(with: ids) }.count
        } else {
            return 0
        }
    }

    func replaceMediaFile(_ id: String, with url: URL) async -> [String]? {
        guard let blobs, let current = media(id) else { return nil }
        guard let probe = await MediaRelink.probe(url: url),
              let hash = await Task.detached(priority: .userInitiated, operation: {
                  try? blobs.store(fileURL: url)
              }).value
        else { return nil }
        modify(MediaItem.self, id: id) {
            $0.fileHash = hash
            $0.fileName = url.lastPathComponent
            $0.mediaKind = probe.mediaKind
            $0.fileStatus = probe.fileStatus
            $0.statusDetail = probe.statusDetail
            $0.durationSeconds = probe.durationSeconds
            $0.pixelWidth = probe.pixelWidth
            $0.pixelHeight = probe.pixelHeight
        }
        return hash == current.fileHash ? [] : MediaRelink.carriedSettings(of: current)
    }

    func restoreMediaTombstone(_ tombstone: MediaItem, with url: URL) async -> [String]? {
        guard let blobs, let posterStore else { return nil }
        guard let probe = await MediaRelink.probe(url: url),
              let hash = await Task.detached(priority: .userInitiated, operation: {
                  try? blobs.store(fileURL: url)
              }).value
        else { return nil }
        let item = MediaRelink.restored(tombstone: tombstone, hash: hash, fileURL: url, probe: probe)
        guard (try? await client.create(item).value) != nil else { return nil }
        posterStore.removeTombstone(id: item.id)
        sweepMediaPosters()
        return hash == tombstone.fileHash ? [] : MediaRelink.carriedSettings(of: tombstone)
    }

    func restoreMediaReference(id: String, suggestedName: String?, with url: URL) async -> [String]? {
        let tombstone = posterStore?.tombstone(id: id) ?? Self.placeholderTombstone(
            id: id, name: suggestedName
        )
        return await restoreMediaTombstone(tombstone, with: url)
    }

    nonisolated static func placeholderTombstone(id: String, name: String?) -> MediaItem {
        MediaItem(
            id: id, name: name ?? "Deleted media", mediaKind: .video,
            classification: .background, fileHash: "", fileName: "",
            fileStatus: .ready, statusDetail: "", tags: [], favorite: false,
            collections: [], loops: false
        )
    }

    func missingMediaTargets() async -> (missing: [MediaItem], tombstones: [MediaItem]) {
        let entries = indexSnapshot.entries(of: .media)
        let missing = entries.compactMap { media($0.id) }.filter { isMediaFileMissing($0) }
        var tombstones = posterStore?.allTombstones() ?? []
        let known = Set(entries.map(\.id)).union(tombstones.map(\.id))
        var referenced = Set<String>()
        if let reader = try? await client.reader() {
            referenced = await Self.mediaReferenceSets(reader: reader, priority: .userInitiated)
                .reduce(into: Set<String>()) { $0.formUnion($1) }
        }
        for id in referenced.subtracting(known).sorted() {

            guard !id.contains("::") else { continue }
            tombstones.append(Self.placeholderTombstone(id: id, name: nil))
        }
        return (missing, tombstones)
    }

    func locateMissingMedia(in folder: URL) async -> (relinked: Int, restored: Int) {
        guard let blobs else { return (0, 0) }
        let targets = await missingMediaTargets()
        var wantedByHash: [String: MediaItem] = [:]

        for item in targets.missing where !item.fileHash.isEmpty { wantedByHash[item.fileHash] = item }
        for item in targets.tombstones where !item.fileHash.isEmpty { wantedByHash[item.fileHash] = item }
        guard !wantedByHash.isEmpty else { return (0, 0) }
        let wanted = Set(wantedByHash.keys)

        let matches: [String: URL] = await Task.detached(priority: .userInitiated) {
            var found: [String: URL] = [:]
            let keys: [URLResourceKey] = [.isRegularFileKey]
            let enumerator = FileManager.default.enumerator(
                at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
            )
            while let url = enumerator?.nextObject() as? URL {
                guard found.count < wanted.count,
                      (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
                      let type = UTType(filenameExtension: url.pathExtension),
                      type.conforms(to: .image) || type.conforms(to: .movie) || type.conforms(to: .video),
                      let hash = try? BlobStore.sha256(of: url),
                      wanted.contains(hash), found[hash] == nil
                else { continue }
                found[hash] = url
            }
            return found
        }.value

        var relinked = 0, restored = 0
        let missingIds = Set(targets.missing.map(\.id))
        for (hash, url) in matches {
            guard let target = wantedByHash[hash] else { continue }
            if missingIds.contains(target.id) {

                if (await Task.detached(priority: .userInitiated, operation: {
                    try? blobs.store(fileURL: url)
                }).value) != nil {
                    relinked += 1
                }
            } else if await restoreMediaTombstone(target, with: url) != nil {
                restored += 1
            }
        }
        if relinked > 0 { noteMutation(.media) }
        return (relinked, restored)
    }

    func sweepMediaPosters() {
        guard let posterStore else { return }
        let client = client
        Task.detached(priority: .utility) {
            if let reader = try? await client.reader() {
                let existing = Set((try? await reader.ids(of: .media)) ?? [])
                let referenced = await Self.mediaReferenceSets(reader: reader, priority: .utility)
                    .reduce(into: Set<String>()) { $0.formUnion($1) }
                posterStore.sweep(existingMediaIds: existing, referencedIds: referenced)
            }
        }
    }

    func duplicate(_ entry: LibraryIndex.Entry) {

        func copy<E: DocumentEntity>(_ type: E.Type, _ rewrite: @escaping (inout E) -> Void) {
            let id = entry.id
            if var value = currentValue(E.documentKind, id: id) as? E {
                rewrite(&value)
                createBeside(value, original: id)
            } else {
                Task {
                    await client.settled()
                    if var value = try? await client.loadValue(type, id: id) {
                        rewrite(&value)
                        createBeside(value, original: id)
                    }
                }
            }
        }
        let newID = UUID().uuidString
        switch entry.kind {
        case .presentation: copy(Presentation.self) { $0.id = newID; $0.name += " Copy" }
        case .service: copy(Service.self) { $0.id = newID; $0.name += " Copy" }
        case .theme: copy(Theme.self) { $0.id = newID; $0.name += " Copy" }
        case .media: copy(MediaItem.self) { $0.id = newID; $0.name += " Copy" }
        case .audio: copy(AudioItem.self) { $0.id = newID; $0.name += " Copy" }
        case .playlist: copy(Playlist.self) { $0.id = newID; $0.name += " Copy" }
        case .overlay: copy(Overlay.self) { $0.id = newID; $0.name += " Copy" }
        case .outputPreset: copy(OutputPreset.self) { $0.id = newID; $0.name += " Copy" }
        case .alertPreset: copy(AlertPreset.self) { $0.id = newID; $0.name += " Copy" }
        case .streamRecordPreset:
            copy(StreamRecordPreset.self) { $0.id = newID; $0.name += " Copy" }
        case .actionCombo: copy(ActionCombo.self) { $0.id = newID; $0.name += " Copy" }
        case .scheduleTrigger:
            duplicateScheduleTrigger(entry.id)
        case .confidenceLayout: copy(ConfidenceLayout.self) { $0.id = newID; $0.name += " Copy" }
        case .midiDevice: copy(MIDIDevice.self) { $0.id = newID; $0.name += " Copy" }
        case .note: break 

        case .streamDestination: copy(StreamDestination.self) { $0.id = newID; $0.name += " Copy" }
        case .schedulerBoard, .controlBoard, .groupPalette, .signageBoard, .effectPresetBoard, .animationPresetBoard, .importLedger, .serviceLinkRules, .stationSettings, .slideBuildingSettings, .font, .workspaceSettings: break 
        }
    }

    func applyTheme(to presentationID: String, themeID: String, design: String? = nil) {
        Task {
            await resident.ready([.theme])
            let themes = Dictionary(resident.themes.values.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            applyTheme(to: presentationID, themeID: themeID, design: design, themes: themes)
        }
    }

    private func applyTheme(to presentationID: String, themeID: String, design: String?, themes: [String: Theme]) {
        modify(Presentation.self, id: presentationID) { presentation in
            let every = Set(presentation.slides.map(\.id))
            if let design, let theme = themes[themeID] {
                if presentation.slides(every, allFollow: themeID, design: design) {
                    for index in presentation.slides.indices {
                        SlideSceneBuilder.resetThemeOverrides(&presentation.slides[index])
                    }
                } else {
                    presentation.applyTheme(theme, toSlides: every, design: design, themes: themes)
                    presentation.clearSlideThemes()
                    presentation.themeId = themeID
                }
            } else if presentation.themeId == themeID, !presentation.hasSlideThemes {
                guard !themeID.isEmpty else { return }
                for index in presentation.slides.indices {
                    SlideSceneBuilder.resetThemeOverrides(&presentation.slides[index])
                }
            } else if themeID.isEmpty {

                presentation.slides = presentation.slides.map { slide in
                    guard let theme = themes[presentation.themeId(for: slide)] else { return slide }
                    var baked = SlideSceneBuilder.bakedSlide(slide, theme: theme)
                    baked.themeId = nil
                    return baked
                }
                presentation.themeId = ""
            } else {

                presentation.adoptDesignActions(of: themes[themeID], themes: themes)
                presentation.clearSlideThemes()
                presentation.themeId = themeID
            }
        }
    }

    func applyTheme(to presentationID: String, slideIDs: [String], themeID: String, design: String? = nil) {
        Task {
            await resident.ready([.theme])
            let themes = Dictionary(resident.themes.values.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let ids = Set(slideIDs)
            if let theme = themes[themeID] {
                updateSlides(presentationID: presentationID, undoLabel: "Apply Theme") { presentation in
                    if presentation.slides(ids, allFollow: themeID, design: design) {
                        for index in presentation.slides.indices where ids.contains(presentation.slides[index].id) {
                            SlideSceneBuilder.resetThemeOverrides(&presentation.slides[index])
                        }
                    } else {
                        presentation.applyTheme(theme, toSlides: ids, design: design, themes: themes)
                    }
                }
            }
        }
    }

    func presentationHasSlideThemes(_ presentationID: String) -> Bool {
        presentation(presentationID)?.hasSlideThemes ?? false
    }

    @discardableResult
    func createPresentation(
        named name: String, folder: String?, themeId: String,
        slides: [Slide], sections: [PresentationSection], arrangement: Arrangement?,
        inDrive: Bool = true
    ) -> String? {
        var presentation = Presentation(
            id: UUID().uuidString, name: name.isEmpty ? "Slides" : name, presentationKind: .deck,
            themeId: themeId, folder: folder?.isEmpty == false ? folder : nil,
            slides: slides.isEmpty ? [Slide(id: UUID().uuidString, name: "", objects: [])] : slides
        )
        presentation.sections = sections.isEmpty ? nil : sections
        presentation.arrangements = arrangement.map { [$0] }
        presentation.defaultArrangementId = arrangement?.id

        if inDrive {
            createInDrive(presentation, folder: folder)
        } else {
            client.create(presentation)
        }
        return presentation.id
    }

    @discardableResult
    func appendSlides(_ slides: [Slide], sections: [PresentationSection], to presentationID: String) -> Bool {

        if !slides.isEmpty, heldPresentation(presentationID) != nil || presentationExists(presentationID) {
            modify(Presentation.self, id: presentationID) { presentation in
                presentation.slides += slides
                if !sections.isEmpty { presentation.sections = (presentation.sections ?? []) + sections }
            }
            return true
        } else {
            return false
        }
    }

    @discardableResult
    func rewriteSlides(in presentationID: String, _ mutate: @escaping @Sendable (inout Presentation) -> Void) -> Presentation? {
        if var fresh = heldPresentation(presentationID) {
            mutate(&fresh)

            modify(Presentation.self, id: presentationID, mutate)
            return fresh
        } else {
            if presentationExists(presentationID) {
                modify(Presentation.self, id: presentationID, mutate)
            }
            return nil
        }
    }

    func setKeepWords(_ keep: Bool, presentationID: String, slideID: String) {
        rewriteSlides(in: presentationID) { presentation in
            guard let index = presentation.slides.firstIndex(where: { $0.id == slideID }) else { return }
            presentation.slides[index].keepWords = keep ? true : nil
        }
    }

    func restoreSlideVersion(_ version: SlideVersion, presentationID: String, slideID: String, now: Date = .now) {
        rewriteSlides(in: presentationID) { presentation in
            guard let index = presentation.slides.firstIndex(where: { $0.id == slideID }) else { return }
            presentation.slides[index] = SlideHistory.restoring(
                version, onto: presentation.slides[index], at: ISO8601DateFormatter().string(from: now))
        }
    }

    @discardableResult
    func updateSlides(in presentationID: String, updated: [Slide], appending: [Slide], removing: Set<String>) -> Bool {
        let held = heldPresentation(presentationID) != nil || presentationExists(presentationID)
        if held {
            modify(Presentation.self, id: presentationID) { presentation in
            let byId = Dictionary(updated.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            var lastIndex: Int?
            for index in presentation.slides.indices {
                if let replacement = byId[presentation.slides[index].id] {
                    presentation.slides[index] = replacement
                    lastIndex = index
                }
            }
            if !appending.isEmpty {
                presentation.slides.insert(contentsOf: appending, at: lastIndex.map { $0 + 1 } ?? presentation.slides.count)
            }
            presentation.slides.removeAll { removing.contains($0.id) }
            }
        }
        return held
    }

    private(set) var multiViewIDs: Set<String> = []
    @ObservationIgnored private var multiViewIDsEpoch: Int?
    @ObservationIgnored private var multiViewIDsFilling = false

    func isMultiView(_ layoutID: String) -> Bool {
        let epoch = kindVersions[.confidenceLayout]
        if multiViewIDsEpoch != epoch, !multiViewIDsFilling {
            multiViewIDsFilling = true
            let entries = indexSnapshot.entries(of: .confidenceLayout)
            let client = client
            Task { @MainActor [weak self] in
                var ids: Set<String> = []
                for entry in entries {
                    if let layout = await ThumbnailStore.shared.faceValue(
                        ConfidenceLayout.self, id: entry.id,
                        updatedAt: entry.updatedAt.timeIntervalSince1970, client: client),
                       layout.multiView != nil {
                        ids.insert(entry.id)
                    }
                }
                if let self {
                    self.multiViewIDs = ids
                    self.multiViewIDsEpoch = epoch
                    self.multiViewIDsFilling = false
                }
            }
        }
        return multiViewIDs.contains(layoutID)
    }

    func themeID(of presentationID: String) -> String {
        presentation(presentationID)?.themeId ?? ""
    }

    func presentationHasLocalEdits(_ presentationID: String) -> Bool {
        guard let slides = presentation(presentationID)?.slides
        else { return false }
        return slides.contains(where: SlideSceneBuilder.hasThemeOverrides)
    }

    func applyThemeToAllPresentations(_ themeID: String) {
        for entry in indexSnapshot.entries(of: .presentation) {
            modify(Presentation.self, id: entry.id) { $0.themeId = themeID }
        }
    }

    func updateMedia(_ id: String, _ mutate: @escaping @Sendable (inout MediaItem) -> Void) {
        modify(MediaItem.self, id: id, mutate)
    }

    func overlay(_ id: String) -> Overlay? {
        resident.overlays.value(id)
    }

    func updateOverlay(_ id: String, _ mutate: @escaping @Sendable (inout Overlay) -> Void) {
        modify(Overlay.self, id: id, mutate)
    }

    func updateTheme(_ id: String, _ mutate: @escaping @Sendable (inout Theme) -> Void) {
        modify(Theme.self, id: id, mutate)
    }

    func updateAudio(_ id: String, _ mutate: @escaping @Sendable (inout AudioItem) -> Void) {
        modify(AudioItem.self, id: id, mutate)
    }

    func updatePlaylist(_ id: String, _ mutate: @escaping @Sendable (inout Playlist) -> Void) {
        let before = (try? playlist(id))?.entries.map(\.id) ?? []
        modify(Playlist.self, id: id, mutate)
        let after = (try? playlist(id))?.entries.map(\.id) ?? []

        moveUndo.registerReorder(label: "Move Track", before: before, after: after) {
            [weak self] order in
            guard let self, (libraryEntry(id)) != nil else { return false }
            updatePlaylist(id) { $0.entries = ListOrder.apply(order, to: $0.entries, id: \.id) }
            return true
        }
    }

    func playlists(in section: LibrarySection) -> [LibraryIndex.Entry] {
        guard let kind = section.playlistKind else { return [] }
        return listedSnapshot.entries(of: .playlist, subkind: kind.rawValue)
    }

    @discardableResult
    func createPlaylist(in section: LibrarySection) -> String? {
        guard let kind = section.playlistKind else { return nil }
        let id = UUID().uuidString
        createInDrive(Playlist(
            id: id,
            name: "Untitled \(kind == .media ? "Media" : "Music") Playlist",
            playlistKind: kind, entries: [],
            playbackMode: .playAll
        ))
        return id
    }

    var alertPresets: [LibraryIndex.Entry] {
        listedSnapshot.entries(of: .alertPreset)
    }

    func alertPreset(_ id: String) throws -> AlertPreset {
        try Self.resident(resident.alertPresets.value(id), kind: .alertPreset, id: id)
    }

    @discardableResult
    func createAlertPreset(
        message: String, behavior: AlertBehavior,
        target: AlertTarget, themeId: String?
    ) -> String? {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let id = UUID().uuidString

        client.create(AlertPreset(
            id: id, name: trimmed, message: trimmed, behavior: behavior,
            target: target == .confidence ? nil : target,
            themeId: themeId
        ))
        return id
    }

    func updateAlertPreset(_ id: String, _ mutate: @escaping @Sendable (inout AlertPreset) -> Void) {
        updateAlertPresetNow(id, mutate)
    }

    private func updateAlertPresetNow(_ id: String, _ mutate: @escaping @Sendable (inout AlertPreset) -> Void) {
        let before = (try? alertPreset(id)).map { (name: $0.name, message: $0.message) }
        modify(AlertPreset.self, id: id, mutate)
        let after = (try? alertPreset(id)).map { (name: $0.name, message: $0.message) }

        guard let before, let after, before != after else { return }
        let apply: ((name: String, message: String)) -> Bool = { [weak self] value in
            guard let self, (libraryEntry(id)) != nil else { return false }
            updateAlertPreset(id) {
                $0.name = value.name
                $0.message = value.message
            }
            return true
        }
        moveUndo.registerEdit(
            key: "alertText:\(id)", label: "Edit Alert",
            undo: { apply(before) }, redo: { apply(after) }
        )
    }

    var streamPresets: [LibraryIndex.Entry] {
        _ = kindVersions[.streamRecordPreset]
        return entries(of: .streamRecordPreset)
    }

    func streamPreset(_ id: String) throws -> StreamRecordPreset {
        try Self.resident(resident.streamPresets.value(id), kind: .streamRecordPreset, id: id)
    }

    @discardableResult
    func createStreamPreset(name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let id = UUID().uuidString
        client.create(StreamRecordPreset(id: id, name: trimmed, destinations: []))
        return id
    }

    func updateStreamPreset(_ id: String, _ mutate: @escaping @Sendable (inout StreamRecordPreset) -> Void) {
        let before = try? streamPreset(id)
        modify(StreamRecordPreset.self, id: id, mutate)
        guard let value = try? streamPreset(id) else { return }

        guard let before, before != value else { return }
        let apply: (StreamRecordPreset) -> Bool = { [weak self] snapshot in
            guard let self, (libraryEntry(id)) != nil else { return false }
            updateStreamPreset(id) { $0 = snapshot }
            return true
        }
        moveUndo.registerEdit(
            key: "streamPreset:\(id)", label: "Edit Stream Preset",
            undo: { apply(before) }, redo: { apply(value) }
        )
    }

    func deleteStreamPreset(_ id: String) {
        client.delete(kind: .streamRecordPreset, id: id)
    }

    var streamDestinations: [LibraryIndex.Entry] {
        _ = kindVersions[.streamDestination]
        return entries(of: .streamDestination)
    }

    func streamDestination(_ id: String) -> StreamDestination? {
        resident.streamDestinations.value(id)
    }

    var allStreamDestinations: [StreamDestination] {
        streamDestinations.compactMap { streamDestination($0.id) }
    }

    func resolvedStreamDestination(_ id: String) -> StreamDestination? {
        streamDestination(id)
    }

    func saveStreamDestination(_ destination: StreamDestination) {
        if indexEntry(destination.id) != nil || streamDestination(destination.id) != nil {
            modify(StreamDestination.self, id: destination.id) { $0 = destination }
        } else {
            client.create(destination)
        }
    }

    func updateStreamDestination(_ id: String, _ mutate: @escaping @Sendable (inout StreamDestination) -> Void) {
        modify(StreamDestination.self, id: id, mutate)
    }

    func deleteStreamDestination(_ id: String) {
        client.delete(kind: .streamDestination, id: id)
        for presetID in presetsUsingStreamDestination(id) {
            updateStreamPreset(presetID) { $0.destinationIds?.removeAll { $0 == id } }
        }
    }

    func presetsUsingStreamDestination(_ id: String) -> [String] {
        streamPresets.compactMap { entry in
            guard let preset = try? streamPreset(entry.id),
                  preset.destinationIds?.contains(id) == true else { return nil }
            return entry.id
        }
    }

    var actionCombos: [LibraryIndex.Entry] {
        listedSnapshot.entries(of: .actionCombo)
    }

    func actionCombo(_ id: String) throws -> ActionCombo {
        try Self.resident(resident.actionCombos.value(id), kind: .actionCombo, id: id)
    }

    @discardableResult
    func createActionCombo(name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let id = UUID().uuidString
        client.create(ActionCombo(id: id, name: trimmed, actions: []))
        return id
    }

    func updateActionCombo(_ id: String, _ mutate: @escaping @Sendable (inout ActionCombo) -> Void) {
        modify(ActionCombo.self, id: id, mutate)
    }

    func deleteActionCombo(_ id: String) {
        client.delete(kind: .actionCombo, id: id)
    }

    var scheduleTriggers: [LibraryIndex.Entry] {
        listedSnapshot.entries(of: .scheduleTrigger)
    }

    func scheduleTrigger(_ id: String) throws -> ScheduleTrigger {
        try Self.resident(resident.scheduleTriggers.value(id), kind: .scheduleTrigger, id: id)
    }

    var residentScheduleTriggers: [ScheduleTrigger] {
        resident.scheduleTriggers.values.sorted { ($0.name, $0.id) < ($1.name, $1.id) }
    }

    @discardableResult
    func createScheduleTrigger(
        name: String, conditions: [ScheduleCondition] = [], actions: [SlideAction] = []
    ) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let id = UUID().uuidString
        client.create(ScheduleTrigger(id: id, name: trimmed, conditions: conditions, actions: actions))
        reconcileSchedulerBoard()
        return id
    }

    func updateScheduleTrigger(_ id: String, _ mutate: @escaping @Sendable (inout ScheduleTrigger) -> Void) {
        updateScheduleTriggerNow(id, mutate)
    }

    private func updateScheduleTriggerNow(_ id: String, _ mutate: @escaping @Sendable (inout ScheduleTrigger) -> Void) {
        let before = (try? scheduleTrigger(id))?.name
        modify(ScheduleTrigger.self, id: id, mutate)
        let after = (try? scheduleTrigger(id))?.name

        guard let before, let after, before != after else { return }
        let apply: (String) -> Bool = { [weak self] value in
            guard let self, (libraryEntry(id)) != nil else { return false }
            updateScheduleTrigger(id) { $0.name = value }
            return true
        }
        moveUndo.registerEdit(
            key: "triggerName:\(id)", label: "Rename Trigger",
            undo: { apply(before) }, redo: { apply(after) }
        )
    }

    @discardableResult
    func duplicateScheduleTrigger(
        _ id: String, placeBesideOriginal: Bool = true
    ) -> String? {

        guard var value = try? scheduleTrigger(id)
        else { return nil }
        let newID = UUID().uuidString
        value.id = newID
        value.name += " Copy"
        value.enabled = false

        value.archived = nil
        createBeside(value, original: id)
        if placeBesideOriginal {
            updateSchedulerBoard { $0.placeTrigger(id: newID, afterSibling: id) }
        }
        return newID
    }

    func duplicateScheduleFolder(_ folderID: String) {
        guard let folder = schedulerBoard.folder(id: folderID) else { return }
        let copies = folder.triggerIds.compactMap {
            duplicateScheduleTrigger($0, placeBesideOriginal: false)
        }
        let copyID = UUID().uuidString
        updateSchedulerBoard { $0.duplicateFolder(id: folderID, memberIDs: copies, copyID: copyID) }
    }

    func deleteScheduleTrigger(_ id: String) {
        client.delete(kind: .scheduleTrigger, id: id)
        reconcileSchedulerBoard()
    }

    private func reconcileSchedulerBoard() {
        if let reader = client.readerNow {
            updateSchedulerBoard { $0.reconcile(withTriggerIDs: (try? reader.idsNow(of: .scheduleTrigger)) ?? []) }
        }
    }

    var schedulerBoard: SchedulerBoard {
        var board = resident.schedulerBoards.value(SchedulerBoard.wellKnownID)
            ?? SchedulerBoard(id: SchedulerBoard.wellKnownID, nodes: [], folders: [])
        board.reconcile(withTriggerIDs: resident.scheduleTriggers.ids.sorted())
        return board
    }

    func updateSchedulerBoard(_ mutate: @escaping @Sendable (inout SchedulerBoard) -> Void) {
        let stored = resident.schedulerBoards.value(SchedulerBoard.wellKnownID)
        var board = stored ?? SchedulerBoard(id: SchedulerBoard.wellKnownID, nodes: [], folders: [])
        let before = board.orderSnapshot
        let beforeNames = Self.folderNames(board.folders.map { ($0.id, $0.name) })
        mutate(&board)
        let after = board.orderSnapshot
        let afterNames = Self.folderNames(board.folders.map { ($0.id, $0.name) })
        let written = client.modify(
            SchedulerBoard.self, id: SchedulerBoard.wellKnownID,
            orMake: { SchedulerBoard(id: SchedulerBoard.wellKnownID, nodes: [], folders: []) }, mutate)
        Task {
            if case .failure(let error) = await written.result {
                DiagnosticsStore.shared.note("scheduler.board.saveFailed", detail: "\(error)")
            }
        }
        guard stored != nil else { return }

        moveUndo.registerBoardMove(label: "Move Trigger", before: before, after: after) {
            [weak self] order in
            guard let self else { return false }
            let applied = !order.membership.isDisjoint(with: schedulerBoard.orderSnapshot.membership)
            if applied {
                updateSchedulerBoard { board in
                    if !order.membership.isDisjoint(with: board.orderSnapshot.membership) {
                        board.restore(order: order)
                    }
                }
            }
            return applied
        }

        registerFolderRenames(
            key: "schedFolderNames", before: beforeNames, after: afterNames
        ) { [weak self] names in
            guard let self else { return false }
            let applied = names.keys.contains { self.schedulerBoard.folder(id: $0) != nil }
            if applied {
                updateSchedulerBoard { board in
                    for (folderID, name) in names where board.folder(id: folderID) != nil {
                        board.renameFolder(id: folderID, to: name)
                    }
                }
            }
            return applied
        }
    }

    private static func folderNames(_ folders: [(String, String)]) -> [String: String] {
        Dictionary(folders, uniquingKeysWith: { first, _ in first })
    }

    private func registerFolderRenames(
        key: String, before: [String: String]?, after: [String: String]?,
        write: @escaping ([String: String]) -> Bool
    ) {
        guard let before, let after, before != after,
              Set(before.keys) == Set(after.keys) else { return }
        moveUndo.registerEdit(
            key: key, label: "Rename Folder",
            undo: { write(before) }, redo: { write(after) }
        )
    }

    var groupPalette: GroupPalette {
        resident.groupPalettes.value(GroupPalette.wellKnownID) ?? GroupPalette.defaults
    }

    var serviceLinkRules: ServiceLinkRules {
        ServiceLinkLogic.merged(
            team: resident.serviceLinkRules.value(ServiceLinkRules.teamID)?.rules ?? [],
            own: resident.serviceLinkRules.value(ServiceLinkRules.wellKnownID)?.rules ?? [])
    }

    func updateServiceLinkRules(_ mutate: @escaping @Sendable (inout ServiceLinkRules) -> Void) {
        let written = client.modify(
            ServiceLinkRules.self, id: ServiceLinkRules.teamID,
            orMake: { ServiceLinkRules(id: ServiceLinkRules.teamID, rules: []) }, seeded: true, area: .team, mutate)
        Task {
            if case .failure(let error) = await written.result {
                DiagnosticsStore.shared.note("serviceLinkRules.saveFailed", detail: "\(error)")
            }
        }
    }

    var slideBuilding: SlideBuildingSettings {
        SlideBuildingSettings.effective(
            document: resident.slideBuildingSettings.value(SlideBuildingSettings.wellKnownID),
            defaults: .fromDefaults(.standard))
    }

    func updateSlideBuilding(_ mutate: @escaping @Sendable (inout SlideBuildingSettings) -> Void) {
        let own = SlideBuildingSettings.fromDefaults(.standard)
        let written = client.modify(
            SlideBuildingSettings.self, id: SlideBuildingSettings.wellKnownID,
            orMake: { SlideBuildingSettings(id: SlideBuildingSettings.wellKnownID) }, seeded: true, area: .team
        ) { settings in
            settings.fillUnset(from: own)
            mutate(&settings)
        }
        Task {
            if case .failure(let error) = await written.result {
                DiagnosticsStore.shared.note("slideBuilding.saveFailed", detail: "\(error)")
            }
        }
    }

    func slideBuildingBinding(_ keyPath: WritableKeyPath<SlideBuildingSettings, String?> & Sendable) -> Binding<String> {
        Binding(
            get: { self.slideBuilding[keyPath: keyPath] ?? "" },
            set: { value in self.updateSlideBuilding { $0[keyPath: keyPath] = value.isEmpty ? nil : value } })
    }

    func removeServiceLinkRule(itemName: String, serviceTypeName: String?) {
        updateServiceLinkRules { ServiceLinkLogic.removeRule(from: &$0, itemName: itemName, serviceTypeName: serviceTypeName) }
        if resident.serviceLinkRules.value(ServiceLinkRules.wellKnownID) != nil {
            updateWellKnown(
                ServiceLinkRules.self, id: ServiceLinkRules.wellKnownID, failure: "serviceLinkRules.saveFailed",
                orMake: { ServiceLinkRules(id: ServiceLinkRules.wellKnownID, rules: []) }) {
                    ServiceLinkLogic.removeRule(from: &$0, itemName: itemName, serviceTypeName: serviceTypeName)
                }
        }
    }

    @discardableResult
    private func updateWellKnown<E: DocumentEntity>(
        _ type: E.Type, id: String, failure: String,
        orMake make: @escaping @Sendable () -> E, _ mutate: @escaping @Sendable (inout E) -> Void
    ) -> Task<LibraryBatch, any Error> {
        let written = client.modify(type, id: id, orMake: make, mutate)
        Task {
            if case .failure(let error) = await written.result {
                DiagnosticsStore.shared.note(failure, detail: "\(error)")
            }
        }
        return written
    }

    func updateGroupPalette(_ mutate: @escaping @Sendable (inout GroupPalette) -> Void) {

        updateWellKnown(
            GroupPalette.self, id: GroupPalette.wellKnownID, failure: "groupPalette.saveFailed",
            orMake: { GroupPalette.defaults }, mutate)
    }

    var effectPresetBoard: EffectPresetBoard {
        resident.effectPresetBoards.value(EffectPresetBoard.wellKnownID)
            ?? EffectPresetBoard(id: EffectPresetBoard.wellKnownID, presets: [])
    }

    func updateEffectPresetBoard(_ mutate: @escaping @Sendable (inout EffectPresetBoard) -> Void) {
        updateWellKnown(
            EffectPresetBoard.self, id: EffectPresetBoard.wellKnownID, failure: "effectPresets.saveFailed",
            orMake: { EffectPresetBoard(id: EffectPresetBoard.wellKnownID, presets: []) }, mutate)
    }

    func saveEffectPreset(name: String, effects: [Effect]) {
        let preset = EffectPreset(id: UUID().uuidString, name: name, effects: effects)
        updateEffectPresetBoard { board in
            board.presets.append(preset)
        }
    }

    func overwriteEffectPreset(id: String, effects: [Effect]) {
        updateEffectPresetBoard { board in
            guard let index = board.presets.firstIndex(where: { $0.id == id }) else { return }
            board.presets[index].effects = effects
        }
    }

    func deleteEffectPreset(id: String) {
        updateEffectPresetBoard { board in
            board.presets.removeAll { $0.id == id }
        }
    }

    var animationPresetBoard: AnimationPresetBoard {
        resident.animationPresetBoards.value(AnimationPresetBoard.wellKnownID)
            ?? AnimationPresetBoard(id: AnimationPresetBoard.wellKnownID, presets: [])
    }

    func updateAnimationPresetBoard(_ mutate: @escaping @Sendable (inout AnimationPresetBoard) -> Void) {
        updateWellKnown(
            AnimationPresetBoard.self, id: AnimationPresetBoard.wellKnownID, failure: "animationPresets.saveFailed",
            orMake: { AnimationPresetBoard(id: AnimationPresetBoard.wellKnownID, presets: []) }, mutate)
    }

    func saveAnimationPreset(name: String, steps: [AnimationStep], scroll: BlockScroll? = nil, tilt: Double? = nil) {
        let preset = AnimationPreset(id: UUID().uuidString, name: name, steps: steps, scroll: scroll, tilt: tilt)
        updateAnimationPresetBoard { board in
            board.presets.append(preset)
        }
    }

    func overwriteAnimationPreset(id: String, steps: [AnimationStep], scroll: BlockScroll? = nil, tilt: Double? = nil) {
        updateAnimationPresetBoard { board in
            guard let index = board.presets.firstIndex(where: { $0.id == id }) else { return }
            board.presets[index].steps = steps
            board.presets[index].scroll = scroll
            board.presets[index].tilt = tilt
        }
    }

    func deleteAnimationPreset(id: String) {
        updateAnimationPresetBoard { board in
            board.presets.removeAll { $0.id == id }
        }
    }

    static let stockAnimationDefaultIn = AnimationStep(
        id: "", kind: .in, animation: .fade, trigger: .onClick, durationSeconds: 0.5
    )
    static let stockAnimationDefaultOut = AnimationStep(
        id: "", kind: .out, animation: .fade, trigger: .onDismiss, durationSeconds: 0.4
    )

    var animationDefaultIn: AnimationStep {
        animationPresetBoard.defaultIn ?? Self.stockAnimationDefaultIn
    }

    var animationDefaultOut: AnimationStep {
        animationPresetBoard.defaultOut ?? Self.stockAnimationDefaultOut
    }

    func setAnimationDefault(in step: AnimationStep?) {
        updateAnimationPresetBoard { $0.defaultIn = step }
    }

    func setAnimationDefault(out step: AnimationStep?) {
        updateAnimationPresetBoard { $0.defaultOut = step }
    }

    var groupColors: [String: String] {
        let epoch = kindVersions[.groupPalette]
        let fill = tableFills[.groupPalette]
        if let cached = groupColorsCache, cached.epoch == epoch, cached.fill == fill {
            return cached.colors
        } else {
            let colors = groupPalette.colorsByNormalizedName
            groupColorsCache = (epoch, fill, colors)
            return colors
        }
    }

    var signageBoard: SignageBoard {
        resident.signageBoards.value(SignageBoard.wellKnownID)
            ?? SignageBoard(id: SignageBoard.wellKnownID, signages: [])
    }

    func updateSignageBoard(_ mutate: @escaping @Sendable (inout SignageBoard) -> Void) {
        updateWellKnown(
            SignageBoard.self, id: SignageBoard.wellKnownID, failure: "signageBoard.saveFailed",
            orMake: { SignageBoard(id: SignageBoard.wellKnownID, signages: []) }, mutate)
    }

    var comboBoard: ControlBoard {
        controlBoard(id: ControlBoard.comboBoardID, itemIDs: boardItemIDs(of: .actionCombo))
    }

    var alertBoard: ControlBoard {
        controlBoard(id: ControlBoard.alertBoardID, itemIDs: boardItemIDs(of: .alertPreset))
    }

    var streamBoard: ControlBoard {
        controlBoard(id: ControlBoard.streamBoardID, itemIDs: boardItemIDs(of: .streamRecordPreset))
    }

    func updateComboBoard(_ mutate: @escaping @Sendable (inout ControlBoard) -> Void) {
        updateControlBoard(
            id: ControlBoard.comboBoardID, itemIDs: boardItemIDs(of: .actionCombo), mutate)
    }

    func updateAlertBoard(_ mutate: @escaping @Sendable (inout ControlBoard) -> Void) {
        updateControlBoard(
            id: ControlBoard.alertBoardID, itemIDs: boardItemIDs(of: .alertPreset), mutate)
    }

    func updateStreamBoard(_ mutate: @escaping @Sendable (inout ControlBoard) -> Void) {
        updateControlBoard(
            id: ControlBoard.streamBoardID, itemIDs: boardItemIDs(of: .streamRecordPreset), mutate)
    }

    private func boardItemIDs(of kind: DocumentKind) -> [String] {
        let listed = indexSnapshot.entries(of: kind).map(\.id)
        let known = Set(listed)
        return listed + residentIDs(of: kind).filter { !known.contains($0) }.sorted()
    }

    private func residentIDs(of kind: DocumentKind) -> [String] {
        switch kind {
        case .actionCombo: resident.actionCombos.ids
        case .alertPreset: resident.alertPresets.ids
        case .streamRecordPreset: resident.streamPresets.ids
        default: []
        }
    }

    private func controlBoard(id: String, itemIDs: [String]) -> ControlBoard {
        _ = listVersion
        var board = resident.controlBoards.value(id) ?? ControlBoard(id: id, nodes: [], folders: [])
        board.reconcile(withItemIDs: itemIDs)
        return board
    }

    private func updateControlBoard(
        id: String, itemIDs: [String], _ mutate: @escaping @Sendable (inout ControlBoard) -> Void
    ) {
        let stored = resident.controlBoards.value(id)
        var board = stored ?? ControlBoard(id: id, nodes: [], folders: [])
        board.reconcile(withItemIDs: itemIDs)
        let before = board.orderSnapshot
        let beforeNames = Self.folderNames(board.folders.map { ($0.id, $0.name) })
        mutate(&board)
        let after = board.orderSnapshot
        let afterNames = Self.folderNames(board.folders.map { ($0.id, $0.name) })
        updateWellKnown(
            ControlBoard.self, id: id, failure: "controlBoard.saveFailed",
            orMake: { ControlBoard(id: id, nodes: [], folders: []) }
        ) { board in
            board.reconcile(withItemIDs: itemIDs)
            mutate(&board)
        }

        moveUndo.registerBoardMove(label: "Move Item", before: before, after: after) {
            [weak self] order in
            guard let self else { return false }
            let items = boardItemIDs(of: kindForControlBoard(id: id))
            let applied = !order.membership.isDisjoint(with: controlBoard(id: id, itemIDs: items).orderSnapshot.membership)
            if applied {
                updateControlBoard(id: id, itemIDs: items) { board in
                    if !order.membership.isDisjoint(with: board.orderSnapshot.membership) {
                        board.restore(order: order)
                    }
                }
            }
            return applied
        }

        registerFolderRenames(
            key: "controlFolderNames:\(id)", before: beforeNames, after: afterNames
        ) { [weak self] names in
            guard let self else { return false }
            let items = boardItemIDs(of: kindForControlBoard(id: id))
            let current = controlBoard(id: id, itemIDs: items)
            let applied = names.keys.contains { current.folder(id: $0) != nil }
            if applied {
                updateControlBoard(id: id, itemIDs: items) { board in
                    for (folderID, name) in names where board.folder(id: folderID) != nil {
                        board.renameFolder(id: folderID, to: name)
                    }
                }
            }
            return applied
        }
    }

    private func kindForControlBoard(id: String) -> DocumentKind {
        switch id {
        case ControlBoard.comboBoardID: .actionCombo
        case ControlBoard.alertBoardID: .alertPreset
        default: .streamRecordPreset
        }
    }

    @discardableResult
    private func modify<E: DocumentEntity>(
        _ type: E.Type, id: String, _ mutate: @escaping @Sendable (inout E) -> Void
    ) -> Task<LibraryBatch, any Error> {
        client.modify(type, id: id, mutate)
    }

    private func land(_ change: DocumentChange) {
        let held = currentValue(change.kind, id: change.id)
        if change.value == nil || held == nil || !Self.same(held, change.value) {

            if upcomingOnly, [.service, .presentation, .playlist].contains(change.kind) {
                refreshUpcoming()
            }
            noteMutation(change.kind)
            reseedCaches(kind: change.kind, id: change.id, value: change.value)

            if change.kind == .service, change.id == currentServiceID {
                warmLiveSet()
            }
        }
    }

    private static func same(_ a: (any DocumentEntity)?, _ b: (any DocumentEntity)?) -> Bool {
        if let a, let b {
            a.isEqual(to: b)
        } else {
            a == nil && b == nil
        }
    }

    private func reseedCaches(kind: DocumentKind, id: String, value: (any DocumentEntity)?) {
        switch kind {
        case .presentation:
            decks.reseed(id: id, value: value as? Presentation)
            rekeyArrangedCache(dropping: id)
        default:

            resident.reseed(kind: kind, id: id, value: value)
        }
    }

    private func rekeyArrangedCache(dropping id: String?) {
        let epoch = kindVersions[.presentation]

        let prior = epoch - 1
        arrangedCache = Dictionary(uniqueKeysWithValues: arrangedCache.compactMap { key, slides in
            let parts = key.split(
                separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3, parts[0] != id ?? "", parts[1] == String(prior)
            else { return nil }
            return ("\(parts[0])|\(epoch)|\(parts[2])", slides)
        })
    }

    @ObservationIgnored private var appliedGeneration = IndexSnapshot.unread

    func noteExternalMutation() {
        noteLibraryWideMutation()
    }

    func noteExternalMutation(of kind: DocumentKind) {
        noteMutation(kind)

        if kind == .presentation {
            decks.kindWideBump()
        }
    }

    private(set) var isImporting = false
    private(set) var lastImportSummary: String?

    private(set) var importReplaceVersion = 0

    func noteImportReplacedDocuments() {
        importReplaceVersion += 1
    }

    func noteImportSummary(_ summary: String) {
        lastImportSummary = summary
    }

    @discardableResult
    func importFiles(_ urls: [URL], placement: LibraryHome.Placement? = nil) async -> [String] {
        isImporting = true
        defer { isImporting = false }
        let results = await importer?.importFiles(at: urls, placement: placement ?? newPlacement) ?? []
        let flagged = results.filter {
            if case .media(_, .needsTranscode) = $0.outcome { return true } else { return false }
        }.count
        let skipped = results.filter {
            if case .skipped = $0.outcome { return true } else { return false }
        }.count
        var summary = "Imported \(results.count - skipped) of \(results.count) files"
        if flagged > 0 { summary += " — \(flagged) flagged for transcode" }
        if skipped > 0 { summary += " — \(skipped) skipped" }
        lastImportSummary = summary
        noteMutation(.media)
        return results.compactMap { result in
            if case .media(let id, _) = result.outcome { return id }
            return nil
        }
    }

    @discardableResult
    func insertDroppedMedia(
        fromFiles urls: [URL], service serviceID: String, beforeItemID: String?
    ) async -> Bool {
        let imported = await importFiles(urls)
        return await insertDroppedMedia(imported.compactMap { media($0) }, service: serviceID, beforeItemID: beforeItemID)
    }

    @discardableResult
    func insertDroppedMedia(
        _ items: [MediaItem], service serviceID: String, beforeItemID: String?
    ) async -> Bool {
        if let drop = RunOrderMediaDrop(items) {
            if case .presentation(let deck, _) = drop {

                _ = try? await createInDrive(deck).value
            }
            let row = drop.row
            updateService(serviceID) { service in
                let index = beforeItemID.flatMap { id in
                    service.items.firstIndex { $0.id == id }
                } ?? service.items.count
                service.items.insert(row, at: index)
            }
            markUsed(row.refId)
            return true
        } else {
            return false
        }
    }

    @discardableResult
    func importLyrics(
        text: String, fallbackTitle: String? = nil, linesPerSlide: Int = 2,
        themeId: String = "", themeSlideName: String = "Lyrics", lyricLines: Set<String> = []
    ) -> String? {
        let presentation = LyricTextImporter.makePresentation(
            text,
            fallbackTitle: fallbackTitle,
            themeId: themeId,
            themeSlideName: themeSlideName,
            linesPerSlide: linesPerSlide,
            lyricLines: lyricLines
        )
        createInDrive(presentation)
        lastImportSummary = "Imported \"\(presentation.name)\" (\(presentation.slides.count) slides)"
        return presentation.id
    }

    @discardableResult
    func importProPresenter(
        urls: [URL], onDocument: ((URL) -> Void)? = nil
    ) async -> [ProPresenterImporter.DocumentSummary] {
        isImporting = true
        defer { isImporting = false }
        let placement = newPlacement
        guard let importer = try? ProPresenterImporter(client: client, placement: placement) else { return [] }
        let summaries = await importer.importItems(
            at: urls, folder: placement.folder(for: .presentation), onDocument: onDocument)
        let imported = summaries.filter { $0.presentationID != nil && $0.skipped == nil }
        let mediaCount = summaries.reduce(0) { $0 + $1.mediaImported }
        var summary = "Imported \(imported.count) of \(summaries.count) ProPresenter documents"
        if mediaCount > 0 { summary += " — \(mediaCount) media files" }

        let kept = summaries.filter { $0.skipped == .edited }
        if !kept.isEmpty {
            summary += " — kept \(kept.count) edited here: \(kept.map(\.name).joined(separator: ", "))"
        }
        let warned = summaries.filter { !$0.warnings.isEmpty }.count
        if warned > 0 { summary += " — \(warned) with warnings" }
        lastImportSummary = summary
        await applyImportedGroupHotKeys(from: summaries)
        noteLibraryWideMutation()
        noteImportReplacedDocuments()
        return summaries
    }

    private func applyImportedGroupHotKeys(
        from summaries: [ProPresenterImporter.DocumentSummary]
    ) async {
        var merged: [String: String] = [:]
        for summary in summaries {
            merged.merge(summary.groupHotKeys) { first, _ in first }
        }
        await applyImportedGroupHotKeys(merged, policy: .updateUnedited)
    }

    func applyImportedGroupHotKeys(
        _ imported: [String: String], policy: ImportConflictPolicy
    ) async {
        if !imported.isEmpty {
            await client.settled()
            await resident.ready([.groupPalette])
            let ledger = (try? await client.loadValue(ImportLedger.self, id: ImportLedger.wellKnownID))
                ?? ImportLedger(id: ImportLedger.wellKnownID, entries: [])
            var palette = groupPalette
            let stamps = palette.applyImportedHotKeys(imported, policy: policy, ledger: ledger)
            updateGroupPalette { _ = $0.applyImportedHotKeys(imported, policy: policy, ledger: ledger) }
            if !stamps.isEmpty {

                let receipts = stamps.map { (docId: $0.docId, hash: $0.hash) }
                client.modify(
                    ImportLedger.self, id: ImportLedger.wellKnownID,
                    orMake: { ImportLedger(id: ImportLedger.wellKnownID, entries: []) }
                ) { value in
                    for stamp in receipts { value.stamp(stamp.docId, stamp.hash) }
                }
            }
        }
    }

    func importProPresenterThemes(urls: [URL]) async -> [ProThemeImportSummary] {
        isImporting = true
        defer { isImporting = false }
        guard let importer = try? ProPresenterImporter(client: client, placement: newPlacement) else { return [] }
        var summaries: [ProThemeImportSummary] = []
        for url in urls {
            summaries.append(await importer.importTheme(at: url))
        }
        let names = summaries.filter { $0.themeID != nil && $0.skipped == nil }.map(\.name)
        if !names.isEmpty {
            lastImportSummary = "Imported theme\(names.count == 1 ? "" : "s") \(names.joined(separator: ", "))"
        }
        noteLibraryWideMutation()
        noteImportReplacedDocuments()
        return summaries
    }

    func importProPresenterPlaylists(urls: [URL]) async -> [ProPresenterImporter.PlaylistBundleSummary] {
        isImporting = true
        defer { isImporting = false }
        let placement = newPlacement
        guard let importer = try? ProPresenterImporter(client: client, placement: placement) else { return [] }
        var summaries: [ProPresenterImporter.PlaylistBundleSummary] = []
        for url in urls {
            summaries.append(await importer.importPlaylistBundle(at: url, folder: placement.folder(for: .presentation)))
        }
        let services = summaries.flatMap(\.services)
        if !services.isEmpty {
            lastImportSummary = "Imported \(services.count) playlist\(services.count == 1 ? "" : "s") → Services: \(services.joined(separator: ", "))"
        }
        await applyImportedGroupHotKeys(from: summaries.flatMap(\.documents))
        noteLibraryWideMutation()
        noteImportReplacedDocuments()
        return summaries
    }

    @discardableResult
    func importPowerPoint(
        urls: [URL], onDocument: ((URL) -> Void)? = nil
    ) async -> [PPTXImporter.DocumentSummary] {
        isImporting = true
        defer { isImporting = false }
        let placement = newPlacement
        guard let importer = try? PPTXImporter(client: client, placement: placement) else { return [] }
        let summaries = await importer.importItems(
            at: urls, folder: placement.folder(for: .presentation), onDocument: onDocument)
        let imported = summaries.filter { $0.presentationID != nil }
        let mediaCount = summaries.reduce(0) { $0 + $1.mediaImported }
        var summary = "Imported \(imported.count) of \(summaries.count) PowerPoint decks"
        if mediaCount > 0 { summary += " — \(mediaCount) media files" }
        let warned = summaries.filter { !$0.warnings.isEmpty }.count
        if warned > 0 { summary += " — \(warned) with warnings" }
        lastImportSummary = summary
        noteLibraryWideMutation()
        noteImportReplacedDocuments()
        return summaries
    }

    func applyFontReplacements(_ replacements: [String: String], to presentationIDs: [String]) {
        guard !replacements.isEmpty, !presentationIDs.isEmpty else { return }
        var nameMap: [String: String] = [:]
        for (missing, family) in replacements {
            nameMap[missing] = Self.faceName(family: family, bold: false, italic: false)
            nameMap["\(missing)-Bold"] = Self.faceName(family: family, bold: true, italic: false)
            nameMap["\(missing)-Italic"] = Self.faceName(family: family, bold: false, italic: true)
            nameMap["\(missing)-BoldItalic"] = Self.faceName(family: family, bold: true, italic: true)
        }

        Task {
            await client.settled()
            let decks = (try? await client.loadValues(Presentation.self, ids: presentationIDs))?.values ?? [:]
            var writes: [Task<LibraryBatch, any Error>] = []
            for id in presentationIDs {
                if let presentation = decks[id] {
                    let replaced = FontReplacement.applying(nameMap, to: presentation)
                    if replaced != presentation { writes.append(client.replace(replaced)) }
                }
            }
            for write in writes { _ = await write.result }
            noteImportReplacedDocuments()
        }
    }

    private static func faceName(family: String, bold: Bool, italic: Bool) -> String {
        var traits: NSFontDescriptor.SymbolicTraits = []
        if bold { traits.insert(.bold) }
        if italic { traits.insert(.italic) }
        let descriptor = NSFontDescriptor(fontAttributes: [.family: family])
            .withSymbolicTraits(traits)
        if let matched = descriptor.matchingFontDescriptor(withMandatoryKeys: [.family]),
           let name = matched.object(forKey: .name) as? String {
            return name
        }
        return family
    }

    private(set) var isTranscoding = false

    func transcodeFlagged() async {
        isTranscoding = true
        defer { isTranscoding = false }
        await transcodeQueue?.drain()
        noteMutation(.media)
    }
}

extension AppModel: LibraryReadSide {

    func currentValue(_ kind: DocumentKind, id: String) -> (any DocumentEntity)? {
        if kind == .presentation {
            decks.currentValue(id)
        } else {
            resident.value(kind: kind, id: id)
        }
    }

    func applyOptimistic(_ change: DocumentChange) {

        pendingEntries[change.id] = Library.listedKinds.contains(change.kind) ? change.value.map { LibraryIndex.Entry(pending: $0) } : nil
        land(change)
    }

    func optimisticWriteFailed(_ change: DocumentChange, error: any Error) {
        DiagnosticsStore.shared.note("library.writeRefused", detail: "\(change.kind.rawValue)/\(change.id): \(error)")
        pendingEntries[change.id] = nil
        noteMutation(change.kind)
        if change.kind == .presentation {
            decks.writeRefused(id: change.id)
        }
    }

    func apply(_ batch: LibraryBatch) {
        for change in batch.changes {
            pendingEntries[change.id] = nil
            land(change)
        }
        if batch.snapshot.generation != appliedGeneration {
            appliedGeneration = batch.snapshot.generation
            listVersion += 1
            if appliedListing.map(batch.snapshot.listsLike) != true {
                listingVersion += 1
            }
            appliedListing = batch.snapshot
        }
        batchObservers.notify(batch)
    }
}

extension DocumentEntity {

    func isEqual(to other: any DocumentEntity) -> Bool {
        (other as? Self) == self
    }
}
