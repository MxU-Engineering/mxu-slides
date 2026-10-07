import Foundation
import Testing
@testable import PresenterCore

private let shown = SheetWatch.Look(isVisible: true, alpha: 1, onScreen: true, hasArea: true)
private let orderedOut = SheetWatch.Look(isVisible: false, alpha: 1, onScreen: true, hasArea: true)

@Test func sheetWatchCallsAnyUnseeableWindowHidden() {
    #expect(!shown.isHidden && shown.summary == "visible")
    #expect(orderedOut.isHidden && orderedOut.summary == "hidden (ordered out)")
    let ghost = SheetWatch.Look(isVisible: true, alpha: 0, onScreen: false, hasArea: false)
    #expect(ghost.summary == "hidden (alpha 0.00, off screen, no area)")
}

@Test func sheetWatchReportsBeginsHidesAndEnds() {
    var watch = SheetWatch()
    let sheet = SheetWatch.Blocker(id: "7", name: "sheet NewSlideSheet on main", look: shown)

    let first = watch.observe([sheet], at: 10)
    #expect(first.began == [sheet] && first.hid.isEmpty && first.ended.isEmpty)

    var hidden = sheet
    hidden.look = orderedOut
    let second = watch.observe([hidden], at: 11)
    #expect(second.began.isEmpty && second.hid == [hidden], "a known sheet going invisible is its own line")

    let third = watch.observe([], at: 12)
    #expect(third.ended == ["sheet NewSlideSheet on main"] && watch.hiddenSince.isEmpty)
}

@Test func sheetWatchUnsticksOnlyAfterTheGraceOfBeingHidden() {
    var watch = SheetWatch()
    let ghost = SheetWatch.Blocker(id: "7", name: "sheet", look: orderedOut)
    _ = watch.observe([ghost], at: 100)
    #expect(!watch.shouldUnstick("7", at: 101.9), "still inside the grace: maybe an animation")
    #expect(watch.shouldUnstick("7", at: 102))
    #expect(!watch.shouldUnstick("8", at: 200), "an unknown blocker is never ended")

    var back = ghost
    back.look = shown
    #expect(watch.observe([back], at: 103).shown == [back], "a revealed sheet is its own line")
    #expect(!watch.shouldUnstick("7", at: 110), "a sheet the operator can see is never ended")
}

@Test func sheetWatchNamesTheBlockerOnABlockedClick() {
    let ghost = SheetWatch.Blocker(id: "7", name: "sheet QuickEditView on MxU Slides", look: orderedOut)
    #expect(
        SheetWatch.blockedClickSummary(target: "MxU Slides", blocker: ghost, hiddenFor: 3.04)
            == "click on MxU Slides blocked by sheet QuickEditView on MxU Slides: hidden (ordered out) for 3.0 s")
}

@Test func sheetWatchNamesAWindowByTheFirstAppTypeInItsContent() {
    let hosting = "SwiftUI.NSHostingView<SwiftUI.ModifiedContent<MxUSlides.NewSlideSheet, SwiftUI._FrameLayout>>"
    #expect(SheetWatch.shortName(typeDescriptions: ["SwiftUI.NSHostingController<SwiftUI.AnyView>", hosting], fallback: "NSPanel") == "NewSlideSheet")
    #expect(SheetWatch.shortName(typeDescriptions: ["SwiftUI.NSHostingView<SwiftUI.AnyView>"], fallback: "_NSAlertPanel") == "_NSAlertPanel")
}

@Test func sheetWatchCountsACoveredSheetAsHidden() {
    let behind = SheetWatch.Look(isVisible: true, alpha: 1, onScreen: true, hasArea: true, covered: true)
    #expect(behind.isHidden && behind.summary == "hidden (covered)")
}
