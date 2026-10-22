import Foundation
import Testing

@Suite struct MediaReplaceSweepTests {
    private var appSources: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources", isDirectory: true)
    }

    private func source(_ name: String) throws -> String {
        try String(contentsOf: appSources.appendingPathComponent(name), encoding: .utf8)
    }

    @Test func theInspectorShowsThePickWithBothVerbs() throws {
        let inspector = try source("SlideObjectInspector.swift")
        #expect(inspector.components(separatedBy: "MediaPickCard(").count == 3, "Media and Background sections")
        #expect(!inspector.contains("systemName: \"pencil\""), "no 9pt pencil")
        let card = try source("MediaPickCard.swift")
        #expect(card.contains("Button(\"Replace…\", action: onReplace)"))
        #expect(card.contains("Button(\"Edit Media…\") {\n                    model.openInEditor(entryID: mediaID)"))
        #expect(!(try source("ActionEditors.swift")).contains("systemName: \"pencil\""))
    }

    @Test func quickMediaSurfacesOpenTheEditorAndTheFile() throws {
        let menu = try source("MediaCueMenu.swift")
        #expect(menu.contains("Button(\"Media Settings…\") { state.settingsTargetID = mediaID }\n            MediaEditorDoors(model: model, mediaID: mediaID, item: item)"))
        #expect(menu.contains("model.openInEditor(entryID: mediaID)\n            UserDefaults.standard.set(AppMode.edit.rawValue, forKey: \"appMode\")"))
        #expect(menu.contains("NSWorkspace.shared.activateFileViewerSelecting([url])"))
        let popup = try source("InspectorView.swift")
        #expect(popup.contains("MediaEditorDoors(model: model, mediaID: mediaID, item: item) { dismiss() }"), "the popup closes before the mode flips")
        let planner = try source("ServicePlannerView.swift")
        #expect(planner.contains("entry.kind.opensInEditor, item.itemKind != .media {"), "media rows don't show Edit twice")
    }

    @Test func mediaPickersSearchOrImportANewItem() throws {
        let picker = try source("SlideEditorView.swift")
        #expect(picker.contains("Label(\"Search Media\", systemImage: \"magnifyingglass\").tag(Tab.search)"))
        #expect(picker.contains("Label(\"Import from Disk\", systemImage: \"square.and.arrow.down\").tag(Tab.importFile)"))
        #expect(picker.contains("if let entry = await appModel.importMediaForPick(urls, placement: placement) {\n                    onPick(entry)"))
        #expect(!picker.contains("replaceMediaFile("), "a pick never swaps an item's file")
    }

    @Test func replaceMediaFileConfirmsWhereItIsUsed() throws {
        for name in ["MediaEditorView.swift", "LibraryView.swift"] {
            let file = try source(name)
            #expect(file.contains("ReplaceMediaFileFlow.start(model: model, id:"), "\(name) asks first")
            #expect(file.contains("ReplaceMediaFileSheet(request: request)"), "\(name) shows the list")
            #expect(!file.contains("model.replaceMediaFile("), "\(name) swaps only through the flow")
        }
        let flow = try source("ReplaceMediaFileFlow.swift")
        #expect(flow.contains("let groups = MediaUsage.groups(await model.mediaUses(of: id))"))
        #expect(flow.contains("if groups.isEmpty {\n                chooseFile("))
    }

    @Test func aFileSwapReloadsWhatShowsTheOldPicture() throws {
        let app = try source("AppModel.swift")
        #expect(app.contains("&& MediaUsage.fileChanged(from: held as? MediaItem, to: change.value as? MediaItem)"))
        #expect(app.contains("ThumbnailStore.shared.mediaFileChanged()"))
        let thumbs = try source("ThumbnailStore.swift")
        #expect(thumbs.contains("if thumbStillIsCurrent(stillID, mediaID: id, pixelWidth: pixelWidth, render: render, model: model) {"),
                "a tile still made from the old file uploads again")
        #expect(thumbs.contains("thumbStillKeys[stillID] = key"))
        #expect(thumbs.contains("guard let image = frame?.cgImage, mediaFilesAtBuild == mediaFilesGeneration else { return }"),
                "a render begun before the swap is never cached")
        #expect(try source("ServiceControls.swift").contains("appModel.observeMediaFileChanges(self) { [weak self] id in\n            self?.reloadLiveMedia(id)"))
        #expect(try source("SlideEditorModel.swift").contains("appModel.stopObservingMediaFileChanges(self)"))
    }

    @Test func keepBothNamesAndTheDateAddedShows() throws {
        let app = try source("AppModel.swift")
        #expect(app.contains("copyName = useExisting ? nil : numbered"))
        #expect(app.contains("at: [url], placement: placement ?? newPlacement, names: copyName.map { [url: $0] } ?? [:]"))
        #expect(app.contains("$0.importedAt = Date().timeIntervalSince1970"), "a Duplicate is added now")
        #expect(try source("MediaEditorView.swift").contains("LabeledContent(\"Added\", value: Date(timeIntervalSince1970: added)"))
        let picker = try source("SlideEditorView.swift")
        #expect(picker.contains("@AppStorage(MediaPickerSort.defaultsKey) private var sort: MediaPickerSort = .bestMatch"))
        #expect(picker.contains("return order.ordered(entries, typed: typed, addedAt: appModel.mediaAddedAt)"))
        #expect(picker.contains("Text(\"Added \\(added.formatted(date: .abbreviated, time: .omitted))\")"))
        let library = try source("LibraryView.swift")
        #expect(library.contains("ForEach(LibrarySort.choices(for: section.kind), id: \\.self)"))
        #expect(library.contains(".merged(items, cloud: cloud, addedAt: model.mediaAddedAt)"))
    }

    @Test func importsAskWithAPictureAndNeverSwapAFile() throws {
        let app = try source("AppModel.swift")
        let start = try #require(app.range(of: "func importFiles(_ urls: [URL], placement: LibraryHome.Placement? = nil) async -> [String] {"))
        let end = try #require(app.range(of: "func importMediaForPick(", range: start.upperBound..<app.endIndex))
        let body = String(app[start.upperBound..<end.lowerBound])
        #expect(!body.contains("replaceMediaFile(") && !body.contains("replaceAudioFile("))
        #expect(body.contains("case .sameFile(let id): (id, media(id)?.name ?? audio(id)?.name ?? name, .sameFile)"))
        #expect(body.contains("let answer = await MediaImportPrompt.ask("))
        let prompt = try source("MediaImportPrompt.swift")
        #expect(prompt.contains("Button(\"Add as New Copy\") { finish(0) }"))
        #expect(prompt.contains("Button(\"Use Existing\") { finish(1) }\n                    .keyboardShortcut(.defaultAction)"))
        #expect(prompt.contains("PosterImage(model: model, mediaId: id)"), "the library item's picture")
        #expect(prompt.contains(".task(id: url) { image = await ThumbnailStore.filePoster(url: url) }"), "the new file's picture")
        #expect(prompt.contains("parent.beginSheet(sheet)"), "a sheet, never a modal loop over a drop")
        let flow = try source("ReplaceMediaFileFlow.swift")
        #expect(flow.contains("let panel = NSOpenPanel()"), "Replace Media File goes straight to disk")
        #expect(!flow.contains("LibraryPickerSheet"))
        #expect(flow.contains("let other = hash.flatMap { model.mediaHolding(file: $0, except: id) }"))
        #expect(flow.contains("if proceed, let carried = await model.replaceMediaFile(id, with: url) {"))
    }
}
