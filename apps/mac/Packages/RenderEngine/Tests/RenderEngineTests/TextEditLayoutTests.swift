import AppKit
import Metal
import XCTest

@testable import RenderEngine

@MainActor
final class TextEditLayoutTests: XCTestCase {
    private let box = CGSize(width: 1920, height: 1080)

    func testAllCapsCaretFollowsTheUppercaseGlyphs() {
        let caps = TextEditLayout(
            text: StyledText(string: "abc", fontSize: 120, alignment: .left, transform: .uppercase), sceneFrame: box
        )
        let upper = TextEditLayout(text: StyledText(string: "ABC", fontSize: 120, alignment: .left), sceneFrame: box)
        let lower = TextEditLayout(text: StyledText(string: "abc", fontSize: 120, alignment: .left), sceneFrame: box)

        XCTAssertEqual(caps.caretRect(at: 3).minX, upper.caretRect(at: 3).minX, accuracy: 0.01)
        XCTAssertGreaterThan(caps.caretRect(at: 3).minX, lower.caretRect(at: 3).minX + 5)
    }

    func testWidenedUppercaseKeepsSourceIndexes() {

        let caps = TextEditLayout(
            text: StyledText(string: "aßb", fontSize: 120, alignment: .left, transform: .uppercase), sceneFrame: box
        )
        let upper = TextEditLayout(text: StyledText(string: "ASSB", fontSize: 120, alignment: .left), sceneFrame: box)

        XCTAssertEqual(caps.sourceLength, 3)
        XCTAssertEqual(caps.caretRect(at: 2).minX, upper.caretRect(at: 3).minX, accuracy: 0.01)
        XCTAssertEqual(caps.index(at: CGPoint(x: upper.caretRect(at: 3).minX + 1, y: 540)), 2)
    }

    func testClicksRoundTripAcrossWrappedLines() {
        let text = StyledText(
            string: "The quick brown fox jumps over the lazy dog\nSecond line",
            fontSize: 96, alignment: .center, verticalAlignment: .middle
        )
        let layout = TextEditLayout(text: text, sceneFrame: CGSize(width: 900, height: 1080))
        let firstLineY = layout.caretRect(at: 0).midY
        let lastLineY = layout.caretRect(at: layout.sourceLength).midY

        XCTAssertGreaterThan(lastLineY - firstLineY, 96 * 2, "wraps to at least three lines")
        for index in [0, 4, 10, 20, 44, layout.sourceLength] {
            let caret = layout.caretRect(at: index)
            XCTAssertEqual(layout.index(at: CGPoint(x: caret.minX + 0.5, y: caret.midY)), index, "index \(index)")
        }
    }

    func testVerticalMovesAndLineBoundariesFollowTheLaidOutLines() {
        let layout = TextEditLayout(
            text: StyledText(string: "one\ntwo\nthree", fontSize: 96, alignment: .left), sceneFrame: box
        )
        let goal = layout.caretRect(at: 1).minX

        XCTAssertEqual(layout.index(from: 1, movingLines: 1, goalX: goal), 5)
        XCTAssertEqual(layout.index(from: 5, movingLines: -1, goalX: goal), 1)
        XCTAssertEqual(layout.index(from: 1, movingLines: -1, goalX: goal), 0)
        XCTAssertEqual(layout.index(from: 9, movingLines: 1, goalX: goal), 13)
        XCTAssertEqual(layout.lineBoundary(of: 5, end: false), 4)
        XCTAssertEqual(layout.lineBoundary(of: 5, end: true), 7)
    }

    func testSelectionSpansEveryCoveredLine() {
        let layout = TextEditLayout(
            text: StyledText(string: "one\ntwo\nthree", fontSize: 96, alignment: .left), sceneFrame: box
        )

        XCTAssertEqual(layout.selectionRects(for: NSRange(location: 1, length: 8)).count, 3)
        XCTAssertEqual(layout.selectionRects(for: NSRange(location: 4, length: 3)).count, 1)
        XCTAssertTrue(layout.selectionRects(for: NSRange(location: 4, length: 0)).isEmpty)
    }

    func testEmptyTextAndTrailingNewlineStillPlaceTheCaret() {
        let empty = TextEditLayout(
            text: StyledText(string: "", fontSize: 96, alignment: .center, verticalAlignment: .middle), sceneFrame: box
        )
        XCTAssertEqual(empty.caretRect(at: 0).midX, 960, accuracy: 1)
        XCTAssertEqual(empty.caretRect(at: 0).midY, 540, accuracy: 30)

        let trailing = TextEditLayout(
            text: StyledText(string: "one\n", fontSize: 96, alignment: .left, verticalAlignment: .top), sceneFrame: box
        )
        let first = trailing.caretRect(at: 0)
        let next = trailing.caretRect(at: 4)
        XCTAssertGreaterThan(next.minY, first.maxY - 1)
        XCTAssertEqual(next.minX, first.minX, accuracy: 0.5)
    }

    func testChordRowsSitBetweenLyricLinesNotUnderTheCaret() {
        let plain = StyledText(string: "Amazing\ngrace", fontSize: 96, alignment: .left, verticalAlignment: .top)
        var chorded = plain
        chorded.chords = [ChordRun(line: 0, column: 0, symbol: "G"), ChordRun(line: 1, column: 0, symbol: "C")]
        let plainLayout = TextEditLayout(text: plain, sceneFrame: box)
        let chordLayout = TextEditLayout(text: chorded, sceneFrame: box)

        XCTAssertGreaterThan(chordLayout.caretRect(at: 0).minY, plainLayout.caretRect(at: 0).minY + 20)
        XCTAssertGreaterThan(
            chordLayout.caretRect(at: 8).minY - chordLayout.caretRect(at: 0).minY,
            plainLayout.caretRect(at: 8).minY - plainLayout.caretRect(at: 0).minY + 20
        )

        XCTAssertLessThan(chordLayout.caretRect(at: 7).minY, chordLayout.caretRect(at: 8).minY)

        let down = chordLayout.index(from: 3, movingLines: 1, goalX: chordLayout.caretRect(at: 3).minX)
        XCTAssertTrue((9 ... 12).contains(down), "landed at \(down)")
    }

    func testChordBoxesSitOverTheirWordsAndDropAnchorsSpeakLineAndColumn() throws {
        var text = StyledText(string: "Amazing grace\nhow sweet", fontSize: 96, alignment: .left, verticalAlignment: .top)
        text.chords = [
            ChordRun(line: 1, column: 4, symbol: "D"),
            ChordRun(line: 0, column: 8, symbol: "C"),
            ChordRun(line: 0, column: 0, symbol: "G"),
        ]
        let layout = TextEditLayout(text: text, sceneFrame: box)

        XCTAssertEqual(Set(layout.chords.map(\.index)), [0, 1, 2])
        let g = try XCTUnwrap(layout.chords.first { $0.index == 2 }).rect
        let c = try XCTUnwrap(layout.chords.first { $0.index == 1 }).rect
        let d = try XCTUnwrap(layout.chords.first { $0.index == 0 }).rect

        XCTAssertEqual(c.minX, layout.caretRect(at: 8).minX, accuracy: 0.5)
        XCTAssertLessThan(c.maxY, layout.caretRect(at: 8).minY + 2)
        XCTAssertEqual(d.minX, layout.caretRect(at: 18).minX, accuracy: 0.5)
        XCTAssertGreaterThan(d.minY, g.maxY, "line 2's chord row sits below line 1")

        XCTAssertEqual(layout.chord(at: CGPoint(x: c.midX, y: c.midY), slop: 4), 1)
        XCTAssertEqual(layout.chord(at: CGPoint(x: g.minX - 3, y: g.midY), slop: 4), 2)
        XCTAssertNil(layout.chord(at: CGPoint(x: 1800, y: g.midY), slop: 4))

        let sweet = layout.caretRect(at: 18)
        XCTAssertTrue(layout.anchor(at: CGPoint(x: sweet.minX + 1, y: sweet.midY)) == (1, 4))
        XCTAssertEqual(layout.caretRect(line: 1, column: 4), sweet)
        XCTAssertTrue(layout.anchor(at: CGPoint(x: 0, y: layout.caretRect(at: 0).midY)) == (0, 0))
    }

    func testCaretBracketsTheRenderedInk() throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("No Metal device available on this machine")
        }
        let text = StyledText(
            string: "HHHH", fontSize: 200, alignment: .left, verticalAlignment: .bottom, transform: .uppercase
        )
        var scene = RenderScene()
        scene.background = .black
        scene.addItem(RenderItem(id: "t", frame: CGRect(origin: .zero, size: box), content: .text(text)), to: .slide)
        let frame = try Compositor().renderFrame(scene: scene, width: 960, height: 540)
        let layout = TextEditLayout(text: text, sceneFrame: box)
        let start = layout.caretRect(at: 0)
        let end = layout.caretRect(at: 4)

        var inkColumns: [Int] = []
        var inkRows: [Int] = []
        frame.data.withUnsafeBytes { raw in
            for y in 0 ..< frame.height {
                for x in 0 ..< frame.width {
                    let halves = (raw.baseAddress! + y * frame.bytesPerRow + x * 8).assumingMemoryBound(to: Float16.self)
                    if Float(halves[0]) > 0.5 {
                        inkColumns.append(x * 2)
                        inkRows.append(y * 2)
                    }
                }
            }
        }
        let inkLeft = CGFloat(try XCTUnwrap(inkColumns.min()))
        let inkRight = CGFloat(try XCTUnwrap(inkColumns.max()))
        let inkTop = CGFloat(try XCTUnwrap(inkRows.min()))
        let inkBottom = CGFloat(try XCTUnwrap(inkRows.max()))

        XCTAssertEqual(start.minX, inkLeft, accuracy: 24)
        XCTAssertEqual(end.minX, inkRight, accuracy: 24)
        XCTAssertLessThanOrEqual(start.minY, inkTop)
        XCTAssertGreaterThanOrEqual(start.maxY, inkBottom)
        XCTAssertGreaterThan(start.minY, 700, "bottom-aligned text carets near the bottom")
    }
}
