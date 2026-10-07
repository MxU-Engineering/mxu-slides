import Foundation
import Observation
import os
import Testing

@testable import PresenterCore

private func makeRoot() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("resident-decks-\(UUID().uuidString)")
}

private func shape(_ id: String, filledWith mediaId: String) -> SlideObject {
    SlideObject(id: id, objectKind: .shape, name: "Fill", text: "", fill: ObjectFill(fillKind: .media, mediaId: mediaId))
}

private func deck(_ id: String, name: String? = nil, themeId: String = "", slides: [Slide]? = nil) -> Presentation {
    Presentation(
        id: id, name: name ?? "Deck \(id)", presentationKind: .deck, themeId: themeId,
        slides: slides ?? [Slide(id: "\(id)-s0", name: "Verse", objects: [])])
}

private func theme(_ id: String, uses mediaId: String? = nil) -> Theme {
    Theme(
        id: id, name: "Theme \(id)", fontFamily: "Helvetica", fontSize: 60, textColorHex: "#fff", backgroundColorHex: "#000",
        slides: [Slide(id: "\(id)-design", name: "Design", objects: mediaId.map { [shape("\(id)-bg", filledWith: $0)] } ?? [])])
}

private func mediaItem(_ id: String) -> MediaItem {
    MediaItem(
        id: id, name: "Image \(id)", mediaKind: .video, classification: .background,
        fileHash: "hash-\(id)", fileName: "\(id).mov", fileStatus: .ready, statusDetail: "",
        tags: [], favorite: false, collections: [], loops: true, inPoint: nil,
        outPoint: nil, durationSeconds: 10, pixelWidth: 1920, pixelHeight: 1080)
}

private func audioItem(_ id: String) -> AudioItem {
    AudioItem(id: id, name: "Song \(id)", fileHash: "hash-\(id)", fileName: "\(id).m4a", tags: [], favorite: false, durationSeconds: 60)
}

@MainActor private func until(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(10)
    while !condition(), ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(2))
    }
    try #require(condition(), "timed out")
}

private final class Gate: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: (entered: 0, open: false))

    var entered: Int { state.withLock { $0.entered } }

    func open() {
        state.withLock { $0.open = true }
    }

    func pass() async {
        state.withLock { $0.entered += 1 }
        while !state.withLock({ $0.open }) {
            try? await Task.sleep(for: .milliseconds(1))
        }
    }
}

private final class Log: Sendable {
    private let lines = OSAllocatedUnfairLock(initialState: [String]())

    var all: [String] { lines.withLock { $0 } }

    func write(_ line: String) {
        lines.withLock { $0.append(line) }
    }

    func index(_ line: String) -> Int {
        all.firstIndex(of: line) ?? Int.max
    }
}

private final class StubDecks: DeckBundleSource {
    private let state = OSAllocatedUnfairLock(initialState: (bundles: [String: DeckBundle](), calls: [[String]]()))
    private let during: @Sendable () async -> Void
    private let renaming: Bool

    init(_ bundles: [DeckBundle], renaming: Bool = false, during: @escaping @Sendable () async -> Void = {}) {
        self.renaming = renaming
        self.during = during
        state.withLock { $0.bundles = Dictionary(uniqueKeysWithValues: bundles.map { ($0.presentation.id, $0) }) }
    }

    var calls: [[String]] { state.withLock { $0.calls } }

    @concurrent
    func deckBundles(ids: [String], priority: TaskPriority?) async -> DeckBundles {
        let call = state.withLock { $0.calls.append(ids.sorted()); return $0.calls.count }
        await during()
        let held = state.withLock { $0.bundles }
        var answer = DeckBundles()
        for id in ids {
            if var bundle = held[id] {
                if renaming { bundle.presentation.name = "Call \(call)" }
                answer.bundles[id] = bundle
            } else {
                answer.failed.insert(id)
            }
        }
        return answer
    }
}

private final class RecordingDecks: DeckBundleSource {
    private let inner: any DeckBundleSource
    private let log = OSAllocatedUnfairLock(initialState: [[String]]())

    init(_ inner: any DeckBundleSource) {
        self.inner = inner
    }

    var calls: [[String]] { log.withLock { $0 } }

    @concurrent
    func deckBundles(ids: [String], priority: TaskPriority?) async -> DeckBundles {
        log.withLock { $0.append(ids.sorted()) }
        return await inner.deckBundles(ids: ids, priority: priority)
    }
}

private struct NoFiles: ResidentFillSource {
    var log: Log?

    @concurrent
    func fillResidentTable<Entity: DocumentEntity>(
        _ type: Entity.Type, epoch: Int, known: [String: DocumentFileStamp]
    ) async -> ResidentTableFill<Entity> {
        log?.write("fill:\(Entity.documentKind.rawValue)")
        try? await Task.sleep(for: .milliseconds(3))
        return ResidentTableFill(epoch: epoch)
    }
}

@MainActor private final class Bumper {
    let epochs: DocumentKindVersions

    init(_ epochs: DocumentKindVersions) {
        self.epochs = epochs
    }

    func bump() {
        epochs.bump(.presentation)
    }
}

@MainActor private struct Rig {
    let epochs: DocumentKindVersions
    let fills = DocumentKindVersions()
    let library: ResidentLibrary
    let decks: ResidentDecks

    init(_ source: any DeckBundleSource, epochs: DocumentKindVersions = DocumentKindVersions(), log: Log? = nil) {
        self.epochs = epochs
        library = ResidentLibrary(source: NoFiles(log: log), epochs: epochs, fills: fills)
        decks = ResidentDecks(source: source, epochs: epochs, fills: fills, library: library)
    }
}

@Suite struct DeckBundleTests {

    @LibraryActor private func writeSunday(_ root: URL) throws -> DocumentStore {
        let files = try DocumentStore(rootURL: root)
        try files.save(TypedDocument(theme("t1")))
        try files.save(TypedDocument(theme("t2", uses: "m2")))
        try files.save(TypedDocument(mediaItem("m1")))
        try files.save(TypedDocument(mediaItem("m2")))
        try files.save(TypedDocument(audioItem("a1")))
        try files.save(TypedDocument(deck("sunday", themeId: "t1", slides: [
            Slide(id: "s0", name: "Walk-in", objects: [shape("o0", filledWith: "m1")]),
            Slide(id: "s1", name: "Song", objects: [shape("o1", filledWith: "a1")], themeId: "t2"),
            Slide(id: "s2", name: "Gone", objects: [shape("o2", filledWith: "gone-media")], themeId: "gone-theme"),
            Slide(id: "s3", name: "Screen", objects: [shape("o3", filledWith: "screen::main")]),
        ])))
        return files
    }

    @MainActor @Test func aBundleCarriesEveryThemeItsMediaAndAudioWithStamps() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let files = try await writeSunday(root)
        let client = LibraryClient(rootURL: root)
        try await client.start().value

        let read = try await client.deckBundles(ids: ["sunday", "nope"])
        #expect(read.failed == ["nope"])
        let bundle = try #require(read.bundles["sunday"])
        #expect(Set(bundle.themes.keys) == ["t1", "t2"], "the deck's theme and a slide's own")
        #expect(Set(bundle.media.keys) == ["m1", "m2"], "the deck's media and its theme's")
        #expect(Set(bundle.audio.keys) == ["a1"], "an id that is not a media item is audio")
        #expect(bundle.missingThemes == ["gone-theme"])
        #expect(bundle.missingMedia == ["gone-media"], "engine ids are not looked for")
        #expect(bundle.stamp == DocumentFileStamp.of(files.url(kind: .presentation, id: "sunday")))
        #expect(bundle.stamps.count == 5)
        #expect(bundle.stamps[SyncLedger.Key(kind: .theme, id: "t2")] == DocumentFileStamp.of(files.url(kind: .theme, id: "t2")))
        #expect(bundle.stamps[SyncLedger.Key(kind: .audio, id: "a1")] == DocumentFileStamp.of(files.url(kind: .audio, id: "a1")))

        let engine = LibraryEngine(rootURL: root)
        let fromEngine = try await Self.engineBundle(engine, id: "sunday")
        #expect(Set(fromEngine.themes.keys) == ["t1", "t2"])
        await #expect(throws: DocumentStore.StoreError.self) { try await Self.engineBundle(engine, id: "nope") }
    }

    @LibraryActor private static func engineBundle(_ engine: LibraryEngine, id: String) async throws -> DeckBundle {
        if (try? engine.reader()) == nil {
            _ = try engine.bootstrap()
        }
        return try await engine.deckBundle(id: id)
    }

    @MainActor @Test func aBundleDecodesBesideAParkedActor() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let files = try await writeSunday(root)
        try await files.save(TypedDocument(deck("big", themeId: "t2", slides: (0..<120).map { n in
            Slide(id: "big-\(n)", name: "Verse \(n)", objects: [shape("big-o\(n)", filledWith: "m1")])
        })))
        let client = LibraryClient(rootURL: root)
        try await client.start().value

        let park = ActorPark()
        let parked = Task.detached { await park.hold(atLeast: .milliseconds(300)) }
        while !park.entered {
            try await Task.sleep(for: .milliseconds(1))
        }
        let began = ContinuousClock.now
        let bundle = try #require(try await client.deckBundles(ids: ["big"]).bundles["big"])
        #expect(park.isHolding, "the bundle decoded beside the parked actor, not behind it")
        #expect(began.duration(to: .now) < .seconds(2))
        #expect(bundle.presentation.slides.count == 120)
        #expect(Set(bundle.themes.keys) == ["t2"] && Set(bundle.media.keys) == ["m1", "m2"])
        park.release()
        await parked.value
    }
}

private final class ActorPark: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: (entered: false, released: false, holding: false))

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

@Suite struct ResidentDecksTests {
    @MainActor @Test func aMissSchedulesOneFillAndReadsJoinIt() async throws {
        let gate = Gate()
        let source = StubDecks([DeckBundle(presentation: deck("a"))], during: { await gate.pass() })
        let rig = Rig(source)
        #expect(rig.decks.value("a") == nil, "a miss answers nil and never decodes on the caller")
        #expect(rig.decks.value("a") == nil)
        let waiting = Task { await rig.decks.ready(["a"]) }
        try await until { gate.entered == 1 }
        #expect(rig.decks.value("a") == nil)
        gate.open()
        #expect(await waiting.value["a"]?.name == "Deck a")
        #expect(source.calls == [["a"]], "every read joined the one fill")
        #expect(rig.decks.currentValue("a")?.name == "Deck a")
        #expect(rig.decks.value("a") != nil)
        #expect(source.calls.count == 1, "current: no refill")
    }

    @MainActor @Test func aLandingSeedsTheTablesInOneTurnAndBumpsOnce() async throws {
        let stamp = DocumentFileStamp(inode: 7, size: 1, modifiedNanoseconds: 1)
        let sunday = DeckBundle(
            presentation: deck("a", themeId: "t"), themes: ["t": theme("t")], media: ["m": mediaItem("m")],
            audio: ["x": audioItem("x")], stamps: [SyncLedger.Key(kind: .theme, id: "t"): stamp])
        let source = StubDecks([sunday, DeckBundle(presentation: deck("b"))])
        let rig = Rig(source)
        var seenAtLanding: [String] = []
        rig.decks.onFillLanded = { id in
            let seeded = rig.library.themes.table.value("t") != nil && rig.library.media.table.value("m") != nil
                && rig.library.audio.table.value("x") != nil
            seenAtLanding.append("\(id) seeded=\(seeded) version=\(rig.decks.fillVersion)")
        }

        rig.decks.pin(["a", "b"])
        let values = await rig.decks.ready(["a", "b"])
        #expect(Set(values.keys) == ["a", "b"])
        #expect(source.calls == [["a", "b"]], "one source call for the set")
        #expect(seenAtLanding == ["a seeded=true version=1", "b seeded=true version=1"], "one turn: tables, then one bump, then the callback")
        #expect(rig.decks.fillVersion == 1)
        #expect(rig.fills[.theme] == 0, "seeding bumps no table's fill version")
        #expect(rig.library.themes.currentValue("t")?.name == "Theme t")
        #expect(rig.library.themes.table.entries["t"]?.stamp == stamp, "the stamp rides with the value")
    }

    @MainActor @Test func aKindWhoseEpochMovedIsNotSeeded() async throws {
        let gate = Gate()
        let source = StubDecks(
            [DeckBundle(presentation: deck("a"), themes: ["t": theme("t")], media: ["m": mediaItem("m")])],
            during: { await gate.pass() })
        let rig = Rig(source)
        _ = rig.decks.value("a")
        try await until { gate.entered == 1 }
        rig.epochs.bump(.media)
        gate.open()
        _ = await rig.decks.ready(["a"])
        #expect(rig.library.themes.table.value("t") != nil)
        #expect(rig.library.media.table.value("m") == nil, "media moved during the fill: its own refill owns it")
    }

    @MainActor @Test func aLibraryWideBumpKeepsBehindValuesAndRefillsOnlyThePinned() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let files = try DocumentStore(rootURL: root)
        for id in ["p1", "p2", "p3"] {
            try await files.save(TypedDocument(deck(id)))
        }
        let client = LibraryClient(rootURL: root)
        try await client.start().value
        let source = RecordingDecks(client.deckBundleSource)
        let rig = Rig(source)
        rig.decks.pin(["p1", "p2"])
        _ = await rig.decks.ready(["p1", "p2", "p3"])
        #expect(Set(source.calls) == [["p1", "p2"], ["p3"]], "the pinned pair in one call; ready joined it")
        let reader = try await client.reader()
        let decoded = reader.cache.counts.fills

        try await onLibraryActor {
            let outside = try files.load(Presentation.self, id: "p1")
            try outside.update { $0.name = "Outside" }
            try files.save(outside)
        }
        rig.epochs.bumpAll()
        rig.decks.libraryWideBump()
        #expect(rig.decks.currentValue("p1") == nil)
        #expect(rig.decks.table.value("p1")?.name == "Deck p1", "behind, still drawn")
        #expect(rig.decks.table.value("p3")?.name == "Deck p3")

        try await until { rig.decks.currentValue("p1") != nil && rig.decks.currentValue("p2") != nil }
        #expect(rig.decks.currentValue("p1")?.name == "Outside")
        #expect(source.calls.dropFirst(2) == [["p1", "p2"]], "only the pinned refilled")
        #expect(rig.decks.currentValue("p3") == nil && rig.decks.table.value("p3") != nil)
        #expect(reader.cache.counts.fills - decoded == 1, "a stat per deck, a decode for the changed file only")
    }

    @MainActor @Test func aSingleChangeRetagsTheOtherDecksAndTheFillsInFlight() async throws {
        let gate = Gate()
        let source = StubDecks(["a", "b", "c"].map { DeckBundle(presentation: deck($0)) }, during: { await gate.pass() })
        let rig = Rig(source)
        gate.open()
        _ = await rig.decks.ready(["a", "b"])

        rig.epochs.bump(.presentation)
        rig.decks.reseed(id: "b", value: deck("b", name: "Edited"))
        #expect(rig.decks.currentValue("a")?.name == "Deck a", "a sibling carries over")
        #expect(rig.decks.currentValue("b")?.name == "Edited")
        _ = rig.decks.value("a")
        #expect(source.calls.count == 1, "no refill")

        rig.epochs.bump(.presentation)  
        rig.epochs.bump(.presentation)
        rig.decks.reseed(id: "b", value: deck("b", name: "Again"))
        #expect(rig.decks.currentValue("a") == nil, "behind stays behind")
        #expect(rig.decks.table.value("a")?.name == "Deck a")

        let before = source.calls.count
        rig.decks.fill(["c"])
        rig.epochs.bump(.presentation)
        rig.decks.reseed(id: "b", value: nil)
        _ = await rig.decks.ready(["c", "b"])
        #expect(rig.decks.currentValue("c")?.name == "Deck c", "a fill in flight is retagged by another deck's change")
        #expect(source.calls.count == before + 1)
        #expect(rig.decks.table.absent["b"] == rig.epochs[.presentation], "a delete is known absent")
    }

    @MainActor @Test func aRestyleCarriesEveryDeckOver() async throws {
        let source = StubDecks(["a", "b"].map { DeckBundle(presentation: deck($0)) })
        let rig = Rig(source)
        _ = await rig.decks.ready(["a", "b", "gone"])
        rig.epochs.bump(.presentation)
        rig.decks.carryOver()
        #expect(rig.decks.currentValue("a")?.name == "Deck a")
        #expect(rig.decks.currentValue("b")?.name == "Deck b")
        #expect(rig.decks.table.absent["gone"] == rig.epochs[.presentation])
        _ = rig.decks.value("a")
        _ = rig.decks.value("gone")
        #expect(source.calls.count == 1, "no refill")

        rig.epochs.bump(.presentation)  
        rig.epochs.bump(.presentation)
        rig.decks.carryOver()
        #expect(rig.decks.currentValue("a") == nil, "behind stays behind")
    }

    @MainActor @Test func readyAnswersAbsentIdsAsAbsentWithNoSynchronousPath() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try await DocumentStore(rootURL: root).save(TypedDocument(deck("p1")))
        let client = LibraryClient(rootURL: root)
        try await client.start().value
        let source = RecordingDecks(client.deckBundleSource)
        let rig = Rig(source)

        var values: [String: Presentation] = [:]
        let trapped = await MainThreadOpenTrap.recordingOpens {
            values = await rig.decks.ready(["p1", "gone"])
        }
        #expect(trapped.isEmpty, "decoded on the main thread: \(trapped)")
        #expect(Set(values.keys) == ["p1"], "no file answers for gone: absent")
        _ = rig.decks.value("gone")
        #expect(source.calls == [["gone", "p1"]], "known absent at this epoch: no refill")
    }

    @MainActor @Test func readyUnderAMovingKindAnswersTheFreshestValue() async throws {
        let epochs = DocumentKindVersions()
        let bumper = Bumper(epochs)
        let source = StubDecks([DeckBundle(presentation: deck("a"))], renaming: true, during: { await bumper.bump() })
        let rig = Rig(source, epochs: epochs)
        let values = await rig.decks.ready(["a"])
        #expect(source.calls.count == ResidentDecks.readyRounds, "bounded refills")
        #expect(values["a"]?.name == "Call \(ResidentDecks.readyRounds)", "the last fill's value")
        #expect(rig.decks.currentValue("a") == nil, "behind: the kind moved during it")
    }

    @MainActor @Test func pinReplacesTheLiveSet() async throws {
        let source = StubDecks(["a", "b", "c"].map { DeckBundle(presentation: deck($0)) })
        let rig = Rig(source)
        rig.decks.pin(["a", "b"])
        rig.decks.pin(["c"])
        #expect(rig.decks.pinned == ["c"])
        try await until { rig.decks.currentValue("c") != nil && rig.decks.currentValue("a") != nil }

        rig.epochs.bumpAll()
        rig.decks.libraryWideBump()
        try await until { rig.decks.currentValue("c") != nil }
        #expect(Set(source.calls.prefix(2)) == [["a", "b"], ["c"]])
        #expect(source.calls.dropFirst(2) == [["c"]], "the bump refilled the new set only")
        #expect(rig.decks.currentValue("a") == nil)
    }
}

@Suite struct DeckWriteTests {

    @MainActor @Test func aHeldDeckWritesNowAndAnAbsentOneAnswersNil() async throws {
        let source = StubDecks([DeckBundle(presentation: deck("a"))])
        let rig = Rig(source)
        _ = await rig.decks.ready(["a", "gone"])
        var seen: [String?] = []
        if case .now = rig.decks.write("a", { seen.append($0?.name) }) {} else { Issue.record("a held deck writes now") }
        if case .now = rig.decks.write("gone", { seen.append($0?.name) }) {} else { Issue.record("a known absence writes now") }
        #expect(seen == ["Deck a", nil])
    }

    @MainActor @Test func aMissWritesAfterTheFillWithTheDeck() async throws {
        let gate = Gate()
        let source = StubDecks([DeckBundle(presentation: deck("a"))], during: { await gate.pass() })
        let rig = Rig(source)
        let log = Log()
        let turn = rig.decks.write("a") { log.write("wrote:\($0?.name ?? "nil")") }
        #expect(!rig.decks.isHeldForWrite("a"))
        try await until { gate.entered == 1 }
        #expect(log.all.isEmpty, "nothing written before the fill")
        gate.open()
        if case .later(let task) = turn { await task.value } else { Issue.record("a miss waits") }
        #expect(log.all == ["wrote:Deck a"])
        #expect(rig.decks.isHeldForWrite("a"), "held once the write ran")
    }

    @MainActor @Test func waitingWritesKeepTheirOrderAndNestedWritesRunInside() async throws {
        let gate = Gate()
        let source = StubDecks([DeckBundle(presentation: deck("a"))], during: { await gate.pass() })
        let rig = Rig(source)
        let log = Log()
        let decks = rig.decks
        let first = decks.write("a") { _ in
            log.write("first")
            if case .now = decks.write("a", { _ in log.write("nested") }) {} else { log.write("nested deferred") }
        }
        let second = decks.write("a") { _ in log.write("second") }
        try await until { gate.entered == 1 }
        gate.open()
        if case .later(let task) = first { await task.value }
        if case .later(let task) = second { await task.value }
        #expect(log.all == ["first", "nested", "second"])
        #expect(source.calls == [["a"]], "one fill for every waiting write")
        #expect(decks.isHeldForWrite("a"))
    }

    @Test func theLiveSetIsTheRunOfShowsDecksAndTheDeckOnAir() {
        let items = [
            ServiceItem(id: "h", itemKind: .header, name: "Worship", refId: ""),
            ServiceItem(id: "1", itemKind: .presentation, name: "Song", refId: "song"),
            ServiceItem(id: "2", itemKind: .media, name: "Bumper", refId: "bumper"),
            ServiceItem(id: "3", itemKind: .presentation, name: "Song again", refId: "song"),
            ServiceItem(id: "4", itemKind: .presentation, name: "Unlinked", refId: ""),
        ]
        #expect(ResidentDecks.liveSet(runOfShow: items, onAir: "welcome") == ["song", "welcome"])
        #expect(ResidentDecks.liveSet(runOfShow: items, onAir: nil) == ["song"])
        #expect(ResidentDecks.liveSet(runOfShow: [], onAir: "") == [])
    }
}

@Suite struct ResidentFireReadTests {
    private func now(_ read: ResidentFireRead<String>) -> String?? {
        if case .now(let value) = read { value } else { nil }
    }

    @Test func aCurrentHitFiresAndACoveredMissIsNoSuchDocument() {
        #expect(now(ResidentFireRead(id: "t", current: "Look", covered: true)) == .some("Look"))
        #expect(now(ResidentFireRead(id: "t", current: "Look", covered: false)) == .some("Look"), "a current value fires at once")
        #expect(now(ResidentFireRead(id: "t", current: nil, covered: true)) == .some(nil), "covered: the theme does not exist")
        #expect(now(ResidentFireRead(id: "", current: nil, covered: false)) == .some(nil), "no theme named: nothing to wait for")
    }

    @Test func anUncoveredMissWaitsForTheFill() {
        if case .afterFill = ResidentFireRead<String>(id: "t", current: nil, covered: false) {} else {
            Issue.record("a table that does not cover the kind yet (or holds it behind) waits, never decodes")
        }
    }

    @MainActor @Test func theTablesReadWaitsUntilTheValueIsCurrent() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try DocumentStore(rootURL: root)
        try await store.save(TypedDocument(theme("t")))
        let epochs = DocumentKindVersions()
        let themes = ResidentDocuments<Theme>(store: store, epochs: epochs, fills: DocumentKindVersions())
        if case .afterFill = themes.fireRead("t") {} else { Issue.record("before the fill: wait") }
        await themes.ready()
        if case .now(let value) = themes.fireRead("t") { #expect(value?.id == "t") } else { Issue.record("a hit") }
        if case .now(let value) = themes.fireRead("gone") { #expect(value == nil) } else { Issue.record("covered: no such theme") }
        epochs.bumpAll()
        if case .afterFill = themes.fireRead("t") {} else { Issue.record("behind: wait for the refill the read started") }
        await themes.ready()
        if case .now(let value) = themes.fireRead("t") { #expect(value?.id == "t") } else { Issue.record("current again") }
    }
}

@Suite struct LaunchResidencyTests {
    @MainActor @Test func theSetupKindsAreThisComputersResidentKindsPlusServices() {
        let rig = Rig(StubDecks([]))
        #expect(ResidentLibrary.kinds == rig.library.all.map(\.kind))
        #expect(ResidentLibrary.setupKinds == [
            .streamRecordPreset, .streamDestination, .schedulerBoard, .controlBoard, .signageBoard, .outputPreset,
            .midiDevice, .service,
        ])
        #expect(ResidencyStageTiming.detail([.init(name: "setup", milliseconds: 12), .init(name: "live", milliseconds: 40)])
            == "setup=12 live=40")
    }

    @MainActor @Test func theStagesRunInOrderAndADemandReadJumpsTheQueue() async throws {
        let log = Log()
        let source = StubDecks([DeckBundle(presentation: deck("live"))], during: { log.write("bundle") })
        let rig = Rig(source, log: log)
        let stages = ResidentLibrary.launchStages(
            setup: { log.write("setup work") },
            liveSet: {
                log.write("live")
                _ = rig.library.themes.value("t")
                rig.decks.pin(["live"])
                _ = await rig.decks.ready(["live"])
            })
        var timings: [ResidencyStageTiming] = []
        await rig.library.warmStaged(stages) { timings = $0 }

        let lines = log.all
        let fillLines = lines.filter { $0.hasPrefix("fill:") }
        #expect(fillLines.count == ResidentLibrary.kinds.count, "one fill per kind: \(fillLines)")
        let setup = ResidentLibrary.setupKinds.map { log.index("fill:\($0.rawValue)") }
        let rest = ResidentLibrary.kinds.filter { ![.media, .audio, .theme].contains($0) && !ResidentLibrary.setupKinds.contains($0) }
        #expect(setup.allSatisfy { $0 < log.index("live") })
        #expect(log.index("setup work") < log.index("live"))
        #expect(log.index("live") < log.index("fill:theme"))
        #expect(log.index("fill:theme") < log.index("fill:media"), "the demand read jumped the queue")
        #expect(log.index("bundle") < log.index("fill:media"), "the live set before media")
        #expect(rest.allSatisfy { log.index("fill:\($0.rawValue)") > max(log.index("fill:media"), log.index("fill:audio")) })
        #expect(timings.map(\.name) == ["setup", "live", "media", "themes", "rest"])
        #expect(rig.decks.currentValue("live") != nil)
    }
}

@Suite struct ResidentDeckObservationTests {
    private final class Flag: @unchecked Sendable {
        var fired = false
    }

    @MainActor private func fires(_ read: () -> Void, when change: () -> Void) -> Bool {
        let flag = Flag()
        withObservationTracking(read) { flag.fired = true }
        change()
        return flag.fired
    }

    @MainActor @Test func aReaderOfOneDeckIgnoresAnothersChanges() async throws {
        let source = StubDecks(["a", "b"].map { DeckBundle(presentation: deck($0)) })
        let rig = Rig(source)
        _ = await rig.decks.ready(["a", "b"])
        let readA = { _ = rig.decks.value("a") }
        #expect(!fires(readA) { rig.epochs.bump(.presentation); rig.decks.reseed(id: "b", value: deck("b", name: "Edited")) })
        #expect(fires(readA) { rig.epochs.bump(.presentation); rig.decks.reseed(id: "a", value: deck("a", name: "Edited")) })
        #expect(fires({ _ = rig.decks.currentValue("a") }) {
            rig.epochs.bump(.presentation)
            rig.decks.writeRefused(id: "a")
        }, "currentValue subscribes to its deck too")

        #expect(!fires(readA) { rig.epochs.bump(.presentation); rig.decks.carryOver() })
    }

    @MainActor @Test func aLandingRedrawsOnlyItsDecksReaders() async throws {
        let gate = Gate()
        let source = StubDecks(["a", "b"].map { DeckBundle(presentation: deck($0)) }, during: { await gate.pass() })
        let rig = Rig(source)
        gate.open()
        _ = await rig.decks.ready(["a"])
        let a = Flag()
        let b = Flag()
        withObservationTracking { _ = rig.decks.value("a") } onChange: { a.fired = true }
        withObservationTracking { _ = rig.decks.value("b") } onChange: { b.fired = true }
        _ = await rig.decks.ready(["b"])
        #expect(b.fired, "b's reader redraws when b lands")
        #expect(!a.fired, "a's reader does not")
        #expect(rig.decks.fillVersion == 2, "the fill version still moves per landing, for memo keys")
    }

    @MainActor @Test func aKindWideMoveRedrawsEveryReader() async throws {
        let source = StubDecks(["a", "b"].map { DeckBundle(presentation: deck($0)) })
        let rig = Rig(source)
        _ = await rig.decks.ready(["a", "b"])
        let readB = { _ = rig.decks.value("b") }
        #expect(fires(readB) { rig.epochs.bumpAll(); rig.decks.libraryWideBump() })
        #expect(fires(readB) { rig.epochs.bump(.presentation); rig.decks.kindWideBump() })

        try await until {
            _ = rig.decks.value("b")
            return rig.decks.currentValue("b") != nil
        }
    }
}
