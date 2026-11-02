import AppKit
import Foundation
import Testing
@testable import PresenterCore

struct NoteFileReaderTests {
    static func notes() -> NSAttributedString {
        let text = NSMutableAttributedString()
        func add(_ string: String, size: CGFloat = 12, bold: Bool = false, underline: Bool = false, list: NSTextList? = nil, newline: Bool = true) {
            var attributes: [NSAttributedString.Key: Any] = [
                .font: bold ? NSFont(name: "Helvetica-Bold", size: size)! : NSFont(name: "Helvetica", size: size)!,
            ]
            let style = NSMutableParagraphStyle()
            style.paragraphSpacing = 8
            if let list { style.textLists = [list]; style.headIndent = 36 }
            attributes[.paragraphStyle] = style
            if underline { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
            text.append(NSAttributedString(string: string + (newline ? "\n" : ""), attributes: attributes))
        }
        add("Unshakable", size: 24, bold: true)
        add("When everything shakes")
        let bullets = NSTextList(markerFormat: .disc, options: 0)
        add("\t•\tGod is our refuge", bold: true, list: bullets)
        add("\t•\tGod is our strength", bold: true, list: bullets)
        add("Psalm 46:1-2")
        add("1 God is our refuge and strength, an ever-present help in trouble. 2 Therefore we will not fear, though the earth give way and the mountains fall into the heart of the sea.")
        add("“Faith is not the absence of fear, but trusting God in the middle of it.” — Corrie ten Boom")
        add("Next step: ", bold: true, newline: false)
        add("Trust", underline: true, newline: false)
        add(" him with one fear this week.")
        return text
    }

    static func temporaryFile(_ name: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("note-files-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent(name)
    }

    static func marks(_ body: NoteBody) -> [String] {
        NoteSlideMarks.groups(in: NoteSlideMarks.suggesting(body)).map { "\($0.type ?? "body"): \($0.text)" }
    }

    @Test func aWordFileAndItsPDFImportToTheSameMarks() throws {
        let notes = Self.notes()
        let url = try Self.temporaryFile("Unshakable.docx")
        try notes.data(from: NSRange(location: 0, length: notes.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML])
            .write(to: url)

        let word = try #require(NoteFileReader.body(ofFile: url))
        let pdf = NoteFileReader.body(pdf: Self.pdf(notes, width: 300))

        #expect(pdf == word)
        #expect(word.blocks.map(\.type) == [.heading, .paragraph, .list, .paragraph, .paragraph, .paragraph, .paragraph])
        #expect(word.blocks[2].items?.map { NoteReading.text(of: $0.runs) } == ["God is our refuge", "God is our strength"])
        #expect(word.blocks.last?.runs == [
            NoteRun(text: "Next step: ", bold: true), NoteRun(text: "Trust ", underline: true),
            NoteRun(text: "him with one fear this week."),
        ])
        #expect(Self.marks(pdf) == Self.marks(word))
        #expect(Self.marks(word).contains { $0.hasPrefix("scripture: Psalm 46:1-2\n1 God is our refuge") })
    }

    @Test func aListWrittenAsTabbedMarkersIsAList() {
        let bold = [NSAttributedString.Key.font: NSFont(name: "Helvetica-Bold", size: 12)!]
        let text = NSMutableAttributedString(string: "Intro: the earthquake\n", attributes: [.font: NSFont(name: "Helvetica", size: 12)!])
        text.append(NSAttributedString(string: "\t1\tEverything that can be shaken will be shaken\n\t2\tWhat God builds can’t be shaken\n\t3\tSo we worship with reverence and awe", attributes: bold))
        let body = NoteFileReader.body(attributed: text)
        #expect(body.blocks.map(\.type) == [.paragraph, .list])
        #expect(body.blocks[1].ordered == true)
        #expect(body.blocks[1].items?.map { NoteReading.text(of: $0.runs) } == [
            "Everything that can be shaken will be shaken", "What God builds can’t be shaken", "So we worship with reverence and awe",
        ])
        #expect(Self.marks(body) == ["points: Everything that can be shaken will be shaken\nWhat God builds can’t be shaken\nSo we worship with reverence and awe"])
    }

    @Test func wrappedPDFLinesJoinIntoTheirParagraph() {
        let verse = NSAttributedString(string: "1 God is our refuge and strength, an ever-present help in trouble. 2 Therefore we will not fear.\nSelah\n",
                                       attributes: [.font: NSFont(name: "Helvetica", size: 12)!])
        let body = NoteFileReader.body(pdf: Self.pdf(verse, width: 160))
        #expect(body.plainText == "1 God is our refuge and strength, an ever-present help in trouble. 2 Therefore we will not fear.\nSelah")
    }

    @Test(arguments: [("rtf", NSAttributedString.DocumentType.rtf), ("odt", .openDocument), ("docx", .officeOpenXML)])
    func richTextFilesKeepBoldAndUnderline(_ type: (String, NSAttributedString.DocumentType)) throws {
        let text = NSMutableAttributedString(string: "Big idea ", attributes: [.font: NSFont(name: "Helvetica-Bold", size: 12)!])
        text.append(NSAttributedString(string: "trust", attributes: [.font: NSFont(name: "Helvetica", size: 12)!, .underlineStyle: NSUnderlineStyle.single.rawValue]))
        let url = try Self.temporaryFile("notes.\(type.0)")
        try text.data(from: NSRange(location: 0, length: text.length), documentAttributes: [.documentType: type.1]).write(to: url)

        let body = try #require(NoteFileReader.body(ofFile: url))
        #expect(body.blocks.first?.runs == [NoteRun(text: "Big idea ", bold: true), NoteRun(text: "trust", underline: true)])
    }

    @Test func plainTextLinesBecomeParagraphsAndTypedLists() {
        let body = NoteFileReader.body(text: "Unshakable\n\n- God is our refuge\n- God is\tour strength\n1. Trust\n2) Rest\n")
        #expect(body.blocks.map(\.type) == [.paragraph, .list, .list])
        #expect(body.blocks[1].ordered == false)
        #expect(body.blocks[2].ordered == true)
        #expect(body.plainText == "Unshakable\nGod is our refuge\nGod is our strength\nTrust\nRest")
    }

    @Test func filesWithNoWordsOrOfAnotherKindAreNotRead() throws {
        let empty = try Self.temporaryFile("empty.txt")
        try Data().write(to: empty)
        let pages = try Self.temporaryFile("notes.pages")
        try Data("x".utf8).write(to: pages)
        #expect(NoteFileReader.body(ofFile: empty) == nil)
        #expect(NoteFileReader.body(ofFile: pages) == nil)
    }

    static func pdf(_ text: NSAttributedString, width: CGFloat) -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let consumer = CGDataConsumer(data: data as CFMutableData)!
        let context = CGContext(consumer: consumer, mediaBox: &box, nil)!
        let storage = NSTextStorage(attributedString: text)
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: width, height: 10_000))
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        context.beginPDFPage(nil)
        context.translateBy(x: 0, y: 792)
        context.scaleBy(x: 1, y: -1)
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        let range = layout.glyphRange(for: container)
        layout.drawBackground(forGlyphRange: range, at: CGPoint(x: 72, y: 72))
        layout.drawGlyphs(forGlyphRange: range, at: CGPoint(x: 72, y: 72))
        NSGraphicsContext.current = previous
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }
}
