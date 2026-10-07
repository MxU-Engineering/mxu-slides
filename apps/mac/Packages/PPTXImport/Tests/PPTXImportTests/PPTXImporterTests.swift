import AppKit
import Foundation
import Testing
import PresenterCore
@testable import PPTXImport

@MainActor
struct PPTXImporterTests {

    @LibraryActor private func makeLibrary() throws -> Library {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return try Library(rootURL: root)
    }

    private func writePNG(to url: URL) throws {
        let image = NSImage(size: NSSize(width: 4, height: 4))
        image.lockFocus()
        NSColor.systemRed.setFill()
        NSRect(x: 0, y: 0, width: 4, height: 4).fill()
        image.unlockFocus()
        let tiff = image.tiffRepresentation!
        let png = NSBitmapImageRep(data: tiff)!.representation(using: .png, properties: [:])!
        try png.write(to: url)
    }

    private func makeDeck(at pptxURL: URL) throws {
        let stage = FileManager.default.temporaryDirectory
            .appendingPathComponent("pptx-stage-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: stage) }

        let parts: [String: String] = [
            "[Content_Types].xml": """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
              <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
              <Default Extension="xml" ContentType="application/xml"/>
              <Default Extension="png" ContentType="image/png"/>
              <Override PartName="/ppt/presentation.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml"/>
              <Override PartName="/ppt/slides/slide1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slide+xml"/>
            </Types>
            """,
            "_rels/.rels": """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
              <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="ppt/presentation.xml"/>
            </Relationships>
            """,
            "ppt/presentation.xml": """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <p:presentation xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"
                            xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
              <p:sldIdLst><p:sldId id="256" r:id="rId2"/></p:sldIdLst>
              <p:sldSz cx="12192000" cy="6858000"/>
            </p:presentation>
            """,
            "ppt/_rels/presentation.xml.rels": """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
              <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide" Target="slides/slide1.xml"/>
            </Relationships>
            """,
            "ppt/slides/slide1.xml": """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <p:sld xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"
                   xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"
                   xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
              <p:cSld>
                <p:spTree>
                  <p:sp>
                    <p:nvSpPr><p:cNvPr id="2" name="Title"/><p:cNvSpPr/><p:nvPr/></p:nvSpPr>
                    <p:spPr>
                      <a:xfrm><a:off x="914400" y="457200"/><a:ext cx="1828800" cy="914400"/></a:xfrm>
                      <a:prstGeom prst="rect"/>
                    </p:spPr>
                    <p:txBody>
                      <a:bodyPr/>
                      <a:p><a:r><a:rPr sz="4000"><a:latin typeface="Helvetica"/></a:rPr><a:t>Hello glass</a:t></a:r></a:p>
                    </p:txBody>
                  </p:sp>
                  <p:pic>
                    <p:nvPicPr><p:cNvPr id="3" name="Picture 1"/><p:cNvPicPr/><p:nvPr/></p:nvPicPr>
                    <p:blipFill><a:blip r:embed="rId2"/><a:srcRect l="25000" r="25000"/></p:blipFill>
                    <p:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="914400" cy="914400"/></a:xfrm></p:spPr>
                  </p:pic>
                </p:spTree>
              </p:cSld>
            </p:sld>
            """,
            "ppt/slides/_rels/slide1.xml.rels": """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
              <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="../media/image1.png"/>
            </Relationships>
            """,
        ]
        for (path, contents) in parts {
            let url = stage.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: url)
        }
        let mediaURL = stage.appendingPathComponent("ppt/media/image1.png")
        try FileManager.default.createDirectory(at: mediaURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try writePNG(to: mediaURL)

        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-c", "-k", stage.path, pptxURL.path]
        try ditto.run()
        ditto.waitUntilExit()
        #expect(ditto.terminationStatus == 0)
    }

    @Test func importsADeckAndReimportReplacesInPlace() async throws {
        let library = try await makeLibrary()
        let importer = try PPTXImporter(client: await started(library))
        let pptxURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).pptx")
        defer { try? FileManager.default.removeItem(at: pptxURL) }
        try makeDeck(at: pptxURL)

        let summaries = await importer.importItems(at: [pptxURL])
        #expect(summaries.count == 1)
        let summary = try #require(summaries.first)
        #expect(summary.presentationID != nil)
        #expect(summary.mediaImported == 1)
        #expect(summary.warnings.isEmpty)
        #expect(summary.missingFonts.isEmpty)  

        let imported = try await library.open(Presentation.self, id: summary.presentationID!).value
        #expect(imported.name == pptxURL.deletingPathExtension().lastPathComponent)
        #expect(imported.folder == "PowerPoint Import")
        #expect(imported.presentationKind == .deck)
        #expect(imported.canvasWidth == nil)  
        #expect(imported.slides.count == 1)
        let objects = imported.slides[0].objects
        #expect(objects.count == 2)
        #expect(objects[0].objectKind == .text)
        #expect(objects[0].text == "Hello glass")
        #expect(objects[0].textStyle?.fontSize == 80)
        #expect(objects[1].objectKind == .shape)
        #expect(objects[1].fill?.fillKind == .media)
        #expect(objects[1].fill?.mediaId?.hasPrefix(PPTXDocumentMapper.placeholderPrefix) == false)
        #expect(objects[1].fill?.mediaSourceRect == MediaSourceRect(x: 0.25, y: 0, width: 0.5, height: 1))

        let again = await importer.importItems(at: [pptxURL])
        #expect(again.first?.presentationID == summary.presentationID)
        #expect(again.first?.mediaImported == 0)
        #expect(((try? await library.index.entries(of: .presentation)) ?? []).count == 1)
        #expect(((try? await library.index.entries(of: .media)) ?? []).count == 1)
    }

    @Test func legacyPPTIsRefusedWithGuidance() async throws {
        let library = try await makeLibrary()
        let importer = try PPTXImporter(client: await started(library))
        let pptURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).ppt")
        defer { try? FileManager.default.removeItem(at: pptURL) }
        try Data("old binary format".utf8).write(to: pptURL)

        let summaries = await importer.importItems(at: [pptURL])
        let summary = try #require(summaries.first)
        #expect(summary.presentationID == nil)
        #expect(summary.warnings == ["legacy .ppt is not supported — open it in PowerPoint and save as .pptx"])
    }

    @Test func garbageFileIsSkippedWithReason() async throws {
        let library = try await makeLibrary()
        let importer = try PPTXImporter(client: await started(library))
        let garbage = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).pptx")
        defer { try? FileManager.default.removeItem(at: garbage) }
        try Data("not a zip at all".utf8).write(to: garbage)

        let summaries = await importer.importItems(at: [garbage])
        let summary = try #require(summaries.first)
        #expect(summary.presentationID == nil)
        #expect(summary.warnings.first?.contains("not a readable PowerPoint document") == true)
    }

    @Test func aPlacedImportLandsTheDeckAndItsMediaInTheDrive() async throws {
        let library = try await makeLibrary()
        let client = try await started(library)
        let placement = LibraryHome.Placement.drive(viewing: .init(kind: .presentation, area: .team, path: "Sermons"))
        let importer = try PPTXImporter(client: client, placement: placement)
        let pptxURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).pptx")
        defer { try? FileManager.default.removeItem(at: pptxURL) }
        try makeDeck(at: pptxURL)

        let summary = try #require(await importer.importItems(at: [pptxURL], folder: placement.folder(for: .presentation)).first)
        let deckID = try #require(summary.presentationID)
        let snapshot = try await client.settledSnapshot()
        let media = try #require(snapshot.entries(of: .media).first)
        #expect(try await client.loadValue(Presentation.self, id: deckID).folder == "Sermons")
        #expect(try await client.loadValue(MediaItem.self, id: media.id).folder == LibraryHome.needsSorted)
        #expect(snapshot.area(kind: .presentation, id: deckID) == .team && snapshot.area(kind: .media, id: media.id) == .team)
    }
}
