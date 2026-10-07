import Foundation
import SQLite3
import Testing

@testable import PresenterCore

private func makeRoot() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("sync-owed-\(UUID().uuidString)")
}

private func combo(_ id: String, _ name: String) -> ActionCombo {
    ActionCombo(id: id, name: name, actions: [])
}

private func rawSQL(_ root: URL, _ sql: String) throws {
    var db: OpaquePointer?
    try #require(sqlite3_open(root.appendingPathComponent("index.sqlite").path, &db) == SQLITE_OK)
    defer { sqlite3_close(db) }
    try #require(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK, "\(sql)")
}

@Suite struct SyncOwedTests {
    private let key = SyncLedger.Key(kind: .actionCombo, id: "c1")

    @Test func aRowIsOwedWhenPendingOrWhenTheRecordedHeadsDifferFromWhatTheServerHolds() {
        let synced = SyncLedger.Entry(lastPushedHeads: ["a"], appliedSeq: 2, remoteSeq: 2)
        #expect(!SyncOwedLogic.isOwed(entry: synced, recordedHeads: ["a"]), "in sync")
        #expect(SyncOwedLogic.isOwed(entry: synced, recordedHeads: ["b"]), "a write here the server lacks, with no pending flag")
        #expect(!SyncOwedLogic.isOwed(entry: synced, recordedHeads: nil), "no heads recorded yet: unknown is never owed")
        var pending = synced
        pending.pending = true
        #expect(SyncOwedLogic.isOwed(entry: pending, recordedHeads: nil) && SyncOwedLogic.isOwed(entry: pending, recordedHeads: ["a"]))
        #expect(!SyncOwedLogic.isOwed(entry: nil, recordedHeads: ["a"]), "no row: the index diff's, not this rule's")
    }

    @Test func theOwedListLeavesOutWhatHasNoCloudNamespace() {
        let other = SyncLedger.Key(kind: .actionCombo, id: "c2")
        let local = SyncLedger.Key(kind: .actionCombo, id: "c3")
        let entries = [
            key: SyncLedger.Entry(lastPushedHeads: ["a"]), other: SyncLedger.Entry(lastPushedHeads: ["a"], pending: true),
            local: SyncLedger.Entry(lastPushedHeads: ["a"], pending: true),
        ]
        let owed = SyncOwedLogic.owed(entries: entries, recordedHeads: [key: ["b"]]) { $0 == local ? nil : .team }
        #expect(owed == [key, other], "Local Only never pushes; sorted by kind then id")
    }

    @Test func thePassAsksThePauseLastAndSkipsWhatWaitsIsBusyOrRests() {
        var asked: [String] = []
        func ask(_ name: String, _ answer: Bool) -> Bool {
            asked.append(name)
            return answer
        }
        #expect(SyncOwedPass.verdict(identityAllows: ask("identity", false), signedIn: ask("signedIn", true), rateLimited: ask("rate", false), paused: ask("paused", false)) == .skip("identity"))
        #expect(asked == ["identity"], "nothing after a failed guard is evaluated")
        asked = []
        #expect(SyncOwedPass.verdict(identityAllows: ask("identity", true), signedIn: ask("signedIn", true), rateLimited: ask("rate", true), paused: ask("paused", true)) == .skip("rate limited"))
        #expect(asked == ["identity", "signedIn", "rate"], "the 429 hold is before the pause (which arms the resume)")
        #expect(SyncOwedPass.verdict(identityAllows: true, signedIn: true, rateLimited: false, paused: true) == .paused)
        #expect(SyncOwedPass.verdict(identityAllows: true, signedIn: false, rateLimited: false, paused: false) == .skip("signed out"))
        #expect(SyncOwedPass.verdict(identityAllows: true, signedIn: true, rateLimited: false, paused: false) == .run)

        let keys = ["a", "b", "c", "d"].map { SyncLedger.Key(kind: .actionCombo, id: $0) }
        let due = SyncOwedPass.due(keys, waiting: [keys[0]], busy: [keys[1]]) { $0 != keys[2] }
        #expect(due == [keys[3]], "a beat armed, in flight, resting after failures: not the pass's")
    }

    @LibraryActor @Test func theEngineRecordsHeadsAtEveryWriteAndKeepsThemAcrossARelaunch() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var heads: [String]?
        do {
            let engine = LibraryEngine(rootURL: root)
            try engine.bootstrap()
            let made = try engine.create(combo("c1", "Walk-in"))
            #expect(engine.recordedHeads(kind: .actionCombo, id: "c1") == made.changes.first?.heads)
            let edited = try engine.modify(ActionCombo.self, id: "c1") { $0.name = "Walk-in 2" }
            heads = edited.changes.first?.heads
            #expect(engine.recordedHeads(kind: .actionCombo, id: "c1") == heads && heads != made.changes.first?.heads)
            let board = try engine.modify(
                GroupPalette.self, id: GroupPalette.wellKnownID, orMake: { GroupPalette(id: GroupPalette.wellKnownID, groups: []) }) { _ in }
            #expect(engine.recordedHeads(kind: .groupPalette, id: GroupPalette.wellKnownID) == board.changes.first?.heads, "unlisted writes too")
            _ = try engine.create(combo("gone", "Gone"))
            _ = try engine.delete(kind: .actionCombo, id: "gone")
            #expect(engine.recordedHeads(kind: .actionCombo, id: "gone") == nil)
        }
        let reopened = LibraryEngine(rootURL: root)
        try reopened.bootstrap()
        #expect(reopened.recordedHeads(kind: .actionCombo, id: "c1") == heads, "read back at the open")
        #expect(try LibraryIndex(url: root.appendingPathComponent("index.sqlite")).allDocumentHeads()[SyncLedger.Key(kind: .actionCombo, id: "gone")] == nil)
    }

    @LibraryActor @Test func aWriteTheServerLacksIsOwedWithNoPendingFlag() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = LibraryEngine(rootURL: root)
        try engine.bootstrap()
        let made = try engine.create(combo("c1", "Walk-in"))
        #expect(engine.owedDocuments().isEmpty, "no row yet: the index diff pushes a document the cloud never saw")
        _ = try engine.setSyncEntry(SyncLedger.Entry(lastPushedHeads: made.changes[0].heads ?? [], appliedSeq: 1, remoteSeq: 1), kind: .actionCombo, id: "c1")
        #expect(engine.owedDocuments().isEmpty, "in sync")
        let edited = try engine.modify(ActionCombo.self, id: "c1") { $0.name = "Walk-in 2" }
        #expect(engine.syncEntry(kind: .actionCombo, id: "c1")?.pending == false)
        #expect(engine.owedDocuments() == [key], "the edit is owed though nothing marked it")
        _ = try engine.setArea(.local, of: [key])
        #expect(engine.owedDocuments().isEmpty, "Local Only never pushes")
        _ = try engine.setArea(.station, of: [key])
        _ = try engine.updateSyncEntry(kind: .actionCombo, id: "c1") { $0.lastPushedHeads = edited.changes[0].heads ?? [] }
        #expect(engine.owedDocuments().isEmpty)
    }

    @LibraryActor @Test func aLibraryFromBeforeTheOwedRuleOpensWithNothingNewOwed() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let synced = SyncLedger.Key(kind: .actionCombo, id: "synced")
        let diverged = SyncLedger.Key(kind: .actionCombo, id: "diverged")
        let pending = SyncLedger.Key(kind: .actionCombo, id: "pending")
        do {
            let engine = LibraryEngine(rootURL: root)
            try engine.bootstrap()
            for key in [synced, diverged, pending] {
                let made = try engine.create(combo(key.id, key.id))
                let heads = key == diverged ? ["an older head"] : made.changes[0].heads ?? []
                _ = try engine.setSyncEntry(SyncLedger.Entry(lastPushedHeads: heads, appliedSeq: 1, remoteSeq: 1, pending: key == pending), kind: key.kind, id: key.id)
            }
            #expect(engine.owedDocuments() == [diverged, pending])
        }
        try rawSQL(root, "DROP TABLE document_heads")
        let upgraded = LibraryEngine(rootURL: root)
        try upgraded.bootstrap()
        #expect(upgraded.owedDocuments() == [pending], "only what was already owed: no storm")
        #expect(try upgraded.localHeads(kind: .actionCombo, id: "diverged") != nil)
        #expect(upgraded.owedDocuments() == [diverged, pending], "a read of its heads records them, and the missed send heals")
    }
}

@Suite struct SyncRefreshCoalescerTests {
    @Test func aRequestDuringAPassRunsItOnceMoreHoweverManyAsked() {
        var refreshes = SyncRefreshCoalescer()
        let first = refreshes.request()
        let during = [refreshes.request(), refreshes.request(), refreshes.request()]
        let again = refreshes.finish()
        let done = refreshes.finish()
        #expect(first, "idle: run now")
        #expect(during == [false, false, false], "running: owed")
        #expect(again, "once more")
        #expect(!done, "then done")
        #expect(!refreshes.running && !refreshes.owed)
        let alone = (refreshes.request(), refreshes.finish())
        #expect(alone == (true, false), "a pass nobody asked about again ends")
    }

    @Test func theSafetyNetReadsAtMostOnceAMinuteAndNeverDuringAPass() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var refreshes = SyncRefreshCoalescer()
        #expect(refreshes.safetyNetDue(lastFinished: nil, now: now))
        #expect(!refreshes.safetyNetDue(lastFinished: now.addingTimeInterval(-59), now: now))
        #expect(refreshes.safetyNetDue(lastFinished: now.addingTimeInterval(-60), now: now))
        let started = refreshes.request()
        #expect(started && !refreshes.safetyNetDue(lastFinished: nil, now: now), "a pass is running")
        #expect(SyncRefreshCoalescer.safetyNetInterval == 60)
    }
}
