import Foundation
import Testing
@testable import PresenterCore

private let order = ["a", "b", "c", "d", "e"]

@Test func plainClickReplacesAndAnchors() {
    let state = ListMultiSelect.click(
        "c", gesture: .replace, in: order,
        state: .init(selected: ["a", "b"], anchor: "a"))
    #expect(state == .init(selected: ["c"], anchor: "c"))
}

@Test func toggleAddsRemovesAndMovesAnchor() {
    var state = ListMultiSelect.click("b", gesture: .toggle, in: order, state: .init())
    #expect(state == .init(selected: ["b"], anchor: "b"))
    state = ListMultiSelect.click("d", gesture: .toggle, in: order, state: state)
    #expect(state == .init(selected: ["b", "d"], anchor: "d"))
    state = ListMultiSelect.click("b", gesture: .toggle, in: order, state: state)
    #expect(
        state == .init(selected: ["d"], anchor: "b"),
        "second ⌘-click deselects; the anchor still follows the click (the grid's rule)")
}

@Test func extendSpansAnchorToClickBothDirections() {
    let down = ListMultiSelect.click(
        "d", gesture: .extend, in: order, state: .init(selected: ["b"], anchor: "b"))
    #expect(down.selected == ["b", "c", "d"])
    #expect(down.anchor == "b", "⇧ never moves the anchor")
    let up = ListMultiSelect.click(
        "a", gesture: .extend, in: order, state: down)
    #expect(up.selected == ["a", "b", "c", "d"], "extend unions — prior range survives")
}

@Test func extendWithoutAnchorSelectsClickedRow() {
    let state = ListMultiSelect.click("c", gesture: .extend, in: order, state: .init())
    #expect(state.selected == ["c"])
    #expect(state.anchor == "c")
}

@Test func extendDegradesOnStaleIds() {

    let missing = ListMultiSelect.click(
        "z", gesture: .extend, in: order, state: .init(selected: ["b"], anchor: "b"))
    #expect(missing == .init(selected: ["b"], anchor: "b"))

    let stale = ListMultiSelect.click(
        "d", gesture: .extend, in: order, state: .init(selected: ["b"], anchor: "z"))
    #expect(stale.selected == ["b", "d"])
}

@Test func batchFollowsTheFinderRule() {
    #expect(
        ListMultiSelect.batch(clicked: "d", selection: ["b", "d", "a"], order: order)
            == ["a", "b", "d"], "inside a multi-selection → the whole set, list order")
    #expect(
        ListMultiSelect.batch(clicked: "c", selection: ["b", "d"], order: order) == ["c"],
        "outside the selection → just the clicked row")
    #expect(ListMultiSelect.batch(clicked: "c", selection: ["c"], order: order) == ["c"])
}
