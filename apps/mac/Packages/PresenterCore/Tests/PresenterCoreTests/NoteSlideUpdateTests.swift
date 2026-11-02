import Foundation
import Testing
@testable import PresenterCore

private func textObject(_ name: String, _ text: String, id: String = UUID().uuidString, w: Double? = nil, h: Double? = nil) -> SlideObject {
    var object = SlideObject(id: id, objectKind: .text, name: name, text: text)
    object.width = w
    object.height = h
    return object
}

private let scriptureTheme = Theme(
    id: "t", name: "Sermon", fontFamily: "Helvetica", fontSize: 60, textColorHex: "#fff", backgroundColorHex: "#000",
    slides: [Slide(id: "d", name: "Scripture", objects: [textObject("Verse", "", w: 1600, h: 500), textObject("Reference", "", w: 800, h: 80)])])

@Test func cardsAfterAPassageAreItsSlides() {
    let body = NoteBody(blocks: [
        NoteBlock(type: .paragraph, runs: [NoteRun(text: "Verse", slideGroup: "a", slideId: "s1")]),
        NoteBlock(type: .slideRef, slide: NoteSlideRef(presentationId: "p", slideId: "s1")),
        NoteBlock(type: .slideRef, slide: NoteSlideRef(presentationId: "p", slideId: "s2")),
        NoteBlock(type: .paragraph, runs: [NoteRun(text: "Between")]),
        NoteBlock(type: .slideRef, slide: NoteSlideRef(presentationId: "p", slideId: "s9")),
    ], plainText: "")
    #expect(NoteSlideUpdate.cards(afterGroup: "a", in: body).map(\.slideId) == ["s1", "s2"])
    #expect(NoteSlideUpdate.cards(afterGroup: "none", in: body).isEmpty)

    let synced = NoteSlideUpdate.syncingCards(
        afterGroup: "a", appending: [NoteSlideRef(presentationId: "p", slideId: "s3")], removing: ["s2"], in: body)
    #expect(synced.blocks.compactMap { $0.slide?.slideId } == ["s1", "s3", "s9"])
    #expect(synced.blocks[3].type == .paragraph)

    var hand = body
    hand.blocks.insert(NoteBlock(type: .slideRef, slide: NoteSlideRef(presentationId: "p", slideId: "h1", placedByHand: true)), at: 3)
    #expect(NoteSlideUpdate.cards(afterGroup: "a", in: hand).map(\.slideId) == ["s1", "s2"])
    let kept = NoteSlideUpdate.syncingCards(
        afterGroup: "a", appending: [NoteSlideRef(presentationId: "p", slideId: "s3")], removing: ["s2"], in: hand)
    #expect(kept.blocks.compactMap { $0.slide?.slideId } == ["s1", "s3", "h1", "s9"])

    let above = NoteBody(blocks: [
        NoteBlock(type: .slideRef, slide: NoteSlideRef(presentationId: "p", slideId: "s1")),
        NoteBlock(type: .paragraph, runs: [NoteRun(text: "Verse", slideGroup: "a", slideId: "s1")]),
        NoteBlock(type: .paragraph, runs: [NoteRun(text: "After")]),
    ], plainText: "")
    #expect(NoteSlideUpdate.cards(afterGroup: "a", in: above).map(\.slideId) == ["s1"])
    let grown = NoteSlideUpdate.syncingCards(afterGroup: "a", appending: [NoteSlideRef(presentationId: "p", slideId: "s2")], removing: [], in: above)
    #expect(grown.blocks.map(\.type) == [.slideRef, .slideRef, .paragraph, .paragraph])

    let stacked = NoteBody(blocks: [
        NoteBlock(type: .slideRef, slide: NoteSlideRef(presentationId: "p", slideId: "s1")),
        NoteBlock(type: .paragraph, runs: [NoteRun(text: "First", slideGroup: "a", slideId: "s1")]),
        NoteBlock(type: .slideRef, slide: NoteSlideRef(presentationId: "p", slideId: "s2")),
        NoteBlock(type: .paragraph, runs: [NoteRun(text: "Second", slideGroup: "b", slideId: "s2")]),
    ], plainText: "")
    #expect(NoteSlideUpdate.cards(afterGroup: "a", in: stacked).map(\.slideId) == ["s1"])
    #expect(NoteSlideUpdate.cards(afterGroup: "b", in: stacked).map(\.slideId) == ["s2"])
    let more = NoteSlideUpdate.syncingCards(afterGroup: "a", appending: [NoteSlideRef(presentationId: "p", slideId: "s1b")], removing: [], in: stacked)
    #expect(more.blocks.compactMap { $0.slide?.slideId } == ["s1", "s1b", "s2"])
}

@Test func aSlideIsBehindWhenThePassageChangedAndUpdatesInPlace() {
    let group = MarkedGroup(id: "a", text: "For God so loved the world\nJohn 3:16")
    var slide = Slide(id: "s1", name: "", objects: [
        textObject("Verse", "For God so loved the world", id: "v"),
        textObject("Reference", "John 3:16", id: "r"),
        SlideObject(id: "shape", objectKind: .shape, name: "Plate", text: ""),
    ])
    slide.themeSlideName = "Scripture"
    slide.objects[0].x = 100
    #expect(!NoteSlideUpdate.isBehind(group, slides: [slide], theme: scriptureTheme))

    let edited = MarkedGroup(id: "a", text: "For God so loved the whole world\nJohn 3:16-17")
    #expect(NoteSlideUpdate.isBehind(edited, slides: [slide], theme: scriptureTheme))

    let row = NoteSlideUpdate.replan(edited, like: [slide], theme: scriptureTheme)!
    let result = NoteSlideUpdate.updating([slide], to: row)
    #expect(result.appended.isEmpty && result.removedIds.isEmpty)
    let updated = result.updated[0]

    #expect(updated.objects.map(\.id) == ["v", "r", "shape"])
    #expect(updated.objects[0].text == "For God so loved the whole world" && updated.objects[0].x == 100)
    #expect(updated.objects[1].text == "John 3:16-17")
    #expect(!NoteSlideUpdate.isBehind(edited, slides: [updated], theme: scriptureTheme))
}

@Test func moreOrFewerPartsAppendOrDropSlides() {
    var first = Slide(id: "s1", name: "", objects: [textObject("Verse", "Line 1"), textObject("Reference", "Ps 1")])
    first.themeSlideName = "Scripture"
    first.themeId = "other"
    let long = MarkedGroup(id: "a", text: (1 ... 8).map { "Line \($0)" }.joined(separator: "\n") + "\nPsalm 1:1-8")
    let grown = NoteSlideUpdate.updating([first], to: NoteSlideUpdate.replan(long, like: [first], theme: scriptureTheme)!)
    #expect(grown.updated.count == 1 && grown.appended.count == 1 && grown.removedIds.isEmpty)
    #expect(grown.appended[0].themeSlideName == "Scripture" && grown.appended[0].themeId == "other")
    #expect(grown.appended[0].objects.map(\.name) == ["Verse", "Reference"])

    let second = Slide(id: "s2", name: "", objects: [textObject("Verse", "Line 7")])
    var kept = Slide(id: "s3", name: "", objects: [textObject("Verse", "x"), SlideObject(id: "m", objectKind: .media, name: "Video", text: "")])
    kept.themeSlideName = "Scripture"
    let short = MarkedGroup(id: "a", text: "Only one line\nPsalm 1:1")
    let shrunk = NoteSlideUpdate.updating([first, second, kept], to: NoteSlideUpdate.replan(short, like: [first], theme: scriptureTheme)!)
    #expect(shrunk.updated.map(\.id) == ["s1", "s3"], "a slide holding more than text stays")
    #expect(shrunk.removedIds == ["s2"])
}

@Test func newPartsCarryTheFirstSlidesActionsAndTheRowsSwitchReplacesPresetSwitches() {
    var slide = Slide(id: "s1", name: "", objects: [textObject("Verse", "Short", id: "v"), textObject("Reference", "John 3:16", id: "r")])
    slide.themeSlideName = "Scripture"
    slide.actions = [
        SlideAction(id: "a1", kind: .switchOutputPreset, presetId: "side"),
        SlideAction(id: "a2", kind: .clearLayer, layer: "videos"),
        SlideAction(id: "a3", kind: .fireCombo, comboId: "mine"),
    ]
    let long = MarkedGroup(id: "a", text: (1 ... 8).map { "Line \($0)" }.joined(separator: "\n") + "\nJohn 3:16")
    let row = NoteSlideUpdate.replan(long, like: [slide], theme: scriptureTheme)!
    let result = NoteSlideUpdate.updating([slide], to: row)
    #expect(!result.appended.isEmpty, "the passage grew past one slide")
    let appended = result.appended[0]
    #expect(appended.actions?.map(\.kind) == [.switchOutputPreset, .clearLayer, .fireCombo])
    #expect(appended.actions?.map(\.id) != slide.actions?.map(\.id), "fresh ids")
    #expect(result.updated[0].actions == slide.actions, "the kept slide keeps its own")

    let switched = NoteSlideUpdate.applyingSwitch(.preset("lower"), to: result.updated + result.appended)
    for s in switched {
        #expect(s.actions?.map { $0.presetId ?? $0.comboId ?? $0.layer ?? "" } == ["videos", "mine", "lower"], "the old switch goes, the rest stay, the new one lands")
    }
    let combo = NoteSlideUpdate.applyingSwitch(.combo("mine"), to: [slide])[0]
    #expect(combo.actions?.map(\.kind) == [.clearLayer, .fireCombo], "a combo already there is not added twice")
    let none = NoteSlideUpdate.applyingSwitch(nil, to: [slide])[0]
    #expect(none.actions?.map(\.kind) == [.clearLayer, .fireCombo])
    var bare = slide
    bare.actions = [SlideAction(id: "x", kind: .switchOutputPreset, presetId: "side")]
    #expect(NoteSlideUpdate.applyingSwitch(nil, to: [bare])[0].actions == nil, "nothing left = no list")
}

@Test func madeSlidesLiveOnlyWhileTheirDeckHoldsThem() {
    let deck = Presentation(id: "p", name: "Deck", presentationKind: .deck, themeId: "t", slides: [Slide(id: "s1", name: "1", objects: []), Slide(id: "s2", name: "2", objects: [])])
    let lookup: (String) -> Presentation? = { $0 == "p" ? deck : nil }

    let living = NoteSlideUpdate.madeSlides(ids: ["s2", "gone"], deckId: "p", presentation: lookup)
    #expect(living.isMade)
    #expect(living.positions == ["s2": 2])
    #expect(living.dead == ["gone"])

    let orphaned = NoteSlideUpdate.madeSlides(ids: ["s1", "s2"], deckId: "missing", presentation: lookup)
    #expect(!orphaned.isMade)
    #expect(orphaned.dead == ["s1", "s2"])
    #expect(!NoteSlideUpdate.madeSlides(ids: ["s1"], deckId: nil, presentation: lookup).isMade)
}
