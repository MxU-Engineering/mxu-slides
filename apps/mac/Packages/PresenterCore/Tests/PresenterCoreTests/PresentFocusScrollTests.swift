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

@Test func comingBackFromAnotherModePutsThePlaceBackOnce() {
    var focus = PresentFocusScroll()
    _ = focus.request("sermon")
    let place = PresentLanding.Anchor(id: "song2", fraction: 0.3, slide: 8, intoRow: 0.5)
    let left = PresentPlace(serviceID: "sunday", focusItemID: "sermon", anchor: place)
    focus.leave()
    #expect(focus.comeBack(to: left, serviceID: "sunday", focusItemID: "sermon") == place)
    #expect(focus.request("sermon") == nil, "the place counts as the selection landed")
    #expect(focus.comeBack(to: left, serviceID: "sunday", focusItemID: "sermon") == nil, "once")
}

@Test func aNewSelectionOrServiceWhileAwayJumpsInstead() {
    let left = PresentPlace(serviceID: "sunday", focusItemID: "sermon", anchor: PresentLanding.Anchor(id: "song2", fraction: 0))
    var picked = PresentFocusScroll()
    picked.leave()
    #expect(picked.comeBack(to: left, serviceID: "sunday", focusItemID: "song5") == nil)
    #expect(picked.request("song5") == "song5", "the item picked while editing lands as a jump")
    var other = PresentFocusScroll()
    other.leave()
    #expect(other.comeBack(to: left, serviceID: "monday", focusItemID: "sermon") == nil)
}

@Test func onlyAReturnPutsThePlaceBack() {
    let left = PresentPlace(serviceID: "sunday", focusItemID: "sermon", anchor: PresentLanding.Anchor(id: "song2", fraction: 0))
    var preview = PresentFocusScroll()
    preview.reset()
    #expect(preview.comeBack(to: left, serviceID: "sunday", focusItemID: "sermon") == nil, "a library preview closing lands on the selection")
    var clicked = PresentFocusScroll()
    clicked.leave()
    clicked.reselect()
    #expect(clicked.comeBack(to: left, serviceID: "sunday", focusItemID: "sermon") == nil, "a click on the selected row jumps to it")
}
