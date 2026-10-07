import Foundation
import Testing
@testable import PresenterCore

@Suite struct IndexSnapshotTests {
    @LibraryActor private func makeIndex() throws -> (LibraryIndex, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (try LibraryIndex(url: root.appendingPathComponent("index.sqlite")), root)
    }

    private func entry(_ id: String, _ kind: DocumentKind = .media, folder: String = "", name: String? = nil) -> LibraryIndex.Entry {
        LibraryIndex.Entry(id: id, kind: kind, subkind: folder, name: name ?? id, updatedAt: Date(timeIntervalSince1970: 0), lastUsedAt: nil)
    }

    @LibraryActor @Test func theSnapshotListsWhatTheQueriesList() throws {
        let (index, root) = try makeIndex()
        defer { try? FileManager.default.removeItem(at: root) }

        try index.upsert(id: "m2", kind: .media, subkind: "Loops", name: "Wave")
        try index.upsert(id: "p1", kind: .presentation, subkind: "song", name: "Wave")
        try index.upsert(id: "m1", kind: .media, name: "Aurora")
        try index.upsert(id: "m3", kind: .media, name: "Wave")
        try index.upsert(id: "pl1", kind: .playlist, subkind: "media", name: "Walk-in")
        try index.upsert(id: "pl2", kind: .playlist, subkind: "audio", name: "Offering")
        try index.touchUsage(id: "m3", at: Date(timeIntervalSince1970: 100))

        let snapshot = try IndexSnapshot.read(index)
        for kind in [DocumentKind.media, .presentation, .playlist, .theme] {
            #expect(snapshot.entries(of: kind) == (try index.entries(of: kind)), "\(kind)")
        }
        #expect(snapshot.entries(of: .media).map(\.id) == ["m1", "m2", "m3"])
        #expect(snapshot.entries(of: .playlist, subkind: "media") == (try index.entries(of: .playlist, subkind: "media")))
        #expect(snapshot.entry(id: "m3") == (try index.entry(id: "m3")))
        #expect(snapshot.entry(id: "m3")?.lastUsedAt == Date(timeIntervalSince1970: 100))
        #expect(snapshot.entry(id: "gone") == nil)
        #expect(snapshot.count == 6)
        #expect(snapshot.generation == index.writeGeneration)
    }

    @LibraryActor @Test func onlyWritesTheSnapshotHoldsMoveTheGeneration() throws {
        let (index, root) = try makeIndex()
        defer { try? FileManager.default.removeItem(at: root) }
        var seen = index.writeGeneration
        func moved() -> Bool {
            defer { seen = index.writeGeneration }
            return index.writeGeneration != seen
        }
        try index.upsert(id: "m1", kind: .media, name: "A")
        #expect(moved(), "upsert")
        try index.touchUsage(id: "m1")
        #expect(moved(), "touchUsage")
        try index.setArea(.team, kind: .media, id: "m1")
        #expect(moved(), "setArea")
        try index.remove(id: "m1")
        #expect(moved(), "remove")
        try index.removeAll()
        #expect(moved(), "removeAll")
        try index.setSyncEntry(SyncLedger.Entry(), kind: .media, id: "m1")
        try index.replaceTeamFolders([TeamFolder(id: "w", name: "Worship")])
        try index.markBlobUploaded("abc")
        _ = try index.entries(of: .media)
        #expect(!moved(), "the ledger, team folders, blobs and reads are not snapshot state")
    }

    @Test func theBrowserSplitsTeamKindsByAreaAndListsTheRestWhole() {
        let snapshot = IndexSnapshot(
            entries: [entry("t"), entry("s"), entry("l"), entry("none"), entry("o1", .outputPreset), entry("o2", .outputPreset)],
            areas: ["media/t": .team, "media/s": .station, "media/l": .local, "outputPreset/o1": .team],
            generation: 3)
        #expect(snapshot.browserEntries(of: .media, showing: .team).map(\.id) == ["t"])
        #expect(snapshot.browserEntries(of: .media, showing: .station).map(\.id) == ["s", "l", "none"], "Local Only and no row sit with This Station")
        #expect(snapshot.browserEntries(of: .media, showing: .local).map(\.id) == ["s", "l", "none"])
        #expect(snapshot.browserEntries(of: .outputPreset, showing: .team).map(\.id) == ["o1", "o2"], "station kinds never filter")
        #expect(snapshot.browserEntries(of: .theme, showing: .team).isEmpty)
    }

    @Test func foldersJoinItemsCloudAndEmptiesSorted() {
        let items = [entry("a", folder: "Lyrics/Hymns"), entry("b", folder: ""), entry("c", folder: "Lyrics/Hymns"), entry("d", folder: "Announce")]
        #expect(LibraryBrowseLogic.folders(items: items, cloudFolders: ["Worship", ""], empties: ["Zed", "Announce"])
            == ["Announce", "Lyrics/Hymns", "Worship", "Zed"])
        #expect(LibraryBrowseLogic.folders(items: [], cloudFolders: [], empties: []) == [])
    }

    @Test func childFoldersCountHeldItemsAnywhereBeneathAndShowEmpties() {
        let rows = LibraryBrowseLogic.childFolders(
            folders: ["Lyrics", "Lyrics/Hymns", "Lyrics/Modern", "archive", "Empty"],
            held: ["Lyrics/Hymns", "Lyrics/Hymns/Old", "Lyrics", "archive", ""],
            under: [])
        #expect(rows.map { "\($0.name)=\($0.count)" } == ["archive=1", "Empty=0", "Lyrics=3"], "case-insensitive order; loose items count nowhere")
        let inside = LibraryBrowseLogic.childFolders(
            folders: ["Lyrics", "Lyrics/Hymns", "Lyrics/Modern"], held: ["Lyrics/Hymns/Old", "Lyrics"], under: ["Lyrics"])
        #expect(inside.map { "\($0.name)=\($0.count)" } == ["Hymns=1", "Modern=0"])
    }

    @Test func drivesKeepTheTeamOrderThenPathOnlyDrives() {
        let rows = LibraryBrowseLogic.drives(
            rows: ["Youth", "Worship"], children: [(name: "Worship", count: 4), (name: "kids", count: 2), (name: "Archive", count: 1)])
        #expect(rows.map { "\($0.name)=\($0.count)" } == ["Youth=0", "Worship=4", "Archive=1", "kids=2"])
    }

    @Test func occupiedFoldersAreTheTeamItemsAndCloudItemsOfTheKindsAsked() {
        let snapshot = IndexSnapshot(
            entries: [
                entry("m", folder: "Worship/Loops"), entry("mStation", folder: "Mine"),
                entry("p", .presentation, folder: "Worship/Lyrics"), entry("pLoose", .presentation),
                entry("o", .outputPreset, folder: "Presets"),
            ],
            areas: ["media/m": .team, "presentation/p": .team, "presentation/pLoose": .team, "outputPreset/o": .team],
            generation: 1)
        #expect(LibraryBrowseLogic.occupiedTeamFolders(in: snapshot, kinds: [.media, .presentation, .outputPreset], cloudFolders: ["Youth", ""])
            == ["Worship/Loops", "Worship/Lyrics", "Youth"], "This Station's folders, station kinds and no-folder stay out")
        #expect(LibraryBrowseLogic.occupiedTeamFolders(in: snapshot, kinds: [.media], cloudFolders: []) == ["Worship/Loops"])
    }
}
