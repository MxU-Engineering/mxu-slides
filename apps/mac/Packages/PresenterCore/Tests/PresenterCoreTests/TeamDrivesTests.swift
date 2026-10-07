import Foundation
import Testing
@testable import PresenterCore

@Suite struct TeamDrivesTests {
    @Test func drivesListRowsInOrderThenFoldersWithNoRow() {
        #expect(TeamDriveLogic.driveNames(rows: ["Youth", "Worship"], folders: ["Worship/Lyrics", "kids/Loops", "Archive", "Youth"])
            == ["Youth", "Worship", "Archive", "kids"])
        #expect(TeamDriveLogic.driveNames(rows: [], folders: []) == [])
    }

    private var tree: TeamFolderTree {
        TeamFolderTree([
            TeamFolder(id: "y", name: "Youth", position: 1),
            TeamFolder(id: "w", name: "Worship", position: 0),
            TeamFolder(id: "l", name: "Lyrics", parentId: "w"),
            TeamFolder(id: "26", name: "2026", parentId: "l"),
            TeamFolder(id: "lost", name: "Orphan", parentId: "never-seen"),
            TeamFolder(id: "a", name: "A", parentId: "b"),
            TeamFolder(id: "b", name: "B", parentId: "a"),
        ])
    }

    @Test func theTreeResolvesPathsBothWaysAndLeavesOutOrphansAndLoops() {
        #expect(tree.path(of: "26") == "Worship/Lyrics/2026")
        #expect(tree.id(ofPath: "Worship/Lyrics", library: .presentation) == "l")
        #expect(tree.path(of: "lost") == nil && tree.path(of: "a") == nil)
        #expect(tree.drives.map(\.name) == ["Worship", "Youth"])
    }

    @Test func aRenameOnTheServerRefreshesOnlyStalePaths() {
        #expect(tree.refreshedPath(folderId: "l", folder: "Music/Lyrics") == "Worship/Lyrics")
        #expect(tree.refreshedPath(folderId: "l", folder: "Worship/Lyrics") == nil, "current")
        #expect(tree.refreshedPath(folderId: "gone", folder: "Anything") == nil, "an unknown folder is left alone")
    }

    @Test func aLibraryListsLegacyFoldersNothingOccupies() {
        let listed = Set(tree.listedPaths(occupied: ["Worship/Lyrics"], library: .media))
        #expect(listed == ["Youth", "Worship/Lyrics/2026"], "Lyrics (and Worship above it) holds items; 2026 under it is empty")
    }

    private var libraries: TeamFolderTree {
        TeamFolderTree([
            TeamFolder(id: "w", name: "Worship", position: 0),
            TeamFolder(id: "mw", name: "Worship", position: 1, library: .media),
            TeamFolder(id: "ml", name: "Loops", parentId: "mw", library: .media),
            TeamFolder(id: "pw", name: "Sermons", position: 2, library: .presentation),
            TeamFolder(id: "ns", name: LibraryHome.needsSorted, position: 3),
            TeamFolder(id: "mns", name: LibraryHome.needsSorted, position: 4, library: .media),
        ])
    }

    @Test func eachLibraryFilesInItsOwnFoldersThenALegacyOne() {
        #expect(libraries.id(ofPath: "Worship", library: .media) == "mw")
        #expect(libraries.id(ofPath: "Worship", library: .presentation) == "w", "no presentation Worship yet: the legacy one")
        #expect(libraries.id(ofPath: "Worship/Loops", library: .overlay) == nil, "another library's folder never files this one")
        #expect(libraries.id(ofPath: LibraryHome.needsSorted, library: .media) == "mns")
        #expect(libraries.id(ofPath: LibraryHome.needsSorted, library: .audio) == nil, "Needs Sorted is each library's own")
    }

    @Test func aFolderGoneOrInAnotherLibraryNoLongerFilesADocument() {
        #expect(libraries.isStale(folderId: "mw", for: .presentation))
        #expect(!libraries.isStale(folderId: "mw", for: .media) && !libraries.isStale(folderId: "w", for: .overlay))
        #expect(libraries.isStale(folderId: "removed", for: .media))
        #expect(!TeamFolderTree.empty.isStale(folderId: "removed", for: .media), "a tree not loaded yet says nothing")
    }

    @Test func aLibraryListsItsOwnFoldersAndOnlyTheLegacyOnesItUsesOrNobodyDoes() {
        let media = Set(libraries.listedPaths(occupied: [LibraryHome.needsSorted], library: .media))
        #expect(media == ["Worship", "Worship/Loops", LibraryHome.needsSorted], "its own, and the empty legacy Worship")
        let decks = Set(libraries.listedPaths(occupied: ["Worship"], library: .presentation))
        #expect(decks == ["Sermons", LibraryHome.needsSorted], "the legacy Worship holds items: it lists where those items are")
        #expect(libraries.drives(library: .presentation, listed: ["Sermons", "Worship"]).map(\.id) == ["w", "pw"])
        #expect(libraries.drives(library: .media, listed: ["Worship", LibraryHome.needsSorted]).map(\.id) == ["mw", "mns"],
                "its own Worship and Needs Sorted stand in for the legacy ones of the same name")
    }

    @Test func thisStationFilesJoinTheDriveUnderTheComputersNameOnceTheFoldersSplit() {
        #expect(StationCleanup.folder(for: .media, path: "ProPresenter Import/Calvary", station: "Booth") == "Booth/Calvary")
        #expect(StationCleanup.folder(for: .presentation, path: "", station: "Booth") == "Booth")
        #expect(StationCleanup.folder(for: .overlay, path: "Booth/Lyrics/Hymns", station: "Booth") == "Booth/Hymns")
        #expect(StationCleanup.folder(for: .service, path: "", station: "Booth") == nil, "services have no folders")
        #expect(StationCleanup.folder(for: .media, path: "Recordings/Sundays", station: "Booth") == "Recordings/Sundays", "recordings join the Drive's Recordings")
        #expect(StationCleanup.folder(for: .presentation, path: "Recordings", station: "Booth") == "Booth/Recordings")
        #expect(!StationCleanup.driveReady(tree), "legacy folders: the Drive half has not run")
        #expect(!StationCleanup.driveReady(.empty))
        #expect(StationCleanup.driveReady(TeamFolderTree([TeamFolder(id: "m", name: "Loops", library: .media)])))
        #expect(StationCleanup.doneKey(libraryRoot: URL(fileURLWithPath: "/a/Library/")) == StationCleanup.doneKey(libraryRoot: URL(fileURLWithPath: "/a/Library")),
                "one flag per library folder, whatever team id the identity carries")
    }

    @Test func filingInADriveKeepsAnItemsFolders() {
        #expect(TeamDriveLogic.filed(folder: "", inDrive: "Worship") == "Worship")
        #expect(TeamDriveLogic.filed(folder: "Lyrics/2026", inDrive: "Worship") == "Worship/Lyrics/2026")
        #expect(TeamDriveLogic.filed(folder: "Worship/Lyrics", inDrive: "Worship") == "Worship/Lyrics", "already there")
    }

    @Test func cloudItemsSkipHiddenFoldersAndSortByName() {
        let items = [
            TeamCloudItem(kind: .presentation, id: "b", name: "beta", folder: "Worship/Lyrics"),
            TeamCloudItem(kind: .presentation, id: "a", name: "Alpha", folder: ""),
            TeamCloudItem(kind: .presentation, id: "c", name: "Gamma", folder: "Archive/Old"),
        ]
        #expect(TeamDriveLogic.cloudItems(items, hidden: ["Archive"]).map(\.id) == ["a", "b"])
        #expect(TeamDriveLogic.isUnder("Worship/Lyrics", prefix: "Worship") && !TeamDriveLogic.isUnder("Worship2", prefix: "Worship"))
        #expect(TeamDriveLogic.isUnder("", prefix: ""))
    }

    @Test func cloudSearchMatchesEveryWordOfTheName() {
        let items = [
            TeamCloudItem(kind: .presentation, id: "a", name: "Ancient Gates", folder: ""),
            TeamCloudItem(kind: .presentation, id: "w", name: "What a God", folder: ""),
            TeamCloudItem(kind: .presentation, id: "e", name: "Él Shaddai", folder: ""),
        ]
        #expect(TeamDriveLogic.cloudMatches(items, query: "gates ANC").map(\.id) == ["a"], "any order, any case")
        #expect(TeamDriveLogic.cloudMatches(items, query: "el").map(\.id) == ["e"], "accents ignored")
        #expect(TeamDriveLogic.cloudMatches(items, query: "  ").isEmpty)
    }

    @Test func searchListsNameMatchesBeforeLyricMatches() {
        func hit(_ name: String) -> LibraryIndex.Hit {
            LibraryIndex.Hit(entry: LibraryIndex.Entry(id: name, kind: .presentation, subkind: "", name: name, updatedAt: .distantPast, lastUsedAt: nil),
                             snippet: nil)
        }
        let cloud = [TeamCloudItem(kind: .presentation, id: "c", name: "What a God", folder: "")]
        let rows = TeamDriveLogic.searchRows(hits: [hit("Holy Spirit"), hit("What a God We Have"), hit("Promises")], cloud: cloud, query: "what a god")
        #expect(rows.map(\.id) == ["What a God We Have", "c", "Holy Spirit", "Promises"], "titles first, then the Drive, then lyrics")
    }

    @Test func foldersCountWhatSitsUnderThemAndMovesKeepTheSubtree() {
        let folders = ["Worship", "Worship/Lyrics", "Worship/Lyrics/2026", "Youth/Loops", ""]
        #expect(TeamDriveLogic.childCounts(of: folders, under: []) == ["Worship": 3, "Youth": 1])
        #expect(TeamDriveLogic.childCounts(of: folders, under: ["Worship"]) == ["Lyrics": 2])
        #expect(TeamDriveLogic.childCounts(of: folders, under: ["Worship", "Lyrics", "2026"]).isEmpty)
        #expect(TeamDriveLogic.rebased(folder: "Lyrics/2026", from: ["Lyrics"], into: ["Worship"]) == "Worship/Lyrics/2026")
        #expect(TeamDriveLogic.rebased(folder: "A/Lyrics", from: ["A", "Lyrics"], into: []) == "Lyrics")
        #expect(TeamDriveLogic.rebased(folder: "Lyrics/2026", from: ["Lyrics"], into: []) == "Lyrics/2026", "a move across areas keeps the path")
        #expect(TeamDriveLogic.renamed(folder: "Loops/Slow/2026", from: ["Loops", "Slow"], to: "Calm") == "Loops/Calm/2026")
        #expect(TeamDriveLogic.renamed(folder: "Loops", from: ["Loops"], to: "Motion") == "Motion")
    }

    @Test func aDraggedFolderCarriesItsArea() {
        let payload = TeamDriveLogic.folderPayload(path: ["Worship", "Lyrics"], area: .team)
        #expect(payload.hasPrefix("folder:"), "the scheduler still reads it as a folder, not an item")
        let parsed = TeamDriveLogic.parseFolderPayload(payload, fallback: .station)
        #expect(parsed?.path == ["Worship", "Lyrics"] && parsed?.area == .team)
        let legacy = TeamDriveLogic.parseFolderPayload("folder:Lyrics/2026", fallback: .station)
        #expect(legacy?.path == ["Lyrics", "2026"] && legacy?.area == .station)
        #expect(TeamDriveLogic.parseFolderPayload("some-entry-id", fallback: .station) == nil)
    }
}

@Suite struct TeamFolderIndexTests {
    @LibraryActor @Test func theIndexKeepsTheTreeAndEachDocumentsFolderId() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try Library(rootURL: root)
        let folders = [TeamFolder(id: "w", name: "Worship"), TeamFolder(id: "l", name: "Lyrics", parentId: "w", position: 2, library: .overlay)]
        try library.index.replaceTeamFolders(folders)
        try library.index.replaceTeamFolders(folders)
        #expect(Set(try library.index.teamFolders().map(\.id)) == ["w", "l"])
        #expect(try library.index.teamFolders().first { $0.id == "l" } == folders[1])

        var overlay = Overlay(id: "o1", name: "Lower Third", objects: [])
        overlay.folder = "Music/Lyrics"
        overlay.folderId = "l"
        try library.save(try TypedDocument(overlay))
        try library.save(try TypedDocument(Overlay(id: "o2", name: "Loose", objects: [])))
        #expect(try library.index.folderRefs() == [.init(kind: .overlay, id: "o1", folderId: "l", folder: "Music/Lyrics")])
        try library.rebuildIndex()
        #expect(try library.index.folderRefs().map(\.id) == ["o1"], "a rebuild reads the id back from the document")
        #expect(try library.index.teamFolders().count == 2, "the tree is not derived data")
    }
}
