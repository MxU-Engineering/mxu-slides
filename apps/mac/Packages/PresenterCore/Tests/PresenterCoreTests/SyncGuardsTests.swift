import Foundation
import Testing
@testable import PresenterCore

@Suite struct SyncGuardsTests {
    @LibraryActor @Test func aLibraryOnlySyncsWithTheTeamItBelongsTo() throws {
        let labs = SyncIdentity(serverHost: "app.example.com", teamHexId: "t1", teamName: "Grace")
        #expect(SyncIdentity.verdict(stored: nil, current: labs) == .adopt)
        #expect(SyncIdentity.verdict(stored: labs, current: labs) == .match(upgrade: false))
        #expect(SyncIdentity.verdict(stored: labs, current: .init(serverHost: "app.example.com", teamHexId: "t2", teamName: "Grace")) == .mismatch, "same name, another team")
        #expect(SyncIdentity.verdict(stored: labs, current: .init(serverHost: "app.other.example", teamHexId: "t1", teamName: "Grace")) == .mismatch, "another server")
        let old = SyncIdentity(serverHost: "app.example.com", teamHexId: nil, teamName: "Grace")
        #expect(SyncIdentity.verdict(stored: old, current: labs) == .match(upgrade: true), "a session saved before the hex id was kept")
        #expect(SyncIdentity.verdict(stored: old, current: .init(serverHost: "app.example.com", teamHexId: "t9", teamName: "Other Church")) == .mismatch)

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try Library(rootURL: root)
        #expect(try library.index.syncIdentity() == nil)
        try library.index.setSyncIdentity(old)
        try library.index.setSyncIdentity(labs)
        #expect(try library.index.syncIdentity() == labs)
        try library.index.setSyncEntry(.init(lastPushedHeads: ["a"], appliedSeq: 1, remoteSeq: 1), kind: .theme, id: "t")
        try library.index.markBlobUploaded("abc")
        try library.index.setArea(.team, kind: .theme, id: "t")
        try library.index.resetSyncState()
        #expect(try library.index.allSyncEntries().isEmpty && !(try library.index.blobUploaded("abc")))
        #expect(try library.index.area(kind: .theme, id: "t") == .team, "where a document lives is the operator's choice, not sync state")
        #expect(try library.index.syncIdentity() == labs)
    }

    @Test func aDocumentBacksOffAndRestsAfterTenFailures() {
        var budget = SyncRetryBudget()
        let start = Date(timeIntervalSince1970: 1_000)
        #expect(budget.allowed("theme/t", now: start))
        budget.failed("theme/t", now: start)
        #expect(!budget.allowed("theme/t", now: start.addingTimeInterval(1)))
        #expect(budget.allowed("theme/t", now: start.addingTimeInterval(2)), "2 s after the first failure")
        budget.failed("theme/t", now: start)
        #expect(!budget.allowed("theme/t", now: start.addingTimeInterval(3)) && budget.allowed("theme/t", now: start.addingTimeInterval(4)))
        for _ in 0..<8 { budget.failed("theme/t", now: start) }
        #expect(budget.exhausted("theme/t") && !budget.allowed("theme/t", now: start.addingTimeInterval(86_400)), "ten failures: it rests")
        #expect(budget.restingCount == 1)
        #expect(budget.allowed("theme/other", now: start), "one document's trouble is its own")
        budget.reset("theme/t")
        #expect(budget.allowed("theme/t", now: start))
        budget.failed("a", now: start); budget.succeeded("a")
        #expect(budget.allowed("a", now: start))
        var capped = SyncRetryBudget()
        for _ in 0..<9 { capped.failed("x", now: start) }
        #expect(!capped.allowed("x", now: start.addingTimeInterval(299)) && capped.allowed("x", now: start.addingTimeInterval(300)), "waits cap at five minutes")
    }
}
