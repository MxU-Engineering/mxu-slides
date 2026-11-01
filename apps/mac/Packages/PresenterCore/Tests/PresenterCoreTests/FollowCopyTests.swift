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
    @LibraryActor @Test func aBoothsSaveLandsThisMacOnlyAndMergesWithTheBackupsEdits() throws {
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

    @LibraryActor @Test func aSaveNamingAnotherIdIsRefused() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = LibraryEngine(rootURL: root)
        try engine.bootstrap()
        try engine.create(deck("d1"))
        let bytes = try #require(try engine.documentBytes(kind: .presentation, id: "d1"))
        #expect(throws: (any Error).self) { try engine.mergeCopy(kind: .presentation, id: "d2", bytes: bytes) }
    }

    @Test func onlyTeamLibraryKindsAreOffered() {
        #expect(FollowCopy.kinds.contains(.presentation))
        #expect(FollowCopy.kinds.contains(.media))
        #expect(!FollowCopy.kinds.contains(.outputPreset), "the setup follows through the cloud")
    }
}
