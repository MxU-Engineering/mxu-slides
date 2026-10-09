import Testing

struct SlideExportPDFSweepTests {
    @Test func pdfTilesRenderClearOverTheGridsBackdrop() throws {
        let file = try #require(try SourceSweep.app().file("SlideImageExport.swift"))
        let pdf = try #require(file.lines.firstIndex { $0.contains("func writePDF(") })
        let body = file.block(from: pdf).map { file.lines[$0] }.joined(separator: "\n")
        #expect(body.contains("transparent: true"), "PDF tiles render clear, or an opaque black fill hides the checker on text-only slides")
        #expect(body.contains("\"slideGrid.transparencyGrid\""), "the PDF backdrop follows the grid's transparency-grid setting")
        #expect(file.text.contains("Self.drawChecker(in: context"), "the checker backs the flattened tile")
    }
}
