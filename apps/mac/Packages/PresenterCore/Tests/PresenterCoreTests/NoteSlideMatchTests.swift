import Testing
@testable import PresenterCore

struct NoteSlideMatchTests {
    private func paragraph(_ text: String) -> NoteBlock { NoteBlock(type: .paragraph, runs: [NoteRun(text: text)]) }
    private func heading(_ text: String) -> NoteBlock { NoteBlock(type: .heading, level: 2, runs: [NoteRun(text: text)]) }
    private func list(_ items: [String]) -> NoteBlock {
        NoteBlock(type: .list, ordered: true, items: items.map { NoteListItem(runs: [NoteRun(text: $0)]) })
    }
    private func body(_ blocks: [NoteBlock]) -> NoteBody {
        NoteBody(blocks: blocks, plainText: blocks.map(NoteReading.text(of:)).joined(separator: "\n"))
    }

    private func sunday() -> (body: NoteBody, deck: Presentation, memory: [NoteMadePassage]) {
        let first = NoteSlides.make(
            body: body([
                heading("Waiting well"),
                paragraph("Wait for the LORD; be strong and take heart and wait for the LORD.\nPsalm 27:14"),
                list(["Waiting is trusting God's timing", "Waiting is strengthening your heart", "Waiting is refusing to run ahead"]),
                paragraph("Most of us treat waiting like a waiting room, a place you sit until the real thing starts."),
                paragraph("Be strong while you wait."),
            ]),
            themeId: "", designMap: SlideDesignMap(), theme: { _ in nil })
        let deck = Presentation(id: "d1", name: "Waiting well", presentationKind: .deck, themeId: "", slides: first.newSlides)
        return (first.body, deck, NoteLiveUpdates.memory(of: first.body, deck: deck, groupBySlideId: first.groupBySlideId))
    }

    @Test func memoryRemembersEveryMadePassage() {
        let (placed, deck, memory) = sunday()
        #expect(memory.count == 5)
        #expect(memory.map(\.groupId) == NoteSlideMarks.groups(in: placed).map(\.id))
        #expect(memory.allSatisfy { !$0.slides.isEmpty })
        #expect(memory[1].slides[0].boxes.contains { $0.text.contains("Psalm 27:14") || $0.text.contains("Wait for the LORD") })
        #expect(Set(memory.flatMap { $0.slides.map(\.slideId) }) == Set(deck.slides.map(\.id)))
    }

    @Test func aPasteOverKeepsSlidesByWordsReferenceTitleAndSimilarity() {
        let (_, _, memory) = sunday()

        let fresh = body([
            heading("Waiting Well"),
            list(["1. Waiting is trusting in God's timing", "2. Waiting is strengthening your own heart", "3. Waiting is refusing to run on ahead"]),
            paragraph("Wait patiently for the LORD. Be brave and courageous. Yes, wait patiently for the LORD.\nPsalm 27:14"),
            paragraph("Nothing about Tuesday afternoon feels like progress."),
            paragraph("So this week, sit in it."),
        ])
        let result = NoteSlideMatch.match(fresh: fresh, memory: memory)

        let rungs = Dictionary(result.matches.map { ($0.groupId, $0.rung) }, uniquingKeysWith: { a, _ in a })
        #expect(rungs[memory[0].groupId] == .text, "the heading matched by its words")
        #expect(rungs[memory[1].groupId] == .scripture, "the verse matched by its reference")
        #expect(rungs[memory[2].groupId] == .similar || rungs[memory[2].groupId] == .title, "the points matched by their words")
        #expect(rungs[memory[3].groupId] == nil && rungs[memory[4].groupId] == nil)
        #expect(result.orphans.map(\.groupId) == [memory[3].groupId, memory[4].groupId])

        let groups = NoteSlideMarks.groups(in: result.body)
        #expect(groups.count == 3, "only recognized passages are marked; new text stays prose")
        #expect(groups.map(\.id) == [memory[0].groupId, memory[2].groupId, memory[1].groupId], "marks follow the new order")
        #expect(groups.allSatisfy { group in group.slideId == memory.first { $0.groupId == group.id }?.slides.first?.slideId })
    }

    @Test func passagesStillMarkedKeepTheirMarksAndTwoAlikePointsDoNotSwap() {
        let (placed, _, memory) = sunday()

        let typed = NoteSlideMatch.match(fresh: placed, memory: memory)
        #expect(typed.matches.allSatisfy { $0.rung == .mark })
        #expect(typed.orphans.isEmpty)
        #expect(typed.body == placed)

        let a = NoteMadePassage(groupId: "ga", text: "Grace is a gift you cannot earn", slides: [NoteMadeSlide(slideId: "sa", boxes: [])])
        let b = NoteMadePassage(groupId: "gb", text: "Grace is a gift you cannot lose", slides: [NoteMadeSlide(slideId: "sb", boxes: [])])
        let swapped = NoteSlideMatch.match(
            fresh: body([paragraph("Grace is a gift you cannot lose"), paragraph("Grace is a gift you cannot earn")]),
            memory: [a, b])
        #expect(NoteSlideMarks.groups(in: swapped.body).map(\.id) == ["gb", "ga"])
        #expect(swapped.matches.allSatisfy { $0.rung == .text })
    }

    @Test func rungsAndNormalization() {
        func candidate(_ text: String, shape: NoteSlideMarks.Shape = .paragraph) -> NoteSlideMarks.Group {
            NoteSlideMarks.Group(id: "c", blockIndexes: [0], text: text, shape: shape)
        }
        func passage(_ text: String) -> NoteMadePassage { NoteMadePassage(groupId: "m", text: text, slides: []) }
        #expect(NoteSlideMatch.rung(candidate("“Be strong,” he said."), passage("\"Be strong\", he said")) == .text)
        #expect(NoteSlideMatch.rung(candidate("1. Trust\n2. Wait"), passage("Trust\nWait")) == .text, "list numbers do not count")
        #expect(NoteSlideMatch.rung(candidate("For God so loved the world.\nJohn 3:16"), passage("God loved the world this way.\nJohn 3:16")) == .scripture)
        #expect(NoteSlideMatch.rung(candidate("Waiting well\nA whole new subtitle here", shape: .heading), passage("Waiting well\nThe old subtitle")) == .title)
        #expect(NoteSlideMatch.rung(candidate("Waiting well\nA whole new subtitle here"), passage("Waiting well\nThe old subtitle")) == nil, "a paragraph's first line is not a title")
        #expect(NoteSlideMatch.rung(candidate("The kingdom of heaven is like a mustard seed planted in a field"), passage("The kingdom of heaven is like a mustard seed a man planted in his field")) == .similar)
        #expect(NoteSlideMatch.rung(candidate("Completely different words about something else entirely"), passage("The kingdom of heaven is like a mustard seed")) == nil)
        #expect(NoteSlideMatch.match(fresh: body([paragraph("x")]), memory: []).matches.isEmpty)
    }

    @Test func untouchedIsExactlyWhatTheRunMade() {
        let (_, deck, memory) = sunday()
        let passage = memory[1], made = passage.slides[0]
        let slide = deck.slides.first { $0.id == made.slideId }!
        #expect(NoteSlideMatch.isUntouched(slide, memory: made, passage: passage))

        var withSwitch = slide
        withSwitch.actions = [SlideAction(id: "a", kind: .switchOutputPreset)]
        withSwitch.notes = "the pastor's aside"
        #expect(NoteSlideMatch.isUntouched(withSwitch, memory: made, passage: passage), "the run's own switch and notes do not count")

        var moved = slide
        moved.objects[0].x = 120
        #expect(!NoteSlideMatch.isUntouched(moved, memory: made, passage: passage))
        var edited = slide
        edited.objects[0].text += " (NIV)"
        #expect(!NoteSlideMatch.isUntouched(edited, memory: made, passage: passage))
        var picture = slide
        picture.objects.append(SlideObject(id: "p", objectKind: .shape, name: "Picture", text: ""))
        #expect(!NoteSlideMatch.isUntouched(picture, memory: made, passage: passage))
        var redesigned = slide
        redesigned.themeSlideName = "Quote"
        #expect(!NoteSlideMatch.isUntouched(redesigned, memory: made, passage: passage))
        var styled = slide
        styled.objects[0].textStyle = TextStyle()
        #expect(!NoteSlideMatch.isUntouched(styled, memory: made, passage: passage))
    }
}
