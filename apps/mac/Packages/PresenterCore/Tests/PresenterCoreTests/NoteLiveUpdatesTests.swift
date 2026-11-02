import Foundation
import Testing
@testable import PresenterCore

struct NoteLiveUpdatesTests {
    private static let fixture = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("packages/make-slides-fixtures/slide-markers.json")

    private struct Made {
        var body: NoteBody
        var deck: Presentation
        var memory: [NoteMadePassage]
        var mode: String
    }

    private func firstDeck() throws -> Made {
        let json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: Self.fixture)) as? [String: Any])
        let email = try fixtureNoteBody(json)
        let made = NoteSlides.make(body: email, themeId: "", designMap: SlideDesignMap(), theme: { _ in nil })
        let deck = Presentation(id: "deck", name: "Message", presentationKind: .deck, themeId: "", slides: made.newSlides)
        return Made(
            body: made.body, deck: deck,
            memory: NoteLiveUpdates.memory(of: made.body, deck: deck, groupBySlideId: made.groupBySlideId),
            mode: NoteLiveUpdates.buildMode(of: email))
    }

    private func changes(_ made: Made, body: NoteBody, skipped: [NoteSkippedUpdate] = []) -> NoteLiveUpdates.Found {
        NoteLiveUpdates.changes(
            body: body, deck: made.deck, memory: made.memory, mode: made.mode, skipped: skipped,
            designMap: SlideDesignMap(), theme: { _ in nil })
    }

    private func index(of text: String, in body: NoteBody) throws -> Int {
        try #require(body.blocks.firstIndex { NoteReading.text(of: $0) == text })
    }

    private func retyping(_ text: String, as typed: String, in body: NoteBody) throws -> NoteBody {
        var body = body
        let at = try index(of: text, in: body)
        body.blocks[at].runs = body.blocks[at].runs?.map { run in
            var run = run
            run.text = run.text.replacingOccurrences(of: text, with: typed)
            return run
        }
        return body
    }

    @Test func theFirstDeckIsRememberedPassageByPassageWithNoCardsInTheNote() throws {
        let made = try firstDeck()
        #expect(made.memory.count == NoteSlideMarks.groups(in: made.body).count)
        #expect(made.memory.flatMap(\.slides).count == made.deck.slides.count)
        #expect(!made.body.blocks.contains { $0.type == .slideRef }, "the note holds no cards")
        #expect(changes(made, body: made.body).updates.isEmpty, "an untouched note waits on nothing")
    }

    @Test func whatTheFirstDeckLeftOutWaitsForNoOneUntilItsWordsChange() throws {
        let made = try firstDeck()
        var marked = made.body

        let question = try index(of: "What is it about prosperity that can cause us to forget God?", in: marked)
        marked.blocks.insert(NoteBlock(type: .paragraph, runs: [NoteRun(text: "Next step: Pray for one neighbour.")]), at: question + 1)
        let found = changes(made, body: marked)
        #expect(!found.updates.isEmpty)
        let skipped = NoteLiveUpdates.baseline(found)
        #expect(changes(made, body: marked, skipped: skipped).updates.isEmpty)
        let edited = try retyping("Next step: Pray for one neighbour.", as: "Next step: Pray for two neighbours.", in: marked)
        #expect(changes(made, body: edited, skipped: skipped).updates.count == 1)
    }

    @Test func oneChangedWordIsAnUpdateOnThatSlideAlone() throws {
        var made = try firstDeck()
        let question = "What is it about prosperity that can cause us to forget God?"
        let edited = try retyping(question, as: "What is it about comfort that can cause us to forget God?", in: made.body)
        let found = changes(made, body: edited)
        #expect(found.updates.count == 1)
        let update = try #require(found.updates.first)
        #expect(update.kind == NotePendingUpdate.words)
        #expect(update.after?.map(\.text) == ["What is it about comfort that can cause us to forget God?"])
        #expect(made.deck.slides.first { $0.id == update.slideId }.map { NoteSlideMatch.boxes(of: $0).map(\.text) } == [question])

        let applied = NoteLiveUpdates.applying(update, to: made.deck, memory: made.memory, body: edited, mode: made.mode, at: "now")
        #expect(applied.body == nil, "an update never writes the note")
        #expect(applied.deck.slides.count == made.deck.slides.count)
        let slide = try #require(applied.deck.slides.first { $0.id == update.slideId })
        #expect(NoteSlideMatch.boxes(of: slide).map(\.text) == ["What is it about comfort that can cause us to forget God?"])
        #expect(slide.history?.first?.reason == NoteSlides.updatedReason)
        made.deck = applied.deck
        made.memory = applied.memory
        #expect(changes(made, body: edited).updates.isEmpty, "applied: nothing waits")

        made.memory = NoteLiveUpdates.settlingTexts(made.memory, body: edited, waiting: [])
        let back = changes(made, body: made.body)
        #expect(back.updates.map(\.id) == [update.id])
        #expect(back.updates.first?.after?.map(\.text) == [question])
    }

    @Test func aNewLabelledLineUnderAPassageIsAnAddAfterItsSlides() throws {
        var made = try firstDeck()
        var edited = made.body
        let question = try index(of: "What is it about prosperity that can cause us to forget God?", in: edited)
        edited.blocks.insert(NoteBlock(type: .paragraph, runs: [NoteRun(text: "Next step: Write down one idol you'll hand back to God this week.")]), at: question + 1)
        let found = changes(made, body: edited)
        #expect(found.updates.count == 1)
        let update = try #require(found.updates.first)
        #expect(update.kind == NotePendingUpdate.new)
        let questionGroup = try #require(NoteSlideMarks.groups(in: made.body).first { $0.text.hasPrefix("What is it about") })
        let questionSlide = try #require(made.memory.first { $0.groupId == questionGroup.id }?.slides.last?.slideId)
        #expect(update.afterSlideId == questionSlide, "the Add lands after the passage before it")

        let applied = NoteLiveUpdates.applying(update, to: made.deck, memory: made.memory, body: edited, mode: made.mode, at: "now")
        let body = try #require(applied.body, "the new words take a mark: a marks-only write")
        #expect(NoteSlideMarks.groups(in: body).contains { $0.id == update.groupId && $0.text.hasPrefix("Next step") })
        let at = try #require(applied.deck.slides.firstIndex { $0.id == questionSlide })
        #expect(applied.deck.slides[at + 1].id == update.proposed?.id)
        made.deck = applied.deck
        made.memory = applied.memory
        #expect(changes(made, body: body).updates.isEmpty)
    }

    @Test func aLabelledLineOutsideTheMarkersIsAnAddToo() throws {
        let made = try firstDeck()
        var edited = made.body
        let question = try index(of: "What is it about prosperity that can cause us to forget God?", in: edited)
        edited.blocks.insert(contentsOf: [
            NoteBlock(type: .paragraph, runs: []),
            NoteBlock(type: .paragraph, runs: [NoteRun(text: "Next step: Write down one idol you'll hand back to God this week.")]),
        ], at: question + 1)
        let found = changes(made, body: edited)
        let update = try #require(found.updates.first)
        #expect(found.updates.count == 1 && update.kind == NotePendingUpdate.new)
        let questionGroup = try #require(NoteSlideMarks.groups(in: made.body).first { $0.text.hasPrefix("What is it about") })
        #expect(update.afterSlideId == made.memory.first { $0.groupId == questionGroup.id }?.slides.last?.slideId)
        #expect(found.texts[update.id]?.hasPrefix("Next step") == true)
    }

    @Test func plainTalkAfterAPassageStaysNotes() throws {
        let made = try firstDeck()
        var edited = made.body
        let talk = try index(of: "That's when I think about my grandfather's farm, and the summer the creek ran dry.", in: edited)
        edited.blocks.insert(NoteBlock(type: .paragraph, runs: [NoteRun(text: "And it rained the next week, which nobody expected.")]), at: talk + 1)
        #expect(changes(made, body: edited).updates.isEmpty)
    }

    @Test func aDeletedPassageIsARemoveOfEachOfItsSlides() throws {
        var made = try firstDeck()
        var edited = made.body

        let marker = try index(of: "Slide 3:", in: edited)
        edited.blocks.removeSubrange(marker ... marker + 1)
        let found = changes(made, body: edited)
        #expect(found.updates.map(\.kind) == [NotePendingUpdate.remove])
        let update = try #require(found.updates.first)
        let applied = NoteLiveUpdates.applying(update, to: made.deck, memory: made.memory, body: edited, mode: made.mode, at: "now")
        #expect(!applied.deck.slides.contains { $0.id == update.slideId })
        #expect(applied.memory.count == made.memory.count - 1)
        made.deck = applied.deck
        made.memory = applied.memory
        #expect(changes(made, body: edited).updates.isEmpty)
    }

    @Test func aSkipStaysSkippedUntilThePassageChangesAgain() throws {
        let made = try firstDeck()
        let question = "What is it about prosperity that can cause us to forget God?"
        let edited = try retyping(question, as: "What is it about comfort that can cause us to forget God?", in: made.body)
        let found = changes(made, body: edited)
        let update = try #require(found.updates.first)
        let skipped = NoteLiveUpdates.skipping(update.id, text: try #require(found.texts[update.id]), in: [])
        #expect(changes(made, body: edited, skipped: skipped).updates.isEmpty)
        let again = try retyping("What is it about comfort that can cause us to forget God?", as: "What is it about success that can cause us to forget God?", in: edited)
        #expect(changes(made, body: again, skipped: skipped).updates.map(\.id) == [update.id], "new words: the change is back")
    }

    @Test func aListItemTypedIntoAPassageIsItsWords() throws {
        let made = try firstDeck()
        var edited = made.body
        let list = try #require(edited.blocks.firstIndex { $0.type == .list && NoteReading.text(of: $0).contains("The idol of comfort") })
        edited.blocks[list].items?.append(NoteListItem(runs: [NoteRun(text: "The idol of approval")]))
        let found = changes(made, body: edited)
        #expect(!found.updates.isEmpty)
        #expect(found.updates.allSatisfy { $0.kind != NotePendingUpdate.remove }, "the passage is still there")
        #expect(found.updates.contains { ($0.after ?? $0.proposed.map(NoteSlideMatch.boxes(of:)) ?? []).contains { $0.text.contains("The idol of approval") } })
    }

    @Test func aPasteThatLostTheMarksFindsItsPassagesByTheirWords() throws {
        let made = try firstDeck()
        let pasted = NoteLiveUpdates.unmarked(made.body)
        let found = changes(made, body: pasted)

        let worded = made.memory.filter { !$0.text.isEmpty }
        #expect(found.updates.allSatisfy { update in !worded.contains { $0.groupId == update.groupId } })
        let remarked = try #require(found.remarked)
        #expect(Set(NoteSlideMarks.groups(in: remarked).map(\.id)).isSuperset(of: worded.map(\.groupId)))
    }

    @Test func aLiveNotesDeletedMarkIsARemove() throws {
        let made = try firstDeck()
        let found = NoteLiveUpdates.changes(
            body: NoteLiveUpdates.unmarked(made.body), deck: made.deck, memory: made.memory, mode: made.mode,
            designMap: SlideDesignMap(), theme: { _ in nil }, refind: false)
        #expect(found.remarked == nil)
        let worded = made.memory.filter { !$0.text.isEmpty }
        #expect(worded.allSatisfy { passage in found.updates.contains { $0.groupId == passage.groupId && $0.kind == NotePendingUpdate.remove } })
    }

    @Test func theReaderShowsMadeSlidesUnderTheirWordsAndSavesNone() throws {
        let made = try firstDeck()
        let shown = NoteLiveUpdates.displayBody(made.body, memory: made.memory, deck: made.deck)
        #expect(shown.blocks.filter { $0.type == .slideRef }.count == made.deck.slides.count - made.deck.slides.filter { slide in !made.memory.contains { $0.slides.contains { $0.slideId == slide.id } } }.count)

        let marker = try index(of: "Slide 3:", in: shown)
        #expect(NoteReading.text(of: shown.blocks[marker + 1]) == "What is it about prosperity that can cause us to forget God?")
        #expect(shown.blocks[marker + 2].type == .slideRef)
        #expect(NoteSlideMarks.groups(in: shown).filter { $0.slideId != nil }.count == made.memory.count, "Make Slides reads them as made")
        #expect(NoteLiveUpdates.savedBody(shown, deckId: made.deck.id).blocks == made.body.blocks)

        var hand = try #require(NoteSlides.handRef(presentationId: "deck", slideId: made.deck.slides[0].id, presentation: { _ in made.deck }))
        hand.placedByHand = true
        var withCards = made.body
        withCards.blocks.append(NoteBlock(type: .slideRef, slide: hand))
        let old = try #require(NoteSlides.dropRef(presentationId: "deck", slideId: made.deck.slides[1].id, presentation: { _ in made.deck }))
        withCards.blocks.insert(NoteBlock(type: .slideRef, slide: old), at: 0)
        let stripped = NoteLiveUpdates.savedBody(withCards, deckId: "deck")
        #expect(stripped.blocks.filter { $0.type == .slideRef }.map(\.slide?.placedByHand) == [true])
    }

    @Test func aMarkedPassageWithNoSlidesIsAnAddAndANoteMarkedByHandProposesNothingElse() throws {
        var made = try firstDeck()
        made.mode = NoteLiveUpdates.byHand
        var edited = made.body
        let talk = try index(of: "That's when I think about my grandfather's farm, and the summer the creek ran dry.", in: edited)
        #expect(changes(made, body: edited).updates.isEmpty)
        edited.blocks[talk] = NoteSlideMarks.marking(edited.blocks[talk], group: "pastor", type: "quote")
        let found = changes(made, body: edited)
        #expect(found.updates.map(\.kind) == [NotePendingUpdate.new])
        #expect(found.updates.first?.groupId == "pastor")
    }

    @Test func aPassageWhoseSlidesTheOperatorDeletedIsNoAdd() throws {
        var made = try firstDeck()
        let gone = try #require(made.memory.first { $0.text.hasPrefix("What is it about") })
        made.deck.slides.removeAll { slide in gone.slides.contains { $0.slideId == slide.id } }
        #expect(changes(made, body: made.body).updates.isEmpty)
    }

    @Test func addsSitInTheGridAfterTheSlideTheyFollow() {
        let first = Slide(id: "n1", name: "", objects: [])
        let second = Slide(id: "n2", name: "", objects: [])
        let updates = [
            NotePendingUpdate(id: "new:g:0", kind: NotePendingUpdate.new, groupId: "g", afterSlideId: "b", proposed: first),
            NotePendingUpdate(id: "new:g:1", kind: NotePendingUpdate.new, groupId: "g", afterSlideId: "n1", proposed: second),
            NotePendingUpdate(id: "new:h:0", kind: NotePendingUpdate.new, groupId: "h", proposed: Slide(id: "n3", name: "", objects: [])),
            NotePendingUpdate(id: "words:a", kind: NotePendingUpdate.words, groupId: "a", slideId: "a"),
        ]
        #expect(NoteLiveUpdates.cells(slideIds: ["a", "b", "c", "b"], updates: updates) == [
            .add("new:h:0"), .slide(0), .slide(1), .add("new:g:0"), .add("new:g:1"), .slide(2), .slide(3),
        ])
    }

    @Test func theWordDiffMarksWhatChanged() {
        let diff = NoteLiveUpdates.wordDiff("What are some ways God provided", "What are three ways God provided")
        #expect(diff.map(\.text) == ["What are", "some", "three", "ways God provided"])
        #expect(diff.map(\.change) == [.kept, .removed, .added, .kept])
    }

    @Test func theModeIsTheSuggestersPick() {
        let plain = NoteBody(blocks: [NoteBlock(type: .paragraph, runs: [NoteRun(text: "Grace is a gift")])], plainText: "")
        #expect(NoteLiveUpdates.buildMode(of: plain) == NoteSlideMarks.SuggestMode.structure.rawValue)
        let bold = NoteBody(blocks: [
            NoteBlock(type: .paragraph, runs: [NoteRun(text: "Grace is a gift", bold: true)]),
            NoteBlock(type: .paragraph, runs: [NoteRun(text: "And we tell the story of a long week at the lake house.")]),
            NoteBlock(type: .paragraph, runs: [NoteRun(text: "Mercy is new every morning", bold: true)]),
            NoteBlock(type: .paragraph, runs: [NoteRun(text: "The kids asked for pancakes again on Saturday.")]),
        ], plainText: "")
        #expect(NoteLiveUpdates.buildMode(of: bold) == NoteSlideMarks.SuggestMode.boldLines.rawValue)
        #expect(NoteLiveUpdates.buildMode(of: plain, autoMark: .boldLines) == "boldLines")
    }
}
