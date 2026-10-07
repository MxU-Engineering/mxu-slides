import Foundation
import Testing

@testable import PresenterCore

@Suite struct LibraryHomeTests {
    @Test func aNewItemFilesInTheOpenDriveFolderOfItsKindElseNeedsSorted() {
        let worship = LibraryHome.Viewed(kind: .presentation, area: .team, path: "Worship")
        #expect(LibraryHome.folder(for: .presentation, named: nil, viewing: worship) == "Worship")
        #expect(LibraryHome.folder(for: .presentation, named: "Easter", viewing: worship) == "Easter", "a folder someone picked wins")
        #expect(LibraryHome.folder(for: .media, named: nil, viewing: worship) == "Needs Sorted", "another library's folder is not this one's")
        let station = LibraryHome.Viewed(kind: .presentation, area: .station, path: "Lyrics")
        #expect(LibraryHome.folder(for: .presentation, named: nil, viewing: station) == "Needs Sorted", "a This Station folder is not in the Drive")
        let top = LibraryHome.Viewed(kind: .presentation, area: .team, path: "")
        #expect(LibraryHome.folder(for: .presentation, named: nil, viewing: top) == "Needs Sorted", "never loose at the top")
        #expect(LibraryHome.folder(for: .presentation, named: nil, viewing: nil) == "Needs Sorted")
        #expect(LibraryHome.folder(for: .theme, named: nil, viewing: nil) == nil, "a kind with no folders")

        #expect(LibraryHome.area(for: .service) == .team && LibraryHome.area(for: .actionCombo) == .team)
        #expect(LibraryHome.area(for: .outputPreset) == nil && LibraryHome.area(for: .importLedger) == nil)
        #expect(LibraryHome.Placement.unplaced.folder(for: .presentation) == nil && LibraryHome.Placement.unplaced.area(for: .media) == nil)
        #expect(LibraryHome.Placement.drive(viewing: worship).folder(for: .presentation) == "Worship")
        #expect(LibraryHome.Placement.drive(viewing: worship).area(for: .audio) == .team)
    }

    @Test func aPickedMediaFolderIsWhereTheImportFiles() {
        let picked = LibraryHome.Placement.drive(viewing: .init(kind: .media, area: .team, path: "Sermon Art/2026"))
        #expect(picked.folder(for: .media) == "Sermon Art/2026")
        #expect(picked.area(for: .media) == .team)
        #expect(picked.folder(for: .audio) == "Needs Sorted")
        let sorted = LibraryHome.Placement.drive(viewing: .init(kind: .media, area: .team, path: LibraryHome.needsSorted))
        #expect(sorted.folder(for: .media) == "Needs Sorted")
    }

    @MainActor @Test func theHomeIsWrittenInTheCreatesOwnTurn() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("home-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let client = LibraryClient(rootURL: root)
        try await client.start().value

        let batch = try await client.create(DeckFixtures.deck(), area: .team).value
        #expect(batch.snapshot.area(kind: .presentation, id: "deck") == .team)
        #expect(!batch.areaMoves.contains { $0.origin == .local }, "not a move the sync acts on")
        #expect(SyncAreaGuess.answer(for: SyncLedger.Key(kind: .presentation, id: "deck"), isReady: true, snapshot: batch.snapshot, sync: batch.sync)
            == .known(.team))

        let preset = OutputPreset(id: "preset", name: "Main", assignments: [])
        let station = try await client.create(preset, area: .team).value
        #expect(station.snapshot.area(kind: .outputPreset, id: "preset") == nil, "a station kind has no area")

        let plain = try await client.create(DeckFixtures.deck("old")).value
        #expect(plain.snapshot.area(kind: .presentation, id: "old") == nil, "no home asked, none written")
    }

    @MainActor @Test func aReimportKeepsItsAreaAndANewOneTakesTheHome() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("home-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let client = LibraryClient(rootURL: root)
        try await client.start().value

        _ = try await client.create(DeckFixtures.deck(), area: .station).value
        let again = try await client.replace(DeckFixtures.deck(), area: .team).value
        #expect(again.snapshot.area(kind: .presentation, id: "deck") == .station)

        let fresh = try await client.replace(DeckFixtures.deck("fresh"), area: .team).value
        #expect(fresh.snapshot.area(kind: .presentation, id: "fresh") == .team)
    }
}

@Suite struct LibraryHomeSweepTests {
    private func source(_ name: String) throws -> String {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  
            .deletingLastPathComponent()  
            .deletingLastPathComponent()  
            .deletingLastPathComponent()  
            .deletingLastPathComponent()  
            .appendingPathComponent("Sources", isDirectory: true)
        return try String(contentsOf: sources.appendingPathComponent(name), encoding: .utf8)
    }

    private func body(of signature: String, in text: String, length: Int = 1400) throws -> Substring {
        let start = try #require(text.range(of: signature), "\(signature) moved")
        return text[start.upperBound...].prefix(length)
    }

    @Test func everyMadeItemGoesThroughTheHomeRule() throws {
        let app = try source("AppModel.swift")
        for signature in [
            "func createEntity(in section: LibrarySection) -> String? {",
            "func createPresentation(named name: String) -> String? {",
            "func createConfidenceLayout(from template: ConfidenceLayoutTemplate) -> String? {",
            "func createMultiView(",
            "func importLyrics(",
            "func createPlaylist(in section: LibrarySection) -> String? {",
        ] {
            let made = try body(of: signature, in: app, length: 900)
            let end = made.range(of: "\n    }\n")?.lowerBound ?? made.endIndex
            #expect(made[..<end].contains("createInDrive(") && !made[..<end].contains("client.create("), "\(signature) must file its item in the Drive")
        }
        #expect(try body(of: "func importFiles(_ urls: [URL], placement: LibraryHome.Placement? = nil) async -> [String] {", in: app)
            .contains("placement: placement ?? newPlacement"))
        for signature in ["func importProPresenter(", "func importProPresenterThemes(", "func importProPresenterPlaylists(", "func importPowerPoint("] {
            #expect(try body(of: signature, in: app).contains("placement"), "\(signature) must land in the Drive")
        }
        #expect(try body(of: "func duplicate(_ entry: LibraryIndex.Entry) {", in: app, length: 700).contains("createBeside(value, original: id)"))
    }

}
