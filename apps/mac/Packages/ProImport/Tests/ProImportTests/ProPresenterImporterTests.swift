import AppKit
import Foundation
import Testing
import PresenterCore
@testable import ProImport

@MainActor
struct ProPresenterImporterTests {

    @LibraryActor private func makeLibrary() throws -> Library {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return try Library(rootURL: root)
    }

    private func writePNG(to url: URL, color: NSColor = .systemRed) throws {
        let image = NSImage(size: NSSize(width: 4, height: 4))
        image.lockFocus()
        color.setFill()
        NSRect(x: 0, y: 0, width: 4, height: 4).fill()
        image.unlockFocus()
        let tiff = image.tiffRepresentation!
        let png = NSBitmapImageRep(data: tiff)!.representation(using: .png, properties: [:])!
        try png.write(to: url)
    }

    private func makeDocument(mediaAbsolutePath: String?) -> RVData_Presentation {
        var doc = RVData_Presentation()
        doc.uuid.string = UUID().uuidString
        doc.name = "Bundle Song"

        var graphics = RVData_Graphics.Element()
        graphics.uuid.string = UUID().uuidString
        graphics.bounds.size.width = 1920
        graphics.bounds.size.height = 1080
        graphics.opacity = 1
        var text = RVData_Graphics.Text()
        text.rtfData = Data("{\\rtf1\\ansi{\\fonttbl\\f0\\fnil Helvetica;}\\f0 Hello glass}".utf8)
        text.attributes.font.name = "Helvetica"
        text.attributes.font.size = 80
        graphics.text = text
        var element = RVData_Slide.Element()
        element.element = graphics

        var slide = RVData_Slide()
        slide.elements = [element]
        slide.size.width = 1920
        slide.size.height = 1080
        var presentationSlide = RVData_PresentationSlide()
        presentationSlide.baseSlide = slide
        var slideType = RVData_Action.SlideType()
        slideType.presentation = presentationSlide
        var slideAction = RVData_Action()
        slideAction.uuid.string = UUID().uuidString
        slideAction.actionTypeData = .slide(slideType)

        var cue = RVData_Cue()
        cue.uuid.string = UUID().uuidString
        cue.actions = [slideAction]

        if let path = mediaAbsolutePath {
            var media = RVData_Media()
            media.uuid.string = UUID().uuidString
            media.url.storage = .absoluteString("file://" + path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!)
            media.typeProperties = .image(RVData_Media.ImageTypeProperties())
            var mediaType = RVData_Action.MediaType()
            mediaType.element = media

            mediaType.layerType = .foreground
            var mediaAction = RVData_Action()
            mediaAction.uuid.string = UUID().uuidString
            mediaAction.actionTypeData = .media(mediaType)
            cue.actions.append(mediaAction)
        }

        doc.cues = [cue]
        return doc
    }

    @Test func importsABundleWithMediaAndDedupes() async throws {
        let library = try await makeLibrary()
        let importer = try ProPresenterImporter(client: await started(library))

        let stage = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fakeOriginal = "Users/test/Documents/ProPresenter - Test/Media/Assets/bg.png"
        let mediaStaged = stage.appendingPathComponent(fakeOriginal)
        try FileManager.default.createDirectory(at: mediaStaged.deletingLastPathComponent(), withIntermediateDirectories: true)
        try writePNG(to: mediaStaged)

        let doc = makeDocument(mediaAbsolutePath: "/" + fakeOriginal)
        try (try doc.serializedData()).write(to: stage.appendingPathComponent("song.pro"))

        let bundleURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).probundle")
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-c", "-k", stage.path, bundleURL.path]
        try ditto.run()
        ditto.waitUntilExit()
        #expect(ditto.terminationStatus == 0)

        let summaries = await importer.importItems(at: [bundleURL])
        #expect(summaries.count == 1)
        let summary = try #require(summaries.first)
        #expect(summary.presentationID != nil)
        #expect(summary.mediaImported == 1)
        #expect(summary.warnings.isEmpty)

        let imported = try await library.open(Presentation.self, id: summary.presentationID!).value
        #expect(imported.name == "Bundle Song")
        #expect(imported.folder == "ProPresenter Import")
        #expect(imported.slides.count == 1)
        #expect(imported.slides[0].objects[0].text == "Hello glass")

        #expect(imported.slides[0].background == nil)
        let fire = try #require(imported.slides[0].actions?.first { $0.kind == .fireMedia })
        let mediaID = try #require(fire.mediaId)
        #expect(!mediaID.hasPrefix(ProDocumentMapper.placeholderPrefix))
        let item = try await library.open(MediaItem.self, id: mediaID).value
        #expect(item.classification == .foreground)

        let again = await importer.importItems(at: [bundleURL])
        #expect(again.first?.mediaImported == 0)
        let mediaEntries = (try? await library.index.entries(of: .media)) ?? []
        #expect(mediaEntries.count == 1)
    }

    @Test func reimportHonorsTheConflictPolicy() async throws {
        let library = try await makeLibrary()
        let importer = try ProPresenterImporter(client: await started(library))

        let doc = makeDocument(mediaAbsolutePath: nil)
        let docID = doc.uuid.string.lowercased()
        var stale = Presentation(
            id: docID, name: "Old Import", presentationKind: .deck, themeId: "",
            slides: [
                Slide(id: "stale-slide", name: "Stale", objects: [],
                      sectionId: "stale-section"),
            ],
            sections: [PresentationSection(id: "stale-section", name: "")]
        )
        stale.folder = "Old Folder"
        try await library.create(stale)

        let stage = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        try (try doc.serializedData()).write(to: stage.appendingPathComponent("song.pro"))

        var summaries = await importer.importItems(at: [stage])
        #expect(summaries.first?.presentationID == docID)
        #expect(summaries.first?.skipped == .edited)
        #expect(try await library.open(Presentation.self, id: docID).value.name == "Old Import")

        summaries = await importer.importItems(at: [stage], policy: .keepMine)
        #expect(summaries.first?.skipped == .existing)

        summaries = await importer.importItems(at: [stage], policy: .replace)
        #expect(summaries.first?.skipped == nil)
        var imported = try await library.open(Presentation.self, id: docID).value
        #expect(imported.name == "Bundle Song")
        #expect(imported.sections == nil)
        #expect(imported.slides.count == 1)
        #expect(imported.slides.allSatisfy { $0.id != "stale-slide" })

        summaries = await importer.importItems(at: [stage])
        #expect(summaries.first?.skipped == nil)

        try await onLibraryActor {
            let edited = try library.open(Presentation.self, id: docID)
            try edited.update { $0.name = "Re-themed here" }
            try library.save(edited)
        }
        summaries = await importer.importItems(at: [stage])
        #expect(summaries.first?.skipped == .edited)
        imported = try await library.open(Presentation.self, id: docID).value
        #expect(imported.name == "Re-themed here")
    }

    @Test func presentationsCanImportWithoutTheirMedia() async throws {
        let library = try await makeLibrary()
        let show = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let defaultLibrary = show.appendingPathComponent("Libraries/Default", isDirectory: true)
        try FileManager.default.createDirectory(at: defaultLibrary, withIntermediateDirectories: true)
        let background = show.appendingPathComponent("Media/Assets/bg.png")
        try FileManager.default.createDirectory(at: background.deletingLastPathComponent(), withIntermediateDirectories: true)
        try writePNG(to: background)
        let doc = makeDocument(mediaAbsolutePath: background.path)
        try (try doc.serializedData()).write(to: defaultLibrary.appendingPathComponent("song.pro"))

        var options = WorkspaceImportOptions()
        options.presentationMedia = false
        options.media = false
        let importer = try await ProWorkspaceImporter(client: await started(library))
        var phases: [String] = []
        let withoutMedia = await importer.importWorkspace(showDirectory: show, options: options) { phases.append($0.phase) }
        #expect(withoutMedia.presentations.first?.presentationID != nil)
        #expect(withoutMedia.mediaImported == 0)
        #expect(withoutMedia.mediaWithheld == 1)
        #expect(!phases.contains("Media"))
        #expect(!withoutMedia.warnings.contains { $0.contains("media not found") })
        #expect(((try? await library.index.entries(of: .media)) ?? []).isEmpty)

        options.presentationMedia = true
        options.policy = .replace
        let withMedia = await importer.importWorkspace(showDirectory: show, options: options)
        #expect(withMedia.mediaImported == 1)
        #expect(withMedia.mediaWithheld == 0)

        options.presentationMedia = false
        let linked = await importer.importWorkspace(showDirectory: show, options: options)
        #expect(linked.mediaImported == 0)
        #expect(linked.mediaWithheld == 0)
        let presentation = try await library.open(Presentation.self, id: doc.uuid.string.lowercased()).value
        let fire = try #require(presentation.slides[0].actions?.first { $0.kind == .fireMedia })
        #expect(fire.mediaId?.hasPrefix(ProDocumentMapper.placeholderPrefix) == false)
    }

    @Test func mediaBinPlaylistsBecomeFolders() async throws {
        let library = try await makeLibrary()
        let show = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let defaultLibrary = show.appendingPathComponent("Libraries/Default", isDirectory: true)
        let assets = show.appendingPathComponent("Media/Assets", isDirectory: true)
        try FileManager.default.createDirectory(at: defaultLibrary, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: show.appendingPathComponent("Playlists"), withIntermediateDirectories: true)
        let shared = assets.appendingPathComponent("shared.png")
        let loop = assets.appendingPathComponent("loop.png")
        try writePNG(to: shared)
        try writePNG(to: loop, color: .systemBlue)
        let doc = makeDocument(mediaAbsolutePath: shared.path)
        try (try doc.serializedData()).write(to: defaultLibrary.appendingPathComponent("song.pro"))

        func cueItem(_ id: String, _ file: URL) -> RVData_PlaylistItem {
            var item = RVData_PlaylistItem()
            item.uuid.string = id
            item.name = file.lastPathComponent
            var media = RVData_Media()
            media.uuid.string = "media-\(id)"
            media.url.storage = .absoluteString("file://" + file.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!)
            media.typeProperties = .image(RVData_Media.ImageTypeProperties())
            var mediaType = RVData_Action.MediaType()
            mediaType.element = media
            var action = RVData_Action()
            action.uuid.string = "action-\(id)"
            action.actionTypeData = .media(mediaType)
            var cue = RVData_Cue()
            cue.uuid.string = "cue-\(id)"
            cue.actions = [action]
            item.itemType = .cue(cue)
            return item
        }
        func playlist(_ id: String, _ name: String, _ items: [RVData_PlaylistItem]) -> RVData_Playlist {
            var node = RVData_Playlist()
            node.uuid.string = id
            node.name = name
            var wrapped = RVData_Playlist.PlaylistItems()
            wrapped.items = items
            node.childrenType = .items(wrapped)
            return node
        }
        func folder(_ id: String, _ name: String, _ children: [RVData_Playlist]) -> RVData_Playlist {
            var node = RVData_Playlist()
            node.uuid.string = id
            node.name = name
            var array = RVData_Playlist.PlaylistArray()
            array.playlists = children
            node.childrenType = .playlists(array)
            return node
        }
        var binDoc = RVData_PlaylistDocument()
        binDoc.rootNode = folder("ROOT", "PLAYLIST", [
            folder("F-1", "Backgrounds", [
                playlist("PL-1", "Christmas", [cueItem("A", shared), cueItem("B", loop)]),
            ]),
            playlist("PL-2", "Loose", [cueItem("C", loop)]),
        ])
        try (try binDoc.serializedData()).write(to: show.appendingPathComponent("Playlists/Media"))

        let mapped = ProPlaylistMapper.mapMediaBinFolders(binDoc)
        #expect(mapped.folders.map(\.path) == ["Backgrounds/Christmas", "Loose"])
        #expect(mapped.folders.map { $0.wantIDs.count } == [2, 1])

        let importer = try await ProWorkspaceImporter(client: await started(library))
        #expect(importer.scan(showDirectory: show).media == 2)

        var phases: [String] = []
        let first = await importer.importWorkspace(showDirectory: show) { phases.append($0.phase) }
        #expect(phases.contains("Media"))
        #expect(first.mediaFoldersImported == ["Backgrounds/Christmas", "Loose"])

        #expect(first.mediaImported == 2)
        let entries = (try? await library.index.entries(of: .media)) ?? []
        #expect(entries.count == 2)
        let items = try await onLibraryActor { entries.compactMap { try? library.open(MediaItem.self, id: $0.id).value } }
        let sharedItem = try #require(items.first { $0.fileName == "shared.png" })
        let loopItem = try #require(items.first { $0.fileName == "loop.png" })
        #expect(sharedItem.folder == "ProPresenter Import/Backgrounds/Christmas")
        #expect(sharedItem.classification == .foreground)

        #expect(loopItem.folder == "ProPresenter Import/Backgrounds/Christmas")

        try await onLibraryActor {
            let filed = try library.open(MediaItem.self, id: loopItem.id)
            _ = try filed.update { $0.folder = "Mine" }
            try library.save(filed)
        }
        let again = await importer.importWorkspace(showDirectory: show)
        #expect(again.mediaImported == 0)
        #expect(((try? await library.index.entries(of: .media)) ?? []).count == 2)
        #expect(try await library.open(MediaItem.self, id: loopItem.id).value.folder == "Mine")

        var binOff = WorkspaceImportOptions()
        binOff.media = false
        let fresh = try await makeLibrary()
        let offResult = await (try await ProWorkspaceImporter(client: await started(fresh))).importWorkspace(showDirectory: show, options: binOff)
        #expect(offResult.mediaImported == 1)
        #expect(offResult.mediaFoldersImported.isEmpty)
        let unfiled = try await onLibraryActor { ((try? fresh.index.entries(of: .media)) ?? []).compactMap { try? fresh.open(MediaItem.self, id: $0.id).value } }
        #expect(unfiled.map(\.folder) == [nil])
    }

    @Test func savedOptionsGainNewRowsAsDefaults() throws {
        let legacy = Data(#"{"policy":"keepMine","presentations":false,"themes":true,"overlays":true,"alerts":true,"confidenceLayouts":true,"combos":true,"playlists":true,"schedules":true,"groupHotKeys":true,"screens":false,"screenCorrections":true,"screenSlices":true,"screenMasks":true,"looks":true,"stageAssignments":true,"timers":true,"videoInputs":true,"midiDevices":true}"#.utf8)
        let decoded = try JSONDecoder().decode(WorkspaceImportOptions.self, from: legacy)
        #expect(decoded.policy == .keepMine)
        #expect(decoded.presentations == false)
        #expect(decoded.screens == false)
        #expect(decoded.presentationMedia == true)
        #expect(decoded.media == true)

        var options = WorkspaceImportOptions()
        options.presentationMedia = false
        options.media = false
        let roundTrip = try JSONDecoder().decode(WorkspaceImportOptions.self, from: try JSONEncoder().encode(options))
        #expect(roundTrip == options)
    }

    @Test func missingMediaBecomesAWarningNotAFailure() async throws {
        let library = try await makeLibrary()
        let importer = try ProPresenterImporter(client: await started(library))

        let doc = makeDocument(mediaAbsolutePath: "/nonexistent/path/gone.mov")
        let proURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).pro")
        try (try doc.serializedData()).write(to: proURL)

        let summaries = await importer.importItems(at: [proURL])
        let summary = try #require(summaries.first)
        #expect(summary.presentationID != nil)
        #expect(summary.warnings.contains { $0.contains("media not found") })

        let imported = try await library.open(Presentation.self, id: summary.presentationID!).value
        #expect(imported.slides[0].background == nil)  
    }

    @Test func garbageFileIsSkippedWithReason() async throws {
        let library = try await makeLibrary()
        let importer = try ProPresenterImporter(client: await started(library))
        let garbage = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).pro")
        try Data("not a protobuf at all, sorry".utf8).write(to: garbage)

        let summaries = await importer.importItems(at: [garbage])
        let summary = try #require(summaries.first)
        #expect(summary.presentationID == nil)
        #expect(summary.warnings.first?.contains("not a readable ProPresenter 7 document") == true)
    }

    @Test func realCorpusSweep() async throws {
        guard let dir = ProcessInfo.processInfo.environment["PRO_IMPORT_FIXTURE_DIR"] else { return }
        let library = try await makeLibrary()
        let importer = try ProPresenterImporter(client: await started(library))
        let summaries = await importer.importItems(at: [URL(fileURLWithPath: NSString(string: dir).expandingTildeInPath)])
        #expect(!summaries.isEmpty)
        let failed = summaries.filter { $0.presentationID == nil }
        for failure in failed {
            Issue.record("\(failure.sourceURL.lastPathComponent): \(failure.warnings.joined(separator: "; "))")
        }
        let warned = summaries.filter { !$0.warnings.isEmpty }
        print("PRO_IMPORT sweep: \(summaries.count) docs, \(failed.count) failed, \(warned.count) with warnings")
        for summary in warned {
            print("  \(summary.name): \(summary.warnings.joined(separator: " | "))")
        }
    }
}
