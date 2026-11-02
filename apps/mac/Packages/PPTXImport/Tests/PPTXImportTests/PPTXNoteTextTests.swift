import Foundation
import PresenterCore
import Testing
@testable import PPTXImport

struct PPTXNoteTextTests {
    @Test func aDeckReadsAsNotesTitleFirstWithBoldAndUnderlineKept() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("notes-\(UUID().uuidString).pptx")
        defer { try? FileManager.default.removeItem(at: url) }
        try makeDeck(at: url)

        let body = try PPTXNoteText.body(ofFile: url)

        #expect(body.blocks.map(\.type) == [.heading, .paragraph, .paragraph])
        #expect(body.blocks[0].level == 2)
        #expect(body.plainText == "Unshakable\nGod is our refuge\nTrust him this week")
        #expect(body.blocks[1].runs == [NoteRun(text: "God is our refuge", bold: true)])
        #expect(body.blocks[2].runs == [NoteRun(text: "Trust ", underline: true), NoteRun(text: "him this week")])
    }

    private func makeDeck(at pptxURL: URL) throws {
        let stage = FileManager.default.temporaryDirectory.appendingPathComponent("pptx-notes-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: stage) }
        let parts: [String: String] = [
            "[Content_Types].xml": """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
              <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
              <Default Extension="xml" ContentType="application/xml"/>
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
                    <p:nvSpPr><p:cNvPr id="3" name="Body"/><p:cNvSpPr/><p:nvPr/></p:nvSpPr>
                    <p:spPr><a:xfrm><a:off x="914400" y="2000000"/><a:ext cx="6000000" cy="3000000"/></a:xfrm></p:spPr>
                    <p:txBody>
                      <a:bodyPr/>
                      <a:p><a:r><a:rPr b="1"/><a:t>God is our refuge</a:t></a:r></a:p>
                      <a:p><a:r><a:rPr u="sng"/><a:t>Trust</a:t></a:r><a:r><a:rPr/><a:t> him this week</a:t></a:r></a:p>
                    </p:txBody>
                  </p:sp>
                  <p:sp>
                    <p:nvSpPr><p:cNvPr id="2" name="Title 1"/><p:cNvSpPr/><p:nvPr><p:ph type="title"/></p:nvPr></p:nvSpPr>
                    <p:spPr><a:xfrm><a:off x="914400" y="457200"/><a:ext cx="6000000" cy="914400"/></a:xfrm></p:spPr>
                    <p:txBody><a:bodyPr/><a:p><a:r><a:t>Unshakable</a:t></a:r></a:p></p:txBody>
                  </p:sp>
                </p:spTree>
              </p:cSld>
            </p:sld>
            """,
        ]
        for (path, contents) in parts {
            let url = stage.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: url)
        }
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-c", "-k", stage.path, pptxURL.path]
        try ditto.run()
        ditto.waitUntilExit()
        #expect(ditto.terminationStatus == 0)
    }
}
