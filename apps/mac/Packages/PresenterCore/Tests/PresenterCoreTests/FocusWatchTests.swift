import Foundation
import Testing
@testable import PresenterCore

private let stuck = FocusWatch.Click(
    appActive: true, hasKeyWindow: false, targetIsMain: true, targetCanBecomeKey: true, targetBlocked: false)

@Test func focusWatchHandsKeyToAClickedMainWindowWhenNoneHasIt() {
    #expect(stuck.rescuesBeforeClick)
    #expect(stuck.summary == "app active, no key window")

    var normal = stuck
    normal.hasKeyWindow = true
    #expect(!normal.rescuesBeforeClick, "a window already has key: the click is ordinary")

    var activating = stuck
    activating.appActive = false
    #expect(!activating.rescuesBeforeClick, "an inactive app's click activates it the usual way")
}

@Test func focusWatchLeavesBlockedPanelAndCommandClicksAlone() {
    var blocked = stuck
    blocked.targetBlocked = true
    #expect(!blocked.rescuesBeforeClick && !blocked.isStuck(hasKeyWindowAfter: false), "a sheet holds it")

    var panel = stuck
    panel.targetIsMain = false
    #expect(!panel.rescuesBeforeClick && !panel.isStuck(hasKeyWindowAfter: false))

    var command = stuck
    command.command = true
    #expect(!command.isStuck(hasKeyWindowAfter: false), "⌘-click never takes key")
}

@Test func focusWatchCallsAClickThatLeftNoKeyWindowStuck() {
    var inactive = stuck
    inactive.appActive = false
    #expect(inactive.isStuck(hasKeyWindowAfter: false), "even inactive: a click on the window should have activated it")
    #expect(!inactive.isStuck(hasKeyWindowAfter: true))
    var noKey = stuck
    noKey.targetCanBecomeKey = false
    #expect(noKey.summary == "app active, no key window, window can't become key")
}
