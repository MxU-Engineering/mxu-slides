import Testing
@testable import PresenterCore

@Test func pastedSpansBecomeRunsAtThePasteOffsetAndPlainSpansAreSkipped() {

    let text = "Hear and obey God"
    let spans = [
        PastedFormatting.Span(location: 0, length: 4),
        PastedFormatting.Span(location: 4, length: 4, fontName: "HelveticaNeue-Bold"),
        PastedFormatting.Span(location: 9, length: 3, underline: true, strikethrough: false),
    ]
    let runs = PastedFormatting.apply(spans, pastedAtUTF16: 5, to: [], in: text)
    #expect(runs.count == 2)
    #expect(runs[0].line == 0 && runs[0].column == 9 && runs[0].length == 4 && runs[0].fontName == "HelveticaNeue-Bold")
    #expect(runs[1].column == 14 && runs[1].length == 3 && runs[1].underline == true && runs[1].strikethrough == false)
    #expect(TextStyleRuns.effectiveRun(at: 6, runs: runs, in: text)?.fontName == nil, "the plain span stays the object's style")
}

@Test func pastedSpansNeverCrossLinesAndEmptySpansAreIgnored() {
    let text = "one\ntwo"
    let spans = [PastedFormatting.Span(location: 0, length: 7, fontName: "HelveticaNeue-Italic"), PastedFormatting.Span(location: 0, length: 0, underline: true)]
    let runs = PastedFormatting.apply(spans, pastedAtUTF16: 0, to: [], in: text)
    #expect(runs.map(\.line) == [0, 1])
    #expect(runs.allSatisfy { $0.fontName == "HelveticaNeue-Italic" })
}
