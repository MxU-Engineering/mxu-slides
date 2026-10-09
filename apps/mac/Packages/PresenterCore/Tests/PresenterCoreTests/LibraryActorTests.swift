import Foundation
import os
import Testing

@testable import PresenterCore

private func makeRoot() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("library-actor-\(UUID().uuidString)")
}

private func combo(_ id: String, _ name: String) -> ActionCombo {
    ActionCombo(id: id, name: name, actions: [])
}

private func deck(_ id: String, name: String = "Deck", slides count: Int = 4) -> Presentation {
    Presentation(
        id: id, name: name, presentationKind: .song, themeId: "",
        slides: (0..<count).map { n in
            Slide(
                id: "\(id)-slide-\(n)", name: "Verse \(n)",
                objects: [SlideObject(id: "\(id)-text-\(n)", objectKind: .text, name: "Lyrics", text: "Line \(n)")])
        })
}

@LibraryActor private func sqlSnapshot(_ root: URL, generation: Int) throws -> IndexSnapshot {
    let index = try LibraryIndex(url: root.appendingPathComponent("index.sqlite"))
    return IndexSnapshot(entries: try index.allEntries(), areas: try index.allAreas(), generation: generation)
}

@LibraryActor func onLibraryActor<T: Sendable>(_ body: @LibraryActor () throws -> T) throws -> T {
    try body()
}

@LibraryActor func onLibraryActor<T: Sendable>(reading root: URL, _ body: @LibraryActor (Library) throws -> T) throws -> T {
    try body(Library(rootURL: root))
}

private func take(_ count: Int, from stream: AsyncStream<LibraryBatch>) async -> [LibraryBatch] {
    var taken: [LibraryBatch] = []
    for await batch in stream {
        taken.append(batch)
        if taken.count == count { break }
    }
    return taken
}

@MainActor private func until(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(10)
    while !condition(), ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(2))
    }
    try #require(condition(), "timed out")
}

@MainActor private final class TableReadSide: LibraryReadSide {
    var combos = ResidentTable<ActionCombo>()
    var decks: [String: Presentation] = [:]
    private var epoch = 0
    private(set) var batches: [LibraryBatch] = []
    private(set) var optimistic: [DocumentChange] = []
    private(set) var failures: [String] = []

    func currentValue(_ kind: DocumentKind, id: String) -> (any DocumentEntity)? {
        if kind == .actionCombo {
            combos.value(id)
        } else {
            decks[id]
        }
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
    }

    func hold(_ value: ActionCombo) {
        epoch += 1
        combos.reseed(id: value.id, value: value, epoch: epoch)
    }

    private func land(_ change: DocumentChange) {
        if change.kind == .actionCombo {
            epoch += 1
            combos.reseed(id: change.id, value: change.value(as: ActionCombo.self), epoch: epoch)
        } else {
            decks[change.id] = change.value(as: Presentation.self)
        }
    }
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

@Suite struct LibraryEngineTests {
    @LibraryActor @Test func everyWritePublishesOneBatchWithTheWritesOrigin() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = LibraryEngine(rootURL: root)
        let start = try engine.bootstrap()

        let published = [
            try engine.create(combo("a", "One")),
            try engine.modify(ActionCombo.self, id: "a") { $0.name = "Two" },
            try engine.save(TypedDocument(combo("b", "Pulled")), origin: .landed),
            try engine.delete(kind: .actionCombo, id: "a"),
            try engine.delete(kind: .actionCombo, id: "b", origin: .landed),
        ]
        #expect(published.map(\.sequence) == [1, 2, 3, 4, 5], "one batch per command, none between")
        #expect(published.map { $0.changes.map(\.origin) } == [[.local], [.local], [.landed], [.deleted], [.landed]])
        #expect(published.map { $0.changes.map(\.id) } == [["a"], ["a"], ["b"], ["a"], ["b"]])
        #expect(published[1].value(ActionCombo.self, id: "a")?.name == "Two")
        #expect(published[2].value(ActionCombo.self, id: "b")?.name == "Pulled")
        #expect(published[3].changes[0].value == nil && published[4].changes[0].value == nil, "a removal carries no value")
        #expect(published.allSatisfy { $0.areaMoves.isEmpty })

        let streamed = await take(5, from: start.batches)
        #expect(streamed.map(\.sequence) == published.map(\.sequence))
        #expect(streamed.map { $0.changes.map(\.origin) } == published.map { $0.changes.map(\.origin) })
    }

    @LibraryActor @Test func theSnapshotAfterAWriteIsTheIndexAfterIt() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = LibraryEngine(rootURL: root)
        try engine.bootstrap()

        let created = try engine.create(deck("p1", name: "Amazing Grace"))
        #expect(created.snapshot.entry(id: "p1")?.name == "Amazing Grace")
        #expect(created.snapshot == (try sqlSnapshot(root, generation: created.snapshot.generation)))

        try engine.create(deck("p2", name: "Great Are You Lord"))
        let renamed = try engine.modify(Presentation.self, id: "p1") { $0.name = "Zion" }
        #expect(renamed.snapshot.entries(of: .presentation).map(\.id) == ["p2", "p1"], "a rename re-sorts")
        #expect(renamed.snapshot == (try sqlSnapshot(root, generation: renamed.snapshot.generation)))

        let keys = [SyncLedger.Key(kind: .presentation, id: "p1"), SyncLedger.Key(kind: .presentation, id: "p2")]
        let moved = try engine.setArea(.team, of: keys)
        #expect(moved.changes.isEmpty)
        #expect(moved.areaMoves == [
            AreaMove(kind: .presentation, id: "p1", from: .station, to: .team, origin: .local),
            AreaMove(kind: .presentation, id: "p2", from: .station, to: .team, origin: .local),
        ])
        #expect(moved.snapshot.browserEntries(of: .presentation, showing: .team).map(\.id) == ["p2", "p1"])
        #expect(moved.snapshot == (try sqlSnapshot(root, generation: moved.snapshot.generation)))
        let unmoved = try engine.setArea(.team, of: [keys[0]], origin: .landed)
        #expect(unmoved.areaMoves.isEmpty, "an area it already has is no move")
        let back = try engine.setArea(.station, of: [keys[1]], origin: .landed)
        #expect(back.areaMoves == [AreaMove(kind: .presentation, id: "p2", from: .team, to: .station, origin: .landed)])

        let removed = try engine.delete(kind: .presentation, id: "p1")
        #expect(removed.snapshot.entry(id: "p1") == nil)
        #expect(removed.snapshot.entries(of: .presentation).map(\.id) == ["p2"])
        #expect(removed.snapshot == (try sqlSnapshot(root, generation: removed.snapshot.generation)))
        #expect(engine.snapshot == removed.snapshot)
    }

    @LibraryActor @Test func theMirrorOrdersEntriesAsTheIndexDoes() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = LibraryEngine(rootURL: root)
        try engine.bootstrap()
        for (id, name) in [("c1", "f"), ("c2", "\u{e9}"), ("c3", "e\u{301}"), ("c4", "Same"), ("c5", "Same"), ("c0", "Same")] {
            try engine.create(combo(id, name))
        }
        let renamed = try engine.modify(ActionCombo.self, id: "c4") { $0.name = "Same" }
        #expect(renamed.snapshot.entries(of: .actionCombo).map(\.id) == ["c4", "c5", "c0", "c3", "c1", "c2"])
        #expect(renamed.snapshot == (try sqlSnapshot(root, generation: renamed.snapshot.generation)))
    }

    @LibraryActor @Test func bootstrapReadsTheLibraryAndRebuildsAMissingIndex() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            let library = try Library(rootURL: root)
            try library.create(deck("p1", name: "Amazing Grace"))
            try library.create(combo("c1", "Walk-in"))
            try library.index.setArea(.team, kind: .presentation, id: "p1")
            try library.index.touchUsage(id: "c1", at: Date(timeIntervalSince1970: 100))
            try library.index.touchUsage(id: "later", at: Date(timeIntervalSince1970: 200))
        }
        let engine = LibraryEngine(rootURL: root)
        #expect(engine.snapshot == .empty, "the init opens nothing")
        let start = try engine.bootstrap()
        #expect(start.snapshot == (try sqlSnapshot(root, generation: start.snapshot.generation)))
        #expect(start.snapshot.entry(id: "c1")?.lastUsedAt == Date(timeIntervalSince1970: 100))
        #expect(start.snapshot.browserEntries(of: .presentation, showing: .team).map(\.id) == ["p1"])
        let later = try engine.create(combo("later", "Stamped before it existed"))
        #expect(later.snapshot.entry(id: "later")?.lastUsedAt == Date(timeIntervalSince1970: 200), "the usage sidecar joins a new row")
        #expect(try engine.bootstrap().snapshot == later.snapshot, "opening again hands back the same state")

        let rebuilt = makeRoot()
        defer { try? FileManager.default.removeItem(at: rebuilt) }
        do {
            let library = try Library(rootURL: rebuilt)
            try library.create(deck("p1", name: "Amazing Grace"))
            try library.create(combo("c1", "Walk-in"))
        }
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(at: rebuilt.appendingPathComponent("index.sqlite" + suffix))
        }
        let fresh = try LibraryEngine(rootURL: rebuilt).bootstrap()
        #expect(fresh.snapshot.entries(of: .presentation).map(\.name) == ["Amazing Grace"])
        #expect(fresh.snapshot.entries(of: .actionCombo).map(\.name) == ["Walk-in"])
    }

    @LibraryActor @Test func aRefusedWritePublishesNoBatch() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = LibraryEngine(rootURL: root)
        #expect(throws: LibraryEngine.EngineError.notBootstrapped) { try engine.create(combo("a", "One")) }
        try engine.bootstrap()

        #expect(try engine.create(combo("a", "One")).sequence == 1)
        #expect(throws: DocumentStore.StoreError.documentNotFound(kind: .actionCombo, id: "gone")) {
            try engine.modify(ActionCombo.self, id: "gone") { $0.name = "Nowhere" }
        }
        struct Refused: Error {}
        #expect(throws: Refused.self) {
            try engine.modify(ActionCombo.self, id: "a") { _ in throw Refused() }
        }
        #expect(throws: DocumentStore.StoreError.documentNotFound(kind: .presentation, id: "gone")) {
            try engine.write("gone") { $0.removeAll() }
        }
        let next = try engine.delete(kind: .actionCombo, id: "a")
        #expect(next.sequence == 2, "the refused writes published nothing")
    }

    @LibraryActor @Test func anEditWhoseSaveFailsIsNotSavedByTheNextEdit() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = LibraryEngine(rootURL: root)
        try engine.bootstrap()
        try engine.create(combo("a", "One"))
        let folder = root.appendingPathComponent(DocumentKind.actionCombo.directoryName)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }

        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        #expect(throws: (any Error).self) { try engine.modify(ActionCombo.self, id: "a") { $0.name = "Refused" } }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
        let batch = try engine.modify(ActionCombo.self, id: "a") { $0.actions = [] }

        #expect((batch.changes.first?.value as? ActionCombo)?.name == "One")
        #expect(try DocumentStore(rootURL: root).load(ActionCombo.self, id: "a").value.name == "One")
    }

    @LibraryActor @Test func aBulkWriteOfTwoHundredDocumentsIsOneBatch() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = LibraryEngine(rootURL: root)
        let start = try engine.bootstrap()

        let values: [any DocumentEntity] = (0..<200).map { combo("c\($0)", "Combo \($0)") }
        let batch = try engine.bulkWrite(values)
        #expect(batch.sequence == 1)
        #expect(batch.changes.count == 200)
        #expect(batch.changes.allSatisfy { $0.origin == .local })
        #expect(batch.snapshot.entries(of: .actionCombo).count == 200)
        #expect(batch.snapshot == (try sqlSnapshot(root, generation: batch.snapshot.generation)))

        let replaced = try engine.bulkWrite([combo("c0", "Replaced"), deck("p1", name: "New Deck")], replacing: true)
        #expect(replaced.sequence == 2)
        #expect(replaced.changes.map { "\($0.origin.rawValue) \($0.id)" } == ["deleted c0", "local c0", "local p1"])
        #expect(replaced.value(ActionCombo.self, id: "c0")?.name == "Replaced")
        #expect(replaced.value(Presentation.self, id: "p1")?.name == "New Deck")
        #expect(try DocumentStore(rootURL: root).load(ActionCombo.self, id: "c0").value.name == "Replaced")

        #expect(await take(2, from: start.batches).map(\.sequence) == [1, 2])
    }

    @LibraryActor @Test func aScopedListWriteRunsOnTheCanonicalReplica() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = LibraryEngine(rootURL: root)
        try engine.bootstrap()
        try engine.create(deck("p1"))

        let batch = try engine.write("p1") { slides in slides.removeAll { $0.id == "p1-slide-1" } }
        #expect(batch.changes.map(\.origin) == [.local])
        #expect(batch.value(Presentation.self, id: "p1")?.slides.map(\.id) == ["p1-slide-0", "p1-slide-2", "p1-slide-3"])
        #expect(try DocumentStore(rootURL: root).load(Presentation.self, id: "p1").value.slides.count == 3)
    }

    @LibraryActor @Test func aCommitLandsTheEditorsBundle() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = LibraryEngine(rootURL: root)
        try engine.bootstrap()
        try engine.create(deck("p1", name: "Before"))

        let store = try DocumentStore(rootURL: root)
        let editor = try store.load(Presentation.self, id: "p1")
        let heads = editor.heads()
        try editor.update { $0.name = "Edited in the editor" }
        let bundle = try editor.encodeChangesSince(heads: heads)

        let batch = try engine.commit(Presentation.self, id: "p1", changes: bundle)
        #expect(batch.changes.map(\.origin) == [.local])
        #expect(batch.value(Presentation.self, id: "p1")?.name == "Edited in the editor")
        #expect(batch.snapshot.entry(id: "p1")?.name == "Edited in the editor")
        #expect(try store.load(Presentation.self, id: "p1").value.name == "Edited in the editor")
    }

    @LibraryActor @Test func theAuthorStampRidesTheEnginesCommits() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = LibraryEngine(rootURL: root)
        try engine.bootstrap()
        engine.setAuthor(ChangeAuthor(userHexId: "u1", stationHexId: "st1"))
        try engine.create(combo("a", "One"))
        try engine.modify(ActionCombo.self, id: "a") { $0.name = "Two" }

        let saved = try DocumentStore(rootURL: root).load(ActionCombo.self, id: "a")
        let head = try #require(saved.heads().first)
        #expect(saved.document.change(hash: head)?.message == "u1|st1|actionCombo")
    }

    @LibraryActor @Test func aReplicaAnOutsideWriteMovedIsReopened() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = LibraryEngine(rootURL: root)
        try engine.bootstrap()
        try engine.create(combo("a", "One"))

        let outside = try DocumentStore(rootURL: root)
        let document = try outside.load(ActionCombo.self, id: "a")
        try document.update { $0.name = "Outside" }
        try outside.save(document)

        let batch = try engine.modify(ActionCombo.self, id: "a") { $0.name += "!" }
        #expect(batch.value(ActionCombo.self, id: "a")?.name == "Outside!")
    }

    @LibraryActor @Test func theEnginesReadsGoThroughTheReader() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = LibraryEngine(rootURL: root)
        await #expect(throws: LibraryEngine.EngineError.notBootstrapped) {
            try await engine.loadValue(ActionCombo.self, id: "a")
        }
        try engine.bootstrap()
        try engine.create(combo("a", "One"))
        try engine.create(combo("b", "Two"))

        #expect(try await engine.loadValue(ActionCombo.self, id: "a").name == "One")
        let loaded = try await engine.loadValues(ActionCombo.self, ids: ["a", "b", "gone", "a"], priority: .utility)
        #expect(loaded.values.mapValues(\.name) == ["a": "One", "b": "Two"], "a repeated id is read once")
        #expect(loaded.failed == ["gone"])
    }
}

@Suite struct LibraryClientTests {

    @MainActor @Test func fiftyInterleavedSavesAndDeletesLandInTheOrderTheyWereMade() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let client = LibraryClient(rootURL: root)
        let side = TableReadSide()
        client.readSide = side
        try await client.start().value

        let park = ActorPark()
        let parked = Task.detached { await park.hold(atLeast: .zero) }
        while !park.entered {
            try await Task.sleep(for: .milliseconds(1))
        }

        var expected: [String] = []
        var commands: [Task<LibraryBatch, any Error>] = []
        for step in 0..<50 {
            let id = "c\(step % 5)"
            let operation = (step / 5) % 3
            let priority: TaskPriority = step.isMultiple(of: 2) ? .background : .userInitiated
            let command = await Task(priority: priority) { @MainActor in
                switch operation {
                case 0: client.create(combo(id, "Step \(step)"))
                case 1: client.modify(ActionCombo.self, id: id) { $0.name = "Step \(step)" }
                default: client.delete(kind: .actionCombo, id: id)
                }
            }.value
            commands.append(command)
            expected.append("\(operation == 2 ? "deleted" : "local") \(id)")
        }
        park.release()
        await parked.value

        var sequences: [Int] = []
        for command in commands {
            sequences.append(try await command.value.sequence)
        }
        #expect(sequences == Array(1...50), "each command ran in the order it was made")

        try await until { side.batches.count == 50 }
        #expect(side.batches.map(\.sequence) == Array(1...50))
        #expect(side.batches.flatMap(\.changes).map { "\($0.origin.rawValue) \($0.id)" } == expected)
        #expect(client.lastAppliedSequence == 50)
        #expect(client.snapshot.entries(of: .actionCombo).map(\.name) == ["Step 45", "Step 46", "Step 47", "Step 48", "Step 49"])
        #expect(side.failures.isEmpty)
    }

    @MainActor @Test func anEditShowsOnMainBeforeTheActorWritesItAndTheBatchCorrectsIt() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let client = LibraryClient(rootURL: root)
        let side = TableReadSide()
        client.readSide = side
        try await client.start().value
        #expect(client.isReady)

        let created = client.create(combo("a", "One"))
        #expect(side.combos.value("a")?.name == "One", "a create shows at once")
        _ = try await created.value

        side.hold(combo("a", "Stale"))
        let edited = client.modify(ActionCombo.self, id: "a") { $0.name += " edited" }
        #expect(side.combos.value("a")?.name == "Stale edited")
        #expect(side.optimistic.last?.origin == .local)
        let batch = try await edited.value
        #expect(batch.value(ActionCombo.self, id: "a")?.name == "One edited")
        try await until { client.lastAppliedSequence == batch.sequence }
        #expect(side.combos.value("a")?.name == "One edited")

        let deleted = client.delete(kind: .actionCombo, id: "a")
        #expect(side.combos.value("a") == nil, "a delete drops the value at once")
        #expect(try await deleted.value.changes.map(\.origin) == [.deleted])
    }

    @MainActor @Test func aMassDeleteLandsAsOneBatch() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let client = LibraryClient(rootURL: root)
        let side = TableReadSide()
        client.readSide = side
        try await client.start().value
        let ids = (0..<40).map { "c\($0)" }
        _ = try await client.bulkWrite(ids.map { combo($0, "Combo \($0)") } + [combo("kept", "Kept")]).value
        let before = side.batches.count

        let deleted = client.delete(ids.map { SyncLedger.Key(kind: .actionCombo, id: $0) })
        #expect(ids.allSatisfy { side.combos.value($0) == nil }, "every value drops at once")
        let batch = try await deleted.value
        #expect(batch.changes.map(\.id) == ids)
        #expect(batch.changes.allSatisfy { $0.origin == .deleted && $0.value == nil })
        #expect(batch.snapshot.entries(of: .actionCombo).map(\.id) == ["kept"])
        try await until { client.lastAppliedSequence == batch.sequence }
        #expect(side.batches.count == before + 1, "one batch for the whole delete")
        #expect(client.snapshot.entries(of: .actionCombo).map(\.id) == ["kept"])
        let onDisk = try await onLibraryActor { try sqlSnapshot(root, generation: batch.snapshot.generation) }
        #expect(onDisk == batch.snapshot)
        #expect(try await onLibraryActor(reading: root) { try $0.store.ids(of: .actionCombo) } == ["kept"])
    }

    @MainActor @Test func aRefusedEditTellsTheReadSideAndPublishesNothing() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let client = LibraryClient(rootURL: root)
        let side = TableReadSide()
        client.readSide = side
        try await client.start().value

        side.hold(combo("gone", "Held on main only"))
        let refused = client.modify(ActionCombo.self, id: "gone") { $0.name = "Edited" }
        #expect(side.combos.value("gone")?.name == "Edited")
        await #expect(throws: DocumentStore.StoreError.documentNotFound(kind: .actionCombo, id: "gone")) {
            try await refused.value
        }
        try await until { side.failures == ["gone"] }

        #expect(try await client.create(combo("a", "One")).value.sequence == 1, "the refused edit published no batch")
    }

    @MainActor @Test func theScopedListOpAppliesOnMainAndOnTheActor() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let client = LibraryClient(rootURL: root)
        let side = TableReadSide()
        client.readSide = side
        try await client.start().value
        _ = try await client.create(deck("p1")).value

        let written = client.write("p1") { slides in slides.removeAll { $0.id == "p1-slide-2" } }
        #expect(side.decks["p1"]?.slides.count == 3, "optimistic")
        let batch = try await written.value
        #expect(batch.value(Presentation.self, id: "p1")?.slides.map(\.id) == ["p1-slide-0", "p1-slide-1", "p1-slide-3"])
    }

    @MainActor @Test func aCommitAndAnAreaMoveGoThroughTheTail() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let client = LibraryClient(rootURL: root)
        try await client.start().value
        _ = try await client.create(deck("p1", name: "Before")).value

        let editor = try await client.loadValue(Presentation.self, id: "p1")
        #expect(editor.name == "Before")
        let changes = try await onLibraryActor {
            let replica = try DocumentStore(rootURL: root).load(Presentation.self, id: "p1")
            let heads = replica.heads()
            try replica.update { $0.name = "After" }
            return try replica.encodeChangesSince(heads: heads)
        }
        let committed = try await client.commit(Presentation.self, id: "p1", changes: changes).value
        #expect(committed.value(Presentation.self, id: "p1")?.name == "After")

        let moved = try await client.setArea(.team, of: [SyncLedger.Key(kind: .presentation, id: "p1")]).value
        #expect(moved.areaMoves.map(\.to) == [.team])
        try await until { client.lastAppliedSequence == moved.sequence }
        #expect(client.snapshot.browserEntries(of: .presentation, showing: .team).map(\.name) == ["After"])
    }

    @MainActor @Test func theBulkLaneWritesOneBatchPerChunk() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let client = LibraryClient(rootURL: root)
        try await client.start().value

        let values: [any DocumentEntity] = (0..<250).map { combo("c\($0)", "Combo \($0)") }
        let batches = try await client.bulkWrite(values, chunkSize: 100).value
        #expect(batches.map(\.changes.count) == [100, 100, 50])
        #expect(batches.map(\.sequence) == [1, 2, 3])
        try await until { client.lastAppliedSequence == 3 }
        #expect(client.snapshot.entries(of: .actionCombo).count == 250)
    }

    @MainActor @Test func aFailedOpenIsTriedAgain() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        try Data().write(to: root)
        let client = LibraryClient(rootURL: root)
        await #expect(throws: (any Error).self) { try await client.start().value }
        #expect(!client.isReady)

        try FileManager.default.removeItem(at: root)
        try await client.start().value
        #expect(client.isReady)
        #expect(try await client.create(combo("a", "One")).value.sequence == 1)
    }

    @MainActor @Test func commandsAndReadsMadeWhileTheLibraryOpensWaitForIt() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let client = LibraryClient(rootURL: root)
        await #expect(throws: LibraryClient.ClientError.notStarted) {
            try await client.loadValue(ActionCombo.self, id: "a")
        }
        let started = client.start()
        #expect(client.start() == started, "starting again is the same open")
        let madeBeforeTheOpenFinished = client.create(combo("a", "One"))
        _ = try await madeBeforeTheOpenFinished.value
        #expect(try await client.loadValue(ActionCombo.self, id: "a").name == "One")
        #expect(client.isReady)
        let loaded = try await client.loadValues(ActionCombo.self, ids: ["a", "gone"])
        #expect(loaded.values.mapValues(\.name) == ["a": "One"])
        #expect(loaded.failed == ["gone"])
    }

    @MainActor @Test func mainNeverWaitsForAParkedActor() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let client = LibraryClient(rootURL: root)
        let side = TableReadSide()
        client.readSide = side
        try await client.start().value
        _ = try await client.create(combo("c", "Walk-in")).value
        _ = try await client.create(deck("big", slides: 120)).value
        try await until { client.lastAppliedSequence == 2 }

        let park = ActorPark()
        let parked = Task.detached { await park.hold(atLeast: .milliseconds(300)) }
        while !park.entered {
            try await Task.sleep(for: .milliseconds(1))
        }

        let queued = client.modify(ActionCombo.self, id: "c") { $0.name = "Queued" }
        #expect(side.combos.value("c")?.name == "Queued", "the edit shows before the actor can write it")

        var slowest = Duration.zero
        var reads = 0
        for _ in 0..<100 {
            let began = ContinuousClock.now
            let listed = client.snapshot.entries(of: .actionCombo)
            let resident = side.combos.value("c")
            slowest = max(slowest, began.duration(to: .now))
            reads += listed.count + (resident == nil ? 0 : 1)
        }
        #expect(slowest < .milliseconds(1), "slowest main read \(slowest)")
        #expect(reads == 200)
        #expect(park.isHolding, "every read finished while the actor was parked")

        let decoded = try await client.loadValue(Presentation.self, id: "big")
        let several = try await client.loadValues(ActionCombo.self, ids: ["c"])
        #expect(decoded.slides.count == 120)
        #expect(several.values["c"]?.name == "Walk-in", "the disk still holds the value the queued edit has not written")
        #expect(park.isHolding, "the decodes ran beside the parked actor, not behind it")

        park.release()
        await parked.value
        #expect(try await queued.value.value(ActionCombo.self, id: "c")?.name == "Queued")
    }
}

@Suite struct LibraryEngineCacheTests {
    private func stamp(_ n: UInt64) -> DocumentFileStamp {
        DocumentFileStamp(inode: n, size: 1, modifiedNanoseconds: 1)
    }

    @LibraryActor @Test func replicasAreBoundedPerKindAndDroppedWhenTheFileMoved() throws {
        var cache = LibraryReplicaCache(perKind: 2)
        let a = try TypedDocument(combo("a", "A"))
        let b = try TypedDocument(combo("b", "B"))
        let c = try TypedDocument(combo("c", "C"))
        let p = try TypedDocument(deck("p"))
        cache.keep(a, stamp: stamp(1))
        cache.keep(b, stamp: stamp(2))
        cache.keep(p, stamp: stamp(9))
        #expect(cache.document(ActionCombo.self, id: "a", stamp: stamp(1)) === a, "a hit makes it the most recent")
        cache.keep(c, stamp: stamp(3))
        #expect(cache.document(ActionCombo.self, id: "b", stamp: stamp(2)) == nil, "least recently used out first")
        #expect(cache.document(ActionCombo.self, id: "a", stamp: stamp(1)) === a)
        #expect(cache.document(Presentation.self, id: "p", stamp: stamp(9)) === p, "another kind keeps its own room")
        #expect(cache.count == 3)

        cache.keep(a, stamp: stamp(4))
        #expect(cache.document(ActionCombo.self, id: "a", stamp: stamp(4)) === a, "a write retags")
        #expect(cache.document(ActionCombo.self, id: "c", stamp: stamp(30)) == nil, "a moved file drops the replica")
        #expect(cache.document(ActionCombo.self, id: "c", stamp: stamp(3)) == nil)
        cache.keep(a, stamp: nil)
        #expect(cache.document(ActionCombo.self, id: "a", stamp: nil) == nil)
        cache.remove(kind: .presentation, id: "p")
        #expect(cache.count == 0)
    }

    @Test func aFillThatRacedAWriteNeverLands() {
        let cache = LibraryValueCache(perKind: 2)
        let key = SyncLedger.Key(kind: .actionCombo, id: "a")
        let started = cache.generation(of: key)
        cache.write(combo("a", "Saved"), key: key, stamp: stamp(2))
        cache.fill(combo("a", "Decoded before the save"), key: key, stamp: stamp(1), generation: started)
        #expect((cache.value(of: key, stamp: stamp(2)) as? ActionCombo)?.name == "Saved")
        #expect(cache.value(of: key, stamp: stamp(1)) == nil, "a hit needs the file the value came from")
        #expect(cache.value(of: key, stamp: nil) == nil)

        cache.fill(combo("a", "Fresh decode"), key: key, stamp: stamp(3), generation: cache.generation(of: key))
        #expect((cache.value(of: key, stamp: stamp(3)) as? ActionCombo)?.name == "Fresh decode")
        #expect(cache.counts.fills == 1)

        cache.remove(key)
        #expect(cache.value(of: key, stamp: stamp(3)) == nil)
        for id in ["x", "y", "z"] {
            let other = SyncLedger.Key(kind: .actionCombo, id: id)
            cache.write(combo(id, id), key: other, stamp: stamp(9))
        }
        #expect(cache.count == 2, "bounded per kind")
        #expect(cache.value(of: SyncLedger.Key(kind: .actionCombo, id: "x"), stamp: stamp(9)) == nil)
    }

    @LibraryActor @Test func theReaderAnswersFromTheEnginesWritesAndRereadsAnOutsideOne() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = LibraryEngine(rootURL: root)
        let reader = try engine.bootstrap().reader
        try engine.create(combo("a", "One"))

        #expect(try await reader.loadValue(ActionCombo.self, id: "a").name == "One")
        #expect(reader.cache.counts.hits == 1, "the engine's write is the cached value")
        #expect(reader.cache.counts.fills == 0)

        let outside = try DocumentStore(rootURL: root)
        let document = try outside.load(ActionCombo.self, id: "a")
        try document.update { $0.name = "Outside" }
        try outside.save(document)
        #expect(try await reader.loadValue(ActionCombo.self, id: "a").name == "Outside")
        #expect(reader.cache.counts.fills == 1, "a moved file decodes again")

        try engine.create(combo("b", "Two"))
        let both = await reader.loadValues(ActionCombo.self, ids: ["a", "b", "gone"])
        #expect(both.values.mapValues(\.name) == ["a": "Outside", "b": "Two"])
        #expect(both.failed == ["gone"])
        #expect(reader.cache.counts.hits == 3 && reader.cache.counts.fills == 1, "the decode and the write were both cached")
        await #expect(throws: DocumentStore.StoreError.documentNotFound(kind: .actionCombo, id: "gone")) {
            try await reader.loadValue(ActionCombo.self, id: "gone")
        }
    }
}

@Suite struct LibraryActorSweepTests {
    private func source(_ path: String) throws -> String {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  
            .deletingLastPathComponent()  
            .deletingLastPathComponent()  
            .appendingPathComponent("Sources/PresenterCore", isDirectory: true)
        return try String(contentsOf: sources.appendingPathComponent(path), encoding: .utf8)
    }

    private func codeLines(_ path: String) throws -> [String] {
        try source(path).split(separator: "\n").map(String.init).filter {
            !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//")
        }
    }

    @MainActor private func applyWithoutSuspending(_ client: LibraryClient, _ batch: LibraryBatch) {
        client.apply(batch)
    }

    @MainActor @Test func applyingABatchNeverAwaits() throws {
        let lines = try codeLines("Library/LibraryClient.swift")
        let declaration = try #require(lines.first { $0.contains("public func apply(_ batch: LibraryBatch)") })
        #expect(!declaration.contains("async"), "LibraryClient.apply must stay synchronous")
        let requirement = try #require(lines.first { $0.contains("func apply(_ batch: LibraryBatch)") && !$0.contains("{") })
        #expect(!requirement.contains("async"), "LibraryReadSide.apply must stay synchronous")
        for line in lines where line.contains("func currentValue(") || line.contains("func applyOptimistic(") || line.contains("func optimisticWriteFailed(") {
            #expect(!line.contains("async"), "\(line)")
        }

        let client = LibraryClient(rootURL: makeRoot())
        let snapshot = IndexSnapshot(entries: [], areas: [:], generation: 7)
        applyWithoutSuspending(client, LibraryBatch(sequence: 2, changes: [], areaMoves: [], snapshot: snapshot))
        #expect(client.snapshot == snapshot, "applied in the call, not after it")
        #expect(client.lastAppliedSequence == 2)
        applyWithoutSuspending(client, LibraryBatch(sequence: 1, changes: [], areaMoves: [], snapshot: .empty))
        #expect(client.snapshot == snapshot, "an older batch is ignored")
    }

    @Test func everyMethodOnTheEngineIsIsolatedToTheActor() throws {
        let engine = try codeLines("Library/LibraryEngine.swift") + codeLines("Library/LibraryEngine+Editor.swift")
        #expect(engine.contains { $0.contains("@globalActor public actor LibraryActor") })
        #expect(engine.contains { $0.hasPrefix("@LibraryActor public final class LibraryEngine") })
        let nonisolated = engine.filter { $0.contains("nonisolated") }
        #expect(nonisolated.count == 1 && nonisolated.allSatisfy { $0.contains("nonisolated init(") }, "only init: \(nonisolated)")
        #expect(!engine.contains { $0.contains("@concurrent") }, "decodes belong to LibraryReader, not the engine")

        let reader = try codeLines("Library/LibraryReader.swift")
        for method in ["func loadValue<", "func loadValues<"] {
            let index = try #require(reader.firstIndex { $0.contains(method) })
            #expect(reader[index - 1].contains("@concurrent"), "\(method) is the off-actor door")
        }
        #expect(try codeLines("Library/LibraryClient.swift").contains { $0.hasPrefix("@MainActor public final class LibraryClient") })

        let escapes = ["assumeIsolated", "nonisolated(unsafe)", "@unchecked Sendable"]
        for file in [
            "Library/LibraryEngine", "Library/LibraryEngine+Editor", "Library/LibraryClient",
            "Library/LibraryReader", "Library/LibraryCaches", "Library/LibraryBatch", "Library/LibraryIndexMirror",
            "Library/LibrarySyncState", "Documents/TypedDocument", "Documents/EditorReplica",
            "Library/Library", "Library/LibraryIndex", "Documents/DocumentStore",
        ] {
            let lines = try codeLines("\(file).swift")
            for escape in escapes {
                #expect(!lines.contains { $0.contains(escape) }, "\(file) uses \(escape)")
            }
        }

        for (file, declaration) in [
            ("Library/Library.swift", "@LibraryActor public final class Library {"),
            ("Library/LibraryIndex.swift", "@LibraryActor public final class LibraryIndex {"),
            ("Documents/TypedDocument.swift", "@LibraryActor public final class TypedDocument<"),
        ] {
            #expect(try codeLines(file).contains { $0.hasPrefix(declaration) }, "\(file) declares \(declaration)")
        }
        let store = try codeLines("Documents/DocumentStore.swift")
        for method in ["public func save<Entity>(_ document: TypedDocument<Entity>)", "public func load<Entity: DocumentEntity>("] {
            let index = try #require(store.firstIndex { $0.contains(method) })
            #expect(store[index - 1].contains("@LibraryActor"), "DocumentStore \(method) is on the actor")
        }
    }

    private func body(of signature: String, in lines: [String], indent: String) throws -> [String] {
        let start = try #require(lines.firstIndex { $0.contains(signature) }, "\(signature)")
        return Array(lines[start...].prefix { $0 != "\(indent)}" })
    }

    @Test func theDecodeFromBytesStopsOnMainAndTheDoorReachesIt() throws {
        let typed = try codeLines("Documents/TypedDocument.swift")
        let helper = try body(of: "static func decoding(_ data: Data) throws -> ReplicaParts<Entity>", in: typed, indent: "    ")
        let belt = try #require(helper.firstIndex { $0.contains("precondition(") })
        #expect(helper[belt - 1].contains("#if DEBUG"))
        #expect(helper[belt + 1].contains("!Thread.isMainThread"))
        #expect(helper.contains { $0.contains("Document(data)") } && helper.contains { $0.contains("AutomergeDecoder(doc: document)") })
        let replica = try body(of: "    init(data: Data) throws {", in: typed, indent: "    ")
        #expect(replica.contains { $0.contains("ReplicaParts<Entity>.decoding(data)") }, "a replica decodes through the helper")

        let store = try codeLines("Documents/DocumentStore.swift")
        #expect(try body(of: "func loadValue<", in: store, indent: "    ").contains { $0.contains("parts(type, id: id)") })
        let parts = try body(of: "private func parts<", in: store, indent: "    ")
        #expect(parts.contains { $0.contains("Library.measuringOpen(") }, "the pass meter's count")
        #expect(parts.contains { $0.contains("ReplicaParts<Entity>.decoding(bytes(") }, "the door decodes through the helper")
        #expect(try body(of: "private func bytes(", in: store, indent: "    ").contains { $0.contains("MainThreadOpenTrap.check(") })
    }
}
