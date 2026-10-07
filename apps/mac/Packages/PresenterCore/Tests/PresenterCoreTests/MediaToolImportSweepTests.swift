import Foundation
import Testing

@Suite struct MediaToolImportSweepTests {
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

    @Test func theMediaToolImportsIntoThePickedFolder() throws {
        let editor = try source("SlideEditorView.swift")
        #expect(editor.contains("""
            onImportMedia: { placement in
                                MediaFilePicker.choose { urls in
                                    model.importMediaObjects(urls, placement: placement)
            """), "the media tool's picker imports from disk through the shared open panel")
        #expect(try source("SlideEditorModel.swift").contains(
            "for id in await appModel.importFiles(urls, placement: placement) {\n"
            + "                addMediaObject(mediaID: id, name: appModel.media(id)?.name ?? \"\")"),
            "each import lands as the tool's media object")
    }

    @Test func thePickerSaysWhereTheImportLands() throws {
        let editor = try source("SlideEditorView.swift")
        #expect(editor.contains("if onImportMedia != nil, activeKind == .media {\n                importDestination"))
        #expect(editor.contains("Text(\"Saves to Media ›\")"))
        #expect(editor.contains("Set(appModel.driveFolders(in: .media) + [current])"), "Make Slides' Drive folder list, plus the default")
        #expect(editor.contains("?? LibraryHome.folder(for: .media, named: nil, viewing: appModel.viewedLibraryFolder)"),
                "starts where new media lands today")
        #expect(editor.contains(".drive(viewing: .init(kind: .media, area: .team, path: currentImportFolder))"))
        #expect(editor.contains("let placement = importPlacement\n                        dismiss()\n                        onImportMedia(placement)"))
    }
}
