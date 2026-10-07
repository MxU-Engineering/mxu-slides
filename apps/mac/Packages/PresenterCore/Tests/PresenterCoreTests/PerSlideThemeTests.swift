import Foundation
import Testing
@testable import PresenterCore

@Test func aSlideFollowsItsOwnThemeElseTheDecks() {
    var own = Slide(id: "s1", name: "", objects: [])
    own.themeId = "scripture"
    let plain = Slide(id: "s2", name: "", objects: [])
    var empty = Slide(id: "s3", name: "", objects: [])
    empty.themeId = ""
    var deck = Presentation(id: "p", name: "Deck", presentationKind: .deck, themeId: "lyrics", slides: [own, plain, empty])

    #expect(deck.themeId(for: own) == "scripture")
    #expect(deck.themeId(for: plain) == "lyrics")
    #expect(deck.themeId(for: empty) == "lyrics", "an empty own theme is no theme")
    #expect(deck.hasSlideThemes)

    deck.clearSlideThemes()
    #expect(!deck.hasSlideThemes && deck.slides.allSatisfy { $0.themeId == nil })
    #expect(deck.themeId(for: deck.slides[0]) == "lyrics")
}

@Test func anOverrideOutputReadsTheSlideThroughItsChosenDesign() {
    var slide = Slide(id: "s", name: "", objects: [])
    slide.themeSlideName = "Scripture"
    let stream = Theme(id: "stream", name: "Stream", fontFamily: "H", fontSize: 60, textColorHex: "#fff", backgroundColorHex: "#000")
    #expect(slide.rendered(throughOverride: stream).themeSlideName == "Scripture", "no choice = the same name")

    slide.setOverrideDesign("Scripture Wide", forTheme: "stream")
    #expect(slide.overrideDesignName(forTheme: "stream") == "Scripture Wide")
    #expect(slide.rendered(throughOverride: stream).themeSlideName == "Scripture Wide")
    #expect(slide.themeSlideName == "Scripture", "the projector keeps its own")

    slide.setOverrideDesign("Reference Only", forTheme: "stream")
    #expect(slide.overrideDesigns?.count == 1 && slide.overrideDesignName(forTheme: "stream") == "Reference Only", "one entry per theme")
    slide.setOverrideDesign(nil, forTheme: "stream")
    #expect(slide.overrideDesigns == nil)
}

@Test func aBlankSlideFollowsNoTheme() {
    var blank = NewSlide.blank(sectionId: nil, id: "b")
    blank.themeId = "scripture"
    let deck = Presentation(id: "p", name: "Deck", presentationKind: .deck, themeId: "lyrics", slides: [blank])

    #expect(deck.themeId(for: blank) == "", "blank wins over the deck's and its own")
    #expect(deck.hasSlideThemes, "Apply Theme confirms: a slide does not follow the deck")
}
