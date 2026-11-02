import AppKit
import Foundation
import Testing
@testable import PresenterCore

struct NoteFileMediaTests {
    static func png(_ color: NSColor = .systemTeal, width: Int = 80, height: Int = 60) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        for x in 0..<width { for y in 0..<height { rep.setColor(color, atX: x, y: y) } }
        return rep.representation(using: .png, properties: [:])!
    }

    static func saver() throws -> NoteFileReader.SaveMedia {
        let folder = try NoteFileReaderTests.temporaryFile("media")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return { data, name in
            let url = folder.appendingPathComponent("\(UUID().uuidString)-\(name)")
            return (try? data.write(to: url)).map { url.absoluteString }
        }
    }

    static func attachment(_ data: Data, named name: String) -> NSAttributedString {
        let wrapper = FileWrapper(regularFileWithContents: data)
        wrapper.preferredFilename = name
        return NSAttributedString(attachment: NSTextAttachment(fileWrapper: wrapper))
    }

    @Test func aBrowsersCopyKeepsHeadingsBoldAndLists() throws {
        let html = "<h2>Pasted heading</h2><p>Some <b>bold</b> words.</p><ul><li>First point</li><li>Second point</li></ul>"
        let pasted = try NSAttributedString(
            data: Data(html.utf8), options: [.documentType: NSAttributedString.DocumentType.html, .characterEncoding: String.Encoding.utf8.rawValue],
            documentAttributes: nil)
        let body = NoteFileReader.body(attributed: pasted)
        #expect(body.blocks.map(\.type) == [.heading, .paragraph, .list])
        #expect(body.blocks[1].runs?.contains { $0.text.trimmingCharacters(in: .whitespaces) == "bold" && $0.bold == true } == true)
        #expect(body.blocks[2].items?.map { NoteReading.text(of: $0.runs) } == ["First point", "Second point"])
    }

    @Test func droppedFilesBecomeTheirBlocks() throws {
        let save = try Self.saver()
        let picture = try NoteFileReaderTests.temporaryFile("Stage.png")
        try Self.png().write(to: picture)
        let video = try NoteFileReaderTests.temporaryFile("Walkthrough.mp4")
        try Data("mp4".utf8).write(to: video)
        let pdf = try NoteFileReaderTests.temporaryFile("Bulletin.pdf")
        try Data("%PDF".utf8).write(to: pdf)
        #expect(NoteFileReader.mediaBlock(file: picture, save: save)?.type == .image)
        let clip = try #require(NoteFileReader.mediaBlock(file: video, save: save))
        #expect(clip.attachmentKind == "video" && clip.filename == "Walkthrough.mp4")
        #expect(NoteFileReader.mediaBlock(file: pdf, save: save) == nil)
    }

    @Test func aPastesPicturesAndVideosBecomeTheirOwnBlocks() throws {
        let text = NSMutableAttributedString(string: "Slide 1: Welcome ")
        text.append(Self.attachment(Self.png(), named: "Screenshot.png"))
        text.append(NSAttributedString(string: "\n"))
        text.append(Self.attachment(Data("mp4".utf8), named: "Snoop.mp4"))
        text.append(NSAttributedString(string: "\n"))
        text.append(Self.attachment(Data("%PDF".utf8), named: "Bulletin.pdf"))
        text.append(Self.attachment(Self.png(width: 16, height: 16), named: "icon_10_generic_list.png"))
        text.append(NSAttributedString(string: "\nSlide 2: Thanks"))

        let body = NoteFileReader.body(attributed: text, save: try Self.saver())
        #expect(body.blocks.map(\.type) == [.paragraph, .image, .attachment, .paragraph])
        #expect(NoteReading.text(of: body.blocks[0]) == "Slide 1: Welcome")
        let picture = try #require(body.blocks[1].url.flatMap(URL.init(string:)))
        #expect(try Data(contentsOf: picture) == Self.png())
        #expect(body.blocks[2].attachmentKind == "video")
        #expect(body.blocks[2].filename == "Snoop.mp4")
        #expect(body.blocks[2].url?.hasSuffix("Snoop.mp4") == true)
        #expect(NoteMedia.blocks(in: body).count == 2)

        #expect(NoteFileReader.body(attributed: text).blocks.map(\.type) == [.paragraph, .paragraph])
    }

    @Test func aDriveChipsVideoLinkBecomesAVideoSlide() throws {
        let drive = "https://drive.google.com/file/d/1dLx/view"
        let text = NSMutableAttributedString(string: "Slide 2:\n(Snoop Dogg video - attached)\n")
        let chip = NSMutableAttributedString(attributedString: Self.attachment(Self.png(width: 16, height: 16), named: "icon.png"))
        chip.append(NSAttributedString(string: " Snoop.mp4"))
        chip.addAttribute(.link, value: URL(string: drive)!, range: NSRange(location: 0, length: chip.length))
        text.append(chip)
        let body = NoteFileReader.body(attributed: text, save: try Self.saver())
        #expect(body.blocks.last?.runs?.contains { $0.href == drive } == true)
        let groups = NoteSlideMarks.groups(in: NoteSlideMarks.suggesting(body))
        #expect(groups.map(\.type) == ["video"])
        #expect(groups.first?.links == [drive])
    }

    @MainActor @Test func mailsHTMLKeepsTheChipsLinkAndDropsItsIcon() throws {
        let drive = "https://drive.google.com/file/d/1dLx3hIMY3SqLjEkvp1nuP9tWoYIwroSw/view?usp=drive_web"
        let html = """
        <div>Slide 2:</div><div>(Snoop Dogg video - attached)</div>
        <div style="border: 1px solid rgb(221, 221, 221);"><a href="\(drive)" aria-label="Snoop.mp4"><img alt="" \
        src="https://ssl.gstatic.com/docs/doclist/images/icon_10_generic_list.png" style="height: 20px;"> \
        <span dir="ltr">Snoop.mp4</span></a></div><br>
        <div>Slide 10: (photo attached)</div>
        <div><img src="cid:ii_mvikieid0" alt="Screenshot.png" width="482" class="Apple-web-attachment"></div>
        """
        let text = try NSAttributedString(data: Data(html.utf8), options: [
            .documentType: NSAttributedString.DocumentType.html, .characterEncoding: String.Encoding.utf8.rawValue,
        ], documentAttributes: nil)
        let body = NoteFileReader.body(attributed: text, save: try Self.saver())
        #expect(!body.blocks.contains { $0.type == .image })
        let chip = try #require(body.blocks.first { NoteReading.text(of: $0) == "Snoop.mp4" })
        #expect(chip.runs?.contains { $0.href == drive } == true)
    }

    @Test func aMarkerNotesEmptyLinesEndItsSlides() throws {
        let text = NSMutableAttributedString(string: "Slide 2: Baptism recap\n")
        text.append(Self.attachment(Data("mp4".utf8), named: "Recap.mp4"))
        text.append(NSAttributedString(string: "\n\n\nI'll tell Sarah's story here.\n\nSlide 3: Go and do likewise.\n\n"))
        let body = NoteFileReader.body(attributed: text, save: try Self.saver())
        #expect(body.blocks.map(\.type) == [.paragraph, .attachment, .paragraph, .paragraph, .paragraph, .paragraph])
        #expect(body.blocks[2].runs == [] && body.blocks[4].runs == [])
        let groups = NoteSlideMarks.groups(in: NoteSlideMarks.suggesting(body))
        #expect(groups.map(\.text) == ["Baptism recap", "", "Go and do likewise."])

        let plain = NoteFileReader.body(attributed: NSAttributedString(string: "1. Grace\n\n2. Truth\n"))
        #expect(plain.blocks.count == 1, "no markers: empty lines go, the points stay one list")
    }

    @Test func aWordFilesPicturesStayAfterTheirParagraph() throws {
        let folder = try NoteFileReaderTests.temporaryFile("docx")
        let files: [String: Data] = [
            "[Content_Types].xml": Data("""
            <?xml version="1.0" encoding="UTF-8"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
            <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
            <Default Extension="xml" ContentType="application/xml"/><Default Extension="png" ContentType="image/png"/>\
            <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/></Types>
            """.utf8),
            "_rels/.rels": Data("""
            <?xml version="1.0" encoding="UTF-8"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
            <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>
            """.utf8),
            "word/_rels/document.xml.rels": Data("""
            <?xml version="1.0" encoding="UTF-8"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
            <Relationship Id="rId5" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="media/image1.png"/></Relationships>
            """.utf8),
            "word/document.xml": Data("""
            <?xml version="1.0" encoding="UTF-8"?><w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" \
            xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><w:body>\
            <w:p><w:r><w:t>Unshakable</w:t></w:r></w:p>\
            <w:p><w:r><w:drawing><a:graphic><a:graphicData><a:blip r:embed="rId5"/></a:graphicData></a:graphic></w:drawing></w:r></w:p>\
            <w:p><w:r><w:t>God is our refuge</w:t></w:r></w:p></w:body></w:document>
            """.utf8),
            "word/media/image1.png": Self.png(),
        ]
        for (path, data) in files {
            let url = folder.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
        let docx = folder.deletingLastPathComponent().appendingPathComponent("Unshakable.docx")
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        zip.arguments = ["-c", "-k", folder.path, docx.path]
        try zip.run()
        zip.waitUntilExit()

        let body = try #require(NoteFileReader.body(ofFile: docx, save: try Self.saver()))
        #expect(body.blocks.map(\.type) == [.heading, .image, .paragraph] || body.blocks.map(\.type) == [.paragraph, .image, .paragraph])
        #expect(try Data(contentsOf: #require(body.blocks[1].url.flatMap(URL.init(string:)))) == Self.png())
        #expect(NoteFileReader.body(ofFile: docx)?.blocks.contains { $0.type == .image } == false)
    }

    @Test func aPDFsPictureStaysWhereThePageDrawsIt() throws {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = CGContext(consumer: CGDataConsumer(data: data as CFMutableData)!, mediaBox: &box, nil)!
        context.beginPDFPage(nil)
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        let font = [NSAttributedString.Key.font: NSFont(name: "Helvetica", size: 12)!]
        NSAttributedString(string: "Above the picture", attributes: font).draw(at: CGPoint(x: 72, y: 700))
        NSAttributedString(string: "Below the picture", attributes: font).draw(at: CGPoint(x: 72, y: 300))
        NSGraphicsContext.current = previous
        let image = NSBitmapImageRep(data: Self.png())!.cgImage!
        context.draw(image, in: CGRect(x: 72, y: 400, width: 200, height: 150))
        context.draw(image, in: CGRect(x: 72, y: 250, width: 10, height: 10))
        context.endPDFPage()
        context.closePDF()

        let body = NoteFileReader.body(pdf: data as Data, save: try Self.saver())
        #expect(body.blocks.map(\.type) == [.paragraph, .image, .paragraph])
        #expect(NoteReading.text(of: body.blocks[2]) == "Below the picture")
        #expect(NoteFileReader.body(pdf: data as Data).blocks.map(\.type) == [.paragraph, .paragraph])
    }
}
