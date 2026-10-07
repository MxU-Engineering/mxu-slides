import Foundation
import SQLite3
import Testing
@testable import PresenterCore

@LibraryActor private func makeLibrary() throws -> (Library, URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    return (try Library(rootURL: root), root)
}

private func song(_ id: String, _ name: String) -> Presentation {
    Presentation(id: id, name: name, presentationKind: .song, themeId: "", slides: [])
}

@LibraryActor @Test func confidenceStartersFillAFreshWorkspace() throws {
    let (library, root) = try makeLibrary()
    defer { try? FileManager.default.removeItem(at: root) }

    #expect(ConfidenceLayoutTemplate.blank.make(name: "x").objects.isEmpty)
    #expect(ConfidenceLayoutTemplate.blank.starterName == "Untitled Layout")

    for template in ConfidenceLayoutTemplate.workspaceStarters {
        try library.create(template.make(name: template.starterName))
    }
    #expect(try Set(library.index.entries(of: .confidenceLayout).map(\.name))
        == ["Current + Next", "Timers", "Current Over Next", "Current Over Next + Chords"])
}

@LibraryActor @Test func libraryIndexesOnCreateRenameAndDelete() throws {
    let (library, root) = try makeLibrary()
    defer { try? FileManager.default.removeItem(at: root) }

    try library.create(song("s1", "Amazing Grace"))
    try library.create(song("s2", "Great Are You Lord"))
    try library.create(Service(id: "svc1", name: "Sunday AM", serviceDate: "2026-07-05", items: []))

    #expect(try library.index.entries(of: .presentation).map(\.name) == ["Amazing Grace", "Great Are You Lord"])
    #expect(try library.index.entries(of: .service).map(\.id) == ["svc1"])

    #expect(try library.index.search("amaz").map(\.id) == ["s1"])
    #expect(try library.index.search("great are").map(\.id) == ["s2"])
    #expect(try library.index.search("nope").isEmpty)
    #expect(try library.index.search("  ").isEmpty)

    let doc = try library.open(Presentation.self, id: "s1")
    try doc.update { $0.name = "Amazing Grace (My Chains Are Gone)" }
    try library.save(doc)
    #expect(try library.index.search("chains").map(\.id) == ["s1"])

    try library.delete(kind: .presentation, id: "s1")
    #expect(try library.index.search("amaz").isEmpty)
    #expect(try library.store.ids(of: .presentation) == ["s2"])
}

@LibraryActor @Test func mediaAudioAndPlaylistsRoundTripAndIndex() throws {
    let (library, root) = try makeLibrary()
    defer { try? FileManager.default.removeItem(at: root) }

    let media = MediaItem(
        id: "m1", name: "Ocean Loop", mediaKind: .video, classification: .background,
        fileHash: "abc123", fileName: "ocean.mov", fileStatus: .ready, statusDetail: "",
        tags: ["nature", "loop"], favorite: true, collections: ["Walk-in"],
        loops: true, inPoint: 1.5, outPoint: nil, durationSeconds: 30,
        pixelWidth: 3840, pixelHeight: 2160
    )
    try library.create(media)
    let audio = AudioItem(
        id: "a1", name: "Pre-service Mix", fileHash: "def456", fileName: "mix.m4a",
        tags: [], favorite: false, durationSeconds: 241.7
    )
    try library.create(audio)
    try library.create(Playlist(
        id: "p1", name: "Walk-in",
        entries: [PlaylistEntry(id: "e1", refKind: .audio, refId: "a1")],
        playbackMode: .loopPlaylist, shuffle: true, crossfadeSeconds: 3
    ))

    let reloaded = try library.open(MediaItem.self, id: "m1").value
    #expect(reloaded == media)
    #expect(reloaded.inPoint == 1.5)
    #expect(reloaded.outPoint == nil)

    #expect(try library.index.entries(of: .media).map(\.id) == ["m1"])
    #expect(try library.index.entries(of: .audio).map(\.id) == ["a1"])
    #expect(try library.index.search("ocean").map(\.id) == ["m1"])

    let doc = try library.open(MediaItem.self, id: "m1")
    try doc.update { $0.inPoint = nil }
    #expect(doc.value.inPoint == nil)
    #expect(try doc.undo().inPoint == 1.5)
}

@LibraryActor @Test func indexRebuildsFromDocumentsOnDisk() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }

    do {
        let library = try Library(rootURL: root)
        try library.create(song("s1", "Build My Life"))
        try library.create(Theme(
            id: "t1", name: "Sermon", fontFamily: "Georgia",
            fontSize: 72, textColorHex: "#FFFFFF", backgroundColorHex: "#101010"
        ))
    }

    for suffix in ["", "-wal", "-shm"] {
        try? FileManager.default.removeItem(at: root.appendingPathComponent("index.sqlite" + suffix))
    }
    let reopened = try Library(rootURL: root)
    #expect(reopened.index.count == 2)
    #expect(try reopened.index.search("build").map(\.id) == ["s1"])
    #expect(try reopened.index.entries(of: .theme).map(\.name) == ["Sermon"])
}

@LibraryActor @Test func searchRanksRecentlyUsedFirstWithinATier() throws {
    let (library, root) = try makeLibrary()
    defer { try? FileManager.default.removeItem(at: root) }
    try library.create(song("s1", "Glorious Day"))
    try library.create(song("s2", "Glorious Day"))
    try library.create(song("s3", "Glorious Day"))

    try library.index.touchUsage(id: "s2", at: Date(timeIntervalSince1970: 100))
    try library.index.touchUsage(id: "s3", at: Date(timeIntervalSince1970: 200))
    #expect(try library.index.search("glorious day").map(\.id) == ["s3", "s2", "s1"])

    try library.index.touchUsage(id: "s2", at: Date(timeIntervalSince1970: 50))
    #expect(try library.index.search("glorious").map(\.id) == ["s3", "s2", "s1"])
    #expect(try library.index.entry(id: "s2")?.lastUsedAt
        == Date(timeIntervalSince1970: 100))

    let lyrics = Presentation(
        id: "s4", name: "Living Hope", presentationKind: .song, themeId: "",
        slides: [Slide(id: "sl1", name: "Verse 1", objects: [
            SlideObject(id: "o1", objectKind: .text, name: "Lyrics", text: "glorious day arrived")
        ])]
    )
    try library.create(lyrics)
    try library.index.touchUsage(id: "s4", at: Date(timeIntervalSince1970: 300))
    #expect(try library.index.search("glorious day").map(\.id) == ["s3", "s2", "s1", "s4"])
}

@LibraryActor @Test func usageSurvivesIndexRebuildAndDiesWithItsEntity() throws {
    let (library, root) = try makeLibrary()
    defer { try? FileManager.default.removeItem(at: root) }
    try library.create(song("s1", "Way Maker"))
    try library.index.touchUsage(id: "s1", at: Date(timeIntervalSince1970: 100))

    try library.rebuildIndex()
    #expect(try library.index.entry(id: "s1")?.lastUsedAt
        == Date(timeIntervalSince1970: 100))

    try library.delete(kind: .presentation, id: "s1")
    try library.create(song("s1", "Way Maker"))
    #expect(try library.index.entry(id: "s1")?.lastUsedAt == nil)
}

@LibraryActor @Test func seedUsageFromServicesStampsPlannedItemsWithServiceDates() throws {
    let (library, root) = try makeLibrary()
    defer { try? FileManager.default.removeItem(at: root) }
    try library.create(song("s1", "Glorious Day"))
    try library.create(song("s2", "Glorious Day"))
    try library.create(Service(
        id: "svc1", name: "Sunday AM", serviceDate: "2026-07-05",
        items: [ServiceItem(id: "i1", itemKind: .presentation, name: "Glorious Day", refId: "s1")]
    ))
    try library.create(Service(
        id: "svc2", name: "Sunday AM", serviceDate: "2026-07-12",
        items: [
            ServiceItem(id: "i2", itemKind: .presentation, name: "Glorious Day", refId: "s2"),
            ServiceItem(id: "i3", itemKind: .header, name: "Worship", refId: ""),
        ]
    ))

    try library.create(Service(
        id: "svc3", name: "Christmas Eve", serviceDate: "2099-12-24",
        items: [ServiceItem(id: "i4", itemKind: .presentation, name: "Glorious Day", refId: "s1")]
    ))

    try library.seedUsageFromServices()

    #expect(try library.index.search("glorious day").map(\.id) == ["s1", "s2"])
    let s2Used = try #require(try library.index.entry(id: "s2")?.lastUsedAt)
    #expect(Calendar.current.dateComponents([.year, .month, .day], from: s2Used)
        == DateComponents(year: 2026, month: 7, day: 12))

    let fired = Date(timeIntervalSince1970: 1_900_000_000)
    try library.index.touchUsage(id: "s2", at: fired)
    try library.seedUsageFromServices()
    #expect(try library.index.entry(id: "s2")?.lastUsedAt == fired)
}

@LibraryActor @Test func searchTreatsFTSOperatorsAsLiterals() throws {
    let (library, root) = try makeLibrary()
    defer { try? FileManager.default.removeItem(at: root) }
    try library.create(song("s1", "Living Hope (Reprise)"))

    #expect(try library.index.search("hope (repr").map(\.id) == ["s1"])

    #expect(try library.index.search("\"living\" OR").isEmpty)
}

@LibraryActor @Test func rebuildIndexPreservesEveryKindsSubkind() throws {

    let (library, root) = try makeLibrary()
    defer { try? FileManager.default.removeItem(at: root) }

    var presentation = song("p1", "Amazing Grace")
    presentation.folder = "Lyrics"
    try library.create(presentation)
    try library.create(Playlist(
        id: "pl1", name: "Kids videos", playlistKind: .media, entries: [],
        playbackMode: .playAll, crossfadeSeconds: 0
    ))

    try library.rebuildIndex()
    #expect(try library.index.entries(of: .presentation, subkind: "Lyrics").count == 1)
    #expect(try library.index.entries(of: .playlist, subkind: "media").count == 1)
}

@LibraryActor @Test func rebuildIndexRelistsEveryListedKind() throws {

    let (library, root) = try makeLibrary()
    defer { try? FileManager.default.removeItem(at: root) }

    try library.create(song("p1", "Amazing Grace"))
    try library.create(Service(id: "svc1", name: "Sunday", serviceDate: "2026-09-06", items: []))
    try library.create(Theme(
        id: "th1", name: "Theme", fontFamily: "Helvetica", fontSize: 96,
        textColorHex: "#FFFFFFFF", backgroundColorHex: "#000000FF"
    ))
    try library.create(MediaItem(
        id: "m1", name: "Loop", mediaKind: .video, classification: .background,
        fileHash: "abc", fileName: "loop.mov", fileStatus: .ready, statusDetail: "",
        tags: [], favorite: false, collections: [], loops: true, inPoint: nil,
        outPoint: nil, durationSeconds: 10, pixelWidth: 1920, pixelHeight: 1080
    ))
    try library.create(AudioItem(
        id: "a1", name: "Mix", fileHash: "def", fileName: "mix.m4a",
        tags: [], favorite: false, durationSeconds: 60
    ))
    try library.create(Playlist(
        id: "pl1", name: "Walk-in", entries: [], playbackMode: .playAll, crossfadeSeconds: 0
    ))
    try library.create(Overlay(id: "ov1", name: "Bug", objects: []))
    try library.create(OutputPreset(id: "op1", name: "Sunday Outputs", assignments: []))
    try library.create(AlertPreset(id: "al1", name: "Nursery", message: "Nursery 12", behavior: .flash))
    try library.create(StreamRecordPreset(id: "sr1", name: "Stream", destinations: []))
    try library.create(StreamDestination(
        id: "sd1", name: "YouTube", transport: .rtmps, url: "rtmps://a.rtmp.youtube.com/live2"
    ))
    try library.create(ActionCombo(id: "ac1", name: "Open", actions: []))
    try library.create(ScheduleTrigger(id: "st1", name: "Sunday 9", conditions: [], actions: []))
    try library.create(ConfidenceLayout(id: "cl1", name: "Stage", objects: []))
    try library.create(MIDIDevice(id: "md1", name: "Lyrics MIDI"))

    let listed: [DocumentKind] = [
        .presentation, .service, .theme, .media, .audio, .playlist, .overlay,
        .outputPreset, .alertPreset, .streamRecordPreset, .streamDestination,
        .actionCombo, .scheduleTrigger, .confidenceLayout, .midiDevice,
    ]
    for kind in listed {
        #expect(try library.index.entries(of: kind).count == 1, "\(kind) lists before rebuild")
    }

    try library.rebuildIndex()
    for kind in listed {
        #expect(try library.index.entries(of: kind).count == 1, "\(kind) lists after rebuild")
    }
}

@LibraryActor @Test func effectPresetBoardRoundTripsThroughTheStore() throws {
    let (library, root) = try makeLibrary()
    defer { try? FileManager.default.removeItem(at: root) }

    var board = EffectPresetBoard(id: EffectPresetBoard.wellKnownID, presets: [])
    board.presets.append(EffectPreset(
        id: "p1", name: "Dream Look",
        effects: [
            Effect(effectKind: .blur, opacity: 0.5, radius: 30),
            Effect(effectKind: .colorAdjust, enabled: false, saturation: 0.4, hue: 90),
        ]
    ))
    try library.store.save(TypedDocument(board))

    let loaded = try library.store.load(EffectPresetBoard.self, id: EffectPresetBoard.wellKnownID)
    #expect(loaded.value.presets.count == 1)
    #expect(loaded.value.presets.first?.name == "Dream Look")
    #expect(loaded.value.presets.first?.effects.first?.radius == 30)
    #expect(loaded.value.presets.first?.effects.last?.enabled == false)
    #expect(loaded.value.presets.first?.effects.last?.hue == 90)
    #expect(try library.index.entries(of: .effectPresetBoard).isEmpty, "singletons never list")
}


@LibraryActor @Test func libraryIndexesCCLIMatchKeysWithoutOpeningDocuments() throws {
    let (library, root) = try makeLibrary()
    defer { try? FileManager.default.removeItem(at: root) }

    var withCCLI = song("s1", "Way Maker (Live)")
    withCCLI.ccli = CCLIInfo(songNumber: 7_115_744, songTitle: "Way Maker")
    try library.create(withCCLI)
    try library.create(song("s2", "Doxology"))
    try library.create(Service(id: "svc1", name: "Sunday", serviceDate: "2026-09-13", items: []))

    let keys = try library.index.presentationMatchKeys().sorted { $0.id < $1.id }
    #expect(keys.map(\.id) == ["s1", "s2"])
    #expect(keys[0].ccliNumber == 7_115_744)
    #expect(keys[0].ccliTitle == "Way Maker")
    #expect(keys[1].ccliNumber == nil)

    try library.rebuildIndex()
    #expect(try library.index.presentationMatchKeys().first { $0.id == "s1" }?.ccliNumber == 7_115_744)
}

@LibraryActor @Test func indexMigrationsAddOnlyTheColumnsAnOlderIndexLacks() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("index.sqlite")
    var db: OpaquePointer?
    try #require(sqlite3_open(url.path, &db) == SQLITE_OK)
    let older = "CREATE TABLE entities (id TEXT PRIMARY KEY, kind TEXT NOT NULL, name TEXT NOT NULL, updated_at REAL NOT NULL);" +
        "CREATE TABLE team_folders (id TEXT PRIMARY KEY, name TEXT NOT NULL, parent_id TEXT, position INTEGER NOT NULL DEFAULT 0)"
    let created = sqlite3_exec(db, older, nil, nil, nil)
    sqlite3_close(db)
    try #require(created == SQLITE_OK)

    for _ in 0..<2 {
        let index = try LibraryIndex(url: url)
        try index.upsert(id: "s1", kind: .presentation, subkind: "song", name: "Grace", ccli: IndexCCLI(number: 7, title: "Grace"), folderId: "f1")
        try index.replaceTeamFolders([TeamFolder(id: "f1", name: "Worship", library: .presentation)])
        #expect(try index.entry(id: "s1")?.subkind == "song")
        #expect(try index.presentationMatchKeys().first?.ccliNumber == 7)
        #expect(try index.folderRefs().map(\.folderId) == ["f1"])
        #expect(try index.teamFolders().first?.library == .presentation)
    }

    let source = try String(
        contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/PresenterCore/Library/LibraryIndex.swift"), encoding: .utf8)
    #expect(!source.contains("try? exec(\"ALTER"), "SQLite logs every failed ALTER, so a column that exists is never re-added")
}
