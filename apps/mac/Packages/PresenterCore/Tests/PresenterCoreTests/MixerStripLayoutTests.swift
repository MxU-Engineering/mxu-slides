import Foundation
import Testing
@testable import PresenterCore

@Test func mixerFaderHeightLeavesRoomForTheGrabBar() {

    #expect(MixerStripLayout.faderHeight(viewportHeight: 500, scrollerHeight: 13) == 262)
    #expect(MixerStripLayout.faderHeight(viewportHeight: 500, scrollerHeight: 0) == 275)
}

@Test func mixerFaderHeightNeverDropsBelowClassicTravel() {
    #expect(MixerStripLayout.faderHeight(viewportHeight: 300, scrollerHeight: 13) == 92)

    #expect(MixerStripLayout.faderHeight(viewportHeight: 0, scrollerHeight: 13) == 92)
}

@Test func mixerGrabBarSnapsNearMissesOntoTheBar() {

    #expect(MixerStripLayout.grabBarY(8, barMinY: 4, barMaxY: 17) == 8)
    #expect(MixerStripLayout.grabBarY(19, barMinY: 4, barMaxY: 17) == 16)
    #expect(MixerStripLayout.grabBarY(1, barMinY: 4, barMaxY: 17) == 5)
}
