import Foundation
import Testing

@testable import PresenterCore

private func theme() -> Theme {
    var full = Slide(id: "full", name: "Lyrics", objects: [])
    full.folder = "Full Slide"
    var lowerA = Slide(id: "lowerA", name: "Lower Third", objects: [])
    lowerA.folder = "Lower Thirds"
    var lowerB = Slide(id: "lowerB", name: "Point (Lower Third)", objects: [])
    lowerB.folder = "Lower Thirds"
    let unfoldered = Slide(id: "bare", name: "Bare", objects: [])
    return Theme(
        id: "t", name: "T", fontFamily: "Helvetica", fontSize: 72,
        textColorHex: "#FFFFFFFF", backgroundColorHex: "#000000FF",
        slides: [unfoldered, full, lowerA, lowerB]
    )
}

@Test func scopingFiltersToTheFolderCaseInsensitively() {
    let scoped = theme().scoped(toSlideFolder: "lower thirds")
    #expect(scoped.slides?.map(\.id) == ["lowerA", "lowerB"], "order kept — first slide is the folder's default")
    #expect(theme().hasSlideFolder("LOWER THIRDS"))
}

@Test func absentOrUnmatchedFolderKeepsTheWholeTheme() {
    #expect(theme().scoped(toSlideFolder: nil) == theme())
    #expect(theme().scoped(toSlideFolder: "") == theme())
    #expect(theme().scoped(toSlideFolder: "Scripture") == theme(), "miss = whole theme, the caller breadcrumbs")
    #expect(!theme().hasSlideFolder("Scripture"))
}

@Test func slideFoldersListDistinctInSlideOrder() {
    #expect(theme().slideFolders == ["Full Slide", "Lower Thirds"], "unfoldered slides don't list")
}

@Test func slidePinNarrowsToOneDesignAndWinsOverFolder() {

    let pinned = theme().scoped(toSlideID: "lowerB")
    #expect(pinned.slides?.map(\.id) == ["lowerB"])
    #expect(theme().scoped(toSlideFolder: "Lower Thirds").scoped(toSlideID: "lowerB").slides?.map(\.id) == ["lowerB"])
    #expect(theme().scoped(toSlideID: nil) == theme())
    #expect(theme().scoped(toSlideID: "gone") == theme(), "miss = wider scope, the caller breadcrumbs")
    #expect(theme().hasSlide(id: "lowerB"))
    #expect(!theme().hasSlide(id: "gone"))
}
