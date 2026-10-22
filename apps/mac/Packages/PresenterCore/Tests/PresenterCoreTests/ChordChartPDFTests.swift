import CoreGraphics
import CoreText
import Foundation
import Testing

@testable import PresenterCore

struct ChordChartPDFTests {
    @Test func aTwoColumnChartBecomesChordProWithItsKeyAndRepeats() throws {
        let text = try #require(ChordChartPDF.chordPro(fromPDF: Self.chartPDF()))

        #expect(text == """
        {title: Amazing Grace}
        {artist: John Newton}
        {key: G}

        Verse 1
        [G]Amazing [Cmaj7]grace how sweet the sound
        That saved a [F#m]wretch like me

        Chorus
        [D]I once was lost
        Amazing grace

        Chorus
        """)
    }

    @Test func theTitleWrappedAtopLaterPagesStaysOutOfTheWords() throws {
        func bold(_ text: String, y: CGFloat, size: CGFloat) -> [PDFGlyph] {
            Self.glyphs(text, y: y).map { PDFGlyph(text: $0.text, x: $0.x, y: $0.y, width: $0.width, size: size, bold: true) }
        }
        let header = bold("A Thousand Hallelujahs [Live From Passion", y: 726, size: 14.75) + bold("2022]", y: 712, size: 14.75)
        let pages = [
            bold("A Thousand Hallelujahs [Live From", y: 724, size: 18.7) + bold("Passion 2022]", y: 708, size: 18.7)
                + bold("CHORUS", y: 650, size: 14.75) + Self.glyphs("With a thousand hallelujahs", y: 620)
                + Self.glyphs("We magnify Your name", y: 605) + Self.glyphs("A thousand hallelujahs", y: 590),
            header + bold("A", y: 692, size: 13) + Self.glyphs("And a thousand more", y: 680)
                + bold("BRIDGE", y: 640, size: 14.75) + Self.glyphs("Praise for He rose", y: 610) + Self.glyphs("Now He reigns", y: 595),
            header + Self.glyphs("We will sing forever", y: 680),
        ].map { PDFPageText(glyphs: $0, bounds: CGRect(x: 0, y: 0, width: 612, height: 792)) }

        #expect(ChordChartPDF.chordPro(from: pages) == """
        {title: A Thousand Hallelujahs [Live From Passion 2022]}

        Chorus
        With a thousand hallelujahs
        We magnify Your name
        A thousand hallelujahs
        [A]And a thousand more

        Bridge
        Praise for He rose
        Now He reigns
        We will sing forever
        """)
    }

    @Test func aTitleAcrossTheGutterStillLeavesTwoColumns() {
        let title = Self.glyphs("The Lord Will Provide (Live From Passion 2025)", y: 726)
            .map { PDFGlyph(text: $0.text, x: $0.x, y: $0.y, width: $0.width, size: 14.75, bold: true) }
        let page = PDFPageText(glyphs: title
            + Self.glyphs("Seek first the kingdom", y: 600) + Self.glyphs("Everything I need", x: 330, y: 600)
            + Self.glyphs("And its treasures", y: 570) + Self.glyphs("My Father has it", x: 330, y: 570),
            bounds: CGRect(x: 0, y: 0, width: 612, height: 792))
        let read = ChordChartPDF.rows(of: page, index: 0, body: 13)
        #expect(read.rows.map(\.text) == [
            "The Lord Will Provide (Live From Passion 2025)",
            "Seek first the kingdom", "And its treasures", "Everything I need", "My Father has it",
        ])

        let ending = PDFPageText(glyphs: Self.glyphs("Every single time", y: 600) + Self.glyphs("The Lord will provide", y: 570)
            + Self.glyphs("My Father has it", y: 540) + Self.glyphs("B", x: 330, y: 650),
            bounds: page.bounds)
        #expect(ChordChartPDF.rows(of: ending, index: 1, body: 13).split == nil)
        #expect(ChordChartPDF.rows(of: ending, index: 1, body: 13, previousSplit: read.split).rows.map(\.text)
            == ["Every single time", "The Lord will provide", "My Father has it", "B"])
    }

    @Test func aWordSpreadForItsChordReadsWhole() {
        let spread = Self.glyphs("of Hea", y: 600) + Self.glyphs("ven", x: 70 + 6 * 6 + 8, y: 600)
        #expect(ChordChartPDF.text(of: spread).text == "of Heaven")

        let unspaced = Self.glyphs("Lord", y: 600) + Self.glyphs("will", x: 70 + 4 * 6 + 8, y: 600)
        #expect(ChordChartPDF.text(of: unspaced).text == "Lord will")
    }

    @Test func aChordOnlySectionRepeatsOnlyWithTheSameChords() {

        let sections: [ChordChartPDF.Section] = [
            .init(name: "Interlude", lines: ["[D][Aadd4][G2]"]),
            .init(name: "Interlude", lines: ["[D][Aadd4][G2]"]),
            .init(name: "Interlude", lines: ["[Bm][G]"]),
            .init(name: "Interlude", lines: ["[Bm][G]"]),
            .init(name: "Chorus", lines: ["[D]Hallelujah"]),
            .init(name: "Chorus", lines: ["[G]Hallelujah"]),

            .init(name: "Chorus", lines: ["Hallelu[G]jah"]),
            .init(name: "Chorus", lines: ["[D]Hallelujah"]),
        ]
        #expect(ChordChartPDF.written(sections: sections, leading: []) == [
            "Interlude", "[D][Aadd4][G2]", "", "Interlude",
            "", "Interlude 2", "[Bm][G]", "", "Interlude 2",

            "", "Chorus", "[D]Hallelujah", "", "Chorus", "[G]Hallelujah", "", "Chorus", "[G]Hallelujah", "", "Chorus",
        ])

        let parsed = Reflow.parse(ChordChartPDF.written(sections: sections, leading: []).joined(separator: "\n"), linesPerSlide: 2)
        #expect(parsed.sections.map(\.name).suffix(2) == ["Chorus", "Chorus"])
        #expect(parsed.order.suffix(4).map { parsed.sections[$0].slides } == [["[D]Hallelujah"], ["[G]Hallelujah"], ["[G]Hallelujah"], ["[D]Hallelujah"]])
        #expect(ChordChartPDF.numbered("Interlude 2", taken: ["Interlude 2"]) == "Interlude 3")

        #expect(ChordChartPDF.written(sections: [
            .init(name: "Vamp", lines: ["[D]Oh oh"]), .init(name: "Vamp", lines: ["[G]Hey hey"]),
            .init(name: "Chorus", lines: ["Way maker"]), .init(name: "Chorus", lines: ["Promise keeper"]),
        ], leading: []) == ["Vamp", "[D]Oh oh", "", "Vamp", "[G]Hey hey", "", "Chorus", "Way maker", "", "Chorus", "Promise keeper"])
    }

    @Test func theChartImportsAsADeckInItsKey() throws {
        let text = try #require(ChordChartPDF.importText(from: Self.chartPDF(), filename: "Chord Chart.pdf"))
        let presentation = LyricTextImporter.makePresentation(text, linesPerSlide: 2)

        #expect(presentation.name == "Amazing Grace")
        #expect(presentation.musicKey == "G")
        let symbols = presentation.slides.flatMap(\.objects).flatMap { $0.chords ?? [] }.map(\.symbol)
        #expect(symbols == ["G", "Cmaj7", "F#m", "D"])
        #expect(presentation.arrangements?.first.map { $0.sectionIds.count } == 4)
    }

    @Test func textChartsPassThroughAndEmptyOnesReadAsNothing() {
        #expect(ChordChartPDF.importText(from: Data("{title: Way Maker}\n[E]You are here".utf8), filename: "song.cho")
            == "{title: Way Maker}\n[E]You are here")
        #expect(ChordChartPDF.importText(from: Data("  \n".utf8), filename: "song.txt") == nil)
        #expect(ChordChartPDF.importText(from: Self.pdf { _ in }, filename: "scan.pdf") == nil)
    }

    @Test func drawnSharpsAndFlatsReadByShape() throws {
        for fontName in ["Apple Symbols", "Menlo"] {
            #expect(PDFGlyphReader.accidental(of: try Self.symbolPath("♯", font: fontName)) == "#")
            #expect(PDFGlyphReader.accidental(of: try Self.symbolPath("♭", font: fontName)) == "b")
        }
        #expect(PDFGlyphReader.accidental(of: CGPath(ellipseIn: CGRect(x: 0, y: 0, width: 4, height: 4), transform: nil)) == nil)

        let flat = CGMutablePath()
        flat.addRect(CGRect(x: 0, y: 0, width: 0.6, height: 5.1))
        flat.addEllipse(in: CGRect(x: 0.6, y: 0, width: 2.1, height: 3.6))
        flat.addEllipse(in: CGRect(x: 1.1, y: 0.8, width: 1.0, height: 2.0))
        #expect(PDFGlyphReader.accidental(of: flat) == "b")
    }

    @Test(arguments: [
        ("Jesus I love You", "love", 1, "Jesus I [D]love You"),
        ("Whatever is true", "Whatever", 4, "What[D]ever is true"),
        ("Of Your name", "Your", 2, "Of [D]Your name"),
        ("I’ve got a sound mind", "mind", 5, "I’ve got a sound mind[D]"),
        ("Receive joy -", "-", 0, "Receive joy [D]"),
    ])
    func chordsLandOnTheirWord(lyric: String, word: String, offset: Int, expected: String) throws {
        let start = try #require(lyric.range(of: word)).lowerBound
        let column = lyric.distance(from: lyric.startIndex, to: start) + offset
        let row = ChordChartPDF.Row(page: 0, column: 0, baseline: 100, glyphs: Self.glyphs(lyric))

        #expect(ChordChartPDF.inline([(x: 70 + CGFloat(column) * 6, symbol: "D")], into: row) == expected)
    }

    @Test(arguments: [
        ("This song is fore-ver Yours", "This song is forever Yours"),
        ("This song is fore - [D]ver Yours", "This song is fore[D]ver Yours"),
        ("Hal-le-lu-jah", "Hallelujah"),
        ("Glo-ri-ous", "Glorious"),
        ("Our God is an all-consuming fire", "Our God is an all-consuming fire"),
        ("Never-ending love", "Never-ending love"),
        ("Oh-oh-oh", "Oh-oh-oh"),
        ("Receive joy -", "Receive joy -"),
    ])
    func syllablesJoinIntoTheirWord(lyric: String, expected: String) {
        #expect(ChordChartPDF.joinedSyllables(lyric) == expected)
    }

    private static func glyphs(_ text: String, x: CGFloat = 70, y: CGFloat = 100) -> [PDFGlyph] {
        text.enumerated().map { index, character in
            PDFGlyph(text: String(character), x: x + CGFloat(index) * 6, y: y, width: 6, size: 13)
        }
    }

    private static func symbolPath(_ symbol: String, font name: String, size: CGFloat = 40) throws -> CGPath {
        let font = CTFontCreateForString(CTFontCreateWithName(name as CFString, size, nil), symbol as CFString, CFRange(location: 0, length: 1))
        var characters = Array(symbol.utf16)
        var glyph = CGGlyph(0)
        CTFontGetGlyphsForCharacters(font, &characters, &glyph, 1)
        return try #require(CTFontCreatePathForGlyph(font, glyph, nil))
    }

    private static func pdf(_ draw: (CGContext) -> Void) -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = CGContext(consumer: CGDataConsumer(data: data as CFMutableData)!, mediaBox: &box, nil)!
        context.beginPDFPage(nil)
        draw(context)
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }

    private static func line(_ text: String, font name: String, size: CGFloat, gray: CGFloat = 0) -> CTLine {
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName(name as CFString, size, nil),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: gray, alpha: 1),
        ]
        return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
    }

    private static func width(_ text: String, font name: String = "Helvetica", size: CGFloat = 13) -> CGFloat {
        CGFloat(CTLineGetTypographicBounds(line(text, font: name, size: size), nil, nil, nil))
    }

    static func chartPDF() -> Data {
        pdf { context in
            func draw(_ text: String, _ font: String, _ size: CGFloat, _ x: CGFloat, _ y: CGFloat, gray: CGFloat = 0) {
                context.textPosition = CGPoint(x: x, y: y)
                CTLineDraw(line(text, font: font, size: size, gray: gray), context)
            }
            let bold = "Helvetica-Bold"
            draw("Amazing Grace", bold, 24, 70, 720)
            draw("Key: G", "Helvetica", 10, 480, 720, gray: 0.57)

            draw("VERSE 1", bold, 15, 70, 650)
            draw("Piano in", "Helvetica", 12, 200, 636, gray: 0.57)
            draw("G", bold, 13, 70, 620)
            let c = 70 + width("Amazing ")
            draw("C", bold, 13, c, 620)
            draw("maj7", bold, 9, c + width("C", font: bold), 623)
            draw("Amazing grace how sweet the sound", "Helvetica", 13, 70, 608)
            let f = 70 + width("That saved a ")
            draw("F", bold, 13, f, 590)
            let sharp = try! symbolPath("♯", font: "Apple Symbols", size: 9)
            let sharpX = f + width("F", font: bold) + 0.4
            context.saveGState()
            context.translateBy(x: sharpX - sharp.boundingBoxOfPath.minX, y: 594 - sharp.boundingBoxOfPath.minY)
            context.addPath(sharp)
            context.setFillColor(gray: 0, alpha: 1)
            context.fillPath()
            context.restoreGState()
            draw("m", bold, 13, sharpX + sharp.boundingBoxOfPath.width + 0.3, 590)
            draw("That saved a wretch like me", "Helvetica", 13, 70, 578)

            for top: CGFloat in [650, 560] {
                draw("CHORUS", bold, 15, 330, top)
                draw("D", bold, 13, 330, top - 30)
                draw("I once was lost", "Helvetica", 13, 330, top - 42)
                draw("Amazing grace", "Helvetica", 13, 330, top - 60)
            }
            draw("Writers: John Newton", "Helvetica", 8, 400, 50, gray: 0.57)
        }
    }
}
