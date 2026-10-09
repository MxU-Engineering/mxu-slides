import CoreGraphics
import Testing

@testable import PresenterCore

struct PresentationExportTests {
    @Test func songsAddChordProTextOtherDecksDoNot() {
        let song = LyricTextImporter.makePresentation("Verse 1\nAmazing grace", linesPerSlide: 2, lyricLines: [])
        let deck = Presentation(id: "d", name: "Announcements", presentationKind: .deck, themeId: "", slides: [Slide(id: "s", name: "Welcome", objects: [])])
        #expect(PresentationExport.formats(for: song) == PresentationExport.Format.allCases)
        #expect(PresentationExport.formats(for: deck) == [.slidesFile, .pdf, .images])
    }

    @Test func fileNamesFollowTheFormat() {
        let deck = Presentation(id: "d", name: "Sunday: 9/14", presentationKind: .deck, themeId: "", slides: [])
        #expect(PresentationExport.fileName(for: deck, format: .slidesFile) == "Sunday- 9-14.mxuslides")
        #expect(PresentationExport.fileName(for: deck, format: .pdf) == "Sunday- 9-14.pdf")
        #expect(PresentationExport.fileName(for: deck, format: .images) == "Sunday- 9-14")
        #expect(PresentationExport.fileName(for: deck, format: .chordPro) == "Sunday- 9-14.cho")
    }

    @Test func imageNamesSortInFinderAndCarryTheLabel() {
        #expect(PresentationExport.imageFileNames(labels: ["Verse 1", nil, "A/B", " "]) == [
            "01 Verse 1.png", "02.png", "03 A-B.png", "04.png",
        ])
        let many = PresentationExport.imageFileNames(labels: Array(repeating: nil, count: 120))
        #expect(many.first == "001.png")
        #expect(many.last == "120.png")
    }

    @Test func sheetFillsPagesInRowsWithinTheMargins() {
        let letter = CGSize(width: 612, height: 792)
        let sheet = PresentationExport.Sheet(pageSize: letter, columns: 3, aspect: 16.0 / 9.0)
        let pages = sheet.pages(count: 40)
        #expect(pages.map(\.count).reduce(0, +) == 40)

        #expect(pages[0].count <= pages[1].count)
        for rect in pages.flatMap({ $0 }) {
            #expect(rect.minX >= PresentationExport.Sheet.margin - 0.001)
            #expect(rect.maxX <= letter.width - PresentationExport.Sheet.margin + 0.001)
            #expect(rect.minY - PresentationExport.Sheet.captionHeight >= PresentationExport.Sheet.margin - 0.001)
            #expect(abs(rect.width / rect.height - 16.0 / 9.0) < 0.001)
        }

        #expect(pages[0][1].minX - pages[0][0].maxX == 12)
        #expect(pages[0][3].maxY < pages[0][0].minY)
    }

    @Test func sheetClampsColumnsAndScalesCorners() {
        let letter = CGSize(width: 612, height: 792)
        #expect(PresentationExport.Sheet(pageSize: letter, columns: 0, aspect: 1).columns == 1)
        #expect(PresentationExport.Sheet(pageSize: letter, columns: 9, aspect: 1).columns == 6)
        #expect(PresentationExport.Sheet(pageSize: letter, columns: 1, aspect: 16.0 / 9.0).cornerRadius == 8)
        #expect(PresentationExport.Sheet(pageSize: letter, columns: 6, aspect: 16.0 / 9.0).cornerRadius < 8)
        #expect(PresentationExport.Sheet(pageSize: letter, columns: 3, aspect: 16.0 / 9.0).pages(count: 0).isEmpty)
    }
}
