import Foundation
import Testing
@testable import PresenterCore

@Test func inputTrailNamesTheNewestInputsFirstWithTheirAges() {
    var trail = InputTrail()
    #expect(trail.summary(at: 5) == "no input yet")
    trail.record("click in run order", at: 10)
    trail.record("scroll in present", at: 11)
    trail.record("scroll in present", at: 11.6)
    trail.record("key ↓ (focus run order)", at: 12)
    #expect(
        trail.summary(at: 12.03)
            == "key ↓ (focus run order) 0.03 s ago · scroll in present 0.43 s ago · click in run order 2.03 s ago",
        "a scroll burst is one line, timed by its newest event")
    #expect(abs((trail.age(of: "scroll", at: 12) ?? -1) - 0.4) < 0.0001)
    #expect(trail.age(of: "right-click", at: 12) == nil)
}

@Test func inputTrailKeepsOnlyTheLastFewInputs() {
    var trail = InputTrail()
    for index in 0..<6 { trail.record("click \(index)", at: Double(index)) }
    #expect(trail.entries.map(\.what) == ["click 2", "click 3", "click 4", "click 5"])
}

@Test func keyNamesReadForClickerKeysArrowsAndLetters() {
    #expect(InputTrail.keyName(keyCode: 125, characters: "\u{F701}") == "↓")
    #expect(InputTrail.keyName(keyCode: 121, characters: "\u{F72D}") == "page down")
    #expect(InputTrail.keyName(keyCode: 1, characters: "S") == "s")
    #expect(InputTrail.keyName(keyCode: 45, characters: "n", command: true, shift: true) == "⇧⌘n")
    #expect(InputTrail.keyName(keyCode: 200, characters: nil) == "code 200")
}

@Test func aBigMoveWithNoScrollOrRunOrderJumpIsUnprompted() {
    #expect(PresentJumpRule.isUnprompted(delta: -900, viewport: 1000, sinceScroll: 3, sinceFocus: nil))
    #expect(!PresentJumpRule.isUnprompted(delta: 900, viewport: 1000, sinceScroll: 0.2, sinceFocus: nil), "the operator scrolled")
    #expect(!PresentJumpRule.isUnprompted(delta: 900, viewport: 1000, sinceScroll: nil, sinceFocus: 0.3), "a run-order jump")
    #expect(!PresentJumpRule.isUnprompted(delta: 300, viewport: 1000, sinceScroll: nil, sinceFocus: nil), "a small nudge")
    #expect(!PresentJumpRule.isUnprompted(delta: 900, viewport: 0, sinceScroll: nil, sinceFocus: nil), "not laid out yet")
}

@Test func aReflowCountsOnlyWhenScrolledAndLarge() {
    #expect(PresentJumpRule.isReflow(delta: 1200, offset: 4000, viewport: 1000))
    #expect(!PresentJumpRule.isReflow(delta: 1200, offset: 0, viewport: 1000), "at the top nothing above can shift it")
    #expect(!PresentJumpRule.isReflow(delta: 200, offset: 4000, viewport: 1000))
}

@Test func theLandingNamesTheCardUnderTheViewportTop() {
    let cards = [
        PresentLanding.Card(id: "song1", top: -900, height: 600),
        PresentLanding.Card(id: "song2", top: -300, height: 700),
        PresentLanding.Card(id: "sermon", top: 400, height: 500),
    ]
    #expect(PresentLanding.cardAtTop(cards)?.id == "song2", "song2 spans the top edge")
    #expect(PresentLanding.cardAtTop([cards[0], cards[2]])?.id == "sermon", "a gap at the top: the next card down")
    #expect(PresentLanding.cardAtTop([PresentLanding.Card(id: "a", top: 0, height: 10)])?.id == "a", "landed exactly")
    #expect(PresentLanding.cardAtTop([]) == nil)
}

@Test func theAnchorIsTheCardAtTheTopAndHowFarIntoItTheViewSits() {
    let before = [
        PresentLanding.Card(id: "song1", top: -1200, height: 800),
        PresentLanding.Card(id: "sermon", top: -400, height: 1600),
        PresentLanding.Card(id: "close", top: 1200, height: 300),
    ]
    let anchor = PresentLanding.anchor(before)
    #expect(anchor == PresentLanding.Anchor(id: "sermon", fraction: 0.25), "no grid known: the share of the card")

    let after = [
        PresentLanding.Card(id: "song1", top: -900, height: 600),
        PresentLanding.Card(id: "sermon", top: -300, height: 1200),
        PresentLanding.Card(id: "close", top: 900, height: 225),
    ]
    #expect(PresentLanding.correction(for: anchor!, in: after) == 0, "the same share into the sermon: nothing to fix")
    let shifted = [PresentLanding.Card(id: "sermon", top: 200, height: 1200)]
    #expect(PresentLanding.correction(for: anchor!, in: shifted) == 500, "scroll down 200 to its top, then a quarter of 1200")
    #expect(PresentLanding.correction(for: anchor!, in: [after[0]]) == nil, "its card is gone")
    #expect(PresentLanding.anchor([PresentLanding.Card(id: "a", top: 50, height: 100)])?.fraction == 0, "below the top edge: its start")
}

@Test func insideAGridTheAnchorIsTheSlideAtTheTop() {
    let cards = [PresentLanding.Card(id: "teaching", top: -500, height: 2400)]

    let three = [PresentLanding.Grid(id: "teaching", top: -440, rowPitch: 200, across: 3, count: 36)]
    let anchor = PresentLanding.anchor(cards, grids: three)
    #expect(anchor?.slide == 6, "row 2 of 3 across starts at slide index 6 (slide 7)")
    #expect(abs((anchor?.intoRow ?? 0) - 0.2) < 0.0001, "40 pt into a 200 pt row")

    let four = [PresentLanding.Grid(id: "teaching", top: -240, rowPitch: 160, across: 4, count: 36)]
    let fix = PresentLanding.correction(for: anchor!, in: cards, grids: four) ?? 0
    let expected: CGFloat = -240 + 160 + 32
    #expect(abs(fix - expected) < 0.0001, "slide 7 is in row 1 at 4 across: that row, 20% in, goes to the top")

    let inHeader = [PresentLanding.Grid(id: "teaching", top: 40, rowPitch: 200, across: 3, count: 36)]
    #expect(PresentLanding.anchor(cards, grids: inHeader)?.slide == nil, "the top edge is above the grid: the card share")
}

@Test func aKeyboardFiredRowStaysInTheMiddleOfTheView() {

    let reveal = { (top: CGFloat) in
        PresentLanding.reveal(rowTop: top, rowPitch: 200, viewport: 1000, topInset: 44)
    }
    #expect(reveal(400) == nil, "in the band: the view stays where the operator left it")
    #expect(reveal(700) == 136, "the next row down leaves the band: back to its bottom edge, rows below still show")
    #expect(reveal(3000) == 2436, "far below: the same, to the band's edge")
    #expect(reveal(100) == -192, "high in the view or under the header: down to the band's top")
    #expect(reveal(-800) == -1092, "far above")
    #expect(
        PresentLanding.reveal(rowTop: 900, rowPitch: 1200, viewport: 1000, topInset: 44) == 608,
        "a row taller than the band keeps its top at the band's top")

    let grid = PresentLanding.Grid(id: "song", top: 1500, rowPitch: 200, across: 3, count: 8)
    #expect(PresentLanding.rowTop(slide: 0, in: grid) == 1500)
    #expect(PresentLanding.rowTop(slide: 5, in: grid) == 1700, "slide 6 sits in row 2 at 3 across")
    #expect(PresentLanding.rowTop(slide: 40, in: grid) == 1900, "past the end: the last row")
}

@Test func theHeldCardStaysPutWhenCardsAboveItChange() {
    #expect(PresentHold.correction(heldTop: 14000, nowTop: 15968) == 1968, "the notes above grew: follow them down")
    #expect(PresentHold.correction(heldTop: 14000, nowTop: 12000) == -2000)
    #expect(PresentHold.correction(heldTop: 14000, nowTop: 14000.4) == nil, "sub-point jitter is not a move")
}

@Test func theHoldNamesTheCardsThatChanged() {
    let names = ["t": "Teaching", "s": "Social Break", "m": "Made For More"]
    #expect(PresentHold.changes(before: ["t": 3300, "s": 400, "m": 900], after: ["t": 5268, "s": 400, "m": 880], names: names)
            == "\"Teaching\" +1968, \"Made For More\" -20")
    #expect(PresentHold.changes(before: ["t": 3300], after: ["t": 3300], names: names) == "no card changed height")
}

@Test func theHoldStandsDownOnABurstOfCorrections() {
    var recent: [TimeInterval] = []
    for tick in 0 ..< 6 {
        #expect(PresentHold.mayCorrect(recent: recent, now: 10 + Double(tick) * 0.05))
        recent = PresentHold.recording(10 + Double(tick) * 0.05, in: recent)
    }
    #expect(!PresentHold.mayCorrect(recent: recent, now: 10.3), "the seventh within the second")
    #expect(PresentHold.mayCorrect(recent: recent, now: 11.5), "a second later it holds again")
    #expect(PresentHold.recording(20, in: recent) == [20], "old corrections age out")
}
