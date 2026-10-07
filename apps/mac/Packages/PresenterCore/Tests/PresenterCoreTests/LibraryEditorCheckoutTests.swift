import Automerge
import Foundation
import os
import Testing

@testable import PresenterCore

private func makeRoot() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("editor-checkout-\(UUID().uuidString)")
}

private func key(_ id: String, _ kind: DocumentKind = .presentation) -> SyncLedger.Key {
    SyncLedger.Key(kind: kind, id: id)
}

@LibraryActor private func engine(_ root: URL, decks: [Presentation] = [], limits: LibraryCacheLimits = .standard) throws -> LibraryEngine {
    let engine = LibraryEngine(rootURL: root, limits: limits)
    try engine.bootstrap()
    for deck in decks {
        try engine.create(deck)
    }
    return engine
}

private func change(_ batch: LibraryBatch, _ id: String) throws -> DocumentChange {
    try #require(batch.changes.last { $0.id == id })
}

@LibraryActor private func commit(
    _ replica: EditorReplica<Presentation>, since lastSent: Set<ChangeHash>, to engine: LibraryEngine, token: EditorToken
) throws -> LibraryBatch {
    try engine.commit(Presentation.self, id: replica.value.id, changes: replica.encodeChangesSince(heads: lastSent), token: token)
}

private final class ActorPark: Sendable {
    private struct State {
        var entered = false
        var released = false
        var holding = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    @LibraryActor func hold(atLeast minimum: Duration, atMost maximum: Duration = .seconds(5)) {
        let began = ContinuousClock.now
        state.withLock { $0.entered = true; $0.holding = true }
        while !(state.withLock({ $0.released }) && began.duration(to: .now) >= minimum), began.duration(to: .now) < maximum {
            usleep(500)
        }
        state.withLock { $0.holding = false }
    }

    var entered: Bool { state.withLock { $0.entered } }
    var isHolding: Bool { state.withLock { $0.holding } }

    func release() {
        state.withLock { $0.released = true }
    }
}

@LibraryActor private func isDecoding(_ engine: LibraryEngine, _ id: String) -> Bool {
    engine.editors.decoding.contains(key(id))
}

@LibraryActor private func isPinned(_ engine: LibraryEngine, _ id: String) -> Bool {
    engine.replicas.isPinned(key(id))
}

private func waitUntil(_ comment: Comment, _ condition: @Sendable () async -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(10)
    var met = await condition()
    while !met, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(1))
        met = await condition()
    }
    try #require(met, comment)
}

@Suite struct LibraryEditorCheckoutTests {

    @LibraryActor @Test func aWarmCheckoutIsAForkAndOpensNoFile() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = try engine(root, decks: [editorDeck("d", slides: 6)])
        engine.setAuthor(ChangeAuthor(userHexId: "u1", stationHexId: "st1"))
        let reader = try engine.reader()
        let file = try engine.opened().store.url(kind: .presentation, id: "d")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path) }

        let checkout = try await engine.checkout(Presentation.self, id: "d")
        #expect(reader.cache.documentLoads == 0, "a warm checkout decodes nothing")
        let canonical = try engine.replica(Presentation.self, id: "d")
        #expect(checkout.replica.value == canonical.value && checkout.replica.heads() == canonical.heads())
        #expect(checkout.replica.commitMessage == "u1|st1|presentation")
        #expect(checkout.sequence == engine.sequence && checkout.token.id == "d")
        #expect(engine.replicas.isPinned(key("d")))

        try checkout.replica.update { $0.name = "Edited in the editor" }
        #expect(try engine.replica(Presentation.self, id: "d").value.name == "Deck d")
    }

    @MainActor @Test func aColdCheckoutDecodesBesideTheParkedActorAndAWriteStillLands() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let client = LibraryClient(rootURL: root)
        try await client.start().value
        _ = try await client.create(editorDeck("big", slides: 183)).value
        let engine = client.engine
        await engine.dropReplica(kind: .presentation, id: "big")
        let reader = try await client.reader()

        let checkingOut = Task { try await engine.checkout(Presentation.self, id: "big").replica.value.name }
        try await waitUntil("the checkout never started its decode") {
            await isDecoding(engine, "big") || reader.cache.documentLoads > 0
        }
        let park = ActorPark()
        let parked = Task.detached { await park.hold(atLeast: .milliseconds(200)) }
        while !park.entered {
            try await Task.sleep(for: .milliseconds(1))
        }
        try await waitUntil("the decode waited for the actor") { reader.cache.documentLoads == 1 }
        #expect(park.isHolding, "the deck decoded while the actor was parked")
        let written = client.modify(Presentation.self, id: "big") { $0.name = "Written during the checkout" }

        park.release()
        await parked.value
        let batch = try await written.value
        let name = try await checkingOut.value
        #expect(try await DocumentStore(rootURL: root).load(Presentation.self, id: "big").value.name == "Written during the checkout")
        #expect(name == "Deck big" || name == "Written during the checkout")
        #expect(reader.cache.documentLoads == 1, "one decode, off the actor")
        #expect(await isPinned(engine, "big"))
        #expect(batch.changes.count == 1)
    }

    @LibraryActor @Test func theCheckoutSequenceSplitsTheBatchesTheForkHolds() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = try engine(root, decks: [editorDeck("d", slides: 3)])
        let before = try engine.modify(Presentation.self, id: "d") { $0.name = "Before" }
        let checkout = try await engine.checkout(Presentation.self, id: "d")
        let after = try engine.modify(Presentation.self, id: "d") { $0.name = "After" }
        #expect(before.sequence <= checkout.sequence && after.sequence > checkout.sequence)
        #expect(checkout.replica.value.name == "Before")
    }

    @LibraryActor @Test func bundlesRideOnlySessionDecksAndTheirBasesChain() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = try engine(root, decks: [editorDeck("d", slides: 5), editorDeck("other", slides: 2)])
        let checkout = try await engine.checkout(Presentation.self, id: "d")
        let replica = checkout.replica
        var expectedBase = replica.heads()

        for n in 0..<3 {
            let batch = try engine.edit(Presentation.self, id: "d") { try $0.updateSlide(at: n) { $0.name = "Grid \(n)" } }
            let bundle = try #require(try change(batch, "d").bundle)
            #expect(bundle.base == expectedBase, "write \(n) chains from the one before")
            #expect(bundle.slideScoped && !bundle.replaced)
            #expect(replica.applyLanded(bundle) == .applied(moved: true))
            expectedBase = try engine.replica(Presentation.self, id: "d").heads()
        }
        #expect(replica.value == (try engine.replica(Presentation.self, id: "d")).value)

        let own = replica.heads()
        try replica.update(\.slides[4].name, at: [.init("slides"), .init(UInt64(4)), .init("name")]) { $0 = "Mine" }
        let committed = try change(commit(replica, since: own, to: engine, token: checkout.token), "d")
        #expect(committed.bundle?.base == expectedBase, "the editor's commit chains too")
        #expect(replica.contains(heads: SyncLedger.heads(try #require(committed.heads))), "and the editor holds it")

        let elsewhere = try engine.modify(Presentation.self, id: "other") { $0.name = "Not checked out" }
        #expect(try change(elsewhere, "other").bundle == nil)
        #if DEBUG
        #expect(replica.core.decodes.whole == 0, "three landings, no whole decode")
        #endif
    }

    @LibraryActor @Test func aReplacedDeckIsCheckedOutAgainOntoTheNewCopy() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = try engine(root, decks: [editorDeck("d", slides: 3)])
        let old = try await engine.checkout(Presentation.self, id: "d")
        let batch = try engine.replace(editorDeck("d", slides: 2))
        #expect(batch.changes.map(\.origin) == [.deleted, .local])
        #expect(batch.changes[0].bundle == nil, "a removal carries none")
        let bundle = try #require(batch.changes[1].bundle)
        #expect(bundle.replaced && !bundle.slideScoped && bundle.changes.isEmpty)
        #expect(bundle.base == old.replica.heads())
        #expect(old.replica.applyLanded(bundle) == .refused)

        let fresh = try await engine.checkout(Presentation.self, id: "d", history: .fresh)
        let newCopy = try engine.replica(Presentation.self, id: "d")
        #expect(fresh.replica.value.slides.count == 2 && fresh.replica.heads() == newCopy.heads())
        let sent = fresh.replica.heads()
        try fresh.replica.update(\.slides[1].name, at: [.init("slides"), .init(UInt64(1)), .init("name")]) { $0 = "Edited on the new copy" }
        let committed = try change(commit(fresh.replica, since: sent, to: engine, token: fresh.token), "d")
        #expect(committed.value(as: Presentation.self)?.slides[1].name == "Edited on the new copy")
        #expect(try DocumentStore(rootURL: root).load(Presentation.self, id: "d").value.slides[1].name == "Edited on the new copy")
        #expect(committed.bundle.map { !$0.replaced && $0.base == sent } == true, "chained from the new copy")
        engine.release(token: old.token)

        let next = try #require(try change(engine.edit(Presentation.self, id: "d") { try $0.updateSlide(at: 0) { $0.name = "Grid" } }, "d").bundle)
        #expect(!next.replaced && next.slideScoped)
        #expect(fresh.replica.applyLanded(next) == .applied(moved: true))
    }

    @LibraryActor @Test func theLiveSetStaysWarmAndReplacingItLetsGo() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let live = (0..<12).map { "live\($0)" }
        let looked = (0..<8).map { "looked\($0)" }
        let busy = (0..<25).map { "busy\($0)" }
        let engine = try engine(root, decks: (live + looked + busy).map { editorDeck($0, slides: 2) })
        let reader = try engine.reader()
        for id in live + looked {
            engine.dropReplica(kind: .presentation, id: id)
        }
        await engine.warmLive(ids: Set(live))
        await engine.warm(Presentation.self, ids: looked)
        #expect(reader.cache.documentLoads == 20)
        #expect(engine.replicas.warmIDs(.presentation) == looked, "the live decks are not counted in the warm set")

        try engine.refile(busy.map { LibraryRefile(kind: .presentation, id: $0, folder: "Archive", folderId: nil) })
        let store = try engine.opened().store
        for id in busy.prefix(10) {
            let landed = try store.load(Presentation.self, id: id)
            try landed.update { $0.name = "Landed \(id)" }
            try engine.save(landed, origin: .landed)
        }
        func held(_ id: String) -> Bool {
            engine.replicas.holds(key(id), stamp: DocumentFileStamp.of(store.url(kind: .presentation, id: id)))
        }
        #expect((live + looked).allSatisfy(held), "every live and looked-at deck is still held")
        let open = try await engine.checkout(Presentation.self, id: "live3")
        #expect(reader.cache.documentLoads == 20, "a live deck's checkout is a fork")

        await engine.warmLive(ids: ["live0", "busy0"])
        #expect(engine.replicas.isLive(key("busy0")) && !engine.replicas.isLive(key("live1")))
        try engine.refile(busy.map { LibraryRefile(kind: .presentation, id: $0, folder: "Moved", folderId: nil) })
        #expect(held("live0"), "still live")
        #expect(held("live3"), "still checked out: the session pins it")
        #expect(!live.filter { $0 != "live0" && $0 != "live3" }.contains(where: held), "let go: the write-recency LRU evicted them")
        #expect(looked.allSatisfy(held), "the looked-at warm set is untouched")
        #expect(open.replica.value.id == "live3")
    }

    @LibraryActor @Test func anOlderLiveRequestNeverOverwritesANewerOne() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = try engine(root, decks: [editorDeck("a", slides: 1), editorDeck("b", slides: 1)])
        await engine.warmLive(ids: ["b"], asked: 2)
        await engine.warmLive(ids: ["a"], asked: 1)
        #expect(engine.replicas.live == [key("b")])
    }

    @LibraryActor @Test func aDeleteDuringASessionRefusesItsLaterCommitsQuietly() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = try engine(root, decks: [editorDeck("gone", slides: 2), editorDeck("swapped", slides: 2)])
        let gone = try await engine.checkout(Presentation.self, id: "gone")
        let swapped = try await engine.checkout(Presentation.self, id: "swapped")
        try engine.delete(kind: .presentation, id: "gone")
        try engine.replace(editorDeck("swapped", slides: 1))
        let sequence = engine.sequence

        for (checkout, id) in [(gone, "gone"), (swapped, "swapped")] {
            let sent = checkout.replica.heads()
            try checkout.replica.update { $0.name = "Edited after it went" }
            #expect(throws: LibraryEngine.EditorError.sessionEnded) {
                try commit(checkout.replica, since: sent, to: engine, token: checkout.token)
            }
            _ = id
        }
        #expect(engine.sequence == sequence, "nothing published")
        let store = try engine.opened().store
        #expect(!store.exists(kind: .presentation, id: "gone"))
        #expect(try store.load(Presentation.self, id: "swapped").value.slides.count == 1, "the new copy is untouched")

        engine.release(token: gone.token, history: gone.replica.history)
        #expect(!engine.replicas.isWarm(key("gone")) && engine.editors.parked[key("gone")] == nil)
        let fresh = try await engine.checkout(Presentation.self, id: "swapped")
        let sent = fresh.replica.heads()
        try fresh.replica.update { $0.name = "On the new copy" }
        #expect(try commit(fresh.replica, since: sent, to: engine, token: fresh.token).changes.count == 1, "a new session commits")
    }

    @MainActor @Test func theClientsRefusedCommitIsQuiet() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let client = LibraryClient(rootURL: root)
        try await client.start().value
        _ = try await client.create(editorDeck("d", slides: 2)).value
        let checkout = try await client.checkout(Presentation.self, id: "d")
        _ = try await client.delete(kind: .presentation, id: "d").value
        let applied = client.lastAppliedSequence
        let sent = checkout.replica.heads()
        try checkout.replica.update { $0.name = "Too late" }
        let refused = client.commit(Presentation.self, id: "d", changes: try checkout.replica.encodeChangesSince(heads: sent), token: checkout.token)
        await #expect(throws: LibraryEngine.EditorError.sessionEnded) { try await refused.value }
        await client.settled()
        #expect(client.lastAppliedSequence == applied)
    }

    @LibraryActor @Test func releaseUnpinsAndWarms() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = try engine(root, decks: [editorDeck("a", slides: 1), editorDeck("b", slides: 1)])
        let a = try await engine.checkout(Presentation.self, id: "a")
        let again = try await engine.checkout(Presentation.self, id: "a")
        let b = try await engine.checkout(Presentation.self, id: "b")
        engine.release(token: a.token)
        #expect(engine.replicas.isPinned(key("a")), "a second session still holds it")
        engine.release(token: again.token)
        engine.release(token: b.token)
        #expect(!engine.replicas.isPinned(key("a")) && !engine.replicas.isPinned(key("b")))
        #expect(engine.replicas.warmIDs(.presentation) == ["a", "b"])
        #expect(engine.editors.bases.isEmpty && engine.editors.sessions.isEmpty)
        engine.release(token: b.token)
        #expect(engine.replicas.warmIDs(.presentation) == ["a", "b"], "a second release of a token does nothing")
    }

    @LibraryActor @Test func historyRoundTripsAcrossReleaseAndAWriteDropsIt() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = try engine(root, decks: [editorDeck("d", slides: 2)])

        func session(_ name: String) async throws -> EditorHistory {
            let checkout = try await engine.checkout(Presentation.self, id: "d")
            let sent = checkout.replica.heads()
            try checkout.replica.update { $0.name = name }
            try commit(checkout.replica, since: sent, to: engine, token: checkout.token)
            let history = checkout.replica.history
            engine.release(token: checkout.token, history: history)
            return history
        }

        _ = try await session("Edited")
        let back = try await engine.checkout(Presentation.self, id: "d")
        #expect(back.replica.canUndo, "the parked history came back")
        #expect(try back.replica.undo().name == "Deck d")
        engine.release(token: back.token)

        _ = try await session("Edited again")
        try engine.modify(Presentation.self, id: "d") { $0.slides[0].name = "The grid wrote since" }
        let afterWrite = try await engine.checkout(Presentation.self, id: "d")
        #expect(!afterWrite.replica.canUndo, "a write since the release dropped it")
        engine.release(token: afterWrite.token)

        _ = try await session("Once more")
        let fresh = try await engine.checkout(Presentation.self, id: "d", history: .fresh)
        #expect(!fresh.replica.canUndo)
        #expect(engine.editors.parked.isEmpty, "a checkout consumes what was parked")
    }

    @LibraryActor @Test func theWarmSetSurvivesARefileChunkAndTenLandings() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let warm = (0..<8).map { "warm\($0)" }
        let busy = (0..<25).map { "busy\($0)" }
        let engine = try engine(root, decks: (warm + busy).map { editorDeck($0, slides: 2) })
        let reader = try engine.reader()
        for id in warm {
            engine.dropReplica(kind: .presentation, id: id)
        }
        await engine.warm(Presentation.self, ids: warm)
        #expect(reader.cache.documentLoads == 8)
        #expect(engine.replicas.warmIDs(.presentation) == warm)

        try engine.refile(busy.map { LibraryRefile(kind: .presentation, id: $0, folder: "Archive", folderId: nil) })
        let store = try engine.opened().store
        for id in busy.prefix(10) {
            let landed = try store.load(Presentation.self, id: id)
            try landed.update { $0.name = "Landed \(id)" }
            try engine.save(landed, origin: .landed)
        }
        for id in warm {
            #expect(engine.replicas.holds(key(id), stamp: DocumentFileStamp.of(store.url(kind: .presentation, id: id))), "\(id) stayed warm")
            _ = try await engine.checkout(Presentation.self, id: id)
        }
        #expect(reader.cache.documentLoads == 8, "every checkout was a fork")
        #expect(engine.replicas.count <= 8 + 8, "the write-recency LRU still bounds the rest")

        await engine.warm(Presentation.self, ids: ["busy24"])
        #expect(engine.replicas.warmIDs(.presentation).count == 8 && engine.replicas.warmIDs(.presentation).last == "busy24")
    }

    @LibraryActor @Test func aWarmDecodeNeverLandsOverAWrite() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = try engine(root, decks: [editorDeck("d", slides: 3)])
        let reader = try engine.reader()
        await engine.warm(Presentation.self, ids: ["d", "missing"])
        #expect(reader.cache.documentLoads == 0, "held already: marked warm, not decoded")
        #expect(engine.replicas.isWarm(key("d")))

        engine.dropReplica(kind: .presentation, id: "d")
        let warming = Task { await engine.warm(Presentation.self, ids: ["d"]) }
        try engine.modify(Presentation.self, id: "d") { $0.name = "Written while it warmed" }
        await warming.value
        #expect(try engine.replica(Presentation.self, id: "d").value.name == "Written while it warmed")
    }

    @Test func documentChangesCarryNoBundleByDefault() {
        let change = DocumentChange(kind: .presentation, id: "d", origin: .local, value: nil)
        #expect(change.bundle == nil)
    }

    @MainActor @Test func theClientsCheckoutFollowsQueuedCommandsAndWarmForks() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let client = LibraryClient(rootURL: root)
        try await client.start().value
        client.create(editorDeck("d", slides: 2))
        client.modify(Presentation.self, id: "d") { $0.name = "Queued just before" }
        let checkout = try await client.checkout(Presentation.self, id: "d")
        #expect(checkout.replica.value.name == "Queued just before")
        _ = try await client.release(token: checkout.token, history: checkout.replica.history).value

        await client.engine.dropReplica(kind: .presentation, id: "d")
        await client.warm(Presentation.self, ids: ["d"]).value
        let reader = try await client.reader()
        let loads = reader.cache.documentLoads
        _ = try await client.checkout(Presentation.self, id: "d")
        #expect(reader.cache.documentLoads == loads, "warmed: the checkout is a fork")
    }
}

extension LibraryEngine {

    @LibraryActor static func bootstrapped(_ root: URL) throws -> LibraryEngine {
        let engine = LibraryEngine(rootURL: root)
        try engine.bootstrap()
        return engine
    }
}
