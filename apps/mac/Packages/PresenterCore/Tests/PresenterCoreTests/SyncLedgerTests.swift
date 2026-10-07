import Foundation
import Testing
@testable import PresenterCore

@Suite struct SyncLedgerTests {
    @LibraryActor @Test func ledgerRowsLiveInTheIndexSidecarAndSurviveARebuild() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try Library(rootURL: root)
        #expect(try library.index.syncEntry(kind: .presentation, id: "d1") == nil)

        let entry = SyncLedger.Entry(lastPushedHeads: ["aa", "bb"], appliedSeq: 4, remoteSeq: 5, pending: true, lastSnapshotAt: Date(timeIntervalSince1970: 100))
        try library.index.setSyncEntry(entry, kind: .presentation, id: "d1")
        try library.index.setSyncEntry(SyncLedger.Entry(appliedSeq: 1), kind: .controlBoard, id: "combo-board")
        #expect(try library.index.syncEntry(kind: .presentation, id: "d1") == entry)
        try library.rebuildIndex()
        #expect(try library.index.allSyncEntries().count == 2, "not derived data: a rebuild keeps it")

        try library.index.quarantine(kind: .presentation, id: "d1", seq: 5, bytes: Data([1, 2, 3]), error: "missing dependency")
        let held = try library.index.quarantined(kind: .presentation, id: "d1")
        #expect(held.map(\.seq) == [5] && held.first?.bytes == Data([1, 2, 3]) && held.first?.error == "missing dependency")
        try library.index.clearQuarantine(kind: .presentation, id: "d1")
        #expect(try library.index.quarantined(kind: .presentation, id: "d1").isEmpty)

        try library.index.removeSyncEntry(kind: .presentation, id: "d1")
        #expect(try library.index.syncEntry(kind: .presentation, id: "d1") == nil)
        #expect(try library.index.syncEntry(kind: .controlBoard, id: "combo-board")?.appliedSeq == 1)
    }

    @LibraryActor @Test func headsRoundTripThroughHexAndSavesHaveASignature() throws {
        let document = try TypedDocument(Presentation(id: "d", name: "D", presentationKind: .deck, themeId: "", slides: []))
        let hex = SyncLedger.hex(document.heads())
        #expect(hex.count == 1 && hex.first?.count == 64)
        #expect(SyncLedger.heads(hex) == document.heads())
        #expect(SyncLedger.heads([]).isEmpty)
        #expect(SyncLedger.signature(of: document.save()).count == 32)
    }

    @LibraryActor @Test func libraryHooksFireOnEverySaveAndDeleteAndStampTheAuthor() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try Library(rootURL: root)
        var saved: [String] = []
        var deleted: [String] = []
        library.didSave = { kind, id in saved.append("\(kind.rawValue)/\(id)") }
        library.didDelete = { kind, id in deleted.append("\(kind.rawValue)/\(id)") }
        library.author = ChangeAuthor(userHexId: "u1", stationHexId: "st1")
        let document = try library.create(Presentation(id: "d", name: "D", presentationKind: .deck, themeId: "", slides: []))
        #expect(document.commitMessage == "u1|st1|presentation")
        try document.update { $0.name = "D2" }
        try library.save(document)
        try library.delete(kind: .presentation, id: "d")
        #expect(saved == ["presentation/d", "presentation/d"])
        #expect(deleted == ["presentation/d"])
    }

    @LibraryActor @Test func seededDocumentsShareOneHistoryAcrossMachines() throws {
        let value = Presentation(id: "pack.digital.theme", name: "Digital", presentationKind: .deck, themeId: "", slides: [Slide(id: "s1", name: "", objects: [])])
        let here = try TypedDocument(value, seed: .init(id: value.id))
        let there = try TypedDocument(value, seed: .init(id: value.id))
        #expect(here.heads() == there.heads(), "the same value seeds to the same first change everywhere")
        #expect(here.firstChangeHash() == there.firstChangeHash())
        #expect(try TypedDocument(value).heads() != here.heads(), "an unseeded create is its own history")

        try here.update { $0.name = "Digital (edited here)" }
        try there.update { $0.slides.append(Slide(id: "s2", name: "", objects: [])) }
        try here.merge(there)
        #expect(here.value.slides.map(\.id) == ["s1", "s2"], "no duplicated lists after the merge")
        #expect(here.document.actor != there.document.actor, "actors re-randomize after the seed commit")

        let bundle = try there.encodeChangesSince(heads: here.heads())
        #expect(!(try here.applyEncodedChanges(bundle)), "a bundle already merged lands as a no-op")
    }
}
