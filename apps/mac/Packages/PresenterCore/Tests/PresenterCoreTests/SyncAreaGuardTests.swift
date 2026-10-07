import Foundation
import Testing

@testable import PresenterCore

private func makeRoot() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("sync-area-\(UUID().uuidString)")
}

private let deckKey = SyncLedger.Key(kind: .presentation, id: "deck")

private func deck() -> Presentation {
    DeckFixtures.deck()
}

@LibraryActor private func secondIndex(_ root: URL) throws -> LibraryIndex {
    try LibraryIndex(url: root.appendingPathComponent("index.sqlite"))
}

@MainActor private func startedClient(_ root: URL) async throws -> LibraryClient {
    let client = LibraryClient(rootURL: root)
    try await client.start().value
    return client
}

@Suite struct SyncAreaGuardTests {

    @LibraryActor @Test func aGuessNeverOverwritesARow() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = LibraryEngine(rootURL: root)
        try engine.bootstrap()
        try engine.create(deck())
        try engine.create(DeckFixtures.deck("other"))
        let other = SyncLedger.Key(kind: .presentation, id: "other")

        try engine.setArea(.team, of: [deckKey], origin: .landed)
        #expect(try engine.setAreaIfAbsent(.station, of: deckKey) == .team, "the team row stands")
        #expect(engine.snapshot.area(kind: .presentation, id: "deck") == .team)
        #expect(try secondIndex(root).area(kind: .presentation, id: "deck") == .team, "nothing reached the index either")

        #expect(try engine.setAreaIfAbsent(.station, of: other) == .station, "no row: the guess is written")
        #expect(try secondIndex(root).area(kind: .presentation, id: "other") == .station)
        #expect(try engine.setAreaIfAbsent(.team, of: other) == .station, "and then it stands against a later guess")
    }

    @MainActor @Test func aGuessNeverOverwritesARowMainHasNotApplied() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let client = try await startedClient(root)
        _ = try await client.create(deck()).value
        await client.settled()

        client.setArea(.team, of: [deckKey], origin: .landed)
        #expect(client.snapshot.area(kind: .presentation, id: "deck") == nil, "main has not applied the team row's batch")
        #expect(client.resolveArea(kind: .presentation, id: "deck") == .station, "main's answer is the guess")
        #expect(await client.standingArea(kind: .presentation, id: "deck") == .team, "the path takes the row that stands")
        #expect(try await client.settledSnapshot().area(kind: .presentation, id: "deck") == .team, "the guess wrote nothing over it")
        #expect(try await secondIndex(root).area(kind: .presentation, id: "deck") == .team)
    }

    @MainActor @Test func nothingIsGuessedOrWrittenBeforeReady() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try await DocumentStore(rootURL: root).save(TypedDocument(deck()))
        let client = LibraryClient(rootURL: root)
        #expect(!client.isReady)
        #expect(client.resolveArea(kind: .presentation, id: "deck") == nil)
        #expect(await client.standingArea(kind: .presentation, id: "deck") == nil)
        #expect(SyncAreaGuess.answer(for: deckKey, isReady: false, snapshot: .empty, sync: .empty) == .unknown)
        #expect(SyncAreaGuess.answer(for: SyncLedger.Key(kind: .stationSettings, id: "s"), isReady: false, snapshot: .empty, sync: .empty)
            == .known(.station), "a station kind needs no read")

        try await client.start().value
        #expect(try await client.settledSnapshot().area(kind: .presentation, id: "deck") == nil, "no guess was queued before the open")
        #expect(try await secondIndex(root).area(kind: .presentation, id: "deck") == nil)
    }

    @Test func theAnswerIsTheRowElseAGuess() {
        let team = IndexSnapshot(entries: [], areas: ["presentation/deck": .team], generation: 1)
        #expect(SyncAreaGuess.answer(for: deckKey, isReady: true, snapshot: team, sync: .empty) == .known(.team))
        let none = IndexSnapshot(entries: [], areas: [:], generation: 1)
        #expect(SyncAreaGuess.answer(for: deckKey, isReady: true, snapshot: none, sync: .empty) == .guess(.station))
    }

    @LibraryActor @Test func theRestoreResetsTheLedgerAndIsNotAMove() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = LibraryEngine(rootURL: root)
        try engine.bootstrap()
        try engine.create(deck())
        try engine.create(DeckFixtures.deck("kept"))
        let kept = SyncLedger.Key(kind: .presentation, id: "kept")
        try engine.setArea(.station, of: [deckKey], origin: .landed)
        try engine.setArea(.team, of: [kept], origin: .landed)
        try engine.setSyncEntry(SyncLedger.Entry(lastPushedHeads: ["x"], appliedSeq: 3, remoteSeq: 3), kind: .presentation, id: "deck")

        let restored = try engine.restoreFlippedAreas([deckKey, kept])
        #expect(restored == [deckKey])
        #expect(engine.snapshot.area(kind: .presentation, id: "deck") == .team)
        #expect(engine.syncEntry(kind: .presentation, id: "deck") == nil)
        #expect(try secondIndex(root).syncEntry(kind: .presentation, id: "deck") == nil)
        #expect(try secondIndex(root).area(kind: .presentation, id: "deck") == .team)
        #expect(engine.snapshot.area(kind: .presentation, id: "kept") == .team)
    }
}
