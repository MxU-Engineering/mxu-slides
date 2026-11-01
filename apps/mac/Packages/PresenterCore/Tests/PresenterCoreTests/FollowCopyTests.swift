import Foundation
import Testing

@testable import PresenterCore

private func makeRoot() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("follow-copy-\(UUID().uuidString)")
}

private func deck(_ id: String) -> Presentation {
    Presentation(id: id, name: "Prelude", presentationKind: .deck, themeId: "",
                 slides: [Slide(id: "s1", name: "Welcome", objects: [])])
}

@Suite struct FollowCopyTests {
    @LibraryActor @Test func aBoothsSaveLandsHereAndMergesWithTheBackupsEdits() throws {
        let (boothRoot, backupRoot) = (makeRoot(), makeRoot())
        defer { [boothRoot, backupRoot].forEach { try? FileManager.default.removeItem(at: $0) } }
        let booth = LibraryEngine(rootURL: boothRoot)
        let backup = LibraryEngine(rootURL: backupRoot)
        try booth.bootstrap()
        try backup.bootstrap()
        try booth.create(deck("d1"), area: .local)

        #expect(try backup.documentBytes(kind: .presentation, id: "d1") == nil, "nothing here yet")
        let first = try #require(try booth.documentBytes(kind: .presentation, id: "d1"))
        let landed = try backup.mergeCopy(kind: .presentation, id: "d1", bytes: first)
        #expect(landed.changes.map(\.origin) == [.landed], "a copy is never pushed")
        #expect(try backup.opened().index.area(kind: .presentation, id: "d1") == .local)
        #expect(try backup.localHeads(kind: .presentation, id: "d1") == booth.localHeads(kind: .presentation, id: "d1"))

        try backup.modify(Presentation.self, id: "d1") { $0.name = "Prelude (backup)" }
        try booth.modify(Presentation.self, id: "d1") { $0.slides[0].name = "Welcome back" }
        try backup.mergeCopy(kind: .presentation, id: "d1", bytes: #require(try booth.documentBytes(kind: .presentation, id: "d1")))
        let merged = try backup.replica(Presentation.self, id: "d1").value
        #expect(merged.name == "Prelude (backup)")
        #expect(merged.slides.map(\.name) == ["Welcome back"])
    }

    @LibraryActor @Test func aSharedItemLandsSharedAndASharedCopyHereStaysShared() throws {
        let (boothRoot, backupRoot) = (makeRoot(), makeRoot())
        defer { [boothRoot, backupRoot].forEach { try? FileManager.default.removeItem(at: $0) } }
        let booth = LibraryEngine(rootURL: boothRoot)
        let backup = LibraryEngine(rootURL: backupRoot)
        try booth.bootstrap()
        try backup.bootstrap()
        try booth.create(deck("shared"), area: .team)
        try booth.create(deck("station"))

        let shared = try #require(try booth.documentBytes(kind: .presentation, id: "shared"))
        let landed = try backup.mergeCopy(kind: .presentation, id: "shared", bytes: shared, area: FollowCopy.landing("team"))
        #expect(landed.changes.map(\.origin) == [.landed])
        #expect(try backup.opened().index.area(kind: .presentation, id: "shared") == .team, "the same shared document")
        try backup.mergeCopy(kind: .presentation, id: "station", bytes: #require(try booth.documentBytes(kind: .presentation, id: "station")), area: FollowCopy.landing(nil))
        #expect(try backup.opened().index.area(kind: .presentation, id: "station") == .local, "the booth's This Station is the booth's alone")

        try backup.mergeCopy(kind: .presentation, id: "shared", bytes: shared, area: .local)
        #expect(try backup.opened().index.area(kind: .presentation, id: "shared") == .team)
    }

    @LibraryActor @Test func anItemTheBackupHoldsKeepsItsOwnArea() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let backup = LibraryEngine(rootURL: root)
        try backup.bootstrap()
        try backup.create(deck("both"))
        let landed = try backup.mergeCopy(kind: .presentation, id: "both", bytes: #require(try backup.documentBytes(kind: .presentation, id: "both")), area: .local)
        #expect(landed.areaMoves.isEmpty, "the backup's own This Station item stays This Station")
        #expect(try backup.opened().index.area(kind: .presentation, id: "both") == nil)
    }

    @Test func aCopyLandsWhereTheBackupAlreadyFilesIt() {
        #expect(FollowCopy.area(.team, here: nil) == .team)
        #expect(FollowCopy.area(.local, here: nil) == .local)
        #expect(FollowCopy.area(.local, here: .station) == .station, "a built-in deck both have")
        #expect(FollowCopy.area(.local, here: .team) == .team, "never out of the shared library")
        #expect(FollowCopy.area(.team, here: .local) == .team, "the booth moved its original to the shared library")
        #expect(FollowCopy.area(.team, here: .station) == .station)
    }

    @Test func theBoothSaysWhichItemsAreShared() {
        #expect(FollowCopy.offered(.team) == "team")
        #expect(FollowCopy.offered(.station) == nil && FollowCopy.offered(.local) == nil && FollowCopy.offered(nil) == nil)
        #expect(FollowCopy.landing("team") == .team)
        #expect(FollowCopy.landing(nil) == .local)
    }

    @LibraryActor @Test func aSaveNamingAnotherIdIsRefused() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = LibraryEngine(rootURL: root)
        try engine.bootstrap()
        try engine.create(deck("d1"))
        let bytes = try #require(try engine.documentBytes(kind: .presentation, id: "d1"))
        #expect(throws: (any Error).self) { try engine.mergeCopy(kind: .presentation, id: "d2", bytes: bytes) }
    }

    @Test func theLibraryAndItsPresetsAreOffered() {
        #expect(FollowCopy.kinds.contains(.presentation))
        #expect(FollowCopy.kinds.contains(.media))
        #expect(FollowCopy.kinds.contains(.outputPreset), "fires switch presets by id")
        #expect(FollowCopy.kinds.contains(.streamRecordPreset), "Start Stream Here after a takeover")
        #expect(!FollowCopy.kinds.contains(.midiDevice), "MIDI gear is each computer's own")
    }
}
