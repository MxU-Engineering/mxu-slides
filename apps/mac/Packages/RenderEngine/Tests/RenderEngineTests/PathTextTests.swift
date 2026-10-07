import CoreGraphics
import Metal
import QuartzCore
import XCTest
@testable import RenderEngine

@MainActor
final class PathTextTests: XCTestCase {

    private func flatCircle(size: CGFloat = 200) -> PathTextLayout.FlatPath {
        let rect = CGRect(x: 0, y: 0, width: size, height: size)
        let path = SVGPathParser.path(from: PathPresets.ellipse, in: rect)!
        return PathTextLayout.flatten(path)!
    }

    func testCirclePresetFlattensClosedWithCircumferentialLength() {
        let flat = flatCircle()
        XCTAssertTrue(flat.isClosed)

        XCTAssertEqual(flat.totalLength, .pi * 200, accuracy: .pi * 200 * 0.01)
    }

    func testLinePresetFlattensOpenWithExactLength() {
        let rect = CGRect(x: 0, y: 0, width: 300, height: 100)
        let path = SVGPathParser.path(from: PathPresets.line, in: rect)!
        let flat = PathTextLayout.flatten(path)!
        XCTAssertFalse(flat.isClosed)
        XCTAssertEqual(flat.totalLength, 300, accuracy: 0.001)
    }

    func testFlatteningIsDeterministic() {

        let first = flatCircle()
        let second = flatCircle()
        XCTAssertEqual(first, second)
    }

    private func makeRun(glyphWidths: [CGFloat], pad: CGFloat = 4) -> PathTextLayout.Run {

        let runLength = glyphWidths.reduce(0, +)
        let stripWidth = runLength + 2 * pad
        var cells: [PathTextLayout.GlyphCell] = []
        var penX: CGFloat = 0
        for (index, width) in glyphWidths.enumerated() {
            let left: CGFloat = index == 0 ? 0 : pad + penX
            let right: CGFloat = index == glyphWidths.count - 1 ? stripWidth : pad + penX + width
            cells.append(
                PathTextLayout.GlyphCell(
                    centerAdvancePx: (left + right) / 2 - pad,
                    uv: CGRect(
                        x: left / stripWidth, y: 0,
                        width: (right - left) / stripWidth, height: 1
                    ),
                    tileWidthPx: right - left
                )
            )
            penX += width
        }
        return PathTextLayout.Run(
            cells: cells,
            runLengthPx: runLength,
            stripWidthPx: Int(stripWidth),
            stripHeightPx: 40,
            baselineFromBottomPx: 12,
            padXPx: pad
        )
    }

    func testClosedPathWrapIsContinuousAcrossTheSeam() {

        let flat = flatCircle()
        let run = makeRun(glyphWidths: [10])
        let total = flat.totalLength

        var previous: CGPoint?
        for step in 0...40 {

            let phase = total - 2 + CGFloat(step) * 0.1 - run.cells[0].centerAdvancePx
            let placed = PathTextLayout.place(
                run: run, along: flat, phasePx: phase, alignment: .left, isScrolling: true
            )
            XCTAssertEqual(placed.count, 1, "glyph must never vanish at the seam")
            if let previous {
                let jump = hypot(placed[0].center.x - previous.x, placed[0].center.y - previous.y)
                XCTAssertLessThan(jump, 1.0, "seam crossing must be continuous")
            }
            previous = placed[0].center
        }
    }

    func testOpenPathCullsGlyphsBeyondTheEnds() {
        let rect = CGRect(x: 0, y: 0, width: 100, height: 100)
        let path = SVGPathParser.path(from: PathPresets.line, in: rect)!
        let flat = PathTextLayout.flatten(path)!

        let run = makeRun(glyphWidths: Array(repeating: 10, count: 15))

        let atStart = PathTextLayout.place(
            run: run, along: flat, phasePx: 0, alignment: .left, isScrolling: true
        )
        XCTAssertTrue(atStart.isEmpty)

        let midway = PathTextLayout.place(
            run: run, along: flat, phasePx: run.runLengthPx, alignment: .left, isScrolling: true
        )
        XCTAssertFalse(midway.isEmpty)
        XCTAssertLessThanOrEqual(midway.count, 11)
        for glyph in midway {
            XCTAssertGreaterThanOrEqual(glyph.center.x, -6)
            XCTAssertLessThanOrEqual(glyph.center.x, 106)
        }
    }

    func testMarqueeLoopsSeamlessly() {

        let rect = CGRect(x: 0, y: 0, width: 100, height: 100)
        let flat = PathTextLayout.flatten(SVGPathParser.path(from: PathPresets.line, in: rect)!)!
        let run = makeRun(glyphWidths: Array(repeating: 10, count: 5))
        let period = flat.totalLength + run.runLengthPx + 2 * run.padXPx

        let first = PathTextLayout.place(
            run: run, along: flat, phasePx: 30, alignment: .left, isScrolling: true
        )
        let looped = PathTextLayout.place(
            run: run, along: flat, phasePx: 30 + period, alignment: .left, isScrolling: true
        )
        XCTAssertEqual(first, looped)
    }

    func testStaticOpenPathAnchorsByAlignment() {
        let rect = CGRect(x: 0, y: 0, width: 200, height: 100)
        let flat = PathTextLayout.flatten(SVGPathParser.path(from: PathPresets.line, in: rect)!)!
        let run = makeRun(glyphWidths: Array(repeating: 10, count: 4)) 

        func firstCenterX(_ alignment: SceneTextAlignment) -> CGFloat {
            PathTextLayout.place(
                run: run, along: flat, phasePx: 0, alignment: alignment, isScrolling: false
            ).first!.center.x
        }

        XCTAssertEqual(firstCenterX(.left), 5, accuracy: 0.01)
        XCTAssertEqual(firstCenterX(.center), 83, accuracy: 0.01)
        XCTAssertEqual(firstCenterX(.right), 163, accuracy: 0.01)
    }

    func testGlyphsTrimSmoothlyAtOpenPathEnds() {

        let rect = CGRect(x: 0, y: 0, width: 100, height: 100)
        let flat = PathTextLayout.flatten(SVGPathParser.path(from: PathPresets.line, in: rect)!)!
        let run = makeRun(glyphWidths: [10])
        let cell = run.cells[0]

        let phase = run.runLengthPx + run.padXPx + flat.totalLength - cell.centerAdvancePx
        let placed = PathTextLayout.place(
            run: run, along: flat, phasePx: phase, alignment: .left, isScrolling: true
        )
        XCTAssertEqual(placed.count, 1)
        let glyph = placed[0]
        XCTAssertEqual(glyph.tileWidthPx, cell.tileWidthPx / 2, accuracy: 0.1)
        XCTAssertEqual(glyph.uv.width, cell.uv.width / 2, accuracy: 0.001)
        XCTAssertEqual(glyph.uv.minX, cell.uv.minX, accuracy: 0.001, "exit end trims the FAR side")

        XCTAssertEqual(glyph.center.x, flat.totalLength - cell.tileWidthPx / 4, accuracy: 0.1)
    }

    func testTangentTurnsContinuouslyAlongACurve() {

        let flat = flatCircle()
        let quarter = flat.totalLength / 4
        var previous = flat.sample(at: 0).tangentRadians
        var maxStep: CGFloat = 0

        let steps = 400
        for step in 1...steps {
            let tangent = flat.sample(at: quarter * CGFloat(step) / CGFloat(steps)).tangentRadians
            var delta = tangent - previous
            while delta > .pi { delta -= 2 * .pi }
            while delta < -.pi { delta += 2 * .pi }
            maxStep = max(maxStep, abs(delta))
            previous = tangent
        }

        XCTAssertLessThan(maxStep, 0.02, "tangent must not snap between flattened segments")
    }

    private func makeCompositor() throws -> Compositor {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("No Metal device available on this machine")
        }
        return try Compositor()
    }

    private func tickerScene(speed: Double, pathData: String = PathPresets.ellipse) -> RenderScene {
        var scene = RenderScene(canvasSize: CGSize(width: 384, height: 216))
        scene.addItem(
            RenderItem(
                id: "ticker",
                frame: CGRect(x: 64, y: 28, width: 256, height: 160),
                content: .text(StyledText(
                    string: "GRACE FELLOWSHIP WELCOMES YOU",
                    fontSize: 18,
                    pathData: pathData,
                    tickerSpeed: speed
                ))
            ),
            to: .slide
        )
        return scene
    }

    func testStaticPathTextIsByteStableAcrossCompositors() throws {

        let first = try makeCompositor()
            .renderFrame(scene: tickerScene(speed: 0), width: 384, height: 216)
        let second = try makeCompositor()
            .renderFrame(scene: tickerScene(speed: 0), width: 384, height: 216)
        XCTAssertEqual(first.data, second.data)
    }

    func testPhaseMovesInkAndSpeedZeroDoesNot() throws {
        let compositor = try makeCompositor()
        let moving0 = try compositor.renderFrame(
            scene: tickerScene(speed: 40), width: 384, height: 216, at: 0
        )
        let moving1 = try compositor.renderFrame(
            scene: tickerScene(speed: 40), width: 384, height: 216, at: 1
        )
        XCTAssertNotEqual(moving0.data, moving1.data, "a running ticker must move")

        let static0 = try compositor.renderFrame(
            scene: tickerScene(speed: 0), width: 384, height: 216, at: 0
        )
        let static1 = try compositor.renderFrame(
            scene: tickerScene(speed: 0), width: 384, height: 216, at: 1
        )
        XCTAssertEqual(static0.data, static1.data, "speed 0 must be time-invariant")
    }

    func testMovingTickerHoldsExactlyOneStripEntry() throws {

        let compositor = try makeCompositor()
        for frame in 0..<60 {
            _ = try compositor.renderFrame(
                scene: tickerScene(speed: 40), width: 384, height: 216,
                at: CFTimeInterval(frame) / 60
            )
        }
        XCTAssertEqual(compositor.stripTextureCount, 1)
        XCTAssertEqual(compositor.textTextureCount, 0, "path text must not touch the block cache")
        XCTAssertEqual(compositor.flatPathCount, 1, "a moving ticker parses and flattens its path once")
    }

    func testStaleFlatPathIsSwept() throws {
        let compositor = try makeCompositor()
        _ = try compositor.renderFrame(scene: tickerScene(speed: 40), width: 384, height: 216)
        XCTAssertEqual(compositor.flatPathCount, 1)
        compositor.sweepCaches(at: CACurrentMediaTime() + Compositor.cacheTTL + 1)
        XCTAssertEqual(compositor.flatPathCount, 0)
    }

    func testStaleStripIsSwept() throws {
        let compositor = try makeCompositor()
        _ = try compositor.renderFrame(scene: tickerScene(speed: 40), width: 384, height: 216)
        XCTAssertEqual(compositor.stripTextureCount, 1)
        compositor.sweepCaches(at: CACurrentMediaTime() + Compositor.cacheTTL + 1)
        XCTAssertEqual(compositor.stripTextureCount, 0)
    }

    func testPathAndSpeedSwapsReuseTheStrip() throws {

        let compositor = try makeCompositor()
        _ = try compositor.renderFrame(scene: tickerScene(speed: 40), width: 384, height: 216)
        _ = try compositor.renderFrame(scene: tickerScene(speed: 90), width: 384, height: 216)
        _ = try compositor.renderFrame(
            scene: tickerScene(speed: 40, pathData: PathPresets.rectanglePerimeter),
            width: 384, height: 216
        )
        XCTAssertEqual(compositor.stripTextureCount, 1)
    }

    func testNormalizedTextCollapsesNewlinesAndPlacementFields() {
        let text = StyledText(
            string: "line one\nline two",
            fontSize: 24,
            alignment: .right,
            verticalAlignment: .top,
            autoShrink: true,
            pathData: PathPresets.ellipse,
            tickerSpeed: 40
        )
        let normalized = PathTextStrip.normalizedText(text)
        XCTAssertEqual(normalized.string, "line one line two")
        XCTAssertEqual(normalized.alignment, .left)
        XCTAssertNil(normalized.pathData)
        XCTAssertEqual(normalized.tickerSpeed, 0)
        XCTAssertFalse(normalized.autoShrink)
    }
}

extension PathTextTests {
    func testClosedStreamAutoFitsWithNoWrapOverlap() {

        let flat = flatCircle() 
        let run = makeRun(glyphWidths: Array(repeating: 10, count: 5)) 
        let placed = PathTextLayout.place(
            run: run, along: flat, phasePx: 0, alignment: .left,
            isScrolling: true, stream: true, gapPx: 100 
        )
        let copies = placed.count / run.cells.count
        XCTAssertEqual(placed.count % run.cells.count, 0, "whole copies only")
        XCTAssertEqual(copies, Int((flat.totalLength / 150).rounded()))

        for (i, a) in placed.enumerated() {
            for b in placed[(i + 1)...] {
                XCTAssertGreaterThan(
                    hypot(a.center.x - b.center.x, a.center.y - b.center.y), 0.5,
                    "wrap overlap: two copies landed on the same arc"
                )
            }
        }
    }

    func testClosedStreamWithHugeGapDegradesToSingleCopy() {
        let flat = flatCircle()
        let run = makeRun(glyphWidths: [10])
        let placed = PathTextLayout.place(
            run: run, along: flat, phasePx: 0, alignment: .left,
            isScrolling: true, stream: true, gapPx: 10_000
        )
        XCTAssertEqual(placed.count, run.cells.count)
    }

    func testOpenStreamTrainIsStridePeriodic() {
        let rect = CGRect(x: 0, y: 0, width: 300, height: 100)
        let flat = PathTextLayout.flatten(SVGPathParser.path(from: PathPresets.line, in: rect)!)!
        let run = makeRun(glyphWidths: Array(repeating: 10, count: 4)) 
        let at30 = PathTextLayout.place(
            run: run, along: flat, phasePx: 30, alignment: .left,
            isScrolling: true, stream: true, gapPx: 20
        )
        let oneStrideLater = PathTextLayout.place(
            run: run, along: flat, phasePx: 90, alignment: .left,
            isScrolling: true, stream: true, gapPx: 20
        )
        XCTAssertEqual(at30, oneStrideLater, "phase mod stride: the train glides seamlessly")
        XCTAssertGreaterThan(at30.count, run.cells.count, "multiple copies visible on the path")
    }

    func testPathOffsetDisplacesAlongAscentNormal() {

        let rect = CGRect(x: 0, y: 0, width: 200, height: 100)
        let flat = PathTextLayout.flatten(SVGPathParser.path(from: PathPresets.line, in: rect)!)!
        let run = makeRun(glyphWidths: [10])
        let base = PathTextLayout.place(
            run: run, along: flat, phasePx: 0, alignment: .center, isScrolling: false
        )[0]
        let raised = PathTextLayout.place(
            run: run, along: flat, phasePx: 0, alignment: .center, isScrolling: false,
            offsetPx: 12
        )[0]
        XCTAssertEqual(raised.center.x, base.center.x, accuracy: 0.001)
        XCTAssertEqual(raised.center.y, base.center.y - 12, accuracy: 0.001)
    }

    func testRepeatLimitBlanksMarqueeAndFreezesClosedRing() throws {
        let compositor = try makeCompositor()

        func item(pathData: String, repeats: Int, anchor: Double?) -> RenderScene {
            var scene = RenderScene(canvasSize: CGSize(width: 384, height: 216))
            scene.addItem(
                RenderItem(
                    id: "t", frame: CGRect(x: 64, y: 28, width: 256, height: 160),
                    content: .text(StyledText(
                        string: "REPEAT TEST", fontSize: 18,
                        pathData: pathData, tickerSpeed: 100, tickerRepeat: repeats
                    )),
                    tickerAnchorHostTime: anchor
                ),
                to: .slide
            )
            return scene
        }

        let early = try compositor.renderFrame(
            scene: item(pathData: PathPresets.line, repeats: 1, anchor: 100),
            width: 384, height: 216, at: 102
        )
        let late = try compositor.renderFrame(
            scene: item(pathData: PathPresets.line, repeats: 1, anchor: 100),
            width: 384, height: 216, at: 1000
        )
        let blank = try compositor.renderFrame(
            scene: RenderScene(canvasSize: CGSize(width: 384, height: 216)),
            width: 384, height: 216
        )
        XCTAssertNotEqual(early.data, blank.data, "mid-pass the marquee shows ink")
        XCTAssertEqual(late.data, blank.data, "after the Nth exit the marquee rests empty")

        let frozen = try compositor.renderFrame(
            scene: item(pathData: PathPresets.ellipse, repeats: 1, anchor: 100),
            width: 384, height: 216, at: 1000
        )
        var restScene = RenderScene(canvasSize: CGSize(width: 384, height: 216))
        restScene.addItem(
            RenderItem(
                id: "t", frame: CGRect(x: 64, y: 28, width: 256, height: 160),
                content: .text(StyledText(
                    string: "REPEAT TEST", fontSize: 18,
                    pathData: PathPresets.ellipse, tickerSpeed: 0
                ))
            ),
            to: .slide
        )
        let rest = try compositor.renderFrame(scene: restScene, width: 384, height: 216)
        XCTAssertEqual(frozen.data, rest.data)

        let preview = try compositor.renderFrame(
            scene: item(pathData: PathPresets.line, repeats: 1, anchor: nil),
            width: 384, height: 216, at: 2.5
        )
        XCTAssertNotEqual(preview.data, blank.data)
    }

    func testWordSpacingWidensSpaceTilesOnly() throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("No Metal device available on this machine")
        }
        let device = MTLCreateSystemDefaultDevice()!
        let plain = PathTextStrip.make(
            text: PathTextStrip.normalizedText(StyledText(string: "AB CD", fontSize: 24)),
            scale: 2, device: device
        )!
        let spaced = PathTextStrip.make(
            text: PathTextStrip.normalizedText(
                StyledText(string: "AB CD", fontSize: 24, wordSpacing: 10)
            ),
            scale: 2, device: device
        )!

        XCTAssertEqual(
            spaced.run.runLengthPx, plain.run.runLengthPx + 20, accuracy: 1.0
        )
        XCTAssertEqual(spaced.run.cells.count, plain.run.cells.count)
    }

    func testStreamSeparatorEntersTheStripAndTheKey() {
        let base = StyledText(string: "NEWS", fontSize: 24, tickerStream: true)
        var withSep = base
        withSep.tickerSeparator = " | "
        let normalizedBase = PathTextStrip.normalizedText(base)
        let normalizedSep = PathTextStrip.normalizedText(withSep)
        XCTAssertEqual(normalizedBase.string, "NEWS")
        XCTAssertEqual(normalizedSep.string, "NEWS | ")

        XCTAssertEqual(normalizedSep.tickerSeparator, " | ")
        XCTAssertNotEqual(normalizedBase, normalizedSep)

        var nonStream = withSep
        nonStream.tickerStream = false
        XCTAssertEqual(PathTextStrip.normalizedText(nonStream).string, "NEWS")
        XCTAssertEqual(PathTextStrip.normalizedText(nonStream).tickerSeparator, "")
    }

    func testStreamSeparatorCentersInTheGap() {

        let rect = CGRect(x: 0, y: 0, width: 300, height: 100)
        let flat = PathTextLayout.flatten(SVGPathParser.path(from: PathPresets.line, in: rect)!)!

        var run = makeRun(glyphWidths: [10, 10, 10, 10])
        run.separatorStartPx = 30
        let gap: CGFloat = 20

        let placed = PathTextLayout.place(
            run: run, along: flat, phasePx: run.runLengthPx + run.padXPx,
            alignment: .left, isScrolling: true, stream: true, gapPx: gap
        )

        let unshiftedStep = run.cells[3].centerAdvancePx - run.cells[2].centerAdvancePx
        let expected = unshiftedStep + gap / 2
        let sorted = placed.map(\.center.x).sorted()
        var foundCenteredSeparator = false
        for index in 1..<sorted.count {
            let delta = sorted[index] - sorted[index - 1]
            if abs(delta - expected) < 0.5 { foundCenteredSeparator = true }
        }
        XCTAssertTrue(foundCenteredSeparator, "separator must shift by gap/2 into the gap")
    }
}

extension PathTextTests {
    func testTickerDirectionDefaultsReadingOrderAndFlips() throws {
        let compositor = try makeCompositor()
        func scene(leftToRight: Bool) -> RenderScene {
            var scene = RenderScene(canvasSize: CGSize(width: 384, height: 216))
            scene.addItem(
                RenderItem(
                    id: "t", frame: CGRect(x: 42, y: 88, width: 300, height: 40),
                    content: .text(StyledText(
                        string: "DIRECTION", fontSize: 18,
                        pathData: PathPresets.line, tickerSpeed: 50,
                        tickerLeftToRight: leftToRight
                    ))
                ),
                to: .slide
            )
            return scene
        }

        let rtl = try compositor.renderFrame(scene: scene(leftToRight: false), width: 384, height: 216, at: 1)
        let ltr = try compositor.renderFrame(scene: scene(leftToRight: true), width: 384, height: 216, at: 1)
        XCTAssertNotEqual(rtl.data, ltr.data)

        let rtlLater = try compositor.renderFrame(scene: scene(leftToRight: false), width: 384, height: 216, at: 2)
        XCTAssertNotEqual(rtl.data, rtlLater.data)
    }
}
