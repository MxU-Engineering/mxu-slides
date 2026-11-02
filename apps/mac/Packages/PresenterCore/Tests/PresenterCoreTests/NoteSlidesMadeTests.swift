import Testing
@testable import PresenterCore

struct NoteSlidesMadeTests {
    private func body(_ lines: [String]) -> NoteBody {
        NoteBody(
            blocks: lines.map { NoteBlock(type: .paragraph, runs: [NoteRun(text: $0)]) },
            plainText: lines.joined(separator: "\n"))
    }

    private func paragraphs(_ lines: [String]) -> NoteBody { body(lines) }

    @Test func firstRunMarksByStructureAndMakesEverySlide() {
        let made = NoteSlides.make(
            body: body(["Grace is a gift.", "Romans 5:8 For God so loved"]),
            themeId: "", designMap: SlideDesignMap(), theme: { _ in nil })

        #expect(made.newSlides.count == 2)
        #expect(made.markedByStructure == true, "the first run marked the note itself")
        #expect(NoteSlideMarks.groups(in: made.body).count == 2, "every paragraph became a passage")
        #expect(made.newSlides.map { made.groupBySlideId[$0.id] } == made.groupOrder.map { Optional($0) })
        #expect(!made.body.blocks.contains { $0.type == .slideRef }, "the note takes marks, never cards")
    }

    @Test func aNoteMarkedByHandMakesNothingExtraOnAFirstRun() {
        var body = paragraphs(["Intro", "Point one", "Aside", "Point two", "Closing"])
        body.blocks[1].runs?[0].slideGroup = "g1"
        body.blocks[3].runs?[0].slideGroup = "g2"
        let first = NoteSlides.make(body: body, themeId: "", designMap: SlideDesignMap(), theme: { _ in nil })
        #expect(first.newSlides.count == 2 && first.markedByStructure == nil, "marks by hand: nothing else is marked")
    }

    @Test func aFirstRunUsesTheNotesStoredSuggestionsInsteadOfMarkingOnItsOwn() {
        var body = paragraphs(["Welcome everyone", "Grace is a gift.", "An aside", "Romans 5:8 For God so loved"])
        body.blocks[0].runs?[0].slideGroup = "d"
        body.blocks[0].runs?[0].slideState = NoteSlideMarks.declined
        body.blocks[1].runs?[0].slideGroup = "s1"
        body.blocks[1].runs?[0].slideState = NoteSlideMarks.suggested
        body.blocks[3].runs?[0].slideGroup = "s2"
        body.blocks[3].runs?[0].slideState = NoteSlideMarks.suggested
        let made = NoteSlides.make(body: body, themeId: "", designMap: SlideDesignMap(), theme: { _ in nil })

        #expect(made.newSlides.count == 2 && made.groupOrder == ["s1", "s2"])
        #expect(made.markedByStructure == nil, "the suggestions stood in for marking by structure")
        #expect(made.body.blocks[2].runs?[0].slideGroup == nil, "unsuggested prose stays prose")
        #expect(made.body.blocks[0].runs?[0].slideState == NoteSlideMarks.declined)
        #expect(made.body.blocks[1].runs?[0].slideState == nil, "the first run confirmed the suggestions it used")

        body.blocks[2].runs?[0].slideGroup = "m"
        let marked = NoteSlides.make(body: body, themeId: "", designMap: SlideDesignMap(), theme: { _ in nil })
        #expect(marked.newSlides.count == 3 && marked.groupOrder == ["s1", "m", "s2"])
        #expect(marked.body.blocks[1].runs?[0].slideState == nil)
    }
}
