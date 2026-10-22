import Foundation
import Testing
@testable import SlideScene

@Test func windowIsNilUntrimmed() {
    #expect(MediaTrimEdit.window(inPoint: nil, outPoint: nil, duration: 40) == nil)
    #expect(MediaTrimEdit.window(inPoint: 0.02, outPoint: 39.97, duration: 40) == nil, "edges within slack read as ends")
    #expect(MediaTrimEdit.window(inPoint: 30, outPoint: 10, duration: 40) == nil, "an inverted pair is no window")
}

@Test func windowAndFractionsFollowThePoints() {
    #expect(MediaTrimEdit.window(inPoint: 5, outPoint: 30, duration: 40) == 5 ... 30)
    #expect(MediaTrimEdit.window(inPoint: 5, outPoint: 90, duration: 40) == 5 ... 40, "out clamps to the file")
    #expect(MediaTrimEdit.fractions(inPoint: 10, outPoint: 30, duration: 40) == 0.25 ... 0.75)
    #expect(MediaTrimEdit.fractions(inPoint: 10, outPoint: 30, duration: 0) == nil, "no duration yet, no shrouds")
}

@Test func pointsFromABarDragTidyAndClearAtTheEnds() {
    let dragged = MediaTrimEdit.points(fractions: 0.25 ... 0.756, duration: 40)
    #expect(dragged.inPoint == 10)
    #expect(dragged.outPoint == 30.24)
    let parked = MediaTrimEdit.points(fractions: 0 ... 1, duration: 40)
    #expect(parked.inPoint == nil)
    #expect(parked.outPoint == nil)
}
