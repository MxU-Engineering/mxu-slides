import Foundation
import Testing

@testable import PresenterCore

@Suite struct IndexSnapshotListingTests {
    private func row(_ id: String, _ name: String, folder: String = "", at seconds: Double = 0, used: Double? = nil) -> LibraryIndex.Entry {
        LibraryIndex.Entry(
            id: id, kind: .presentation, subkind: folder, name: name,
            updatedAt: Date(timeIntervalSince1970: seconds), lastUsedAt: used.map(Date.init(timeIntervalSince1970:)))
    }

    private func snapshot(_ rows: [LibraryIndex.Entry], areas: [String: LibraryArea] = [:], generation: Int = 1) -> IndexSnapshot {
        IndexSnapshot(entries: rows, areas: areas, generation: generation)
    }

    @Test func aContentSaveListsTheSame() {
        let before = snapshot([row("a", "Amazing Grace", at: 1), row("b", "Build My Life", at: 1)])
        let after = snapshot([row("a", "Amazing Grace", at: 99), row("b", "Build My Life", at: 1)], generation: 2)
        #expect(after.listsLike(before))
    }

    @Test func whatAListShowsIsAChange() {
        let before = snapshot([row("a", "Amazing Grace"), row("b", "Build My Life")])
        #expect(!snapshot([row("a", "Amazing Grace (Live)"), row("b", "Build My Life")]).listsLike(before), "a rename")
        #expect(!snapshot([row("a", "Amazing Grace", folder: "Hymns"), row("b", "Build My Life")]).listsLike(before), "a move to a folder")
        #expect(!snapshot([row("a", "Amazing Grace", used: 5), row("b", "Build My Life")]).listsLike(before), "a use (Recents)")
        #expect(!snapshot([row("a", "Amazing Grace")]).listsLike(before), "a delete")
        #expect(!snapshot([row("b", "Build My Life"), row("a", "Amazing Grace")]).listsLike(before), "a new order")
        #expect(
            !snapshot([row("a", "Amazing Grace"), row("b", "Build My Life")], areas: ["presentation/a": .team]).listsLike(before),
            "an area move")
        let theme = LibraryIndex.Entry(id: "t", kind: .theme, subkind: "", name: "Theme", updatedAt: .distantPast, lastUsedAt: nil)
        #expect(!snapshot([row("a", "Amazing Grace"), row("b", "Build My Life"), theme]).listsLike(before), "another kind")
    }
}
