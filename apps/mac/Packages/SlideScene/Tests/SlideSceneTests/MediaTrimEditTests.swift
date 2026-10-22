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

@Test func typedInClampsClearsAndSwallowsALaterOut() {
    #expect(MediaTrimEdit.typedIn(12.345, outPoint: 30, duration: 40) == (12.35, 30))
    #expect(MediaTrimEdit.typedIn(0, outPoint: 30, duration: 40) == (nil, 30), "the start clears it")
    #expect(MediaTrimEdit.typedIn(nil, outPoint: 30, duration: 40) == (nil, 30), "an emptied field clears it")
    #expect(MediaTrimEdit.typedIn(35, outPoint: 30, duration: 40) == (35, nil), "past the out: a fresh window to the end")
    #expect(MediaTrimEdit.typedIn(99, outPoint: nil, duration: 40) == (40, nil), "clamped into the file")
}

@Test func typedOutClampsClearsAndRefusesBeforeTheIn() {
    #expect(MediaTrimEdit.typedOut(30, inPoint: 10, duration: 40)! == (10, 30))
    #expect(MediaTrimEdit.typedOut(99, inPoint: 10, duration: 40)! == (10, nil), "the end clears it")
    #expect(MediaTrimEdit.typedOut(nil, inPoint: 10, duration: 40)! == (10, nil))
    #expect(MediaTrimEdit.typedOut(8, inPoint: 10, duration: 40) == nil, "before the in is refused")
}

@Test func timecodesParseAndFormat() {
    #expect(MediaTrimEdit.seconds(fromTimecode: "1:05.5") == 65.5)
    #expect(MediaTrimEdit.seconds(fromTimecode: "65.5") == 65.5)
    #expect(MediaTrimEdit.seconds(fromTimecode: " 0:15 ") == 15)
    #expect(MediaTrimEdit.seconds(fromTimecode: "1:02:03") == 3723)
    #expect(MediaTrimEdit.seconds(fromTimecode: "abc") == nil)
    #expect(MediaTrimEdit.seconds(fromTimecode: "1:") == nil)
    #expect(MediaTrimEdit.seconds(fromTimecode: "-3") == nil)
    #expect(MediaTrimEdit.timecode(65.5) == "1:05.5")
    #expect(MediaTrimEdit.timecode(15.44) == "0:15.4")
}
