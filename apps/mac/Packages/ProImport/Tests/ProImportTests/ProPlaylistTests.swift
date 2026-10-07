import AppKit
import Foundation
import Testing
import PresenterCore
@testable import ProImport

@MainActor
struct ProPlaylistTests {

    private func uuid(_ string: String) -> RVData_UUID {
        var uuid = RVData_UUID()
        uuid.string = string
        return uuid
    }

    private func presentationItem(id: String, name: String, path: String, arrangement: String? = nil) -> RVData_PlaylistItem {
        var item = RVData_PlaylistItem()
        item.uuid = uuid(id)
        item.name = name
        var presentation = RVData_PlaylistItem.Presentation()
        presentation.documentPath.storage = .absoluteString(
            "file://" + path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!)
        var local = RVData_URL.LocalRelativePath()
        local.path = String(path.split(separator: "/").suffix(3).joined(separator: "/"))
        presentation.documentPath.relativeFilePath = .local(local)
        if let arrangement { presentation.arrangement = uuid(arrangement) }
        item.itemType = .presentation(presentation)
        return item
    }

    private func headerItem(id: String, name: String) -> RVData_PlaylistItem {
        var item = RVData_PlaylistItem()
        item.uuid = uuid(id)
        item.name = name
        var header = RVData_PlaylistItem.Header()
        var color = RVData_Color()
        color.red = 1
        color.alpha = 1
        header.color = color
        item.itemType = .header(header)
        return item
    }

    private func mediaCueItem(id: String, name: String, mediaPath: String) -> RVData_PlaylistItem {
        var item = RVData_PlaylistItem()
        item.uuid = uuid(id)
        item.name = name
        var media = RVData_Media()
        media.uuid = uuid("media-\(id)")
        media.url.storage = .absoluteString(
            "file://" + mediaPath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!)
        media.typeProperties = .image(RVData_Media.ImageTypeProperties())
        var mediaType = RVData_Action.MediaType()
        mediaType.element = media
        var action = RVData_Action()
        action.uuid = uuid("action-\(id)")
        action.actionTypeData = .media(mediaType)
        var cue = RVData_Cue()
        cue.uuid = uuid("cue-\(id)")
        cue.name = name
        cue.actions = [action]
        item.itemType = .cue(cue)
        return item
    }

    private func playlistNode(id: String, name: String, items: [RVData_PlaylistItem]) -> RVData_Playlist {
        var node = RVData_Playlist()
        node.uuid = uuid(id)
        node.name = name
        var wrapped = RVData_Playlist.PlaylistItems()
        wrapped.items = items
        node.childrenType = .items(wrapped)
        return node
    }

    private func document(root leaves: [RVData_Playlist], foldered: Bool = true) -> RVData_PlaylistDocument {
        var folder = RVData_Playlist()
        folder.uuid = uuid("FOLDER-1")
        folder.name = "Folder"
        var array = RVData_Playlist.PlaylistArray()
        array.playlists = leaves
        folder.childrenType = .playlists(array)

        var root = RVData_Playlist()
        root.uuid = uuid("ROOT-1")
        root.name = "PLAYLIST"
        var rootChildren = RVData_Playlist.PlaylistArray()
        rootChildren.playlists = foldered ? [folder] : leaves
        root.childrenType = .playlists(rootChildren)

        var doc = RVData_PlaylistDocument()
        doc.type = .presentation
        doc.rootNode = root
        return doc
    }

    @Test func playlistsBecomeServicesThroughFolders() {
        let doc = document(root: [playlistNode(id: "PL-1", name: "Weekend Services", items: [
            headerItem(id: "IT-H", name: "Worship"),
            presentationItem(
                id: "IT-P", name: "Opener",
                path: "/Users/anna/Documents/Show/Libraries/Default/Opener.pro",
                arrangement: "ARR-1"),
            presentationItem(
                id: "IT-GONE", name: "Missing",
                path: "/Users/anna/Documents/Show/Libraries/Default/Missing.pro"),
            mediaCueItem(id: "IT-M", name: "Bumper", mediaPath: "/Users/anna/Media/bumper.png"),
        ])])

        let mapped = ProPlaylistMapper.mapPresentationPlaylists(doc) { ref in
            ref.absolutePath?.hasSuffix("Opener.pro") == true ? "pres-opener" : nil
        }

        #expect(mapped.services.count == 1)
        let service = mapped.services[0].service
        #expect(service.id == "pl-1")
        #expect(service.name == "Weekend Services")
        #expect(service.serviceDate.isEmpty)
        #expect(service.items.count == 3)

        #expect(service.items[0].itemKind == .header)
        #expect(service.items[0].name == "Worship")
        #expect(service.items[0].colorHex == "#FF0000FF")

        #expect(service.items[1].itemKind == .presentation)
        #expect(service.items[1].refId == "pres-opener")
        #expect(service.items[1].arrangementId == "arr-1")

        #expect(service.items[2].itemKind == .media)
        #expect(service.items[2].refId.hasPrefix(ProDocumentMapper.placeholderPrefix))
        #expect(mapped.mediaWants.count == 1)

        #expect(mapped.services[0].warnings.contains { $0.contains("Missing") })
    }

    @Test func replacingMediaIDsResolvesDropsAndFlipsAudio() {
        let service = Service(id: "s", name: "S", serviceDate: "", items: [
            ServiceItem(id: "1", itemKind: .media, name: "Track", refId: "pro-media://a"),
            ServiceItem(id: "2", itemKind: .media, name: "Lost", refId: "pro-media://b"),
            ServiceItem(id: "3", itemKind: .presentation, name: "Song", refId: "pres-1"),
        ])
        let (resolved, warnings) = ProPlaylistMapper.replacingMediaIDs(
            service, with: ["pro-media://a": "audio-1"], audioIDs: ["audio-1"])
        #expect(resolved.items.count == 2)
        #expect(resolved.items[0].itemKind == .audio)
        #expect(resolved.items[0].refId == "audio-1")
        #expect(resolved.items[1].refId == "pres-1")
        #expect(warnings.count == 1)
    }

    @LibraryActor private func makeLibrary() throws -> Library {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return try Library(rootURL: root)
    }

    private func writePNG(to url: URL) throws {
        let image = NSImage(size: NSSize(width: 4, height: 4))
        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSRect(x: 0, y: 0, width: 4, height: 4).fill()
        image.unlockFocus()
        let tiff = image.tiffRepresentation!
        let png = NSBitmapImageRep(data: tiff)!.representation(using: .png, properties: [:])!
        try png.write(to: url)
    }

    private func minimalPresentation(id: String, name: String) -> RVData_Presentation {
        var doc = RVData_Presentation()
        doc.uuid = uuid(id)
        doc.name = name
        var graphics = RVData_Graphics.Element()
        graphics.uuid = uuid("EL-\(id)")
        graphics.opacity = 1
        var text = RVData_Graphics.Text()
        text.rtfData = Data("{\\rtf1\\ansi{\\fonttbl\\f0\\fnil Helvetica;}\\f0 Line}".utf8)
        graphics.text = text
        var element = RVData_Slide.Element()
        element.element = graphics
        var slide = RVData_Slide()
        slide.elements = [element]
        var presentationSlide = RVData_PresentationSlide()
        presentationSlide.baseSlide = slide
        var slideType = RVData_Action.SlideType()
        slideType.presentation = presentationSlide
        var action = RVData_Action()
        action.uuid = uuid("ACT-\(id)")
        action.actionTypeData = .slide(slideType)
        var cue = RVData_Cue()
        cue.uuid = uuid("CUE-\(id)")
        cue.actions = [action]
        doc.cues = [cue]
        return doc
    }

    @Test func workspaceImportBringsPlaylistsAsServices() async throws {
        let library = try await makeLibrary()
        let show = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let defaultLibrary = show.appendingPathComponent("Libraries/Default")
        try FileManager.default.createDirectory(at: defaultLibrary, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: show.appendingPathComponent("Playlists"), withIntermediateDirectories: true)

        let song = minimalPresentation(id: "PRES-1", name: "Opener")
        try (try song.serializedData()).write(to: defaultLibrary.appendingPathComponent("Opener.pro"))

        var item = presentationItem(
            id: "IT-1", name: "Opener",
            path: "/Users/original-machine/Show/Libraries/Default/Opener.pro")
        var local = RVData_URL.LocalRelativePath()
        local.path = "Libraries/Default/Opener.pro"
        var presentation = try #require({
            if case .presentation(let p) = item.itemType { return p } else { return nil }
        }())
        presentation.documentPath.relativeFilePath = .local(local)
        item.itemType = .presentation(presentation)

        let playlists = document(root: [playlistNode(id: "PL-1", name: "Sunday", items: [item])])
        try (try playlists.serializedData()).write(to: show.appendingPathComponent("Playlists/Library"))

        let importer = try await ProWorkspaceImporter(client: await started(library))
        var phases: [String] = []
        let result = await importer.importWorkspace(showDirectory: show) { phases.append($0.phase) }

        #expect(result.servicesImported == ["Sunday"])
        #expect(phases.contains("Presentations"))
        #expect(phases.contains("Playlists"))

        let service = try await library.open(Service.self, id: "pl-1").value
        #expect(service.name == "Sunday")
        #expect(service.items.count == 1)
        #expect(service.items[0].itemKind == .presentation)
        #expect(service.items[0].refId == "pres-1")
    }

    @Test func workspaceWithoutPlaylistsWarnsInsteadOfSilence() async throws {
        let library = try await makeLibrary()
        let show = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: show.appendingPathComponent("Libraries/Default"), withIntermediateDirectories: true)

        let importer = try await ProWorkspaceImporter(client: await started(library))
        let noFolder = await importer.importWorkspace(showDirectory: show)
        #expect(noFolder.servicesImported.isEmpty)
        #expect(noFolder.warnings.contains { $0.contains("no Playlists folder") })

        try FileManager.default.createDirectory(
            at: show.appendingPathComponent("Playlists"), withIntermediateDirectories: true)
        let noLibrary = await importer.importWorkspace(showDirectory: show)
        #expect(noLibrary.warnings.contains { $0.contains("no Playlists/Library document") })
    }

    @Test func playlistBundleImportsAsService() async throws {
        let library = try await makeLibrary()
        let importer = try ProPresenterImporter(client: await started(library))

        let stage = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let originalPro = "Users/test/Show/Libraries/Default/Opener.pro"
        let originalMedia = "Users/test/Show/Media/Assets/bumper.png"
        try FileManager.default.createDirectory(
            at: stage.appendingPathComponent(originalPro).deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: stage.appendingPathComponent(originalMedia).deletingLastPathComponent(),
            withIntermediateDirectories: true)

        let song = minimalPresentation(id: "PRES-9", name: "Opener")
        try (try song.serializedData()).write(to: stage.appendingPathComponent(originalPro))
        try writePNG(to: stage.appendingPathComponent(originalMedia))

        let playlists = document(root: [playlistNode(id: "PL-9", name: "Exported Set", items: [
            presentationItem(id: "IT-1", name: "Opener", path: "/" + originalPro),
            mediaCueItem(id: "IT-2", name: "Bumper", mediaPath: "/" + originalMedia),
        ])])
        try (try playlists.serializedData()).write(to: stage.appendingPathComponent("playlist.data"))

        let bundleURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).proPlaylist")
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-c", "-k", stage.path, bundleURL.path]
        try ditto.run()
        ditto.waitUntilExit()
        #expect(ditto.terminationStatus == 0)

        let summary = await importer.importPlaylistBundle(at: bundleURL)
        #expect(summary.failureReason == nil)
        #expect(summary.services == ["Exported Set"])
        #expect(summary.documents.count == 1)
        #expect(summary.mediaImported == 1)

        let service = try await library.open(Service.self, id: "pl-9").value
        #expect(service.items.count == 2)
        #expect(service.items[0].itemKind == .presentation)
        #expect(service.items[0].refId == "pres-9")
        #expect(service.items[1].itemKind == .media)
        #expect(!service.items[1].refId.hasPrefix(ProDocumentMapper.placeholderPrefix))
    }
}
