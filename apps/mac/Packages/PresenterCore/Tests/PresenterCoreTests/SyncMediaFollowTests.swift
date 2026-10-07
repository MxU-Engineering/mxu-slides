import Foundation
import Testing

@testable import PresenterCore

private func makeRoot() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("media-follow-\(UUID().uuidString)")
}

private func mediaItem(_ id: String, hash: String) -> MediaItem {
    MediaItem(
        id: id, name: "Image \(id)", mediaKind: .video, classification: .background,
        fileHash: hash, fileName: "\(id).mov", fileStatus: .ready, statusDetail: "",
        tags: [], favorite: false, collections: [], loops: true, inPoint: nil,
        outPoint: nil, durationSeconds: 10, pixelWidth: 1920, pixelHeight: 1080)
}

private func audioItem(_ id: String, hash: String) -> AudioItem {
    AudioItem(id: id, name: "Song \(id)", fileHash: hash, fileName: "\(id).m4a", tags: [], favorite: false, durationSeconds: 60)
}

private func preroll(_ id: String = "preroll", uses: [String] = ["m1", "a1"]) -> Presentation {
    Presentation(
        id: id, name: "Pre-roll", presentationKind: .deck, themeId: "",
        slides: uses.enumerated().map { n, mediaId in
            Slide(
                id: "\(id)-s\(n)", name: "Slide \(n)",
                objects: [
                    SlideObject(id: "\(id)-o\(n)", objectKind: .shape, name: "Fill", text: "", fill: ObjectFill(fillKind: .media, mediaId: mediaId))
                ])
        })
}

private func key(_ kind: DocumentKind, _ id: String) -> SyncLedger.Key {
    SyncLedger.Key(kind: kind, id: id)
}

private let deckKey = key(.presentation, "preroll")

@Suite struct SyncMediaFollowTests {

    @LibraryActor @Test func aTeamDeckTakesItsStationMediaAndThisMacOnlyAsks() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = LibraryEngine(rootURL: root)
        let start = try engine.bootstrap()
        try engine.create(mediaItem("m1", hash: "h1"))
        try engine.create(mediaItem("m2", hash: "h2"))
        try engine.create(audioItem("a1", hash: "ha"))
        try engine.create(preroll(uses: ["m1", "m2", "a1", "not-here", "screen::1"]))
        try engine.setArea(.station, of: [key(.media, "m1")], origin: .landed)
        try engine.setArea(.local, of: [key(.audio, "a1")], origin: .landed)
        try engine.setArea(.team, of: [deckKey], origin: .landed)
        try engine.setSyncEntry(SyncLedger.Entry(lastPushedHeads: ["x"], appliedSeq: 2, remoteSeq: 2), kind: .media, id: "m1")

        let moved = try engine.followMediaToTeam([deckKey: MediaReferences.ids(in: preroll(uses: ["m1", "m2", "a1", "not-here", "screen::1"]))])
        #expect(moved == [key(.media, "m1"), key(.media, "m2")], "m2 had no row: This Station's; a1 is This Mac only and asks")
        #expect(engine.snapshot.area(kind: .audio, id: "a1") == .local)
        for moved in moved {
            #expect(engine.snapshot.area(kind: moved.kind, id: moved.id) == .team)
            #expect(try DocumentStore(rootURL: root).exists(kind: moved.kind, id: moved.id), "the file stays")
        }
        #expect(engine.syncEntry(kind: .media, id: "m1") == nil, "the ledger starts over in the move's turn")
        #expect(engine.sync.heldDeletes.map { "\($0.key.kind.rawValue)/\($0.key.id) \($0.side.rawValue) \($0.namespace.rawValue)" }
            == ["media/m1 local station"], "only the pushed station copy has a tombstone to send")
        #expect(engine.snapshot.entry(id: "not-here") == nil, "media not held here is left alone")
        #expect(engine.snapshot.area(kind: .media, id: "not-here") == nil)

        var moves: [AreaMove] = []
        for await batch in start.batches where !batch.areaMoves.isEmpty && batch.areaMoves.allSatisfy({ $0.to == .team && $0.kind != .presentation }) {
            moves = SyncBatchRoute(batch).moved
            break
        }
        #expect(moves.map { "\($0.kind.rawValue)/\($0.id) \($0.from.rawValue)" } == ["media/m1 station", "media/m2 station"],
                "the operator's kind of move: the sync pushes each whole")
    }

    @LibraryActor @Test func localOnlyDocumentsAndMediaNotHeldAreUntouched() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = LibraryEngine(rootURL: root)
        try engine.bootstrap()
        try engine.create(mediaItem("m1", hash: "h1"))
        try engine.setArea(.station, of: [key(.media, "m1")], origin: .landed)
        let refs: Set<String> = ["m1"]
        for (id, area) in [("local", LibraryArea.local), ("station", .station)] {
            try engine.create(preroll(id, uses: ["m1"]))
            try engine.setArea(area, of: [key(.presentation, id)], origin: .landed)
        }
        try engine.create(preroll("unfiled", uses: ["m1"]))
        try engine.create(preroll("team", uses: ["gone"]))
        try engine.setArea(.team, of: [key(.presentation, "team")], origin: .landed)

        let moved = try engine.followMediaToTeam([
            key(.presentation, "local"): refs, key(.presentation, "station"): refs, key(.presentation, "unfiled"): refs,
            key(.presentation, "team"): ["gone"],
        ])
        #expect(moved.isEmpty)
        #expect(engine.snapshot.area(kind: .media, id: "m1") == .station)
        #expect(engine.snapshot.area(kind: .media, id: "gone") == nil, "no row written for media not held here")
        #expect(SyncMediaFollow.toMove(
            references: [key(.stationSettings, "s"): refs], snapshot: engine.snapshot, sync: engine.sync).isEmpty, "only referencing kinds count")
    }

    @LibraryActor @Test func thisMacOnlyMediaAsksOnlyWhenADriveDocumentNewlyUsesIt() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = LibraryEngine(rootURL: root)
        try engine.bootstrap()
        try engine.create(mediaItem("m1", hash: "h1"))
        try engine.create(audioItem("a1", hash: "ha"))
        try engine.create(mediaItem("st", hash: "hs"))
        try engine.setArea(.local, of: [key(.media, "m1"), key(.audio, "a1")], origin: .landed)
        try engine.setArea(.station, of: [key(.media, "st")], origin: .landed)
        for id in ["sunday", "old"] {
            try engine.create(preroll(id, uses: ["m1"]))
            try engine.setArea(.team, of: [key(.presentation, id)], origin: .landed)
        }
        try engine.create(preroll("mine", uses: ["m1"]))
        try engine.setArea(.local, of: [key(.presentation, "mine")], origin: .landed)

        let ask = SyncMediaFollow.toAsk(
            references: [key(.presentation, "sunday"): ["m1", "a1", "st"], key(.presentation, "old"): ["m1"], key(.presentation, "mine"): ["m1"]],
            known: [key(.presentation, "old"): ["m1"]], snapshot: engine.snapshot, sync: engine.sync)
        #expect(ask.documents == [key(.presentation, "sunday")], "old's use is known to the team; mine is not a team document")
        #expect(ask.media == [key(.audio, "a1"), key(.media, "m1")], "This Station media moves on its own, never asks")
    }

    @LibraryActor @Test func theRuleIsOneWay() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = LibraryEngine(rootURL: root)
        try engine.bootstrap()
        try engine.create(mediaItem("m1", hash: "h1"))
        try engine.create(preroll(uses: ["m1"]))
        try engine.setArea(.station, of: [key(.media, "m1")], origin: .landed)
        try engine.setArea(.team, of: [deckKey], origin: .landed)
        #expect(try engine.followMediaToTeam([deckKey: ["m1"]]) == [key(.media, "m1")])

        try engine.setArea(.station, of: [deckKey])
        #expect(try engine.followMediaToTeam([deckKey: ["m1"]]).isEmpty)
        #expect(engine.snapshot.area(kind: .media, id: "m1") == .team, "the media stays in the team")
        #expect(SyncMediaFollow.candidates(["m1"], snapshot: engine.snapshot, sync: engine.sync).isEmpty)
        let reachedTeam = SyncLedger.Entry(lastPushedHeads: ["x"], appliedSeq: 1, remoteSeq: 1)
        #expect(SyncMediaFollow.area(of: key(.media, "old"), snapshot: .empty, sync: LibrarySyncState(entries: [key(.media, "old"): reachedTeam]))
            == .team, "no row but already in the team library: the team's")
    }

    @Test func theSweepMovesOnceAndThenFindsNothing() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = LibraryEngine(rootURL: root)
        let reader = try await engine.bootstrap().reader
        try await engine.create(mediaItem("m1", hash: "h1"))
        try await engine.create(audioItem("a1", hash: "ha"))
        try await engine.create(preroll(uses: ["m1"]))
        try await engine.create(Playlist(
            id: "walk-in", name: "Walk-in", entries: [PlaylistEntry(id: "e", refKind: .media, refId: "a1")], playbackMode: .playAll, crossfadeSeconds: 0))
        try await engine.create(preroll("station-deck", uses: ["m1"]))
        try await engine.setArea(.team, of: [deckKey, key(.playlist, "walk-in")], origin: .landed)

        let documents = SyncMediaFollow.teamDocuments(in: await engine.snapshot)
        #expect(Set(documents) == [deckKey, key(.playlist, "walk-in")], "team documents only")
        let references = await SyncMediaFollow.references(of: documents, reader: reader)
        #expect(references == [deckKey: ["m1"], key(.playlist, "walk-in"): ["a1"]])
        #expect(try await engine.followMediaToTeam(references) == [key(.audio, "a1"), key(.media, "m1")])

        let again = await SyncMediaFollow.references(of: SyncMediaFollow.teamDocuments(in: await engine.snapshot), reader: reader)
        #expect(try await engine.followMediaToTeam(again).isEmpty, "a second run moves nothing")
    }

    @LibraryActor @Test func theSavePathReadsTheBatchValues() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = LibraryEngine(rootURL: root)
        try engine.bootstrap()
        let saved = try engine.create(preroll(uses: ["m1", "a1"]))
        #expect(SyncMediaFollow.saved(in: saved).map(\.key) == [deckKey])
        #expect(await SyncMediaFollow.references(in: SyncMediaFollow.saved(in: saved)) == [deckKey: ["m1", "a1"]])
        #expect(SyncMediaFollow.saved(in: try engine.create(preroll("landed"), origin: .landed)).isEmpty)
        #expect(SyncMediaFollow.saved(in: try engine.create(mediaItem("m1", hash: "h1"))).isEmpty, "media itself references nothing")
    }

    @LibraryActor @Test func pausedTheFollowIsDeferred() throws {
        var owed = SyncMediaFollow.Owed()
        #expect(owed.offer([deckKey], waiting: true).isEmpty)
        #expect(owed.offer([key(.playlist, "p")], waiting: true).isEmpty)
        #expect(owed.documents == [deckKey, key(.playlist, "p")])
        #expect(owed.offer([key(.overlay, "o")], waiting: false) == [key(.overlay, "o")], "not waiting: checked now, not owed")
        #expect(owed.release() == [key(.playlist, "p"), deckKey])
        #expect(owed.release().isEmpty, "once")

        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = LibraryEngine(rootURL: root)
        try engine.bootstrap()
        try engine.create(mediaItem("m1", hash: "h1"))
        try engine.create(preroll(uses: ["m1"]))
        try engine.setArea(.station, of: [key(.media, "m1")], origin: .landed)
        try engine.setArea(.team, of: [deckKey], origin: .landed)
        try engine.setSyncEntry(SyncLedger.Entry(lastPushedHeads: ["x"], appliedSeq: 1, remoteSeq: 1), kind: .media, id: "m1")
        #expect(engine.snapshot.area(kind: .media, id: "m1") == .station, "owed: nothing moved while paused")

        #expect(try engine.followMediaToTeam([deckKey: ["m1"]]) == [key(.media, "m1")], "the release checks it")
        let held = try #require(engine.sync.heldDeletes.first)
        #expect(SyncDeleteHold.release(held, paused: true, usedByLive: false, heldHere: true, currentNamespace: .team) == .keep)
        #expect(SyncDeleteHold.release(held, paused: false, usedByLive: false, heldHere: true, currentNamespace: .team) == .apply)
    }
}
