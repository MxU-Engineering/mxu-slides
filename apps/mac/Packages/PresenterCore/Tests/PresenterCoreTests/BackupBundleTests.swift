import Foundation
import Testing
@testable import PresenterCore

@MainActor
struct BackupBundleTests {

    private let defaults = UserDefaults(suiteName: "backup-tests-\(UUID().uuidString)")!

    private func makeRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    private func client(at root: URL) async throws -> LibraryClient {
        let client = LibraryClient(rootURL: root)
        try await client.start().value
        return client
    }

    private func populate(_ client: LibraryClient) async throws {
        _ = try await client.create(Presentation(
            id: "s1", name: "Amazing Grace", presentationKind: .song, themeId: "t1",
            slides: [Slide(id: "sl1", name: "Verse 1", objects: [
                SlideObject(id: "o1", objectKind: .text, name: "Lyrics", text: "Amazing grace"),
            ])]
        )).value
        _ = try await client.create(Theme(
            id: "t1", name: "Default", fontFamily: "Helvetica Neue",
            fontSize: 96, textColorHex: "#FFFFFF", backgroundColorHex: "#000000"
        )).value
        _ = try await client.create(Playlist(
            id: "p1", name: "Walk-in", entries: [], playbackMode: .loopPlaylist, crossfadeSeconds: 2
        )).value

        let blobSource = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).bin")
        try Data("fake media bytes".utf8).write(to: blobSource)
        defer { try? FileManager.default.removeItem(at: blobSource) }
        let blobs = try BlobStore(libraryRoot: client.rootURL)
        let hash = try blobs.store(fileURL: blobSource)
        _ = try await client.create(MediaItem(
            id: "m1", name: "Ocean", mediaKind: .video, classification: .background,
            fileHash: hash, fileName: "ocean.bin", fileStatus: .ready, statusDetail: "",
            tags: ["loop"], favorite: true, collections: [], loops: true,
            inPoint: nil, outPoint: nil, durationSeconds: 30, pixelWidth: nil, pixelHeight: nil
        )).value
    }

    @Test func exportWipeImportRoundTrips() async throws {
        let root = makeRoot()
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).mxubackup")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: bundleURL)
        }

        var originalSong: Presentation?
        do {
            let library = try await client(at: root)
            try await populate(library)
            originalSong = try await library.loadValue(Presentation.self, id: "s1")
            let manifest = try await BackupBundle.export(client: library, to: bundleURL, defaults: defaults)
            #expect(manifest.documentCounts["presentation"] == 1)
            #expect(manifest.blobCount == 1)
        }

        try FileManager.default.removeItem(at: root)

        let result = try await BackupBundle.restore(from: bundleURL, into: try await client(at: root), defaults: defaults)
        #expect(result.manifest.formatVersion == BackupBundle.formatVersion)
        #expect(result.added[.presentations] == 1)
        #expect(result.mediaFilesCopied == 1)
        #expect(result.warnings.isEmpty)

        let song = originalSong
        try await onLibraryActor(reading: root) { restored throws in
            #expect(try restored.open(Presentation.self, id: "s1").value == song)
            #expect(try restored.index.entries(of: .theme).map(\.id) == ["t1"])
            #expect(try restored.index.entries(of: .playlist).map(\.id) == ["p1"])
            #expect(try restored.index.search("amaz").map(\.id) == ["s1"])

            let media = try restored.open(MediaItem.self, id: "m1").value
            let blobs = try BlobStore(libraryRoot: root)
            #expect(blobs.url(forHash: media.fileHash) != nil)
        }
    }

    @Test func importOverLiveDataMergesInsteadOfClobbering() async throws {
        let root = makeRoot()
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).mxubackup")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: bundleURL)
        }

        let live = try await client(at: root)
        try await populate(live)
        try await BackupBundle.export(client: live, to: bundleURL, defaults: defaults)

        _ = try await live.modify(Presentation.self, id: "s1") { $0.name = "Amazing Grace (My Chains Are Gone)" }.value

        try await BackupBundle.restore(from: bundleURL, into: live, defaults: defaults)
        try await onLibraryActor(reading: root) { library throws in

            #expect(
                try library.open(Presentation.self, id: "s1").value.name
                    == "Amazing Grace (My Chains Are Gone)"
            )

            #expect(try library.index.entries(of: .presentation).count == 1)
        }
    }

    @Test func nonBackupDirectoryIsRejected() async throws {
        let root = makeRoot()
        let junk = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: junk, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: junk)
        }
        let library = try await client(at: root)
        await #expect(throws: BackupBundle.BackupError.notABackup(junk.lastPathComponent)) {
            try await BackupBundle.restore(from: junk, into: library, defaults: defaults)
        }
    }

    private func exportedThenEdited(root: URL, bundleURL: URL) async throws -> LibraryClient {
        let library = try await client(at: root)
        try await populate(library)
        try await BackupBundle.export(client: library, to: bundleURL, defaults: defaults)
        _ = try await library.modify(Presentation.self, id: "s1") { $0.name = "Edited here" }.value
        return library
    }

    @Test func uncheckedSectionsStayOut() async throws {
        let root = makeRoot()
        let freshRoot = makeRoot()
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).mxubackup")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: freshRoot)
            try? FileManager.default.removeItem(at: bundleURL)
        }
        _ = try await exportedThenEdited(root: root, bundleURL: bundleURL)

        let scan = try BackupBundle.scan(bundleURL)
        #expect(scan.count(.presentations) == 1)
        #expect(scan.count(.media) == 1)
        #expect(scan.count(.mediaFiles) == 1)
        #expect(scan.count(.overlays) == 0)

        var options = BackupImportOptions()
        options.excluded = [.themes, .media]
        let result = try await BackupBundle.restore(
            from: bundleURL, into: try await client(at: freshRoot), options: options, defaults: defaults)
        try await onLibraryActor(reading: freshRoot) { fresh throws in
            #expect(try fresh.index.entries(of: .presentation).map(\.id) == ["s1"])
            #expect(try fresh.index.entries(of: .theme).isEmpty)
            #expect(try fresh.index.entries(of: .media).isEmpty)
        }

        #expect(result.mediaFilesCopied == 0)
    }

    @Test func keepMineSkipsAndReplaceRollsBack() async throws {
        let root = makeRoot()
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).mxubackup")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: bundleURL)
        }
        let live = try await exportedThenEdited(root: root, bundleURL: bundleURL)

        var options = BackupImportOptions()
        options.policy = .keepMine
        let kept = try await BackupBundle.restore(
            from: bundleURL, into: live, options: options, defaults: defaults)
        #expect(kept.kept == 4)
        try await onLibraryActor(reading: root) { library throws in #expect(try library.open(Presentation.self, id: "s1").value.name == "Edited here") }

        options.policy = .replace
        let replaced = try await BackupBundle.restore(
            from: bundleURL, into: live, options: options, defaults: defaults)
        #expect(replaced.replaced == 4)
        try await onLibraryActor(reading: root) { library throws in
            #expect(try library.open(Presentation.self, id: "s1").value.name == "Amazing Grace")
            #expect(try library.index.entries(of: .presentation).map(\.name) == ["Amazing Grace"])
        }
    }

    @Test func fontsPostersUsageAndSettingsRideAlong() async throws {
        let root = makeRoot()
        let freshRoot = makeRoot()
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).mxubackup")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: freshRoot)
            try? FileManager.default.removeItem(at: bundleURL)
        }
        let library = try await client(at: root)
        try await populate(library)
        for folder in ["fonts", "thumbnails"] {
            let directory = root.appendingPathComponent(folder, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("bytes".utf8).write(to: directory.appendingPathComponent("file.bin"))
        }
        let fired = Date(timeIntervalSince1970: 1_700_000_000)
        _ = try await library.touchUsage(id: "s1", at: fired).value
        defaults.set("F1", forKey: "keyboard.map")
        defaults.set("secret", forKey: "present.runOnlyPIN")

        let manifest = try await BackupBundle.export(client: library, to: bundleURL, defaults: defaults)
        #expect(manifest.fontCount == 1)

        #expect(manifest.settingsCount == 1)

        let target = UserDefaults(suiteName: "backup-tests-\(UUID().uuidString)")!
        let result = try await BackupBundle.restore(from: bundleURL, into: try await client(at: freshRoot), defaults: target)

        #expect(result.fontsCopied == 1)
        #expect(FileManager.default.fileExists(
            atPath: freshRoot.appendingPathComponent("thumbnails/file.bin").path))
        try await onLibraryActor(reading: freshRoot) { library throws in #expect(try library.index.allUsage()["s1"] == fired) }

        #expect(result.settingsStaged == 1)
        #expect(target.string(forKey: "keyboard.map") == nil)
        BackupSettings.applyPending(defaults: target)
        #expect(target.string(forKey: "keyboard.map") == "F1")
        #expect(target.object(forKey: "present.runOnlyPIN") == nil)
    }

    @Test func incompleteBundleAndBadDocumentAreReported() async throws {
        let root = makeRoot()
        let freshRoot = makeRoot()
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).mxubackup")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: freshRoot)
            try? FileManager.default.removeItem(at: bundleURL)
        }
        _ = try await exportedThenEdited(root: root, bundleURL: bundleURL)
        try FileManager.default.removeItem(
            at: bundleURL.appendingPathComponent("themes/t1.automerge"))
        try Data("not automerge".utf8).write(
            to: bundleURL.appendingPathComponent("playlists/p1.automerge"))

        let result = try await BackupBundle.restore(from: bundleURL, into: try await client(at: freshRoot), defaults: defaults)

        try await onLibraryActor(reading: freshRoot) { library throws in #expect(try library.index.entries(of: .presentation).map(\.id) == ["s1"]) }
        #expect(result.warnings.contains { $0.contains("themes lists 1 documents but holds 0") })
        #expect(result.warnings.contains { $0.hasPrefix("playlists/p1 could not be imported") })
    }

    @Test func olderBundleStillImports() async throws {
        let root = makeRoot()
        let freshRoot = makeRoot()
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).mxubackup")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: freshRoot)
            try? FileManager.default.removeItem(at: bundleURL)
        }
        _ = try await exportedThenEdited(root: root, bundleURL: bundleURL)
        let manifestURL = bundleURL.appendingPathComponent("manifest.json")
        var manifest = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
        for key in ["fontCount", "settingsCount", "modernVocabulary"] {
            manifest.removeValue(forKey: key)
        }
        try JSONSerialization.data(withJSONObject: manifest).write(to: manifestURL)

        let result = try await BackupBundle.restore(from: bundleURL, into: try await client(at: freshRoot), defaults: defaults)
        #expect(result.documentsLanded == 4)
        try await onLibraryActor(reading: freshRoot) { library throws in #expect(try library.index.search("amaz").map(\.id) == ["s1"]) }
    }
}
