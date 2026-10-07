import Foundation
import Testing
@testable import PresenterCore

private func design(_ name: String, folder: String? = nil, boxes: [String] = []) -> Slide {
    var slide = Slide(
        id: name, name: name,
        objects: boxes.map { SlideObject(id: "\(name)-\($0)", objectKind: .text, name: $0, text: "Sample Text") }
            + [SlideObject(id: "\(name)-shape", objectKind: .shape, name: "Bar", text: "")])
    slide.folder = folder
    return slide
}

private func theme(_ id: String, _ designs: [Slide]) -> Theme {
    Theme(id: id, name: id.capitalized, fontFamily: "H", fontSize: 60, textColorHex: "#fff", backgroundColorHex: "#000", slides: designs)
}

@Test func aBlankSlideHasNothingOnIt() {
    let slide = NewSlide.blank(sectionId: "verse", id: "b")
    #expect(slide.objects.isEmpty && slide.unthemed == true && slide.sectionId == "verse")
    #expect(slide.themeSlideName == nil && slide.themeId == nil)
}

@Test func aSlideFromADesignGetsAnEmptyBoxPerPlaceholder() {
    var ids = 0
    let lyrics = design("Lyrics", boxes: ["Main", "Reference"])
    let own = NewSlide.fromDesign(
        lyrics, themeId: "worship", deckThemeId: "worship", sectionId: "chorus", id: "n",
        objectID: { ids += 1; return "o\(ids)" })

    #expect(own.themeSlideName == "Lyrics" && own.themeId == nil, "the deck's theme stays implicit")
    #expect(own.objects.map(\.name) == ["Main", "Reference"], "text placeholders only, name-bound")
    #expect(own.objects.allSatisfy { $0.text == "" && $0.objectKind == .text })
    #expect(own.objects.map(\.id) == ["o1", "o2"] && own.sectionId == "chorus" && own.unthemed == nil)

    let other = NewSlide.fromDesign(lyrics, themeId: "scripture", deckThemeId: "worship", sectionId: nil)
    #expect(other.themeId == "scripture", "another theme's design: the slide follows that theme")
}

@Test func aSlideFromADesignTakesItsActions() {
    var verse = design("Verse", boxes: ["Main"])
    verse.actions = [SlideAction(id: "a", kind: .switchOutputPreset, presetId: "sideThird")]
    let made = NewSlide.fromDesign(verse, themeId: "worship", deckThemeId: "worship", sectionId: nil)
    #expect(made.actions?.map(\.presetId) == ["sideThird"] && made.actions?.first?.id != "a", "a copy, its own id")
    #expect(NewSlide.fromDesign(design("Plain"), themeId: "worship", deckThemeId: "worship", sectionId: nil).actions == nil)
}

@Test func aPreviewIsTheDeckSlideWithSampleText() {
    let lyrics = design("Lyrics", boxes: ["Main"])
    let preview = NewSlide.preview(of: lyrics, themeId: "worship")
    #expect(preview.themeSlideName == "Lyrics" && preview.backgroundFill == nil, "drawn through the theme, no design backdrop")
    #expect(preview.objects.map(\.text) == ["Sample Text"] && preview.objects.map(\.name) == ["Main"])
    #expect(preview.id == NewSlide.preview(of: lyrics, themeId: "worship").id, "stable for the thumbnail cache")
    #expect(preview.id != NewSlide.preview(of: lyrics, themeId: "digital").id, "copied packs share design ids")
}

@Test func theExplorerNestsThemesIntoFoldersAndDesigns() {
    let digital = theme("digital", [
        design("Full"), design("Lower", folder: "Thirds"), design("Title"), design("Side", folder: "Thirds"),
        design("Verse", folder: "Scripture"),
    ])

    #expect(ThemeExplorer.folders(in: digital).map(\.name) == ["Thirds", "Scripture"])
    #expect(ThemeExplorer.folders(in: digital).first?.designs.map(\.name) == ["Lower", "Side"])
    #expect(ThemeExplorer.looseDesigns(in: digital).map(\.name) == ["Full", "Title"])
    #expect(ThemeExplorer.designs(in: digital, folder: "Scripture").map(\.name) == ["Verse"])
}

@Test func theExplorerSearchesEveryWordAcrossThemeFolderAndDesign() {
    let digital = theme("digital", [design("Lower", folder: "Thirds"), design("Full")])
    let worship = theme("worship", [design("Lower Lyrics"), design("Title")])

    #expect(ThemeExplorer.search("lower", in: [digital, worship]).map(\.design.name) == ["Lower", "Lower Lyrics"])
    #expect(ThemeExplorer.search("THIRDS digital", in: [digital, worship]).map(\.design.name) == ["Lower"])
    #expect(ThemeExplorer.search("worship title", in: [digital, worship]).map(\.theme.id) == ["worship"])
    #expect(ThemeExplorer.search("  ", in: [digital, worship]).isEmpty)
}

@Test func aChoiceMakesItsSlide() {
    let lyrics = design("Lyrics", boxes: ["Main"])
    #expect(NewSlideChoice.blank.slide(sectionId: "v", deckThemeId: "worship").unthemed == true)
    let made = NewSlideChoice.design(themeId: "worship", design: lyrics).slide(sectionId: "v", deckThemeId: "worship")
    #expect(made.themeSlideName == "Lyrics" && made.objects.count == 1 && made.sectionId == "v")
}

@Test func newSlideLandsInTheGridLastPointedAtElseTheHosts() {
    let contexts = ["welcome", "song", "sermon"]
    let clicked = NewSlideRoute(contextID: "song", occurrence: 4)
    #expect(contexts.filter { clicked.answers($0, contexts: contexts, isHostTarget: $0 == "sermon") } == ["song"])
    #expect(clicked.anchor(in: "song", selected: [], count: 8) == 4, "after the clicked tile")
    #expect(clicked.anchor(in: "song", selected: [1, 6], count: 8) == 6, "after the last selected tile")
    #expect(clicked.anchor(in: "song", selected: [], count: 3) == nil, "a tile gone since: the end")

    let row = NewSlideRoute(contextID: "sermon")
    #expect(row.anchor(in: "sermon", selected: [], count: 5) == nil, "a run-order row: the end")

    let offScreen = NewSlideRoute(contextID: "library-deck", occurrence: 2)
    #expect(contexts.filter { offScreen.answers($0, contexts: contexts, isHostTarget: $0 == "sermon") } == ["sermon"])
    #expect(contexts.filter { NewSlideRoute().answers($0, contexts: contexts, isHostTarget: false) }.isEmpty)
}
