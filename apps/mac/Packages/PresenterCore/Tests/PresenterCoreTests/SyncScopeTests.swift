import Foundation
import Testing
@testable import PresenterCore

@Suite struct SyncScopeTests {
    @Test func everyKindHasExactlyOneScopeAndTheStationBoardsNeverReachTheTeam() {
        for kind in DocumentKind.allCases {
            let scope = SyncScope.scope(for: kind)
            #expect(SyncScope.kinds(in: scope).contains(kind))
        }
        let all = SyncScope.allCases.flatMap { SyncScope.kinds(in: $0) }
        #expect(Set(all) == Set(DocumentKind.allCases))
        #expect(all.count == DocumentKind.allCases.count)

        #expect(SyncScope.scope(for: .presentation) == .team)
        #expect(SyncScope.scope(for: .alertPreset) == .team)
        #expect(SyncScope.scope(for: .controlBoard) == .station)
        #expect(SyncScope.scope(for: .outputPreset) == .station)
        #expect(SyncScope.scope(for: .stationSettings) == .station)
        #expect(SyncScope.scope(for: .importLedger) == .local)
    }

    @Test func stationSettingsIsAStationSingletonUnderTheSettingsBackupSection() {
        #expect(StationSettings.documentKind == .stationSettings)
        #expect(StationSettings.wellKnownID == "station-settings")
        #expect(BackupSection.section(for: .stationSettings) == .settings)
        #expect(DocumentKind.stationSettings.directoryName == "station-settings")
    }

    @Test func everyKindHasAnEntityTypeAndTheOfflineSetCoversFoldersAndItems() {
        for kind in DocumentKind.allCases {
            #expect(SyncScope.entityType(for: kind).documentKind == kind)
        }
        let entries = [OfflineSetLogic.Entry(kind: "folder", ref: "Lyrics"), OfflineSetLogic.Entry(kind: "item", ref: "d9"), OfflineSetLogic.Entry(kind: "scheduled_services", ref: "")]
        #expect(OfflineSetLogic.covers(entries, docId: "d1", folder: "Lyrics"))
        #expect(OfflineSetLogic.covers(entries, docId: "d1", folder: "Lyrics/2026"))
        #expect(!OfflineSetLogic.covers(entries, docId: "d1", folder: "Lyrics2"))
        #expect(OfflineSetLogic.covers(entries, docId: "d9", folder: nil))
        #expect(!OfflineSetLogic.covers(entries, docId: "d2", folder: nil))
        #expect(OfflineSetLogic.firstSyncFolder(station: "Booth Mac", folder: "Lyrics/2026") == "Booth Mac/Lyrics/2026")
        #expect(OfflineSetLogic.firstSyncFolder(station: "Booth Mac", folder: nil) == "Booth Mac")
        #expect(OfflineSetLogic.firstSyncFolder(station: "Booth Mac", folder: "Booth Mac/Lyrics") == "Booth Mac/Lyrics", "idempotent")
    }

    @Test func reconcileDecidesPushRemoveOrKeepFromThePushedHeads() {
        let pushed = SyncLedger.Entry(lastPushedHeads: ["a"], appliedSeq: 1, remoteSeq: 1)
        #expect(SyncReconcileLogic.decision(entry: nil, inCloud: false, localHeads: ["a"]) == .push)
        #expect(SyncReconcileLogic.decision(entry: nil, inCloud: true, localHeads: ["a"]) == .keep)
        #expect(SyncReconcileLogic.decision(entry: SyncLedger.Entry(pending: true), inCloud: false, localHeads: ["a"]) == .push, "a refused push is not a tombstone")
        #expect(SyncReconcileLogic.decision(entry: pushed, inCloud: false, localHeads: ["a"]) == .removeLocal)
        #expect(SyncReconcileLogic.decision(entry: pushed, inCloud: false, localHeads: ["b"]) == .push, "edit wins")
        #expect(SyncReconcileLogic.decision(entry: pushed, inCloud: true, localHeads: ["b"]) == .keep)
        #expect(SyncReconcileLogic.decision(entry: SyncLedger.Entry(lastPushedHeads: ["a"], pending: true), inCloud: true, localHeads: ["b"]) == .push)
    }

    @Test func aTombstoneRemovesAnUnchangedCopyAndAnEditHereWins() {
        let pushed = SyncLedger.Entry(lastPushedHeads: ["a"], appliedSeq: 2, remoteSeq: 2)
        #expect(SyncReconcileLogic.afterTombstone(entry: pushed, localHeads: ["a"]) == .removeLocal)
        #expect(SyncReconcileLogic.afterTombstone(entry: pushed, localHeads: ["a", "b"]) == .push, "edit wins")
        #expect(SyncReconcileLogic.afterTombstone(entry: pushed, localHeads: nil) == .removeLocal, "the file is already gone")
        var opened = false
        #expect(SyncReconcileLogic.afterTombstone(entry: nil, localHeads: { opened = true; return ["a"] }()) == .keep)
        #expect(!opened, "no ledger row: the document is never opened")
    }

    private func reconcileDeletedBefore(entry: SyncLedger.Entry?, localHeads: () -> [String]?) -> (SyncReconcileLogic.Decision, opened: Bool) {
        var opened = false
        guard let entry else { return (.keep, opened) }
        let heads: [String]? = { opened = true; return localHeads() }()
        if heads != nil, heads != entry.lastPushedHeads {
            return (.push, opened)
        } else {
            return (.removeLocal, opened)
        }
    }

    @Test func afterTombstoneIsThePreExtractionRule() {
        let entries: [SyncLedger.Entry?] = [nil, .init(), .init(lastPushedHeads: ["a"]), .init(lastPushedHeads: ["a", "b"], pending: true)]
        let heads: [[String]?] = [nil, [], ["a"], ["a", "b"], ["c"]]
        for entry in entries {
            for local in heads {
                let then = reconcileDeletedBefore(entry: entry, localHeads: { local })
                var opened = false
                let now = SyncReconcileLogic.afterTombstone(entry: entry, localHeads: { opened = true; return local }())
                #expect(now == then.0 && opened == then.opened, "\(String(describing: entry)) with \(String(describing: local))")
            }
        }
    }

    @Test func onlineOnlyDropsWhatAWiderKeepCoversAndTheDeeperEntryWins() {
        typealias E = OfflineSetLogic.Entry
        let all = [E(kind: "all_drives", ref: "")]
        let marked = OfflineSetLogic.droppingFolder(all, folder: "Worship/Old", library: "presentation")
        #expect(marked == all + [E(kind: "online_only", ref: "Worship/Old", library: "presentation")], "all_drives still covers it, so it is marked")
        #expect(!OfflineSetLogic.covers(marked, docId: "d", folder: "Worship/Old/2019", library: "presentation"))
        #expect(OfflineSetLogic.covers(marked, docId: "d", folder: "Worship/Lyrics", library: "presentation"))
        #expect(OfflineSetLogic.covers(marked + [E(kind: "item", ref: "d")], docId: "d", folder: "Worship/Old", library: "presentation"), "a pulled item beats its folder's mark")
        #expect(OfflineSetLogic.covers(marked + [E(kind: "folder", ref: "Worship/Old/Keep", library: "presentation")], docId: "x", folder: "Worship/Old/Keep", library: "presentation"), "a folder kept inside an online-only one")

        let chosen = [E(kind: "folder", ref: "Worship", library: "presentation"), E(kind: "folder", ref: "Worship/Old/Keep", library: "presentation"), E(kind: "scheduled_services", ref: "")]
        #expect(OfflineSetLogic.droppingFolder(chosen, folder: "Worship", library: "presentation") == [E(kind: "scheduled_services", ref: "")], "nothing wider covers it: no mark needed")
        #expect(OfflineSetLogic.keeping(marked, folder: "Worship", library: "presentation") == all, "keeping a drive clears the marks under it, and all_drives already covers it")
        #expect(OfflineSetLogic.keeping([], folder: "Youth", library: "media") == [E(kind: "folder", ref: "Youth", library: "media")])
    }

    @Test func aFolderEntryNamesItsLibraryAndAnOlderOneSplitsBeforeAChange() {
        typealias E = OfflineSetLogic.Entry
        let dropped = OfflineSetLogic.droppingFolder([E(kind: "all_drives", ref: "")], folder: "Needs Sorted", library: "media")
        #expect(!OfflineSetLogic.covers(dropped, docId: "m", folder: "Needs Sorted", library: "media"))
        #expect(OfflineSetLogic.covers(dropped, docId: "p", folder: "Needs Sorted", library: "presentation"), "the slides library's Needs Sorted stays")

        let older = [E(kind: "folder", ref: "Worship")]
        #expect(OfflineSetLogic.covers(older, docId: "p", folder: "Worship/Lyrics", library: "presentation"), "an entry with no library names every library")
        let split = OfflineSetLogic.droppingFolder(older, folder: "Worship", library: "media")
        #expect(!OfflineSetLogic.covers(split, docId: "m", folder: "Worship", library: "media"))
        #expect(OfflineSetLogic.covers(split, docId: "p", folder: "Worship", library: "presentation"))
        #expect(OfflineSetLogic.covers(split, docId: "o", folder: "Worship", library: "overlay"))
        #expect(!split.contains { $0.library == nil })
    }

    @Test func anOnlineOnlyItemBeatsEveryKeepUntilItIsDownloadedAgain() {
        typealias E = OfflineSetLogic.Entry
        let base = [E(kind: "scheduled_services", ref: ""), E(kind: "all_drives", ref: ""), E(kind: "item", ref: "m1")]
        let dropped = OfflineSetLogic.droppingItems(base, ids: [("m1", "Needs Sorted", "media"), ("m2", nil, "media")], upcoming: ["m2"])
        #expect(dropped == [E(kind: "scheduled_services", ref: ""), E(kind: "all_drives", ref: ""), E(kind: "online_only_item", ref: "m1"), E(kind: "online_only_item", ref: "m2")])
        #expect(!OfflineSetLogic.covers(dropped, docId: "m2", folder: nil, library: "media", upcoming: ["m2"]), "an upcoming service's use doesn't bring it back")
        #expect(OfflineSetLogic.droppedItems(dropped) == ["m1", "m2"])

        let kept = OfflineSetLogic.keepingItems(dropped, ids: [("m1", "Needs Sorted", "media")])
        #expect(OfflineSetLogic.covers(kept, docId: "m1", folder: "Needs Sorted", library: "media"))
        #expect(!kept.contains(E(kind: "item", ref: "m1")), "the Drive already keeps it: no item entry")
        #expect(OfflineSetLogic.keepingItems([], ids: [("d", nil, "presentation")]) == [E(kind: "item", ref: "d")])
        #expect(OfflineSetLogic.droppingItems([E(kind: "item", ref: "d")], ids: [("d", nil, "presentation")]) == [E(kind: "online_only_item", ref: "d")],
                "marked even when no rule keeps it: a document here pointing at it would pull it back")
    }

    @Test func aNarrowerSetStopsOnlyWhatHadNotFinishedComingDown() {
        typealias E = OfflineSetLogic.Entry
        let entries = [E(kind: "scheduled_services", ref: ""), E(kind: "folder", ref: "Loops", library: "media")]
        let items: [(id: String, folder: String?, library: String, fileHere: Bool)] = [
            ("waiting", "Needs Sorted", "media", false),
            ("finished", "Needs Sorted", "media", true),
            ("kept", "Loops", "media", false),
            ("upcoming", "Needs Sorted", "media", false),
            ("onASlide", "Needs Sorted", "media", false),
            ("song", nil, "audio", false),
        ]
        #expect(OfflineSetLogic.unfinished(items, entries: entries, upcoming: ["upcoming"], referenced: ["onASlide"]) == ["waiting", "song"])
    }

    @Test func scheduledServicesKeepWhatServicesDatedTodayOrLaterUse() {
        typealias E = OfflineSetLogic.Entry
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let today = calendar.date(from: DateComponents(year: 2026, month: 10, day: 6, hour: 15))!
        #expect(OfflineSetLogic.upcomingServices([("past", "2026-10-05"), ("today", "2026-10-06"), ("later", "2026-10-11"), ("undated", nil), ("odd", "")], today: today, calendar: calendar) == ["today", "later"])
        let rule = [E(kind: "scheduled_services", ref: "")]
        #expect(OfflineSetLogic.covers(rule, docId: "deck", folder: "Needs Sorted", library: "presentation", upcoming: ["deck"]))
        #expect(!OfflineSetLogic.covers(rule, docId: "other", folder: "Needs Sorted", library: "presentation", upcoming: ["deck"]))
        #expect(!OfflineSetLogic.covers([], docId: "deck", folder: nil, upcoming: ["deck"]), "without the rule, upcoming use keeps nothing")
        #expect(OfflineSetLogic.covers(rule + [E(kind: "online_only", ref: "Needs Sorted", library: "presentation")], docId: "deck", folder: "Needs Sorted", library: "presentation", upcoming: ["deck"]), "a folder not kept here still sends what a service uses (§1b)")
    }

    @LibraryActor @Test func theAreaPicksTheNamespaceAndLivesInTheSidecar() throws {
        #expect(LibraryArea.namespace(kind: .media, area: .team) == .team)
        #expect(LibraryArea.namespace(kind: .media, area: .station) == .station, "This Station backs up under the station, never the team's drives")
        #expect(LibraryArea.namespace(kind: .media, area: .local) == nil)
        #expect(LibraryArea.namespace(kind: .outputPreset, area: .team) == .station, "a station kind is always the station's")
        #expect(LibraryArea.namespace(kind: .importLedger, area: .team) == nil)
        #expect(LibraryArea.default == .station)
        #expect(LibraryArea.resolve(row: .local, entry: .init(remoteSeq: 4)) == .local, "a row always wins")
        #expect(LibraryArea.resolve(row: nil, entry: .init(remoteSeq: 4)) == .team, "already in the team library before areas existed")
        #expect(LibraryArea.resolve(row: nil, entry: .init(pending: true)) == .station, "a refused push proves nothing")
        #expect(LibraryArea.resolve(row: nil, entry: nil) == .station, "no row: content that predates homes; the open tab never decides")
        #expect(OfflineSetLogic.covers([.init(kind: "all_drives", ref: "")], docId: "x", folder: nil))
        #expect(OfflineSetLogic.drive(ofFolder: "Media/Loops") == "Media" && OfflineSetLogic.drive(ofFolder: nil) == nil)

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try Library(rootURL: root)
        #expect(try library.index.area(kind: .media, id: "m1") == nil)
        try library.index.setArea(.team, kind: .media, id: "m1")
        try library.index.setArea(.local, kind: .media, id: "m1")
        try library.index.setArea(.team, kind: .theme, id: "t1")
        try library.rebuildIndex()
        #expect(try library.index.area(kind: .media, id: "m1") == .local)
        #expect(try library.index.allAreas() == ["media/m1": .local, "theme/t1": .team])
    }

    @Test func anOfflineDocumentBringsTheMediaItPointsAt() {
        let held: Set<String> = ["media|here"]
        let cloud: Set<String> = ["media|image", "audio|song"]
        let result = OfflineSetLogic.referencedMedia(
            ["here", "image", "song", "not-pushed-yet", "screen::1"],
            held: { held.contains("\($0.rawValue)|\($1)") },
            inCloud: { cloud.contains("\($0.rawValue)|\($1)") })
        #expect(result.pull.map { "\($0.kind.rawValue)|\($0.id)" } == ["media|image", "audio|song"])
        #expect(result.wanted == ["not-pushed-yet", "screen::1"], "stays wanted until the cloud lists it; engine ids never match")
        let deck = Presentation(id: "d", name: "Deck", presentationKind: .deck, themeId: "", slides: [], background: CueMedia(mediaId: "bg", layer: .stillGraphics))
        #expect(MediaReferences.ids(inDocument: deck) == ["bg"])
    }
}
