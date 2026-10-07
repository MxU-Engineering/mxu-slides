import Foundation
import Testing
@testable import PresenterCore

@Test func menuTrackSummaryKeepsTheOldFieldsAndAddsClickSubmenuHoverAndStalls() {
    var timeline = MenuTrackingTimeline(title: "", itemCount: 7, began: 100.085, lastClick: 100.0, windows: 1)
    timeline.sample(at: 100.185, windows: 1, hoveringSubmenuItem: false)
    timeline.sample(at: 100.495, windows: 1, hoveringSubmenuItem: true)
    timeline.noteHitch()
    timeline.sample(at: 100.595, windows: 2, hoveringSubmenuItem: true)
    timeline.sample(at: 100.695, windows: 1, hoveringSubmenuItem: false)
    #expect(
        timeline.summary(endedAt: 101.185)
            == "(context) 7 items, 1.10 s, menu windows peak 2 (submenu opened), hitches 1, opened after 85 ms,"
            + " submenu after 510 ms, hovered submenu item: yes after 410 ms, longest tick gap 490 ms, late ticks 2",
        "the 310 ms and the 490 ms gaps are each at least 100 ms past the 0.1 s tick")
}

@Test func menuTrackSaysNeverHoveredApartFromHoveredButNoSubmenu() {
    var never = MenuTrackingTimeline(title: "File", itemCount: 4, began: 10, lastClick: nil, windows: 0)
    never.sample(at: 10.1, windows: 1, hoveringSubmenuItem: false)
    #expect(
        never.summary(endedAt: 10.2)
            == "File 4 items, 0.20 s, menu windows peak 1 (no submenu), hitches 0, opened after ? ms (no click),"
            + " submenu never, hovered submenu item: no, longest tick gap 100 ms, late ticks 0")

    var stuck = MenuTrackingTimeline(title: "", itemCount: 7, began: 10, lastClick: 9.9, windows: 1)
    stuck.sample(at: 10.1, windows: 1, hoveringSubmenuItem: true)
    #expect(stuck.hoveredSubmenuAfter != nil && stuck.submenuAfter == nil, "the booth symptom: hovered, no submenu window")
}

@Test func menuTrackIgnoresAClickOutsideTheWindow() {
    let stale = MenuTrackingTimeline(title: "", itemCount: 1, began: 20, lastClick: 16.9, windows: 1)
    let future = MenuTrackingTimeline(title: "", itemCount: 1, began: 20, lastClick: 20.5, windows: 1)
    let edge = MenuTrackingTimeline(title: "", itemCount: 1, began: 20, lastClick: 17, windows: 1)
    #expect(stale.openLatency == nil && future.openLatency == nil && edge.openLatency == 3)
}

@Test func menuTrackCountsTheCloseAsAFinalTick() {
    let timeline = MenuTrackingTimeline(title: "", itemCount: 3, began: 0, lastClick: nil, windows: 1)
    #expect(timeline.summary(endedAt: 0.75).hasSuffix("longest tick gap 750 ms, late ticks 1"), "a menu the sampler never reached still reports the stall")
}
