import Foundation
import Testing

@testable import PresenterCore

private func makeRoot() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("sync-hold-\(UUID().uuidString)")
}

@Suite struct SyncHoldTests {
    private let key = SyncLedger.Key(kind: .actionCombo, id: "c1")

    @Test func aRemoteDeleteWaitsWhilePausedOrWhileTheLiveServiceUsesItAndALocalOneWhilePaused() {
        var asked = false
        #expect(SyncDeleteHold.remote(paused: true, usedByLive: { asked = true; return false }()) == .hold("paused for the service"))
        #expect(!asked, "paused: the services are not walked")
        #expect(SyncDeleteHold.remote(paused: false, usedByLive: true) == .hold("the live service uses it"))
        #expect(SyncDeleteHold.remote(paused: false, usedByLive: false) == .apply, "no service running: at once")
        #expect(SyncDeleteHold.local(paused: true) == .hold("paused for the service"))
        #expect(SyncDeleteHold.local(paused: false) == .apply, "a live service never holds a delete made here")
    }

    @Test func aHeldDeleteIsReleasedWhenWhatItWaitsForLetsGo() {
        let remote = SyncLedger.HeldDelete(key: key, side: .remote, namespace: .team)
        #expect(SyncDeleteHold.release(remote, paused: true, usedByLive: false, heldHere: true, currentNamespace: .team) == .keep)
        #expect(SyncDeleteHold.release(remote, paused: false, usedByLive: true, heldHere: true, currentNamespace: .team) == .keep)
        #expect(SyncDeleteHold.release(remote, paused: false, usedByLive: false, heldHere: true, currentNamespace: .team) == .apply)
        #expect(SyncDeleteHold.release(remote, paused: true, usedByLive: true, heldHere: false, currentNamespace: nil) == .drop, "the copy already left")

        let local = SyncLedger.HeldDelete(key: key, side: .local, namespace: .team)
        #expect(SyncDeleteHold.release(local, paused: true, usedByLive: false, heldHere: false, currentNamespace: nil) == .keep)
        #expect(SyncDeleteHold.release(local, paused: false, usedByLive: true, heldHere: false, currentNamespace: nil) == .apply)
        #expect(SyncDeleteHold.release(local, paused: false, usedByLive: false, heldHere: true, currentNamespace: .station) == .apply, "moved away: the old copy's tombstone goes")
        #expect(SyncDeleteHold.release(local, paused: false, usedByLive: false, heldHere: true, currentNamespace: .team) == .drop, "it lives there again: no tombstone")

        #expect(SyncDeleteHold.isHeldLocally(key, in: [local]) && !SyncDeleteHold.isHeldLocally(key, in: [remote]))
    }

    @Test func theCheckpointSnapshotsOnlyWhatTheCloudAlreadyHolds() {
        let synced = SyncLedger.Entry(lastPushedHeads: ["a"], appliedSeq: 3, remoteSeq: 3)
        #expect(SyncCheckpoint.snapshots(entry: synced, localHeads: ["a"]))
        #expect(!SyncCheckpoint.snapshots(entry: synced, localHeads: ["b"]), "edits the cloud lacks stay owed")
        var pending = synced
        pending.pending = true
        #expect(!SyncCheckpoint.snapshots(entry: pending, localHeads: ["a"]), "a push owed (the pause's mark, a failed push)")
        #expect(!SyncCheckpoint.snapshots(entry: nil, localHeads: ["a"]), "never synced: nothing to compact")
    }

    @LibraryActor @Test func heldDeletesAreKeptAcrossARelaunchAndTheDocumentsRemoval() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let local = SyncLedger.HeldDelete(key: key, side: .local, namespace: .team, heldAt: Date(timeIntervalSince1970: 100))
        let remote = SyncLedger.HeldDelete(
            key: SyncLedger.Key(kind: .presentation, id: "deck"), side: .remote, namespace: .station, heldAt: Date(timeIntervalSince1970: 200))
        do {
            let engine = LibraryEngine(rootURL: root)
            try engine.bootstrap()
            _ = try engine.create(ActionCombo(id: "c1", name: "Walk-in", actions: []))
            let held = try engine.holdDelete(local)
            #expect(held.sync.heldDeletes == [local])
            _ = try engine.holdDelete(remote)
            _ = try engine.delete(kind: .actionCombo, id: "c1")
            #expect(engine.sync.heldDeletes == [local, remote], "the document's removal keeps its hold")
        }
        let reopened = LibraryEngine(rootURL: root)
        let start = try reopened.bootstrap()
        #expect(start.sync.heldDeletes == [local, remote], "read back at the open, oldest first")
        _ = try reopened.releaseHeldDelete(local)
        #expect(reopened.sync.heldDeletes == [remote])
        _ = try reopened.resetSyncState()
        #expect(reopened.sync.heldDeletes.isEmpty)
        #expect(try LibraryIndex(url: root.appendingPathComponent("index.sqlite")).allHeldDeletes().isEmpty)
    }

    @LibraryActor @Test func aDeleteMadeHereNamesTheNamespaceItSyncedUnder() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = LibraryEngine(rootURL: root)
        try engine.bootstrap()
        for (id, area) in [("team", LibraryArea.team), ("station", .station), ("local", .local)] {
            _ = try engine.create(ActionCombo(id: id, name: id, actions: []))
            _ = try engine.setArea(area, of: [SyncLedger.Key(kind: .actionCombo, id: id)])
        }
        _ = try engine.create(ActionCombo(id: "synced", name: "synced", actions: []))
        _ = try engine.setSyncEntry(SyncLedger.Entry(lastPushedHeads: ["h"], appliedSeq: 1, remoteSeq: 1), kind: .actionCombo, id: "synced")
        _ = try engine.create(ActionCombo(id: "landed", name: "landed", actions: []))
        var named: [String: SyncScope?] = [:]
        for id in ["team", "station", "local", "synced"] {
            let batch = try engine.delete(kind: .actionCombo, id: id)
            named[id] = batch.changes.first?.syncedUnder
            #expect(SyncBatchRoute(batch).deletedFrom[SyncLedger.Key(kind: .actionCombo, id: id)] == batch.changes.first?.syncedUnder)
        }
        #expect(named == ["team": .team, "station": .station, "local": nil, "synced": .team], "no area row: the ledger's guess")
        let landed = try engine.delete(kind: .actionCombo, id: "landed", origin: .landed)
        #expect(landed.changes.first?.syncedUnder == nil, "a landing's removal sends nothing")
    }
}
