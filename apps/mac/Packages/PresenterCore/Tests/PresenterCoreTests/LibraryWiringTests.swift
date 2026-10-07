import Foundation
import os
import Testing

@testable import PresenterCore

private func makeRoot() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("library-wiring-\(UUID().uuidString)")
}

private func deck(_ id: String, name: String = "Deck", slides count: Int = 4) -> Presentation {
    Presentation(
        id: id, name: name, presentationKind: .song, themeId: "",
        slides: (0..<count).map { n in
            Slide(
                id: "slide-\(n)", name: "Verse \(n)",
                objects: [SlideObject(id: "text-\(n)", objectKind: .text, name: "Lyrics", text: "Line \(n)")],
                actions: [SlideAction(id: "clear-\(n)", kind: .clearAll)])
        })
}

private func combo(_ id: String, _ name: String) -> ActionCombo {
    ActionCombo(id: id, name: name, actions: [])
}

@LibraryActor private func indexed(_ root: URL, _ id: String) throws -> LibraryIndex.Entry? {
    try LibraryIndex(url: root.appendingPathComponent("index.sqlite")).entry(id: id)
}

@LibraryActor private func stored<E: DocumentEntity>(_ type: E.Type, _ root: URL, _ id: String) throws -> E {
    try DocumentStore(rootURL: root).load(type, id: id).value
}

@MainActor private final class RecordingReadSide: LibraryReadSide {
    var combos: [String: ActionCombo] = [:]
    var decks: [String: Presentation] = [:]
    private(set) var optimistic: [DocumentChange] = []
    private(set) var failures: [String] = []
    private(set) var batches: [LibraryBatch] = []
    let observers = LibraryBatchObservers()

    func currentValue(_ kind: DocumentKind, id: String) -> (any DocumentEntity)? {
        kind == .actionCombo ? combos[id] : kind == .presentation ? decks[id] : nil
    }

    func applyOptimistic(_ change: DocumentChange) {
        optimistic.append(change)
        land(change)
    }

    func optimisticWriteFailed(_ change: DocumentChange, error: any Error) {
        failures.append(change.id)
    }

    func apply(_ batch: LibraryBatch) {
        batches.append(batch)
        batch.changes.forEach(land)
        observers.notify(batch)
    }

    private func land(_ change: DocumentChange) {
        if change.kind == .actionCombo {
            combos[change.id] = change.value(as: ActionCombo.self)
        } else if change.kind == .presentation {
            decks[change.id] = change.value(as: Presentation.self)
        }
    }
}

@MainActor private func startedClient(_ root: URL, readSide: RecordingReadSide? = nil) async throws -> LibraryClient {
    let client = LibraryClient(rootURL: root)
    client.readSide = readSide
    try await client.start().value
    return client
}

@MainActor private func until(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(10)
    while !condition(), ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(2))
    }
    try #require(condition(), "timed out")
}

@Suite struct LibraryWiringEngineTests {

    @LibraryActor @Test func aWellKnownIDEditHasNoIndexRowAndIsPushedWhenItsKindSyncs() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = LibraryEngine(rootURL: root)
        try engine.bootstrap()

        let made = try engine.modify(
            SchedulerBoard.self, id: SchedulerBoard.wellKnownID,
            orMake: { SchedulerBoard(id: SchedulerBoard.wellKnownID, nodes: [], folders: []) }
        ) { _ = $0.addFolder(named: "Morning", id: "f1") }
        let edited = try engine.modify(
            SchedulerBoard.self, id: SchedulerBoard.wellKnownID,
            orMake: { SchedulerBoard(id: SchedulerBoard.wellKnownID, nodes: [], folders: []) }
        ) { $0.renameFolder(id: "f1", to: "Evening") }
        for batch in [made, edited] {
            #expect(batch.changes.map(\.listed) == [false])
            #expect(batch.changes.map(\.origin) == [.local])
            #expect(SyncBatchRoute(batch).edited == [SyncLedger.Key(kind: .schedulerBoard, id: SchedulerBoard.wellKnownID)], "pushed")
        }
        let ledger = try engine.modify(
            ImportLedger.self, id: ImportLedger.wellKnownID, orMake: { ImportLedger(id: ImportLedger.wellKnownID, entries: []) }
        ) { $0.entries.append(ImportLedgerEntry(docId: "d1", hash: "h1")) }
        #expect(ledger.changes.map(\.listed) == [false])
        #expect(SyncBatchRoute(ledger).edited.isEmpty, "the import ledger stays local")
        #expect(edited.snapshot.entry(id: SchedulerBoard.wellKnownID) == nil)
        #expect(try indexed(root, SchedulerBoard.wellKnownID) == nil, "no index row")
        #expect(try stored(SchedulerBoard.self, root, SchedulerBoard.wellKnownID).folders.map(\.name) == ["Evening"])

        let listed = try engine.modify(ActionCombo.self, id: "c1", orMake: { combo("c1", "Walk-in") }) { $0.name = "Walk-in 2" }
        #expect(listed.changes.map(\.listed) == [true])
        #expect(SyncBatchRoute(listed).edited == [SyncLedger.Key(kind: .actionCombo, id: "c1")])
        #expect(try indexed(root, "c1")?.name == "Walk-in 2")
    }

    @LibraryActor @Test func launchPreparationPublishesNothing() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = LibraryEngine(rootURL: root)
        let start = try engine.bootstrap { library in
            try library.create(combo("seeded", "Starter"))
            try library.rebuildIndex()
        }
        #expect(start.snapshot.entry(id: "seeded")?.name == "Starter", "the first snapshot has what it wrote")
        let first = try engine.touchUsage(id: "seeded")
        #expect(first.sequence == 1, "the preparation published no batch before it")
        var iterator = start.batches.makeAsyncIterator()
        #expect(await iterator.next()?.sequence == 1)
    }

    @Test(.disabled(
        if: ProcessInfo.processInfo.environment["MXU_VERIFY_SCOPED_WRITES"] != nil,
        "diverges the document from the cache on purpose"))
    @LibraryActor func aScopedSlideEditEncodesOnlyItsSlide() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = LibraryEngine(rootURL: root)
        try engine.bootstrap()
        try engine.create(deck("d"))

        let replica = try engine.replica(Presentation.self, id: "d")
        try plant("Planted", onSlide: 3, in: replica)
        let batch = try engine.edit(Presentation.self, id: "d") { try $0.updateSlide(id: "slide-0") { $0.actions = nil } }
        #expect(batch.changes.map(\.origin) == [.local])
        #expect(try stored(Presentation.self, root, "d").slides[3].name == "Planted", "slide 3 was never written")
        #expect(try stored(Presentation.self, root, "d").slides[0].actions == nil)

        let whole = try engine.replica(Presentation.self, id: "d")
        try plant("Planted again", onSlide: 3, in: whole)
        try engine.modify(Presentation.self, id: "d") { $0.slides[0].name = "Verse zero" }
        #expect(try stored(Presentation.self, root, "d").slides[3].name != "Planted again", "the whole-value edit rewrote slide 3")
    }

    @LibraryActor @Test func aRefusedScopedOpPublishesNothing() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = LibraryEngine(rootURL: root)
        let start = try engine.bootstrap()
        try engine.create(deck("d"))
        let before = try stored(Presentation.self, root, "d")
        #expect(throws: (any Error).self) {
            try engine.edit(Presentation.self, id: "d") { try $0.updateSlides { $0.slides.removeFirst() } }
        }
        #expect(try stored(Presentation.self, root, "d") == before)
        let next = try engine.touchUsage(id: "d")
        #expect(next.sequence == 2, "the create's batch, then this one: the refused op published none")
        _ = start
    }

    @LibraryActor @Test func maintenancePublishesWhatTheLibrarySavedAndDeleted() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = LibraryEngine(rootURL: root)
        try engine.bootstrap()
        try engine.create(combo("gone", "Old"))
        let batch = try engine.maintain { library in
            try library.create(combo("c1", "Made"))
            try library.delete(kind: .actionCombo, id: "gone")
        }
        #expect(batch.changes.map { "\($0.origin.rawValue) \($0.id)" } == ["local c1", "deleted gone"])
        #expect(batch.value(ActionCombo.self, id: "c1")?.name == "Made")
        #expect(batch.snapshot.entry(id: "c1")?.name == "Made")
        #expect(batch.snapshot.entry(id: "gone") == nil)
        #expect(SyncBatchRoute(batch).edited == [SyncLedger.Key(kind: .actionCombo, id: "c1")])
        #expect(SyncBatchRoute(batch).deleted == [SyncLedger.Key(kind: .actionCombo, id: "gone")])
    }

    @LibraryActor private func plant(_ name: String, onSlide index: Int, in document: TypedDocument<Presentation>) throws {
        let doc = document.document
        if case let .Object(slides, _)? = try doc.get(obj: .ROOT, key: "slides"),
           case let .Object(slide, _)? = try doc.get(obj: slides, index: UInt64(index)) {
            try doc.put(obj: slide, key: "name", value: .String(name))
        } else {
            Issue.record("slide \(index) not found")
        }
    }
}

@MainActor @Suite struct LibraryWiringClientTests {

    @Test func everyFunnelsOptimisticValueIsTheValueItsBatchBringsBack() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let side = RecordingReadSide()
        let client = try await startedClient(root, readSide: side)

        var tasks: [(name: String, task: Task<LibraryBatch, any Error>, key: SyncLedger.Key)] = []
        let deckKey = SyncLedger.Key(kind: .presentation, id: "d")
        tasks.append(("create", client.create(deck("d")), deckKey))
        tasks.append(("modify", client.modify(Presentation.self, id: "d") { $0.name = "Renamed" }, deckKey))
        tasks.append(("slide", client.edit(Presentation.self, id: "d", value: { deck in
            if let index = deck.slides.firstIndex(where: { $0.id == "slide-1" }) { deck.slides[index].notes = "Key change" }
        }, op: { try $0.updateSlide(id: "slide-1") { $0.notes = "Key change" } }), deckKey))
        let clear: @Sendable (inout Presentation) -> Void = { deck in
            for index in deck.slides.indices { deck.slides[index].actions = nil }
        }
        tasks.append(("slides", client.edit(Presentation.self, id: "d", value: clear, op: { try $0.updateSlides(clear) }), deckKey))
        tasks.append(("field", client.edit(Presentation.self, id: "d", value: { $0.musicKey = "D" }, op: {
            try $0.updateField(\.musicKey, key: "musicKey", to: "D")
        }), deckKey))
        tasks.append(("list", client.write("d") { $0.swapAt(0, 1) }, deckKey))
        let comboKey = SyncLedger.Key(kind: .actionCombo, id: "c1")
        tasks.append(("create combo", client.create(combo("c1", "Walk-in")), comboKey))
        tasks.append(("orMake", client.modify(ActionCombo.self, id: "c1", orMake: { combo("c1", "Made") }) { $0.name += "!" }, comboKey))

        #expect(side.optimistic.count == tasks.count, "every funnel applied before the actor wrote")
        for (index, entry) in tasks.enumerated() {
            let batch = try await entry.task.value
            let canonical = try #require(batch.changes.last { $0.key == entry.key }?.value)
            let optimistic = try #require(side.optimistic[index].value)
            #expect(optimistic.isEqualTo(canonical), "\(entry.name): the optimistic value is the one that landed")
        }
        #expect(side.failures.isEmpty)
    }

    @Test func undoAfterAQueuedModifyRestoresTheBeforeValue() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let side = RecordingReadSide()
        let client = try await startedClient(root, readSide: side)
        _ = try await client.create(combo("c1", "Walk-in")).value
        let journal = MoveUndoJournal()

        let before = try #require(side.combos["c1"])
        client.modify(ActionCombo.self, id: "c1") { $0.name = "Walk-out" }
        let after = try #require(side.combos["c1"])
        #expect(after.name == "Walk-out", "main holds the edit at once")
        journal.registerEdit(key: "rename:c1", label: "Rename", undo: {
            client.modify(ActionCombo.self, id: "c1") { $0 = before }
            return true
        }, redo: {
            client.modify(ActionCombo.self, id: "c1") { $0 = after }
            return true
        })
        #expect(journal.undo(), "undone before the edit's batch landed")
        #expect(side.combos["c1"] == before)
        await client.settled()
        #expect(try await stored(ActionCombo.self, root, "c1") == before)
        try await until { side.combos["c1"] == before && side.batches.count >= 3 }
    }

    @Test func theEditorsCommitLandsAndAGridEditReachesIt() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let client = try await startedClient(root)
        _ = try await client.create(deck("d")).value

        let checkout = try await client.checkout(Presentation.self, id: "d")
        let editor = checkout.replica
        let opened = editor.heads()
        _ = try editor.update(\.slides[0].name, at: [.init("slides"), .init(UInt64(0)), .init("name")]) { $0 = "Chorus" }
        let committed = try await client.commit(
            Presentation.self, id: "d", changes: editor.encodeChangesSince(heads: opened), token: checkout.token
        ).value
        let own = try #require(committed.changes.last)
        #expect(own.origin == .local)
        #expect(editor.contains(heads: SyncLedger.heads(own.heads ?? [])), "the editor's own commit: nothing to take")
        #expect(try await stored(Presentation.self, root, "d").slides[0].name == "Chorus")

        let grid = try await client.edit(Presentation.self, id: "d", value: { _ in }, op: {
            try $0.updateSlide(id: "slide-2") { $0.notes = "From the grid" }
        }).value
        let other = try #require(grid.changes.last)
        #expect(!editor.contains(heads: SyncLedger.heads(other.heads ?? [])), "a change the editor did not make")
        let bundle = try #require(other.bundle, "a checked-out deck's write carries a bundle")
        #expect(editor.applyLanded(bundle) == .applied(moved: true))
        #expect(editor.value.slides[2].notes == "From the grid")
        #expect(editor.value.slides[0].name == "Chorus", "its own edit stays")
        _ = try await client.release(token: checkout.token, history: editor.history).value
    }

    @Test func applyHandsTheBatchToObserversSynchronouslyInOrder() {
        let side = RecordingReadSide()
        let client = LibraryClient(rootURL: makeRoot())
        client.readSide = side
        var heard: [String] = []
        side.observers.add { heard.append("sync \($0.sequence)") }
        let media = side.observers.add { heard.append("media \($0.sequence)") }
        side.observers.add { heard.append("editor \($0.sequence)") }

        client.apply(LibraryBatch(sequence: 1, changes: [], areaMoves: [], snapshot: .empty))
        #expect(heard == ["sync 1", "media 1", "editor 1"], "every observer ran inside apply, in order")
        side.observers.remove(media)
        client.apply(LibraryBatch(sequence: 2, changes: [], areaMoves: [], snapshot: .empty))
        #expect(heard.suffix(2) == ["sync 2", "editor 2"])
        client.apply(LibraryBatch(sequence: 1, changes: [], areaMoves: [], snapshot: .empty))
        #expect(heard.count == 5, "an older batch reaches no one")
    }

    @Test func settledSeedAndAuthor() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let client = try await startedClient(root)

        client.create(deck("d"))
        await client.settled()
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("presentations/d.automerge").path))
        #expect(try await client.settledSnapshot().entry(id: "d") != nil)

        _ = try await client.create(deck("pack.x"), seed: .init(id: "pack.x")).value
        try await onLibraryActor {
            let other = try TypedDocument(deck("pack.x"), seed: .init(id: "pack.x"))
            #expect(try DocumentStore(rootURL: root).load(Presentation.self, id: "pack.x").firstChangeHash() == other.firstChangeHash())
        }

        client.setAuthor(ChangeAuthor(userHexId: "u1", stationHexId: "st1"))
        _ = try await client.modify(Presentation.self, id: "d") { $0.name = "Authored" }.value
        try await onLibraryActor {
            let document = try DocumentStore(rootURL: root).load(Presentation.self, id: "d")
            let message = document.document.heads().first.flatMap { document.document.change(hash: $0)?.message }
            #expect(message == "u1|st1|presentation")
        }
    }

    @Test func restoreWelcomeDeckFillsOnlyWhatIsMissing() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let client = try await startedClient(root)
        #expect(try await client.restoreWelcomeDeck(serviceDate: "2026-09-23").count == 2)
        _ = try await client.modify(Presentation.self, id: WelcomeDeck.presentationID) { $0.name = "Mine now" }.value
        #expect(try await client.restoreWelcomeDeck(serviceDate: "2026-09-24").isEmpty)
        #expect(try await stored(Presentation.self, root, WelcomeDeck.presentationID).name == "Mine now")
    }
}

@Suite struct LibraryWiringRouteTests {

    @Test func theSyncRouteIsTheHooksPushSet() {
        let key = { (id: String) in SyncLedger.Key(kind: .presentation, id: id) }
        let value = deck("x")
        let batch = LibraryBatch(
            sequence: 1,
            changes: [
                DocumentChange(kind: .presentation, id: "edited", origin: .local, value: value),
                DocumentChange(kind: .schedulerBoard, id: "board", origin: .local, value: nil, listed: false),
                DocumentChange(kind: .importLedger, id: "ledger", origin: .local, value: nil, listed: false),
                DocumentChange(kind: .presentation, id: "deleted", origin: .deleted, value: nil),
                DocumentChange(kind: .presentation, id: "pulled", origin: .landed, value: value),
                DocumentChange(kind: .presentation, id: "evicted", origin: .landed, value: nil),
            ],
            areaMoves: [
                AreaMove(kind: .presentation, id: "moved", from: .station, to: .team, origin: .local),
                AreaMove(kind: .presentation, id: "noted", from: .station, to: .team, origin: .landed),
            ],
            snapshot: .empty)
        let route = SyncBatchRoute(batch)
        #expect(
            route.edited == [key("edited"), SyncLedger.Key(kind: .schedulerBoard, id: "board")],
            "an unlisted write of a synced kind is pushed (P2-F); the import ledger is not")
        #expect(route.deleted == [key("deleted")])
        #expect(route.landed == [key("pulled")], "a landed removal (an eviction) reaches no one")
        #expect(route.moved.map(\.id) == ["moved"], "the sync's own area bookkeeping moves nothing")
    }
}

private extension DocumentEntity {
    func isEqualTo(_ other: any DocumentEntity) -> Bool {
        (other as? Self) == self
    }
}
