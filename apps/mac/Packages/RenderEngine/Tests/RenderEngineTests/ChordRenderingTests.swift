import AppKit
import Metal
import XCTest

@testable import RenderEngine

@MainActor
final class ChordRenderingTests: XCTestCase {
    private func makeCompositor() throws -> Compositor {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("No Metal device available on this machine")
        }
        return try Compositor()
    }

    private func renderText(
        _ text: StyledText,
        frame: CGRect = CGRect(x: 0, y: 0, width: 1920, height: 1080),
        width: Int = 960,
        height: Int = 540
    ) throws -> RenderedFrame {
        let compositor = try makeCompositor()
        var scene = RenderScene()
        scene.background = .black
        scene.addItem(RenderItem(id: "t", frame: frame, content: .text(text)), to: .slide)
        return try compositor.renderFrame(scene: scene, width: width, height: height)
    }

    private func pixel(_ frame: RenderedFrame, x: Int, y: Int) -> SIMD4<Float> {
        var out = SIMD4<Float>()
        frame.data.withUnsafeBytes { raw in
            let base = raw.baseAddress! + y * frame.bytesPerRow + x * 8
            let halves = base.assumingMemoryBound(to: Float16.self)
            out = SIMD4(Float(halves[0]), Float(halves[1]), Float(halves[2]), Float(halves[3]))
        }
        return out
    }

    private func inkBounds(_ frame: RenderedFrame, threshold: Float = 0.05) -> CGRect? {
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
        for y in 0..<frame.height {
            for x in 0..<frame.width {
                let p = pixel(frame, x: x, y: y)
                if max(p.x, p.y, p.z) > threshold {
                    minX = min(minX, x); minY = min(minY, y)
                    maxX = max(maxX, x); maxY = max(maxY, y)
                }
            }
        }
        guard maxX >= 0 else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    func testInterleaveAddsASpacerRowPerLine() {
        let text = StyledText(
            string: "Amazing grace\nHow sweet the sound",
            fontSize: 60, alignment: .left,
            chords: [
                ChordRun(line: 0, column: 0, symbol: "G"),
                ChordRun(line: 1, column: 4, symbol: "C"),
            ]
        )
        let layout = TextRasterizer.chordedLayout(for: text, sceneWidth: 1600, fontScale: 1)
        let chorded = layout!

        XCTAssertEqual(chorded.text.string, "\nAmazing grace\n\nHow sweet the sound")
        XCTAssertEqual(chorded.rows.count, 2)
        XCTAssertEqual(chorded.rows[0].spacerLine, 0)
        XCTAssertEqual(chorded.rows[0].lyricLine, 1)
        XCTAssertEqual(chorded.rows[0].chords.map(\.symbol), ["G"])
        XCTAssertEqual(chorded.rows[1].chords.map(\.utf16Column), [4])

        XCTAssertTrue(chorded.text.chords.isEmpty)
        XCTAssertEqual(
            chorded.text.lineOverrides.first { $0.lineIndex == 0 }?.fontSize,
            60 * TextRasterizer.chordSizeFactor
        )
    }

    func testWrapRoutesChordsToTheirFragment() {

        let text = StyledText(
            string: "Amazing grace how sweet the sound that saved a wretch like me",
            fontSize: 60, alignment: .left,
            chords: [
                ChordRun(line: 0, column: 0, symbol: "G"),
                ChordRun(line: 0, column: 56, symbol: "D7"),
            ]
        )
        let layout = TextRasterizer.chordedLayout(for: text, sceneWidth: 700, fontScale: 1)
        let chorded = layout!
        XCTAssertGreaterThan(chorded.rows.count, 1, "the line must wrap at 700 units")
        XCTAssertEqual(chorded.rows[0].chords.map(\.symbol), ["G"])
        XCTAssertEqual(chorded.rows.last?.chords.map(\.symbol), ["D7"])
    }

    func testChordOnlyLineKeepsItsAnchors() {
        let text = StyledText(
            string: "      \nAmazing grace",
            fontSize: 60, alignment: .left,
            chords: [
                ChordRun(line: 0, column: 0, symbol: "C"),
                ChordRun(line: 0, column: 6, symbol: "G"),
            ]
        )
        let chorded = TextRasterizer.chordedLayout(for: text, sceneWidth: 1600, fontScale: 1)!
        XCTAssertEqual(chorded.rows[0].chords.map(\.symbol), ["C", "G"])
    }

    func testWordlessTextStillLaysOutItsChordRow() {

        for string in ["", "Amazing grace\n"] {
            let line = string.isEmpty ? 0 : 1
            let text = StyledText(
                string: string, fontSize: 60,
                chords: [ChordRun(line: line, column: 0, symbol: "G"), ChordRun(line: line, column: 0, symbol: "D")]
            )
            let chorded = try! XCTUnwrap(TextRasterizer.chordedLayout(for: text, sceneWidth: 1600, fontScale: 1))
            XCTAssertEqual(chorded.rows.last?.chords.map(\.symbol), ["G", "D"], string)
            XCTAssertEqual(
                chorded.text.string.components(separatedBy: "\n").last, TextRasterizer.chordOnlyLyric, string
            )
        }
    }

    func testMeasuredHeightGrowsWithChords() {
        let plain = StyledText(string: "Amazing grace", fontSize: 96, autoShrink: true, minFontSize: 10)
        var chorded = plain
        chorded.chords = [ChordRun(line: 0, column: 0, symbol: "G")]

        let tightHeight = CGSize(width: 1600, height: 130)
        let plainScale = TextRasterizer.fittedFontScale(for: plain, sceneFrame: tightHeight)
        let chordedScale = TextRasterizer.fittedFontScale(for: chorded, sceneFrame: tightHeight)
        XCTAssertEqual(plainScale, 1)
        XCTAssertLessThan(chordedScale, 1, "chord rows take real height")
    }

    func testChordedShrinkPreventsSoftWrap() {

        let text = StyledText(
            string: "Amazing grace how sweet the sound", fontSize: 96,
            autoShrink: true, minFontSize: 10,
            chords: [ChordRun(line: 0, column: 0, symbol: "G")]
        )
        let frame = CGSize(width: 900, height: 600)
        let scale = TextRasterizer.fittedFontScale(for: text, sceneFrame: frame)
        XCTAssertLessThan(scale, 1, "the line is wider than 900 at 96pt — must shrink")
        let layout = TextRasterizer.chordedLayout(
            for: text, sceneWidth: frame.width, fontScale: scale
        )
        XCTAssertEqual(layout?.rows.count, 1, "one source line = one fragment after the fit")

        var plain = text
        plain.chords = []
        XCTAssertEqual(TextRasterizer.fittedFontScale(for: plain, sceneFrame: frame), 1)
    }

    func testChordInkDrawsAboveTheLyric() throws {
        let plain = StyledText(
            string: "grace", fontSize: 200, alignment: .left, verticalAlignment: .bottom
        )
        var chorded = plain
        chorded.chords = [ChordRun(line: 0, column: 0, symbol: "G")]
        let plainBounds = try XCTUnwrap(inkBounds(try renderText(plain)))
        let chordedBounds = try XCTUnwrap(inkBounds(try renderText(chorded)))
        XCTAssertLessThan(
            chordedBounds.minY, plainBounds.minY - 10,
            "chord ink must appear above the lyric line"
        )
    }

    func testWordlessChordRowAlignsLikeTheWords() throws {

        let text = StyledText(
            string: "", fontSize: 200, alignment: .center,
            chords: [ChordRun(line: 0, column: 0, symbol: "G"), ChordRun(line: 0, column: 0, symbol: "C")]
        )
        let rendered = try renderText(text)
        let bounds = try XCTUnwrap(inkBounds(rendered), "a blank slide's chords must draw")
        XCTAssertLessThan(bounds.minX, CGFloat(rendered.width) / 2)
        XCTAssertGreaterThan(bounds.maxX, CGFloat(rendered.width) / 2)
    }

    func testChordColorTintsTheChordRow() throws {
        var text = StyledText(
            string: "grace", fontSize: 200, alignment: .left, verticalAlignment: .bottom,
            chords: [ChordRun(line: 0, column: 0, symbol: "G")]
        )
        text.chordColor = SceneColor(red: 1, green: 0, blue: 0)
        let frame = try renderText(text)

        var foundRed = false
        for y in 0..<frame.height where !foundRed {
            for x in 0..<frame.width {
                let p = pixel(frame, x: x, y: y)
                if p.x > 0.3, p.y < 0.05, p.z < 0.05 { foundRed = true; break }
            }
        }
        XCTAssertTrue(foundRed, "the chord row must wear the chord color")
    }

    func testAdjacentChordsNeverOverlap() {

        let text = StyledText(
            string: "go", fontSize: 200, alignment: .left,
            chords: [
                ChordRun(line: 0, column: 0, symbol: "Gmaj7"),
                ChordRun(line: 0, column: 0, symbol: "Cadd9"),
            ]
        )
        let chorded = TextRasterizer.chordedLayout(for: text, sceneWidth: 1900, fontScale: 1)!
        XCTAssertEqual(chorded.rows[0].chords.count, 2)
    }
}
