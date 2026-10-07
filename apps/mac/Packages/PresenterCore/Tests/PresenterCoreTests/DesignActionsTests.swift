import Foundation
import Testing
@testable import PresenterCore

private func preset(_ id: String, _ presetId: String) -> SlideAction {
    SlideAction(id: id, kind: .switchOutputPreset, presetId: presetId)
}

private func design(_ name: String, _ actions: [SlideAction]? = nil) -> Slide {
    var slide = Slide(id: name, name: name, objects: [])
    slide.actions = actions
    return slide
}

private func theme(_ id: String, _ designs: [Slide]) -> Theme {
    Theme(id: id, name: id, fontFamily: "H", fontSize: 60, textColorHex: "#fff", backgroundColorHex: "#000", slides: designs)
}

@Test func aThemeResolvesADesignByNameElseItsFirst() {
    let worship = theme("worship", [design("Lyrics"), design("Verse")])
    #expect(worship.design(named: "verse")?.name == "Verse")
    #expect(worship.design(named: nil)?.name == "Lyrics" && worship.design(named: "Gone")?.name == "Lyrics")
    #expect(theme("empty", []).design(named: "Verse") == nil)
}

@Test func takingADesignCopiesItsActionsWithFreshIds() {
    var ids = 0
    var slide = Slide(id: "s", name: "", objects: [], actions: [preset("mine", "wide")])
    slide.adoptActions(of: design("Verse", [preset("v1", "sideThird")]), newID: { ids += 1; return "n\(ids)" })
    #expect(slide.actions?.map(\.id) == ["mine", "n1"], "the slide's own actions stay, the copy gets a fresh id")
    #expect(slide.actions?.last?.presetId == "sideThird")

    slide.adoptActions(of: design("Verse", [preset("v1", "sideThird")]))
    #expect(slide.actions?.count == 2, "taking it again adds nothing it already has")

    var bare = Slide(id: "b", name: "", objects: [])
    bare.adoptActions(of: design("Plain"))
    #expect(bare.actions == nil, "no actions stores as absent")
}

@Test func switchingDesignsSwapsTheOldDesignsActions() {
    let verse = design("Verse", [preset("v1", "sideThird"), SlideAction(id: "v2", kind: .clearAll)])
    let point = design("Point", [preset("p1", "lowerThird"), SlideAction(id: "p2", kind: .clearAll)])
    var slide = Slide(id: "s", name: "", objects: [])
    slide.adoptActions(of: verse)
    slide.actions?.append(preset("mine", "wide"))
    let kept = slide.actions?[1].id

    slide.adoptActions(of: point, replacing: verse)
    #expect(slide.actions?.compactMap(\.presetId) == ["wide", "lowerThird"], "the verse preset leaves, the point preset arrives")
    #expect(slide.actions?.first?.id == kept, "an action both designs give stays put")

    var edited = Slide(id: "e", name: "", objects: [], actions: [preset("x", "sideThird-edited")])
    edited.adoptActions(of: point, replacing: design("Verse", [preset("v1", "sideThird")]))
    #expect(edited.actions?.first?.presetId == "sideThird-edited", "an action changed since it came stays")
}

@Test func applyingADeckThemeSwapsEachSlidesDesignActions() {
    let old = theme("old", [design("Verse", [preset("o", "sideThird")])])
    let new = theme("new", [design("Verse", [preset("n", "lowerThird")])])
    let other = theme("other", [design("Verse", [preset("x", "full")])])
    var follows = Slide(id: "a", name: "", objects: [])
    follows.themeSlideName = "Verse"
    follows.adoptActions(of: old.slides?.first)
    var own = Slide(id: "b", name: "", objects: [])
    own.themeSlideName = "Verse"
    own.themeId = "other"
    own.adoptActions(of: other.slides?.first)
    var blank = Slide(id: "c", name: "", objects: [])
    blank.unthemed = true
    var deck = Presentation(id: "p", name: "Deck", presentationKind: .deck, themeId: "old", slides: [follows, own, blank])

    deck.adoptDesignActions(of: new, themes: ["old": old, "new": new, "other": other])
    #expect(deck.slides[0].actions?.compactMap(\.presetId) == ["lowerThird"])
    #expect(deck.slides[1].actions?.compactMap(\.presetId) == ["lowerThird"], "its own theme's design leaves")
    #expect(deck.slides[2].actions == nil, "a Blank slide takes none")
}

@Test func applyingAThemeToSomeSlidesStylesOnlyThoseSlides() {
    let deckTheme = theme("deck", [design("Verse", [preset("d", "sideThird")])])
    let scripture = theme("scripture", [design("Verse", [preset("s", "lowerThird")])])
    var verse = Slide(id: "a", name: "", objects: [])
    verse.themeSlideName = "Verse"
    verse.adoptActions(of: deckTheme.slides?.first)
    var blank = Slide(id: "b", name: "", objects: [])
    blank.unthemed = true
    let untouched = Slide(id: "c", name: "", objects: [])
    var deck = Presentation(id: "p", name: "Deck", presentationKind: .deck, themeId: "deck", slides: [verse, blank, untouched])
    let themes = ["deck": deckTheme, "scripture": scripture]

    deck.applyTheme(scripture, toSlides: ["a", "b"], themes: themes)
    #expect(deck.slides[0].themeId == "scripture" && deck.slides[0].themeSlideName == "Verse", "keeps its design, follows the new theme")
    #expect(deck.slides[0].actions?.compactMap(\.presetId) == ["lowerThird"], "the old design's actions swap for the new one's")
    #expect(deck.slides[1].themeId == "scripture" && deck.slides[1].unthemed == nil, "a Blank slide takes the theme")
    #expect(deck.slides[2].themeId == nil && deck.themeId == "deck", "unselected slides and the deck keep theirs")
    #expect(deck.slides(["a", "b"], allFollow: "scripture") && !deck.slides(["a", "c"], allFollow: "scripture"))

    deck.applyTheme(deckTheme, toSlides: ["a"], themes: themes)
    #expect(deck.slides[0].themeId == nil, "the deck's own theme clears the slide's")
    #expect(deck.slides[0].actions?.compactMap(\.presetId) == ["sideThird"])
}

@Test func pickingADesignPutsEverySlideOnIt() {
    let deckTheme = theme("deck", [design("Verse", [preset("d", "sideThird")])])
    let scripture = theme("scripture", [design("Verse"), design("Reference", [preset("r", "lowerThird")])])
    var verse = Slide(id: "a", name: "", objects: [])
    verse.themeSlideName = "Verse"
    verse.adoptActions(of: deckTheme.slides?.first)
    var deck = Presentation(id: "p", name: "Deck", presentationKind: .deck, themeId: "deck", slides: [verse, Slide(id: "b", name: "", objects: [])])

    deck.applyTheme(scripture, toSlides: ["a", "b"], design: "Reference", themes: ["deck": deckTheme, "scripture": scripture])
    #expect(deck.slides.allSatisfy { $0.themeId == "scripture" && $0.themeSlideName == "Reference" })
    #expect(deck.slides[0].actions?.compactMap(\.presetId) == ["lowerThird"], "the picked design's actions replace the old design's")
    #expect(deck.slides(["a", "b"], allFollow: "scripture", design: "reference"))
    #expect(!deck.slides(["a", "b"], allFollow: "scripture", design: "Verse"))
}
