import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import PresenterCore

@Suite(.serialized)
struct MediaMissingTests {
    private func makeRoot() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeMediaItem(id: String = "m1", hash: String = "abc123", inPoint: Double? = nil) -> MediaItem {
        MediaItem(
            id: id, name: "Clip", mediaKind: .video, classification: .background,
            fileHash: hash, fileName: "clip.mp4", fileStatus: .ready, statusDetail: "",
            tags: [], favorite: false, collections: [], loops: false, inPoint: inPoint
        )
    }

    @Test func removingABlobFreesItAndReadsAsMissing() throws {
        let root = try makeRoot()
        let blobs = try BlobStore(libraryRoot: root)
        let source = root.appendingPathComponent("loop.txt")
        try Data("loop".utf8).write(to: source)
        let hash = try blobs.store(fileURL: source)
        #expect(try blobs.remove(hash: hash))
        #expect(blobs.url(forHash: hash) == nil)
        #expect(try !blobs.remove(hash: hash), "nothing left to remove")
    }

    @Test func blobLookupSurvivesCachingAndDetectsDeletion() throws {
        let root = try makeRoot()
        let blobs = try BlobStore(libraryRoot: root)
        let source = root.appendingPathComponent("in.txt")
        try Data("hello".utf8).write(to: source)
        let hash = try blobs.store(fileURL: source)

        let resolved = blobs.url(forHash: hash)
        #expect(resolved != nil)

        #expect(blobs.url(forHash: hash) == resolved)

        try FileManager.default.removeItem(at: resolved!)
        #expect(blobs.url(forHash: hash) == nil)

        let other = try BlobStore(libraryRoot: root)
        let source2 = root.appendingPathComponent("in2.txt")
        try Data("world".utf8).write(to: source2)
        let hash2 = try other.store(fileURL: source2)
        #expect(blobs.url(forHash: hash2) != nil)
    }

    @Test func aMissIsRememberedUntilTheDirectoryChanges() throws {
        let root = try makeRoot()
        let blobs = try BlobStore(libraryRoot: root)
        let source = root.appendingPathComponent("held.txt")
        try Data("held".utf8).write(to: source)
        let held = try blobs.store(fileURL: source)

        #expect(blobs.url(forHash: "not-on-this-mac") == nil)
        let listed = blobs.directoryListings
        for _ in 0 ..< 50 { #expect(blobs.url(forHash: "not-on-this-mac") == nil) }
        #expect(blobs.url(forHash: held) != nil)
        #expect(blobs.directoryListings == listed, "absent and held answers come from the one listing")
    }

    @Test func aFileLandingBehindTheStoreMovesTheStampAndIsFound() throws {
        let root = try makeRoot()
        let blobs = try BlobStore(libraryRoot: root)
        let hash = String(repeating: "ab", count: 32)
        #expect(blobs.url(forHash: hash) == nil)
        let listed = blobs.directoryListings

        try Data("behind".utf8).write(to: blobs.directory.appendingPathComponent("\(hash).mov"))
        #expect(blobs.url(forHash: hash) != nil)
        #expect(blobs.directoryListings == listed + 1)
    }

    @Test func storeAdoptAndRemoveAreSeenAtOnce() throws {
        let root = try makeRoot()
        let blobs = try BlobStore(libraryRoot: root)
        let source = root.appendingPathComponent("a.txt")
        try Data("alpha".utf8).write(to: source)
        let expected = try BlobStore.sha256(of: source)
        #expect(blobs.url(forHash: expected) == nil, "remembered absent first")

        let stored = try blobs.store(fileURL: source)
        #expect(blobs.url(forHash: stored) != nil)

        let moved = root.appendingPathComponent("b.txt")
        try Data("beta".utf8).write(to: moved)
        let movedHash = try BlobStore.sha256(of: moved)
        #expect(blobs.url(forHash: movedHash) == nil)
        #expect(try blobs.adopt(fileURL: moved) == movedHash)
        #expect(blobs.url(forHash: movedHash) != nil)

        #expect(try blobs.remove(hash: stored))
        #expect(blobs.url(forHash: stored) == nil)
        #expect(blobs.url(forHash: movedHash) != nil)
    }

    @Test func noteDirectoryChangedListsAgain() throws {
        let root = try makeRoot()
        let blobs = try BlobStore(libraryRoot: root)
        #expect(blobs.url(forHash: "x") == nil)
        let listed = blobs.directoryListings
        #expect(blobs.url(forHash: "x") == nil)
        #expect(blobs.directoryListings == listed)
        blobs.noteDirectoryChanged()
        #expect(blobs.url(forHash: "x") == nil)
        #expect(blobs.directoryListings == listed + 1)
    }

    @Test func presenceAnswersAWholePassFromOneListing() throws {
        let root = try makeRoot()
        let blobs = try BlobStore(libraryRoot: root)
        var held: [String] = []
        for index in 0 ..< 3 {
            let source = root.appendingPathComponent("f\(index).txt")
            try Data("file \(index)".utf8).write(to: source)
            held.append(try blobs.store(fileURL: source))
        }
        let asked = held + (0 ..< 40).map { "missing-\($0)" }
        #expect(blobs.presence(forHashes: asked) == Set(held))
        let listed = blobs.directoryListings
        #expect(blobs.presence(forHashes: asked) == Set(held))
        #expect(blobs.directoryListings == listed, "an unchanged directory is not listed again")
    }

    @Test func presenceIsThePerFileAnswer() throws {
        let root = try makeRoot()
        let perFile = try BlobStore(libraryRoot: root)
        let whole = try BlobStore(libraryRoot: root)
        var held: [String] = []
        for index in 0 ..< 4 {
            let source = root.appendingPathComponent("p\(index).txt")
            try Data("presence \(index)".utf8).write(to: source)
            held.append(try perFile.store(fileURL: source))
        }
        let asked = held + ["absent-1", "absent-2"]
        func expectAgree(_ hashes: [String], _ what: String, sourceLocation: SourceLocation = #_sourceLocation) {
            let answer = Set(hashes.filter { perFile.url(forHash: $0) != nil })
            #expect(whole.presence(forHashes: hashes) == answer, "\(what)", sourceLocation: sourceLocation)
        }
        expectAgree(asked, "held and absent")
        #expect(whole.presence(forHashes: asked) == Set(held))

        let path = perFile.directory.path
        var info = stat()
        #expect(stat(path, &info) == 0)
        let gone = try #require(perFile.url(forHash: held[0]))
        try FileManager.default.removeItem(at: gone)
        var times = [info.st_atimespec, info.st_mtimespec]
        #expect(utimensat(AT_FDCWD, path, &times, 0) == 0)
        expectAgree(asked, "removed inside the stamp's resolution")
        #expect(whole.presence(forHashes: asked) == Set(held.dropFirst()))

        let landed = String(repeating: "cd", count: 32)
        try Data("behind".utf8).write(to: perFile.directory.appendingPathComponent("\(landed).mov"))
        expectAgree(asked + [landed], "landed behind the store")
        #expect(whole.presence(forHashes: [landed]) == [landed])
    }

    @Test func referenceScanFindsEveryHome() {
        let object = SlideObject(id: "o1", objectKind: .media, name: "", text: "", mediaId: "direct")
        let filled = SlideObject(
            id: "o2", objectKind: .shape, name: "", text: "",
            fill: ObjectFill(fillKind: .media, mediaId: "fill")
        )
        let action = SlideAction(id: "a1", kind: .fireMedia, mediaId: "fired")
        let slide = Slide(
            id: "s1", name: "", objects: [object, filled],
            background: CueMedia(mediaId: "cue"),
            backgroundFill: ObjectFill(fillKind: .media, mediaId: "slideFill"),
            actions: [action]
        )
        let presentation = Presentation(
            id: "p1", name: "", presentationKind: .deck, themeId: "", slides: [slide],
            background: CueMedia(mediaId: "presCue"),
            backgroundFill: ObjectFill(fillKind: .media, mediaId: "presFill"),
            sections: [PresentationSection(id: "sec", name: "", background: CueMedia(mediaId: "sectionCue"))]
        )
        #expect(MediaReferences.ids(in: presentation) == [
            "direct", "fill", "fired", "cue", "slideFill", "presCue", "presFill", "sectionCue",
        ])

        let playlist = Playlist(
            id: "pl", name: "",
            entries: [
                PlaylistEntry(id: "e1", refKind: .media, refId: "walk"),
                PlaylistEntry(id: "e2", refKind: .audio, refId: "song"),
            ],
            playbackMode: .playAll, crossfadeSeconds: 0
        )
        #expect(MediaReferences.ids(in: playlist) == ["walk"])

        let service = Service(
            id: "sv", name: "", serviceDate: "", items: [
                ServiceItem(id: "i1", itemKind: .media, name: "", refId: "bumper"),
                ServiceItem(id: "i2", itemKind: .presentation, name: "", refId: "p1"),
            ]
        )
        #expect(MediaReferences.ids(in: service) == ["bumper"])

        let combo = ActionCombo(id: "c1", name: "", actions: [action])
        #expect(MediaReferences.ids(in: combo) == ["fired"])
    }

    @Test func v87MediaCueFieldsAreOptionalAndRoundTrip() throws {
        let legacy = Data("""
        {"id":"m1","name":"Clip","mediaKind":"video","classification":"background",\
        "fileHash":"h","fileName":"c.mp4","fileStatus":"ready","statusDetail":"",\
        "tags":[],"favorite":false,"collections":[],"loops":false}
        """.utf8)
        let decoded = try JSONDecoder().decode(MediaItem.self, from: legacy)
        #expect(decoded.actions == nil)
        #expect(decoded.autoAdvance == nil)
        #expect(MediaRelink.carriedSettings(of: decoded).isEmpty)

        var item = decoded
        item.actions = [SlideAction(id: "a", kind: .fireCombo, comboId: "c1")]
        item.autoAdvance = AutoAdvance(delaySeconds: 5, afterPlayback: true)
        let round = try JSONDecoder().decode(MediaItem.self, from: JSONEncoder().encode(item))
        #expect(round == item)
        #expect(MediaRelink.carriedSettings(of: item) == ["Actions", "Auto Advance"])
    }

    @Test func posterSiblingOverwriteKeepsOneFilePerItem() throws {
        let root = try makeRoot()
        let store = try MediaPosterStore(libraryRoot: root)
        let fp1 = MediaPosterStore.fingerprint(fileHash: "aaa", inPoint: nil)
        let fp2 = MediaPosterStore.fingerprint(fileHash: "aaa", inPoint: 3)
        #expect(fp1 != fp2)

        try store.writePoster(Data([1]), id: "m1", fingerprint: fp1)
        try store.writePoster(Data([2]), id: "m1", fingerprint: fp2)
        try store.writePoster(Data([3]), id: "m2", fingerprint: fp1)

        let files = try FileManager.default.contentsOfDirectory(at: store.directory, includingPropertiesForKeys: nil)
        #expect(files.count == 2)
        #expect(
            store.anyPosterURL(id: "m1")?.lastPathComponent
                == store.posterURL(id: "m1", fingerprint: fp2).lastPathComponent
        )
        #expect(store.anyPosterURL(id: "m1").flatMap { try? Data(contentsOf: $0) } == Data([2]))
    }

    @Test func aMissingPosterIsRememberedUntilOneIsWritten() throws {
        let root = try makeRoot()
        let store = try MediaPosterStore(libraryRoot: root)
        let fingerprint = MediaPosterStore.fingerprint(fileHash: "aaa", inPoint: nil)
        #expect(store.anyPosterURL(id: "m1") == nil)

        try Data([9]).write(to: store.posterURL(id: "m1", fingerprint: fingerprint))
        #expect(store.anyPosterURL(id: "m1") == nil)

        let copy = store
        try copy.writePoster(Data([1]), id: "m1", fingerprint: fingerprint)
        #expect(store.anyPosterURL(id: "m1").flatMap { try? Data(contentsOf: $0) } == Data([1]))
        #expect(store.anyPosterURL(id: "m2") == nil)
    }

    private func writePNG(to url: URL, size: Int = 32) throws {
        let context = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(srgbRed: 0.9, green: 0.4, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
        )!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        #expect(CGImageDestinationFinalize(destination))
    }

    @Test func restoredItemAdoptsIncomingNameAndCarriesSettings() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent("Totally Renamed Copy.png")
        try writePNG(to: fileURL)
        let probe = await MediaRelink.probe(url: fileURL)
        let unwrappedProbe = try #require(probe)
        #expect(unwrappedProbe.mediaKind == .image)
        #expect(unwrappedProbe.pixelWidth == 32)

        var tombstone = makeMediaItem(id: "ghost", hash: "oldhash")
        tombstone.name = "Sermon Bumper"
        tombstone.inPoint = 2
        tombstone.playRate = 1.5
        tombstone.favorite = true
        tombstone.tags = ["bumpers"]

        let restored = MediaRelink.restored(
            tombstone: tombstone, hash: "newhash", fileURL: fileURL, probe: unwrappedProbe
        )

        #expect(restored.id == "ghost")
        #expect(restored.name == "Totally Renamed Copy")
        #expect(restored.fileName == "Totally Renamed Copy.png")
        #expect(restored.fileHash == "newhash")
        #expect(restored.mediaKind == .image)
        #expect(restored.pixelWidth == 32)
        #expect(restored.favorite)
        #expect(restored.tags == ["bumpers"])
        #expect(restored.inPoint == 2)

        #expect(MediaRelink.carriedSettings(of: tombstone) == ["Trim", "Play Rate"])
        #expect(MediaRelink.carriedSettings(of: makeMediaItem()).isEmpty)
    }

    @LibraryActor @Test func tombstoneRestoreHealsReferencesUnderOriginalId() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try Library(rootURL: root)
        let blobs = try BlobStore(libraryRoot: root)
        let posters = try MediaPosterStore(libraryRoot: root)

        let original = root.appendingPathComponent("bumper.png")
        try writePNG(to: original)
        let hash = try blobs.store(fileURL: original)
        var item = makeMediaItem(id: "m-ref", hash: hash)
        item.name = "Bumper"
        try library.create(item)
        try library.create(
            Presentation(
                id: "p1", name: "Opener", presentationKind: .deck, themeId: "",
                slides: [Slide(id: "s1", name: "", objects: [], background: CueMedia(mediaId: "m-ref"))]
            )
        )

        posters.writeTombstone(item)
        try library.delete(kind: .media, id: "m-ref")
        #expect((try? library.open(MediaItem.self, id: "m-ref")) == nil)

        let returned = root.appendingPathComponent("from-backup (1).png")
        try FileManager.default.copyItem(at: original, to: returned)
        let probe = try #require(await MediaRelink.probe(url: returned))
        let newHash = try blobs.store(fileURL: returned)
        #expect(newHash == hash)
        let restored = MediaRelink.restored(
            tombstone: posters.tombstone(id: "m-ref")!, hash: newHash, fileURL: returned, probe: probe
        )
        try library.create(restored)
        posters.removeTombstone(id: "m-ref")

        let reopened = try library.open(MediaItem.self, id: "m-ref").value
        #expect(reopened.name == "from-backup (1)")
        #expect(reopened.fileHash == hash)

        let presentation = try library.open(Presentation.self, id: "p1").value
        #expect(MediaReferences.ids(in: presentation) == ["m-ref"])
        #expect(blobs.url(forHash: reopened.fileHash) != nil)
    }

    @Test func tombstoneRoundTripAndSweep() throws {
        let root = try makeRoot()
        let store = try MediaPosterStore(libraryRoot: root)
        let fp = MediaPosterStore.fingerprint(fileHash: "aaa", inPoint: nil)

        try store.writePoster(Data([1]), id: "live", fingerprint: fp)
        try store.writePoster(Data([2]), id: "ghost", fingerprint: fp)
        try store.writePoster(Data([3]), id: "gone", fingerprint: fp)
        store.writeTombstone(makeMediaItem(id: "ghost", hash: "bbb"))
        store.writeTombstone(makeMediaItem(id: "gone", hash: "ccc"))

        store.writeTombstone(makeMediaItem(id: "live", hash: "aaa"))

        #expect(store.tombstone(id: "ghost")?.fileHash == "bbb")

        let removed = store.sweep(existingMediaIds: ["live"], referencedIds: ["ghost"])

        #expect(removed == 3)
        #expect(store.anyPosterURL(id: "live") != nil)
        #expect(store.anyPosterURL(id: "ghost") != nil)
        #expect(store.anyPosterURL(id: "gone") == nil)
        #expect(store.tombstone(id: "ghost") != nil)
        #expect(store.tombstone(id: "live") == nil)
        #expect(store.allTombstones().map(\.id) == ["ghost"])
    }
}

@Suite struct ServiceRunOrderTests {
    private func item(_ id: String, _ kind: ServiceItemKind) -> ServiceItem {
        ServiceItem(id: id, itemKind: kind, name: id, refId: "ref-\(id)")
    }

    @Test func nextFireableWalksPastHeadersAndTransport() {
        let items = [
            item("deck", .presentation),
            item("head", .header),
            item("walkin", .playlist),
            item("bumper", .media),
            item("sermon", .presentation),
        ]
        #expect(ServiceRunOrder.nextFireable(in: items, after: "deck")?.id == "bumper")
        #expect(ServiceRunOrder.nextFireable(in: items, after: "bumper")?.id == "sermon")
        #expect(ServiceRunOrder.nextFireable(in: items, after: "sermon") == nil)
        #expect(ServiceRunOrder.nextFireable(in: items, after: "missing") == nil)
    }

    @Test func hiddenRowsLeaveTheWalkAndTheVisibleList() {
        var hidden = item("hidden", .presentation)
        hidden.hiddenInPresenter = true
        let items = [item("deck", .presentation), hidden, item("sermon", .presentation)]
        #expect(ServiceRunOrder.nextFireable(in: ServiceRunOrder.fireable(items), after: "deck")?.id == "sermon")
        #expect(ServiceRunOrder.visible(items).map(\.id) == ["deck", "sermon"])
        #expect(ServiceRunOrder.hidden(items).map(\.id) == ["hidden"])
    }

    @Test func selectedPlanTimeFiltersExcludedRowsEverywhere() {
        var elevenOnly = item("eleven", .media)
        elevenOnly.excludedTimeHexIds = ["nine"]
        var nineHeader = item("nine-head", .header)
        nineHeader.excludedTimeHexIds = ["eleven"]
        let items = [item("deck", .presentation), nineHeader, elevenOnly, item("sermon", .presentation)]

        #expect(ServiceRunOrder.fireable(items).map(\.id) == ["deck", "eleven", "sermon"])

        #expect(ServiceRunOrder.fireable(items, timeHexId: "nine").map(\.id) == ["deck", "sermon"])
        #expect(ServiceRunOrder.visible(items, timeHexId: "nine").map(\.id) == ["deck", "nine-head", "sermon"])

        #expect(
            ServiceRunOrder.sidebarRows(items, collapsedHeaders: ["nine-head"], timeHexId: "eleven").map(\.id)
                == ["deck", "eleven", "sermon"])
    }

    @Test func divergentTimesAreTheOnesWhoseRunDiffersFromTheReference() {

        var opener = item("opener", .presentation); opener.mxuItemHexId = "h-opener"
        var sermon = item("sermon", .presentation); sermon.mxuItemHexId = "h-sermon"
        var baptism = item("baptism", .info); baptism.mxuItemHexId = "h-baptism"
        baptism.excludedTimeHexIds = ["nine", "five"]
        let times = [
            MxUPlanTime(hexId: "nine", name: "9:00 am"),
            MxUPlanTime(hexId: "eleven", name: "11:00 am"),
            MxUPlanTime(hexId: "five", name: "5:00 pm"),
        ]
        let sameRows = [opener, sermon]
        let items = [opener, baptism, sermon]
        let orders = [
            MxUPlanTimeOrder(timeHexId: "nine", itemHexIds: ["h-opener", "h-sermon"]),
            MxUPlanTimeOrder(timeHexId: "eleven", itemHexIds: ["h-sermon", "h-baptism", "h-opener"]),
            MxUPlanTimeOrder(timeHexId: "five", itemHexIds: ["h-opener", "h-sermon"]),
        ]

        #expect(ServiceRunOrder.divergentTimes(sameRows, times: times, orders: nil, selectedTimeHexId: nil).isEmpty)
        #expect(ServiceRunOrder.divergentTimes(sameRows, times: times, orders: nil, selectedTimeHexId: "five").isEmpty)

        #expect(
            ServiceRunOrder.divergentTimes(items, times: times, orders: nil, selectedTimeHexId: nil).map(\.hexId)
                == ["eleven"])
        #expect(
            ServiceRunOrder.divergentTimes(items, times: times, orders: nil, selectedTimeHexId: "eleven").map(\.hexId)
                == ["nine", "five"])

        let reordered = [MxUPlanTimeOrder(timeHexId: "five", itemHexIds: ["h-sermon", "h-opener"])]
        #expect(
            ServiceRunOrder.divergentTimes(sameRows, times: times, orders: reordered, selectedTimeHexId: "nine").map(\.hexId)
                == ["five"])
        #expect(
            ServiceRunOrder.divergentTimes(items, times: times, orders: orders, selectedTimeHexId: "nine").map(\.hexId)
                == ["eleven"])

        var hidden = items; hidden[1].hiddenInPresenter = true
        #expect(ServiceRunOrder.divergentTimes(hidden, times: times, orders: nil, selectedTimeHexId: nil).isEmpty)

        #expect(ServiceRunOrder.divergentTimes(items, times: [times[0]], orders: nil, selectedTimeHexId: nil).isEmpty)
        #expect(ServiceRunOrder.divergentTimes(items, times: times, orders: nil, selectedTimeHexId: "gone").isEmpty)
    }

    @Test func orderedFollowsTheTimeSequenceAndLocalRowsFollowTheirAnchor() {

        var opener = item("opener", .presentation); opener.mxuItemHexId = "h-opener"
        var sermon = item("sermon", .presentation); sermon.mxuItemHexId = "h-sermon"
        var closer = item("closer", .media); closer.mxuItemHexId = "h-closer"
        let local = item("walk-in", .media)
        let items = [opener, local, sermon, closer]
        #expect(
            ServiceRunOrder.ordered(items, by: ["h-opener", "h-closer", "h-sermon"]).map(\.id)
                == ["opener", "walk-in", "closer", "sermon"])
        #expect(ServiceRunOrder.ordered(items, by: nil).map(\.id) == ["opener", "walk-in", "sermon", "closer"])

        var extra = item("extra", .presentation); extra.mxuItemHexId = "h-extra"
        #expect(
            ServiceRunOrder.ordered([extra] + items, by: ["h-closer", "h-opener"]).map(\.id)
                == ["extra", "closer", "opener", "walk-in", "sermon"])
        #expect(
            ServiceRunOrder.fireable(items, order: ["h-closer", "h-opener"]).map(\.id)
                == ["closer", "opener", "walk-in", "sermon"])
    }

    @Test func fireableNumbersPresentationsAndMediaOnly() {
        var hidden = item("hidden", .media)
        hidden.hiddenInPresenter = true
        let items = [
            item("head", .header), item("deck", .presentation), hidden,
            item("clip", .media), item("bed", .audio), item("sermon", .presentation),
        ]
        #expect(ServiceRunOrder.fireable(items).map(\.id) == ["deck", "clip", "sermon"])
    }

    @Test func hiddenHeaderUngroupsItsItemsInsteadOfJoiningThePreviousGroup() {
        var worship = item("worship", .header)
        worship.hiddenInPresenter = true
        let items = [
            item("pre", .header), item("walk-in", .media),
            worship, item("song", .presentation),
        ]

        #expect(
            ServiceRunOrder.sidebarRows(items, collapsedHeaders: ["pre"]).map(\.id)
                == ["pre", "song"])
        #expect(
            ServiceRunOrder.sidebarRows(items, collapsedHeaders: []).map(\.id)
                == ["pre", "walk-in", "song"])
    }
}
