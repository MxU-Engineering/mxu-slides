import Testing
@testable import PresenterCore

@Test func scrollsOncePerNewlySelectedItem() {
    var focus = PresentFocusScroll()
    #expect(focus.request("song2") == "song2")
    #expect(focus.request("song2") == nil, "the same selection again is not a click")
    #expect(focus.request("song5") == "song5")
    #expect(focus.honoredItemID == "song5")
}

@Test func aSelectionPassingThroughNilNeverReplays() {
    var focus = PresentFocusScroll()
    _ = focus.request("song2")
    #expect(focus.request(nil) == nil)
    #expect(focus.request("song2") == nil, "the sidebar's row reload hands the same item back")
    var fresh = PresentFocusScroll()
    #expect(fresh.request(nil) == nil)
}

@Test func resetLandsOnTheSelectionAgain() {
    var focus = PresentFocusScroll()
    _ = focus.request("song2")
    focus.reset()
    #expect(focus.honoredItemID == nil)
    #expect(focus.request("song2") == "song2", "returning from the editor starts scrolled to it")
}

@Test func reselectScrollsToTheSameItemAgainAndTicks() {
    var focus = PresentFocusScroll()
    _ = focus.request("sermon")
    #expect(focus.request("sermon") == nil)
    focus.reselect()
    #expect(focus.reselects == 1, "the surface watches the tick")
    #expect(focus.request("sermon") == "sermon")
    #expect(focus.request("sermon") == nil, "one reselect is one jump")
}

@Test func onlyAPlainClickOnTheShownRowIsAReselect() {
    #expect(RunOrderSelection.isReselect(pressed: "sermon", current: "sermon", command: false, shift: false, control: false))
    #expect(!RunOrderSelection.isReselect(pressed: "song2", current: "sermon", command: false, shift: false, control: false))
    #expect(!RunOrderSelection.isReselect(pressed: "sermon", current: nil, command: false, shift: false, control: false))
    #expect(!RunOrderSelection.isReselect(pressed: "sermon", current: "sermon", command: true, shift: false, control: false), "⌘ toggles it out")
    #expect(!RunOrderSelection.isReselect(pressed: "sermon", current: "sermon", command: false, shift: true, control: false), "⇧ extends")
    #expect(!RunOrderSelection.isReselect(pressed: "sermon", current: "sermon", command: false, shift: false, control: true), "⌃ opens the menu")
}
