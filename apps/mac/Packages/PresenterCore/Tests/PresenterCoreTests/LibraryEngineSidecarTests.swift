import Foundation
import Testing

@testable import PresenterCore

private func makeRoot() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("library-sidecar-\(UUID().uuidString)")
}

private func combo(_ id: String, _ name: String) -> ActionCombo {
    ActionCombo(id: id, name: name, actions: [])
}

private func song(_ id: String, name: String, lyrics: String) -> Presentation {
    Presentation(
        id: id, name: name, presentationKind: .song, themeId: "",
        slides: [Slide(id: "\(id)-s0", name: "Verse", objects: [SlideObject(id: "\(id)-t0", objectKind: .text, name: "Lyrics", text: lyrics)])])
}

@LibraryActor private func secondIndex(_ root: URL) throws -> LibraryIndex {
    try LibraryIndex(url: root.appendingPathComponent("index.sqlite"))
}

@LibraryActor private func sqlSnapshot(_ root: URL, generation: Int) throws -> IndexSnapshot {
    let index = try secondIndex(root)
    return IndexSnapshot(entries: try index.allEntries(), areas: try index.allAreas(), generation: generation)
}

@MainActor private func until(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(10)
    while !condition(), ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(2))
    }
    try #require(condition(), "timed out")
}

@Suite struct LibraryEngineSidecarTests {
    @LibraryActor @Test func usageStampsReachTheSnapshot() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = LibraryEngine(rootURL: root)
        try engine.bootstrap()
        let created = try engine.create(combo("c1", "Walk-in"))
        #expect(created.snapshot.entry(id: "c1")?.lastUsedAt == nil)

        let fired = try engine.touchUsage(id: "c1", at: Date(timeIntervalSince1970: 1_000))
        #expect(fired.sequence == created.sequence + 1)
        #expect(fired.changes.isEmpty && fired.areaMoves.isEmpty)
        #expect(fired.snapshot.entry(id: "c1")?.lastUsedAt == Date(timeIntervalSince1970: 1_000))
        let older = try engine.touchUsage(id: "c1", at: Date(timeIntervalSince1970: 500))
        #expect(older.snapshot.entry(id: "c1")?.lastUsedAt == Date(timeIntervalSince1970: 1_000), "monotonic")
        #expect(older.snapshot == (try sqlSnapshot(root, generation: older.snapshot.generation)))

        try engine.touchUsage(id: "later", at: Date(timeIntervalSince1970: 700))
        let merged = try engine.mergeUsage([
            "c1": Date(timeIntervalSince1970: 2_000), "later": Date(timeIntervalSince1970: 100), "ghost": Date(timeIntervalSince1970: 300),
        ])
        #expect(merged.snapshot.entry(id: "c1")?.lastUsedAt == Date(timeIntervalSince1970: 2_000))
        let later = try engine.create(combo("later", "Stamped first"))
        #expect(later.snapshot.entry(id: "later")?.lastUsedAt == Date(timeIntervalSince1970: 700), "the older merged stamp lost")
        #expect(later.snapshot == (try sqlSnapshot(root, generation: later.snapshot.generation)))
        #expect(try secondIndex(root).allUsage()["ghost"] == Date(timeIntervalSince1970: 300))
        #expect(try engine.allUsage() == (try secondIndex(root).allUsage()))

        let now = Date()
        let stamped = try engine.touchUsage(id: "c1", at: now.addingTimeInterval(1_000_000))
        #expect(stamped.snapshot == (try sqlSnapshot(root, generation: stamped.snapshot.generation)), "a fractional date reads back as the index keeps it")
    }

    @LibraryActor @Test func anAreaRowIsWrittenAndOnlyAChangeIsAMove() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = LibraryEngine(rootURL: root)
        try engine.bootstrap()
        try engine.create(song("p1", name: "Grace", lyrics: "amazing"))
        let key = SyncLedger.Key(kind: .presentation, id: "p1")

        let noted = try engine.setArea(.station, of: [key], origin: .landed)
        #expect(noted.areaMoves.isEmpty, "no row read as This Station already")
        #expect(noted.snapshot.area(kind: .presentation, id: "p1") == .station)
        #expect(try secondIndex(root).area(kind: .presentation, id: "p1") == .station)
        #expect(noted.snapshot == (try sqlSnapshot(root, generation: noted.snapshot.generation)))

        let moved = try engine.setArea(.team, of: [key])
        #expect(moved.areaMoves == [AreaMove(kind: .presentation, id: "p1", from: .station, to: .team, origin: .local)])
        #expect(moved.snapshot.area(kind: .presentation, id: "p1") == .team)
        #expect(moved.snapshot.area(kind: .presentation, id: "none") == nil)
    }

    @LibraryActor @Test func theLedgerIsPublishedAndEqualsTheIndex() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = LibraryEngine(rootURL: root)
        try engine.bootstrap()
        try engine.create(combo("a", "A"))
        try engine.create(combo("b", "B"))

        let set = try engine.setSyncEntry(SyncLedger.Entry(lastPushedHeads: ["aa"], appliedSeq: 3, remoteSeq: 4), kind: .actionCombo, id: "a")
        #expect(set.changes.isEmpty)
        #expect(set.sync.entry(kind: .actionCombo, id: "a")?.remoteSeq == 4)
        let owed = try engine.updateSyncEntry(kind: .actionCombo, id: "b") { $0.pending = true }
        #expect(owed.sync.entry(kind: .actionCombo, id: "b") == SyncLedger.Entry(pending: true), "a missing row starts empty")
        try engine.updateSyncEntry(kind: .actionCombo, id: "a") { $0.pending = true }
        #expect(engine.sync.syncedCount == 2 && engine.sync.pendingCount == 2)
        #expect(engine.sync.pendingKeys == [SyncLedger.Key(kind: .actionCombo, id: "a"), SyncLedger.Key(kind: .actionCombo, id: "b")])
        #expect(engine.sync.entries == (try secondIndex(root).allSyncEntries()))
        #expect(engine.syncEntry(kind: .actionCombo, id: "a") == (try secondIndex(root).syncEntry(kind: .actionCombo, id: "a")))

        let removed = try engine.removeSyncEntry(kind: .actionCombo, id: "a")
        #expect(removed.sync.entry(kind: .actionCombo, id: "a") == nil)
        #expect(removed.sync.pendingCount == 1)
        let deleted = try engine.delete(kind: .actionCombo, id: "b")
        #expect(deleted.sync.entries.isEmpty, "a delete takes the ledger row with it, as the index does")
        #expect(engine.sync.entries == (try secondIndex(root).allSyncEntries()))
    }

    @LibraryActor @Test func teamFoldersIdentityAndAResetRideTheBatch() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = LibraryEngine(rootURL: root)
        try engine.bootstrap()
        let folders = [TeamFolder(id: "d1", name: "Sunday"), TeamFolder(id: "f1", name: "Songs", parentId: "d1", position: 2)]
        let foldered = try engine.replaceTeamFolders(folders)
        #expect(foldered.sync.teamFolders == folders)
        #expect(try secondIndex(root).teamFolders().sorted { $0.id < $1.id } == folders)

        let identity = SyncIdentity(serverHost: "app.lvh.me", teamHexId: "t1", teamName: "Team")
        #expect(try engine.setSyncIdentity(identity).sync.identity == identity)
        try engine.setSyncEntry(SyncLedger.Entry(remoteSeq: 1), kind: .theme, id: "x")
        try engine.quarantine(kind: .theme, id: "x", seq: 2, bytes: Data([1]), error: "bad")
        try engine.markBlobUploaded("sha")

        let reset = try engine.resetSyncState()
        #expect(reset.sync.entries.isEmpty)
        #expect(reset.sync.identity == identity && reset.sync.teamFolders == folders, "the identity and folders stay")
        #expect(try engine.quarantined(kind: .theme, id: "x").isEmpty)
        #expect(try !engine.isBlobUploaded("sha"))

        try engine.setSyncEntry(SyncLedger.Entry(pending: true), kind: .theme, id: "y")
        let reopened = try LibraryEngine(rootURL: root).bootstrap()
        #expect(reopened.sync == engine.sync)
        #expect(reopened.sync.pendingCount == 1)
    }

    @LibraryActor @Test func quarantineAndBlobMarksAreOneBatchEach() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = LibraryEngine(rootURL: root)
        try engine.bootstrap()
        let at = Date(timeIntervalSince1970: 1_234)
        let kept = try engine.quarantine(kind: .presentation, id: "p", seq: 7, bytes: Data([9, 9]), error: "decode", at: at)
        #expect(kept.sequence == 1 && kept.changes.isEmpty)
        #expect(try engine.quarantined(kind: .presentation, id: "p") == [
            SyncLedger.Quarantined(seq: 7, bytes: Data([9, 9]), error: "decode", quarantinedAt: at),
        ])
        #expect(try engine.clearQuarantine(kind: .presentation, id: "p").sequence == 2)
        #expect(try engine.quarantined(kind: .presentation, id: "p").isEmpty)

        #expect(try engine.markBlobUploaded("a1").sequence == 3)
        try engine.markBlobUploaded("b2")
        #expect(try engine.isBlobUploaded("a1"))
        #expect(try engine.uploadedBlobs(among: ["a1", "b2", "c3"]) == ["a1", "b2"])
        try engine.forgetBlobUploaded("a1")
        #expect(try engine.uploadedBlobs(among: ["a1", "b2"]) == ["b2"])
        #expect(try secondIndex(root).blobUploaded("b2"))
    }

    @LibraryActor @Test func searchReturnsWhatTheIndexReturns() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = LibraryEngine(rootURL: root)
        try engine.bootstrap()
        try engine.create(song("p1", name: "Amazing Grace", lyrics: "how sweet the sound"))
        try engine.create(song("p2", name: "Grace Alone", lyrics: "every promise"))
        try engine.create(song("p3", name: "Great Are You Lord", lyrics: "amazing grace in every breath"))
        try engine.touchUsage(id: "p3", at: Date(timeIntervalSince1970: 50))

        for query in ["grace", "amazing", "sweet", "gr", "  "] {
            #expect(try engine.search(query) == (try secondIndex(root).searchHits(query)), "\(query)")
        }
        #expect(try engine.search("grace").count == 3)
        #expect(try engine.search("  ").isEmpty)
        #expect(try engine.presentationMatchKeys().map(\.id).sorted() == ["p1", "p2", "p3"])
        #expect(try engine.presentationMatchKeys().sorted { $0.id < $1.id } == (try secondIndex(root).presentationMatchKeys().sorted { $0.id < $1.id }))

        try engine.create(Presentation(id: "filed", name: "Filed", presentationKind: .deck, themeId: "", folder: "Sunday/Songs", folderId: "f1", slides: []))
        #expect(try engine.folderRefs() == [LibraryIndex.FolderRef(kind: .presentation, id: "filed", folderId: "f1", folder: "Sunday/Songs")])
        #expect(try engine.folderRefs() == (try secondIndex(root).folderRefs()))
    }

    @LibraryActor @Test func aRebuildRepopulatesTheIndexAndKeepsTheSidecar() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = LibraryEngine(rootURL: root)
        try engine.bootstrap()
        try engine.create(song("p1", name: "Grace", lyrics: "sound"))
        try engine.create(combo("c1", "Walk-in"))
        try engine.touchUsage(id: "c1", at: Date(timeIntervalSince1970: 10))
        try engine.setArea(.team, of: [SyncLedger.Key(kind: .presentation, id: "p1")])

        try secondIndex(root).removeAll()

        let rebuilt = try engine.rebuildIndex()
        #expect(rebuilt.changes.isEmpty)
        #expect(rebuilt.snapshot.entries(of: .presentation).map(\.name) == ["Grace"])
        #expect(rebuilt.snapshot.entry(id: "c1")?.lastUsedAt == Date(timeIntervalSince1970: 10))
        #expect(rebuilt.snapshot.area(kind: .presentation, id: "p1") == .team)
        #expect(rebuilt.snapshot == (try sqlSnapshot(root, generation: rebuilt.snapshot.generation)))
        #expect(try engine.search("sound").map(\.entry.id) == ["p1"])
    }

    @LibraryActor @Test func aReplaceRemovesThenSavesAndAWellKnownDocumentIsMadeThenEdited() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = LibraryEngine(rootURL: root)
        try engine.bootstrap()
        try engine.create(combo("c1", "Original"))
        try engine.setSyncEntry(SyncLedger.Entry(remoteSeq: 2), kind: .actionCombo, id: "c1")

        let replaced = try engine.replace(combo("c1", "Mapped"))
        #expect(replaced.changes.map { "\($0.origin.rawValue) \($0.id)" } == ["deleted c1", "local c1"])
        #expect(replaced.value(ActionCombo.self, id: "c1")?.name == "Mapped")
        #expect(replaced.sync.entry(kind: .actionCombo, id: "c1") == nil, "a replace is a delete: the ledger row goes")
        let fresh = try engine.replace(combo("c2", "New"))
        #expect(fresh.changes.map(\.origin) == [.local], "nothing to remove")

        let id = SchedulerBoard.wellKnownID
        let made = try engine.modify(SchedulerBoard.self, id: id, orMake: { SchedulerBoard(id: id, nodes: [], folders: []) }) {
            $0.folders.append(ScheduleFolder(id: "f1", name: "Morning", triggerIds: []))
        }
        #expect(made.changes.map(\.origin) == [.local])
        #expect(made.value(SchedulerBoard.self, id: id)?.folders.map(\.name) == ["Morning"])
        let edited = try engine.modify(SchedulerBoard.self, id: id, orMake: { SchedulerBoard(id: id, nodes: [], folders: []) }) {
            $0.folders.append(ScheduleFolder(id: "f2", name: "Evening", triggerIds: []))
        }
        #expect(edited.value(SchedulerBoard.self, id: id)?.folders.map(\.name) == ["Morning", "Evening"], "the second call edits, not remakes")
        #expect(try DocumentStore(rootURL: root).load(SchedulerBoard.self, id: id).value.folders.count == 2)
    }

    @LibraryActor @Test func reconcileDeletedDecidesAndRemovesInOneTurn() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = LibraryEngine(rootURL: root)
        try engine.bootstrap()
        try engine.create(combo("a", "A"))
        let untracked = try engine.reconcileDeleted(kind: .actionCombo, id: "a")
        #expect({ if case .untracked = untracked { true } else { false } }())

        let heads = try #require(try engine.localHeads(kind: .actionCombo, id: "a"))
        #expect(try engine.localHeads(kind: .actionCombo, id: "gone") == nil)
        try engine.setSyncEntry(SyncLedger.Entry(lastPushedHeads: heads, remoteSeq: 1), kind: .actionCombo, id: "a")
        try engine.modify(ActionCombo.self, id: "a") { $0.name = "Edited here" }
        let kept = try engine.reconcileDeleted(kind: .actionCombo, id: "a")
        #expect({ if case .editWins = kept { true } else { false } }())
        #expect(try DocumentStore(rootURL: root).load(ActionCombo.self, id: "a").value.name == "Edited here")

        let pushed = try #require(try engine.localHeads(kind: .actionCombo, id: "a"))
        try engine.updateSyncEntry(kind: .actionCombo, id: "a") { $0.lastPushedHeads = pushed }
        let removed = try engine.reconcileDeleted(kind: .actionCombo, id: "a")
        if case let .removed(batch) = removed {
            #expect(batch.changes.map(\.origin) == [.landed])
            #expect(batch.changes.first?.value == nil)
            #expect(batch.sync.entry(kind: .actionCombo, id: "a") == nil)
            #expect(batch.snapshot.entry(id: "a") == nil)
        } else {
            Issue.record("an unchanged copy leaves with the cloud's")
        }
        #expect(try secondIndex(root).allSyncEntries().isEmpty)
    }

    @LibraryActor @Test func bootstrapRunsTheLaunchPreparationBeforeTheFirstSnapshot() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        struct Refused: Error {}
        let failing = LibraryEngine(rootURL: root)
        #expect(throws: Refused.self) { try failing.bootstrap { _ in throw Refused() } }
        #expect(throws: LibraryEngine.EngineError.notBootstrapped) { try failing.touchUsage(id: "x") }

        let start = try failing.bootstrap { library in
            try library.create(combo("seeded", "Seeded at launch"))
            try library.index.setSyncIdentity(SyncIdentity(serverHost: "h", teamHexId: nil, teamName: "T"))
        }
        #expect(start.snapshot.entry(id: "seeded")?.name == "Seeded at launch")
        #expect(start.sync.identity?.teamName == "T")
        #expect(try failing.bootstrap { _ in throw Refused() }.snapshot == start.snapshot, "an open library does not prepare again")
    }
}

@Suite struct LibraryClientSidecarTests {

    @MainActor @Test func theClientsSidecarCommandsLandInItsSnapshotAndSync() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let client = LibraryClient(rootURL: root)
        try await client.start { library in try library.create(combo("prepared", "Prepared")) }.value
        #expect(client.snapshot.entry(id: "prepared") != nil)
        #expect(client.sync == .empty)

        _ = client.create(song("p1", name: "Grace", lyrics: "sound"))
        _ = client.touchUsage(id: "p1", at: Date(timeIntervalSince1970: 5))
        _ = client.mergeUsage(["prepared": Date(timeIntervalSince1970: 6)])
        _ = client.setArea(.station, of: [SyncLedger.Key(kind: .presentation, id: "p1")], origin: .landed)
        _ = client.replaceTeamFolders([TeamFolder(id: "d", name: "Drive")])
        _ = client.setSyncIdentity(SyncIdentity(serverHost: "h", teamHexId: "t", teamName: "Team"))
        _ = client.setSyncEntry(SyncLedger.Entry(remoteSeq: 1), kind: .presentation, id: "p1")
        _ = client.updateSyncEntry(kind: .presentation, id: "p1") { $0.pending = true }
        _ = client.quarantine(kind: .presentation, id: "p1", seq: 2, bytes: Data([1]), error: "bad")
        _ = client.markBlobUploaded("sha")
        let renamed = client.modify(Presentation.self, id: "p1") { $0.name = "Grace Renamed" }

        #expect(try await client.search("renamed").map(\.entry.id) == ["p1"])
        #expect(try await client.quarantined(kind: .presentation, id: "p1").map(\.seq) == [2])
        #expect(try await client.isBlobUploaded("sha"))
        #expect(try await client.uploadedBlobs(among: ["sha", "other"]) == ["sha"])
        #expect(try await client.presentationMatchKeys().map(\.id) == ["p1"])
        #expect(try await client.folderRefs().isEmpty)
        #expect(try await client.localHeads(kind: .presentation, id: "p1")?.isEmpty == false)
        #expect(try await client.exists(kind: .presentation, id: "p1"))
        #expect(try await !client.exists(kind: .presentation, id: "gone"))
        #expect(try await client.ids(of: .actionCombo) == ["prepared"])
        #expect(try await client.allUsage()["prepared"] == Date(timeIntervalSince1970: 6))

        let last = try await renamed.value
        try await until { client.lastAppliedSequence >= last.sequence }
        #expect(client.snapshot.entry(id: "p1")?.lastUsedAt == Date(timeIntervalSince1970: 5))
        #expect(client.snapshot.entry(id: "prepared")?.lastUsedAt == Date(timeIntervalSince1970: 6))
        #expect(client.snapshot.area(kind: .presentation, id: "p1") == .station)
        #expect(client.sync.teamFolders.map(\.name) == ["Drive"])
        #expect(client.sync.identity?.teamName == "Team")
        #expect(client.sync.entry(kind: .presentation, id: "p1") == SyncLedger.Entry(remoteSeq: 1, pending: true))
        #expect(client.sync.pendingKeys == [SyncLedger.Key(kind: .presentation, id: "p1")])

        _ = client.clearQuarantine(kind: .presentation, id: "p1")
        _ = client.forgetBlobUploaded("sha")
        _ = client.removeSyncEntry(kind: .presentation, id: "p1")
        #expect(try await client.quarantined(kind: .presentation, id: "p1").isEmpty)
        #expect(try await !client.isBlobUploaded("sha"))
        let reset = try await client.resetSyncState().value
        #expect(reset.sync.entries.isEmpty)
        let rebuilt = try await client.rebuildIndex().value
        #expect(rebuilt.snapshot.entries(of: .presentation).map(\.name) == ["Grace Renamed"])

        let replaced = client.replace(combo("prepared", "Replaced"))
        #expect(try await replaced.value.changes.map(\.origin) == [.deleted, .local])
        let board = SchedulerBoard.wellKnownID
        let made = try await client.modify(SchedulerBoard.self, id: board, orMake: { SchedulerBoard(id: board, nodes: [], folders: []) }) {
            $0.folders.append(ScheduleFolder(id: "f", name: "Folder", triggerIds: []))
        }.value
        #expect(made.value(SchedulerBoard.self, id: board)?.folders.count == 1)

        _ = try await client.setSyncEntry(SyncLedger.Entry(lastPushedHeads: ["00"]), kind: .presentation, id: "p1").value
        let tombstone = try await client.reconcileDeleted(kind: .presentation, id: "p1").value
        #expect({ if case .editWins = tombstone { true } else { false } }())

        let evicted = try await client.delete(kind: .presentation, id: "p1", origin: .landed).value
        #expect(evicted.changes.map(\.origin) == [.landed], "an eviction is no tombstone")
        #expect(try await client.delete(kind: .actionCombo, id: "prepared").value.changes.map(\.origin) == [.deleted])
    }
}

@Suite struct TypedDocumentWorkingCopyTests {
    @LibraryActor @Test func aWorkingCopySharesNothingAndContainsFollowsHistory() throws {
        let original = try TypedDocument(combo("a", "One"))
        let base = original.heads()
        let copy = original.workingCopy()
        #expect(copy.value == original.value)
        #expect(copy.heads() == base)
        try original.update { $0.name = "Edited on the original" }
        #expect(copy.value.name == "One", "an edit to the original does not reach the copy")
        #expect(original.contains(heads: base), "the original descends from the copy's base")
        #expect(!copy.contains(heads: original.heads()), "the copy lacks the later edit")
        #expect(copy.contains(heads: []))
        let other = try TypedDocument(combo("a", "One"))
        #expect(!other.contains(heads: base), "another history under the same id")
    }
}
