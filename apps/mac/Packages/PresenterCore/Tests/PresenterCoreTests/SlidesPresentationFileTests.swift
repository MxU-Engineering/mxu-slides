import Foundation
import Testing
@testable import PresenterCore

@MainActor
struct SlidesPresentationFileTests {
    private func temporary(_ name: String = UUID().uuidString) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(name)
    }

    private func client() async throws -> LibraryClient {
        let client = LibraryClient(rootURL: temporary())
        try await client.start().value
        return client
    }

    private func storeBlob(_ text: String, ext: String, in client: LibraryClient) throws -> String {
        let source = temporary("\(UUID()).\(ext)")
        try Data(text.utf8).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        return try BlobStore(libraryRoot: client.rootURL).store(fileURL: source)
    }

    private func media(_ id: String, hash: String, name: String = "Ocean") -> MediaItem {
        MediaItem(
            id: id, name: name, mediaKind: .image, classification: .background, fileHash: hash,
            fileName: "\(name).png", fileStatus: .ready, statusDetail: "", tags: [], favorite: false,
            collections: [], loops: false, folder: "Team Media/Backgrounds")
    }

    private func deck(mediaID: String, audioID: String) -> Presentation {
        Presentation(
            id: "deck", name: "Amazing Grace", presentationKind: .song, themeId: "theme",
            folder: "Songs/Hymns",
            slides: [
                Slide(id: "s1", name: "Verse 1", objects: [
                    SlideObject(id: "o1", objectKind: .text, name: "Lyrics", text: "Amazing grace"),
                ], background: CueMedia(mediaId: mediaID)),
                Slide(id: "s2", name: "Walk Out", objects: [], actions: [SlideAction(id: "a1", kind: .fireAudio, audioItemId: audioID)]),
            ])
    }

    private let theme = Theme(
        id: "theme", name: "Hymns", fontFamily: "Helvetica Neue", fontSize: 96,
        textColorHex: "#FFFFFF", backgroundColorHex: "#000000")

    private func exported() async throws -> URL {
        let source = try await client()
        defer { try? FileManager.default.removeItem(at: source.rootURL) }
        let imageHash = try storeBlob("png bytes", ext: "png", in: source)
        let audioHash = try storeBlob("wav bytes", ext: "wav", in: source)
        _ = try await source.create(theme).value
        _ = try await source.create(media("m1", hash: imageHash)).value
        _ = try await source.create(AudioItem(
            id: "a1", name: "Outro", fileHash: audioHash, fileName: "Outro.wav", tags: [], favorite: false)).value
        _ = try await source.create(deck(mediaID: "m1", audioID: "a1")).value
        let bundle = try await SlidesPresentationFile.bundle(id: "deck", reader: source.reader())
        let url = temporary("\(UUID()).mxuslides")
        let summary = try SlidesPresentationFile.write(
            bundle, blobs: BlobStore(libraryRoot: source.rootURL), fonts: [], to: url)
        #expect(summary.missingFiles.isEmpty)
        return url
    }

    @Test func aDeckRoundTripsIntoAnotherLibrary() async throws {
        let file = try await exported()
        let scratch = temporary()
        let target = try await client()
        defer {
            for url in [file, scratch, target.rootURL] { try? FileManager.default.removeItem(at: url) }
        }
        let contents = try SlidesPresentationFile.read(file, into: scratch)
        #expect(contents.manifest.name == "Amazing Grace")
        #expect(contents.manifest.slideCount == 2)
        #expect(try await !SlidesPresentationFile.isInLibrary(contents, client: target))

        let placement = LibraryHome.Placement.drive(viewing: nil)
        let result = try await SlidesPresentationFile.importContents(
            contents, client: target, blobs: BlobStore(libraryRoot: target.rootURL),
            placement: placement, conflict: .keepBoth)
        #expect(result.presentationID == "deck")
        #expect(result.themesAdded == 1)
        #expect(result.mediaAdded == 2)
        #expect(result.missing.isEmpty)

        let landed = try await target.loadValue(Presentation.self, id: "deck")
        #expect(landed.slides.map(\.id) == ["s1", "s2"])
        #expect(landed.slides[0].background?.mediaId == "m1")

        #expect(landed.folder == LibraryHome.needsSorted)
        #expect(try await target.loadValue(Theme.self, id: "theme").name == "Hymns")
        let item = try await target.loadValue(MediaItem.self, id: "m1")
        #expect(item.folder == LibraryHome.needsSorted)
        let blobs = try BlobStore(libraryRoot: target.rootURL)
        #expect(blobs.url(forHash: item.fileHash) != nil)
        let audio = try await target.loadValue(AudioItem.self, id: "a1")
        #expect(blobs.url(forHash: audio.fileHash) != nil)
    }

    @Test func importingTheSameDeckAgainReplacesOrKeepsBoth() async throws {
        let file = try await exported()
        let scratch = temporary()
        let target = try await client()
        defer {
            for url in [file, scratch, target.rootURL] { try? FileManager.default.removeItem(at: url) }
        }
        let contents = try SlidesPresentationFile.read(file, into: scratch)
        let blobs = try BlobStore(libraryRoot: target.rootURL)
        _ = try await SlidesPresentationFile.importContents(
            contents, client: target, blobs: blobs, placement: .unplaced, conflict: .keepBoth)
        _ = try await target.modify(Presentation.self, id: "deck") { $0.name = "Edited here" }.value
        #expect(try await SlidesPresentationFile.isInLibrary(contents, client: target))

        let copy = try await SlidesPresentationFile.importContents(
            contents, client: target, blobs: blobs, placement: .unplaced, conflict: .keepBoth)
        #expect(copy.presentationID != "deck")

        #expect(copy.themesAdded == 0)
        #expect(copy.mediaAdded == 0)
        #expect(try await target.loadValue(Presentation.self, id: "deck").name == "Edited here")

        _ = try await SlidesPresentationFile.importContents(
            contents, client: target, blobs: blobs, placement: .unplaced, conflict: .replace)
        #expect(try await target.loadValue(Presentation.self, id: "deck").name == "Amazing Grace")
    }

    @Test func planPointsAtFilesTheLibraryHasAndReportsOnesNobodyHas() {
        let payload = SlidesPresentationFile.Payload(
            presentation: deck(mediaID: "m1", audioID: "a1"),
            themes: [theme],
            media: [media("m1", hash: "h1"), media("m2", hash: "h2", name: "Lost")],
            audio: [])
        let plan = SlidesPresentationFile.plan(
            payload,
            existing: .init(themes: ["theme"], media: ["local": "h1"]),
            files: ["h1"], placement: .unplaced, presentationID: "copy")
        #expect(plan.presentation.id == "copy")

        #expect(plan.presentation.slides[0].background?.mediaId == "local")
        #expect(plan.media.isEmpty)
        #expect(plan.themes.isEmpty)
        #expect(plan.missing == ["Lost"])
        #expect(plan.presentation.folder == nil)
    }

    @Test func readRefusesOtherFilesAndNewerFormats() throws {
        let scratch = temporary()
        let notZip = temporary("\(UUID()).mxuslides")
        defer { for url in [scratch, notZip] { try? FileManager.default.removeItem(at: url) } }
        try Data("hello".utf8).write(to: notZip)
        #expect(throws: SlidesPresentationFile.FileError.notAPresentation(notZip.lastPathComponent)) {
            try SlidesPresentationFile.read(notZip, into: scratch.appendingPathComponent("a"))
        }

        let staged = scratch.appendingPathComponent("staged", isDirectory: true)
        try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
        try Data(#"{"formatVersion":99,"createdAt":"2026-10-07T00:00:00Z","name":"x","slideCount":0}"#.utf8)
            .write(to: staged.appendingPathComponent("manifest.json"))
        let newer = scratch.appendingPathComponent("newer.mxuslides")
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-c", "-k", staged.path, newer.path]
        try ditto.run()
        ditto.waitUntilExit()
        #expect(throws: SlidesPresentationFile.FileError.unsupportedFormat(99)) {
            try SlidesPresentationFile.read(newer, into: scratch.appendingPathComponent("b"))
        }
    }
}
