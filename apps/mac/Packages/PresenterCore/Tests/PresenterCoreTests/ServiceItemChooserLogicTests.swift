import Foundation
import Testing
@testable import PresenterCore

@MainActor @Suite struct ServiceItemChooserLogicTests {
    private func entry(_ id: String, _ kind: DocumentKind, used: TimeInterval? = nil) -> LibraryIndex.Entry {
        LibraryIndex.Entry(
            id: id, kind: kind, subkind: "", name: id, updatedAt: .distantPast,
            lastUsedAt: used.map { Date(timeIntervalSince1970: $0) })
    }

    @Test func tabsOpenOnTheLibrary() {
        #expect(ServiceItemChooserLogic.Tab.allCases == [.library, .importFile, .new])
    }

    @Test func idleListsBothKindsLastUsedFirst() {
        let idle = [entry("Zeta", .presentation), entry("Loop", .media, used: 10), entry("Song", .presentation, used: 20), entry("Alpha", .media)]
        let all = ServiceItemChooserLogic.results(query: " ", hits: [], idle: idle, filter: .all)
        #expect(all.map(\.entry.id) == ["Song", "Loop", "Alpha", "Zeta"])
        #expect(ServiceItemChooserLogic.results(query: "", hits: [], idle: idle, filter: .slides).map(\.entry.id) == ["Song", "Zeta"])
        #expect(ServiceItemChooserLogic.results(query: "", hits: [], idle: idle, filter: .media).map(\.entry.id) == ["Loop", "Alpha"])
    }

    @Test func anAddDoesNotMoveTheRowsUnderThePointer() {
        let opened = ["Song", "Loop", "Alpha", "Zeta"]

        let resorted = ["Zeta", "Song", "Loop", "New", "Alpha"].map { LibraryIndex.Hit(entry: entry($0, .presentation), snippet: nil) }
        #expect(ServiceItemChooserLogic.steady(resorted, order: opened).map(\.entry.id) == ["Song", "Loop", "Alpha", "Zeta", "New"])
    }

    @Test func typedSearchKeepsTheIndexRankAndFilters() {
        let hits = [
            LibraryIndex.Hit(entry: entry("Way Maker", .presentation), snippet: "way maker, miracle worker"),
            LibraryIndex.Hit(entry: entry("Waves", .media), snippet: nil),
            LibraryIndex.Hit(entry: entry("Walk-in", .audio), snippet: nil),
            LibraryIndex.Hit(entry: entry("Welcome", .theme), snippet: nil),
        ]
        #expect(ServiceItemChooserLogic.results(query: "wa", hits: hits, idle: [], filter: .all).map(\.entry.id) == ["Way Maker", "Waves", "Walk-in"])
        #expect(ServiceItemChooserLogic.results(query: "wa", hits: hits, idle: [], filter: .slides).first?.snippet == "way maker, miracle worker")
        #expect(ServiceItemChooserLogic.results(query: "wa", hits: hits, idle: [], filter: .media).map(\.entry.id) == ["Waves", "Walk-in"])
    }

    @Test func importRoutesEachFileToItsImporter() {
        func route(_ name: String) -> ServiceItemChooserLogic.ImportRoute? {
            ServiceItemChooserLogic.route(URL(fileURLWithPath: "/tmp/\(name)"))
        }
        #expect(route("Song.mxuslides") == .slidesFile)
        #expect(route("Song.pro") == .proPresenter)
        #expect(route("Library.probundle") == .proPresenter)
        #expect(route("Deck.PPTX") == .powerPoint)
        #expect(route("Song.cho") == .lyrics)
        #expect(route("Song.txt") == .lyrics)
        #expect(route("Chart.pdf") == .lyrics)
        #expect(route("Loop.mov") == .media)
        #expect(route("Still.png") == .media)
        #expect(route("Track.mp3") == nil, "music stays in the Music library's import")
        #expect(route("Show.proPlaylist") == nil, "playlists import as services, not one item")
        #expect(ServiceItemChooserLogic.ImportRoute.allCases.first == .slidesFile, "decks land first")
    }

    @Test func aFileItCantImportIsNamed() {
        let song = URL(fileURLWithPath: "/tmp/Song.txt"), still = URL(fileURLWithPath: "/tmp/Still.png")
        let notes = URL(fileURLWithPath: "/tmp/Notes.md")
        #expect(ServiceItemChooserLogic.refusal([song, still]) == nil, "Add makes a row of each")
        #expect(ServiceItemChooserLogic.refusal([notes]) == "MxU Slides can't import Notes.md")
        #expect(ServiceItemChooserLogic.refusal([notes, still]) == nil, "the usable ones go in")
    }

    private var appSources: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources", isDirectory: true)
    }

    private func source(_ name: String) throws -> String {
        try String(contentsOf: appSources.appendingPathComponent(name), encoding: .utf8)
    }

    @Test func addFromLibraryOpensTheChooser() throws {
        let planner = try source("ServicePlannerView.swift")
        #expect(planner.contains("ServiceItemChooser(model: model, serviceID: serviceID, render: render)"))
        let chooser = try source("ServiceItemChooser.swift")
        #expect(chooser.contains("@State private var tab: ServiceItemChooserLogic.Tab = .library"), "always opens on From Library")
        #expect(chooser.contains("case .slidesFile: await importPresentationFiles(files)"))
        #expect(chooser.contains("case .proPresenter: await runProPresenterImport(files)"))
        #expect(chooser.contains("case .powerPoint: await runPowerPointImport(files)"))
        #expect(chooser.contains("case .lyrics: await importLyricsFiles(files)"))
        #expect(chooser.contains("case .media: await importFiles(files)"))
        #expect(chooser.contains("await client.settled()"), "imports are listed before a row reads them")
        #expect(chooser.contains("ServiceItemChooserLogic.refusal(urls)"), "drops and picks go through the one rule")
        #expect(!chooser.contains("NSSound"), "never a system sound: a skipped file is named in the pane")
        let library = try source("LibraryView.swift")
        #expect(library.contains("await model.runProPresenterImport(urls)") && library.contains("await model.runPowerPointImport(urls)"),
                "the File menu runs the same import flows")
    }
}
