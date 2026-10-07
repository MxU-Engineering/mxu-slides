import Foundation
import Testing

@testable import PresenterCore

private func makeRoot() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("library-refile-\(UUID().uuidString)")
}

private func deck(_ id: String, slides count: Int) -> Presentation {
    Presentation(
        id: id, name: "Deck \(id)", presentationKind: .song, themeId: "",
        slides: (0..<count).map { n in
            Slide(
                id: "slide-\(n)", name: "Verse \(n)",
                objects: [SlideObject(id: "text-\(n)", objectKind: .text, name: "Lyrics", text: "Line \(n) of a long song")],
                actions: [SlideAction(id: "clear-\(n)", kind: .clearAll)])
        })
}

private func media(_ id: String) -> MediaItem {
    MediaItem(
        id: id, name: "Clip", mediaKind: .video, classification: .background, fileHash: "hash-\(id)", fileName: "\(id).mp4",
        fileStatus: .ready, statusDetail: "", tags: [], favorite: false, collections: [], loops: false,
        folder: "Old", folderId: "old-record")
}

private func audio(_ id: String) -> AudioItem {
    AudioItem(id: id, name: "Song", fileHash: "hash-\(id)", fileName: "\(id).m4a", tags: [], favorite: false, durationSeconds: 60)
}

@LibraryActor private func makeLibrary(_ engine: LibraryEngine) throws {
    try engine.create(deck("big", slides: 300))
    try engine.create(deck("d", slides: 3))
    try engine.create(Overlay(id: "ov", name: "Bug", objects: []))
    try engine.create(media("m"))
    try engine.create(audio("a"))
    try engine.create(ConfidenceLayout(id: "cl", name: "Stage", objects: []))
}

@LibraryActor private func stored<E: DocumentEntity>(_ type: E.Type, _ root: URL, _ id: String) throws -> E {
    try DocumentStore(rootURL: root).load(type, id: id).value
}

@LibraryActor private func changeCount<E: DocumentEntity>(_ type: E.Type, _ engine: LibraryEngine, _ id: String) throws -> Int {
    try engine.replica(type, id: id).document.getHistory().count
}

@Suite struct LibraryRefileEngineTests {

    @Test(.disabled(
        if: ProcessInfo.processInfo.environment["MXU_VERIFY_SCOPED_WRITES"] != nil,
        "diverges the document from the cache on purpose"))
    @LibraryActor func aChunkIsOneBatchOfLocalChangesThatWritesOnlyTheFolderFields() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = LibraryEngine(rootURL: root)
        try engine.bootstrap()
        try makeLibrary(engine)

        let first = [
            LibraryRefile(kind: .presentation, id: "big", folder: "Songs/Hymns", folderId: "f-hymns"),
            LibraryRefile(kind: .presentation, id: "d", folder: "Songs", folderId: nil),
            LibraryRefile(kind: .overlay, id: "ov", folder: "Bugs", folderId: "f-bugs"),
        ]
        let second = [
            LibraryRefile(kind: .media, id: "m", folder: nil, folderId: nil),
            LibraryRefile(kind: .audio, id: "a", folder: "Walk-in", folderId: "f-walk"),
            LibraryRefile(kind: .confidenceLayout, id: "cl", folder: "Stage", folderId: "f-stage"),
        ]
        let before = (
            big: try stored(Presentation.self, root, "big"), d: try stored(Presentation.self, root, "d"),
            ov: try stored(Overlay.self, root, "ov"), m: try stored(MediaItem.self, root, "m"),
            a: try stored(AudioItem.self, root, "a"), cl: try stored(ConfidenceLayout.self, root, "cl"))
        let replica = try engine.replica(Presentation.self, id: "big")
        try plant("Planted", onSlide: 3, in: replica)

        let changes = (
            big: try changeCount(Presentation.self, engine, "big"), m: try changeCount(MediaItem.self, engine, "m"),
            a: try changeCount(AudioItem.self, engine, "a"))

        let batches = [try engine.refile(first), try engine.refile(second)]
        #expect(batches.map(\.refused.isEmpty) == [true, true])
        #expect(batches[1].batch.sequence == batches[0].batch.sequence + 1, "one batch per chunk")
        for (refiled, chunk) in zip(batches, [first, second]) {
            #expect(refiled.batch.changes.map(\.key) == chunk.map(\.key))
            #expect(refiled.batch.changes.allSatisfy { $0.origin == .local })
            #expect(SyncBatchRoute(refiled.batch).edited == chunk.map(\.key), "the route pushes every document")
            #expect(refiled.batch.areaMoves.isEmpty, "a refile moves no area")
            #expect(chunk.allSatisfy { refiled.batch.snapshot.area(kind: $0.kind, id: $0.id) == nil }, "and writes or guesses no area row (rows 48-56)")
        }

        func refiled<E: TeamFolderedEntity>(_ value: E, _ folder: String?, _ folderId: String?) -> E {
            var next = value
            next.folder = folder
            next.folderId = folderId
            return next
        }
        var big = refiled(before.big, "Songs/Hymns", "f-hymns")
        big.slides[3].name = "Planted"
        #expect(try stored(Presentation.self, root, "big") == big, "slide 3 was never rewritten")
        #expect(try stored(Presentation.self, root, "d") == refiled(before.d, "Songs", nil))
        #expect(try stored(Overlay.self, root, "ov") == refiled(before.ov, "Bugs", "f-bugs"))
        #expect(try stored(MediaItem.self, root, "m") == refiled(before.m, nil, nil), "nil removes both fields")
        #expect(try stored(AudioItem.self, root, "a") == refiled(before.a, "Walk-in", "f-walk"))
        #expect(try stored(ConfidenceLayout.self, root, "cl") == refiled(before.cl, "Stage", "f-stage"))
        #expect(batches[1].batch.changes.first?.value(as: MediaItem.self) == refiled(before.m, nil, nil), "the batch brings the value")
        #expect(try changeCount(Presentation.self, engine, "big") == changes.big + 1, "both fields in one change")
        #expect(try changeCount(MediaItem.self, engine, "m") == changes.m + 1)
        #expect(try changeCount(AudioItem.self, engine, "a") == changes.a + 1)

        let again = try engine.refile([second[1]])
        #expect(again.batch.changes.map(\.origin) == [.local])
        #expect(try changeCount(AudioItem.self, engine, "a") == changes.a + 1)
    }

    @LibraryActor @Test func aRefusedDocumentIsRefusedAloneAndTheChunkLands() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = LibraryEngine(rootURL: root)
        try engine.bootstrap()
        try makeLibrary(engine)

        let refiled = try engine.refile([
            LibraryRefile(kind: .presentation, id: "gone", folder: "Songs", folderId: nil),
            LibraryRefile(kind: .overlay, id: "ov", folder: "Bugs", folderId: nil),
        ])
        #expect(Array(refiled.refused.keys) == [SyncLedger.Key(kind: .presentation, id: "gone")])
        #expect(refiled.batch.changes.map(\.id) == ["ov"])
        #expect(try stored(Overlay.self, root, "ov").folder == "Bugs")
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

@MainActor private final class ValuesReadSide: LibraryReadSide {
    var values: [SyncLedger.Key: any DocumentEntity] = [:]
    private(set) var optimistic: [DocumentChange] = []
    private(set) var failures: [String] = []
    private(set) var batches: [LibraryBatch] = []

    func currentValue(_ kind: DocumentKind, id: String) -> (any DocumentEntity)? {
        values[SyncLedger.Key(kind: kind, id: id)]
    }

    func applyOptimistic(_ change: DocumentChange) {
        optimistic.append(change)
        values[change.key] = change.value
    }

    func optimisticWriteFailed(_ change: DocumentChange, error: any Error) {
        failures.append(change.id)
    }

    func apply(_ batch: LibraryBatch) {
        batches.append(batch)
        for change in batch.changes {
            values[change.key] = change.value
        }
    }
}

@MainActor @Suite struct LibraryRefileClientTests {

    @Test func aChunkLandsOnMainAtOnceAndAnEditQueuedDuringThePassSurvives() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let side = ValuesReadSide()
        let client = LibraryClient(rootURL: root)
        client.readSide = side
        try await client.start().value
        try await client.create(deck("big", slides: 300)).value
        try await client.create(deck("d", slides: 3)).value
        try await client.create(media("m")).value
        side.values[SyncLedger.Key(kind: .media, id: "ghost")] = media("ghost")

        let first = [
            LibraryRefile(kind: .presentation, id: "d", folder: "Songs", folderId: "f-songs"),
            LibraryRefile(kind: .media, id: "ghost", folder: "Songs", folderId: "f-songs"),
        ]
        let second = [
            LibraryRefile(kind: .presentation, id: "big", folder: "Songs", folderId: "f-songs"),
            LibraryRefile(kind: .media, id: "m", folder: "Songs", folderId: "f-songs"),
        ]
        let optimisticBefore = side.optimistic.count
        let chunk = client.refile(first)
        #expect(side.optimistic.count == optimisticBefore + 2, "main took the chunk in the call")
        #expect((side.values[SyncLedger.Key(kind: .presentation, id: "d")] as? Presentation)?.folder == "Songs")

        client.modify(Presentation.self, id: "d") { $0.name = "Renamed d" }
        client.modify(Presentation.self, id: "big") { $0.name = "Renamed big" }
        let firstRefiled = try await chunk.value
        #expect(Array(firstRefiled.refused.keys) == [SyncLedger.Key(kind: .media, id: "ghost")])
        let secondRefiled = try await client.refile(second).value
        #expect(secondRefiled.refused.isEmpty)
        await client.settled()
        try await until { side.failures == ["ghost"] && side.batches.last?.sequence == secondRefiled.batch.sequence }

        let d = try await stored(Presentation.self, root, "d")
        let big = try await stored(Presentation.self, root, "big")
        #expect((d.name, d.folder, d.folderId) == ("Renamed d", "Songs", "f-songs"), "an edit queued behind a chunk keeps the refile")
        #expect((big.name, big.folder, big.folderId) == ("Renamed big", "Songs", "f-songs"), "a chunk after the edit keeps the edit")
        #expect(try await stored(MediaItem.self, root, "m").folder == "Songs")
        for id in ["d", "big"] {
            let shown = side.values[SyncLedger.Key(kind: .presentation, id: id)] as? Presentation
            #expect(shown == (try await stored(Presentation.self, root, id)), "\(id): main shows what reached disk")
        }
        let pushed = side.batches.flatMap { SyncBatchRoute($0).edited }
        for key in (first + second).map(\.key) where key.id != "ghost" {
            #expect(pushed.contains(key), "\(key.id) pushed")
        }
        #expect(!pushed.contains(SyncLedger.Key(kind: .media, id: "ghost")))
        #expect([firstRefiled, secondRefiled].map { $0.batch.changes.count } == [1, 2], "one batch per chunk")
    }
}

@MainActor private func until(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(10)
    while !condition(), ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(2))
    }
    try #require(condition(), "timed out")
}
