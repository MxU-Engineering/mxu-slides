import Foundation
import Testing
@testable import PresenterCore

@Test func sidewaysWheelTurnsMouseTicksIntoStripTravel() {

    let travel = SidewaysWheelLogic.sidewaysTravel(
        deltaX: 0, deltaY: -1, precise: false, contentWidth: 900, visibleWidth: 400)
    #expect(travel == SidewaysWheelLogic.pointsPerNotch)
    let back = SidewaysWheelLogic.sidewaysTravel(
        deltaX: 0, deltaY: 2, precise: false, contentWidth: 900, visibleWidth: 400)
    #expect(back == -2 * SidewaysWheelLogic.pointsPerNotch)
}

@Test func sidewaysWheelLeavesTrackpadAndSidewaysEventsAlone() {

    #expect(SidewaysWheelLogic.sidewaysTravel(
        deltaX: 0, deltaY: -1, precise: true, contentWidth: 900, visibleWidth: 400) == nil)

    #expect(SidewaysWheelLogic.sidewaysTravel(
        deltaX: 3, deltaY: 0, precise: false, contentWidth: 900, visibleWidth: 400) == nil)
    #expect(SidewaysWheelLogic.sidewaysTravel(
        deltaX: 0, deltaY: 0, precise: false, contentWidth: 900, visibleWidth: 400) == nil)
}

@Test func sidewaysWheelPassesThroughWhenTheRowFits() {

    #expect(SidewaysWheelLogic.sidewaysTravel(
        deltaX: 0, deltaY: -1, precise: false, contentWidth: 300, visibleWidth: 400) == nil)
    #expect(SidewaysWheelLogic.sidewaysTravel(
        deltaX: 0, deltaY: -1, precise: false, contentWidth: 400, visibleWidth: 400) == nil)
}

@Test func sidewaysWheelClampsToTheRowsEnds() {
    #expect(SidewaysWheelLogic.clampedOrigin(
        current: 0, travel: -30, contentWidth: 900, visibleWidth: 400) == 0)
    #expect(SidewaysWheelLogic.clampedOrigin(
        current: 490, travel: 30, contentWidth: 900, visibleWidth: 400) == 500)
    #expect(SidewaysWheelLogic.clampedOrigin(
        current: 100, travel: 30, contentWidth: 900, visibleWidth: 400) == 130)

    #expect(SidewaysWheelLogic.clampedOrigin(
        current: 50, travel: 30, contentWidth: 300, visibleWidth: 400) == 0)
}
