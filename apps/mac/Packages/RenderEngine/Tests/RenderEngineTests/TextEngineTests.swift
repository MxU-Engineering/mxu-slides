import AppKit
import Metal
import XCTest
@testable import RenderEngine

@MainActor
final class TextEngineTests: XCTestCase {
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

    func testAutoShrinkKeepsFittingTextAtFullSize() {
        let text = StyledText(string: "Short", fontSize: 60, autoShrink: true)
        XCTAssertEqual(
            TextRasterizer.fittedFontScale(for: text, sceneFrame: CGSize(width: 1600, height: 400)),
            1
        )
    }

    func testAutoShrinkShrinksOverflowingText() {
        let long = Array(repeating: "Amazing grace how sweet the sound", count: 12)
            .joined(separator: "\n")
        let text = StyledText(string: long, fontSize: 96, autoShrink: true, minFontSize: 10)
        let frame = CGSize(width: 1600, height: 400)
        let scale = TextRasterizer.fittedFontScale(for: text, sceneFrame: frame)
        XCTAssertLessThan(scale, 1)
        XCTAssertGreaterThan(scale, 0)

        XCTAssertEqual(scale * 1000, (scale * 1000).rounded(), accuracy: 0.0001)
    }

    func testAutoShrinkRespectsMinimumFontSize() {
        let absurd = Array(repeating: "word", count: 4000).joined(separator: " ")
        let text = StyledText(string: absurd, fontSize: 100, autoShrink: true, minFontSize: 50)
        let scale = TextRasterizer.fittedFontScale(
            for: text, sceneFrame: CGSize(width: 400, height: 100)
        )
        XCTAssertGreaterThanOrEqual(scale, 0.5 - 0.001, "shrink must stop at minFontSize")
    }

    private func visualLines(_ text: StyledText, width: CGFloat) -> [String] {
        let attributed = TextRasterizer.attributedString(
            for: text, fontScale: 1, pixelScale: 1
        ) as NSAttributedString
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let path = CGPath(
            rect: CGRect(x: 0, y: 0, width: width, height: 100_000), transform: nil
        )
        let frame = CTFramesetterCreateFrame(
            framesetter, CFRange(location: 0, length: 0), path, nil)
        let lines = CTFrameGetLines(frame) as! [CTLine]
        return lines.map {
            let range = CTLineGetStringRange($0)
            return (attributed.string as NSString)
                .substring(with: NSRange(location: range.location, length: range.length))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    func testBalancedWrapMovesTheOrphanBreakEarlier() {
        var text = StyledText(
            string: "Amazing grace, how sweet the sound", fontSize: 96, balancedWrap: true
        )
        let unwrapped = visualLines(text, width: 100_000)[0]
        XCTAssertFalse(unwrapped.isEmpty)
        let framesetter = CTFramesetterCreateWithAttributedString(
            TextRasterizer.attributedString(for: text, fontScale: 1, pixelScale: 1))
        let full = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter, CFRange(location: 0, length: 0), nil,
            CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude), nil
        ).width
        let width = full * 0.95
        let ragged = visualLines(text, width: width)
        XCTAssertEqual(ragged.count, 2, "the test box must force exactly one wrap")

        let insets = TextRasterizer.balancedLineInsets(for: text, sceneWidth: width, fontScale: 1)
        XCTAssertEqual(insets.count, 1)
        text.balancedLineInsets = insets
        let balanced = visualLines(text, width: width)
        XCTAssertEqual(balanced.count, ragged.count, "balance must never add a row")
        XCTAssertLessThan(
            balanced[0].count, ragged[0].count,
            "the break must move earlier — words redistribute toward the last row"
        )
        XCTAssertGreaterThan(
            balanced[1].split(separator: " ").count,
            ragged[1].split(separator: " ").count,
            "the orphan row must gain company"
        )
    }

    func testBalancedWrapLeavesNonWrappingTextAlone() {
        let text = StyledText(string: "Short line", fontSize: 40, balancedWrap: true)
        XCTAssertTrue(
            TextRasterizer.balancedLineInsets(for: text, sceneWidth: 2000, fontScale: 1).isEmpty
        )
    }

    func testBalancedWrapSplitsDeltaPerAlignment() {
        var text = StyledText(
            string: "Amazing grace, how sweet the sound that saved a wretch like me",
            fontSize: 96, alignment: .center, balancedWrap: true
        )
        let width: CGFloat = 1200
        let centered = TextRasterizer.balancedLineInsets(for: text, sceneWidth: width, fontScale: 1)
        XCTAssertFalse(centered.isEmpty)
        XCTAssertEqual(centered[0].left, centered[0].right, accuracy: 0.001)
        XCTAssertGreaterThan(centered[0].left, 0)
        text.alignment = .left
        let leftAligned = TextRasterizer.balancedLineInsets(
            for: text, sceneWidth: width, fontScale: 1)
        XCTAssertFalse(leftAligned.isEmpty)
        XCTAssertEqual(leftAligned[0].left, 0)
        XCTAssertGreaterThan(leftAligned[0].right, 0)
    }

    func testKeepLinesWholeShrinksWrappingLine() {
        var text = StyledText(
            string: "Amazing grace, how sweet the sound\nThat saved a wretch like me",
            fontSize: 110, autoShrink: true, minFontSize: 20
        )
        let frame = CGSize(width: 1400, height: 600)
        XCTAssertEqual(
            TextRasterizer.fittedFontScale(for: text, sceneFrame: frame), 1,
            "height-only fit must pass — the wrapped word still fits the box"
        )
        text.keepLinesWhole = true
        let scale = TextRasterizer.fittedFontScale(for: text, sceneFrame: frame)
        XCTAssertLessThan(scale, 1)
        XCTAssertGreaterThanOrEqual(scale, 20.0 / 110.0 - 0.001, "floor holds")
        XCTAssertFalse(
            TextRasterizer.overflows(text, sceneFrame: frame),
            "whole lines at a smaller size are a fit, not clipping"
        )
    }

    func testKeepLinesWholeFloorWrapsWithoutOverflowWarning() {
        let text = StyledText(
            string: Array(repeating: "word", count: 40).joined(separator: " "),
            fontSize: 100, autoShrink: true, minFontSize: 90, keepLinesWhole: true
        )
        let frame = CGSize(width: 800, height: 4000)
        let scale = TextRasterizer.fittedFontScale(for: text, sceneFrame: frame)
        XCTAssertGreaterThanOrEqual(scale, 0.9 - 0.001, "shrink must stop at minFontSize")
        XCTAssertFalse(
            TextRasterizer.overflows(text, sceneFrame: frame),
            "floor wrap that fits the height is graceful, not clipped"
        )
    }

    func testAutoShrinkOffNeverScales() {
        let long = Array(repeating: "line", count: 200).joined(separator: "\n")
        let text = StyledText(string: long, fontSize: 96, autoShrink: false)
        XCTAssertEqual(
            TextRasterizer.fittedFontScale(for: text, sceneFrame: CGSize(width: 100, height: 50)),
            1
        )
    }

    func testUppercaseTransformChangesRenderedPixels() throws {
        let base = StyledText(string: "grace", fontSize: 300)
        var upper = base
        upper.transform = .uppercase
        let a = try renderText(base)
        let b = try renderText(upper)
        XCTAssertNotEqual(a.data, b.data, "all-caps transform must change rendered glyphs")
    }

    func testTrackingWidensRenderedInk() throws {
        let base = StyledText(string: "IIIIIIII", fontSize: 200, alignment: .left)
        var tracked = base
        tracked.tracking = 40
        let normal = try inkBounds(try renderText(base))
        let wide = try inkBounds(try renderText(tracked))
        let normalBounds = try XCTUnwrap(normal)
        let wideBounds = try XCTUnwrap(wide)
        XCTAssertGreaterThan(
            wideBounds.maxX, normalBounds.maxX + 10,
            "positive tracking must widen the line"
        )
    }

    func testLineHeightMultipleSpreadsLines() throws {
        let base = StyledText(string: "UP\nDOWN", fontSize: 150)
        var spread = base
        spread.lineHeightMultiple = 1.8
        let tight = try XCTUnwrap(inkBounds(try renderText(base)))
        let loose = try XCTUnwrap(inkBounds(try renderText(spread)))
        XCTAssertGreaterThan(
            loose.height, tight.height + 10,
            "a larger line-height multiple must spread the block vertically"
        )
    }

    func testVerticalAlignmentPlacesBlock() throws {
        let base = StyledText(string: "ANCHOR", fontSize: 120)
        var top = base
        top.verticalAlignment = .top
        var bottom = base
        bottom.verticalAlignment = .bottom
        let topInk = try XCTUnwrap(inkBounds(try renderText(top)))
        let middleInk = try XCTUnwrap(inkBounds(try renderText(base)))
        let bottomInk = try XCTUnwrap(inkBounds(try renderText(bottom)))
        XCTAssertLessThan(topInk.midY, middleInk.midY - 50)
        XCTAssertGreaterThan(bottomInk.midY, middleInk.midY + 50)
    }

    private func inkBounds(_ frame: RenderedFrame, rows: Range<Int>, threshold: Float = 0.05) -> CGRect? {
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
        for y in rows {
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

    func testInsetsShiftBlockInFromEdges() throws {
        let base = StyledText(
            string: "ANCHOR", fontSize: 120, alignment: .left, verticalAlignment: .top
        )
        var padded = base
        padded.insetLeft = 200
        padded.insetTop = 200
        let flush = try XCTUnwrap(inkBounds(try renderText(base)))
        let inset = try XCTUnwrap(inkBounds(try renderText(padded)))

        XCTAssertGreaterThan(inset.minX, flush.minX + 80, "left inset must push ink right")
        XCTAssertGreaterThan(inset.minY, flush.minY + 80, "top inset must push ink down")
    }

    func testInsetsTightenAutoShrinkFit() {
        let long = Array(repeating: "Amazing grace how sweet the sound", count: 6)
            .joined(separator: "\n")
        let text = StyledText(string: long, fontSize: 96, autoShrink: true, minFontSize: 10)
        let frame = CGSize(width: 1600, height: 800)
        var padded = text
        padded.insetLeft = 400
        padded.insetRight = 400
        padded.insetTop = 150
        padded.insetBottom = 150
        XCTAssertLessThan(
            TextRasterizer.fittedFontScale(for: padded, sceneFrame: frame),
            TextRasterizer.fittedFontScale(for: text, sceneFrame: frame),
            "insets shrink the layout box, so the same text must fit smaller"
        )
    }

    func testLeftIndentShiftsBlockAndRightIndentPullsRightEdge() throws {
        let base = StyledText(string: "HHHH", fontSize: 150, alignment: .left)
        var indented = base
        indented.leftIndent = 300
        let flush = try XCTUnwrap(inkBounds(try renderText(base)))
        let shifted = try XCTUnwrap(inkBounds(try renderText(indented)))
        XCTAssertGreaterThan(shifted.minX, flush.minX + 120, "left indent must move the line right")

        let rightBase = StyledText(string: "HHHH", fontSize: 150, alignment: .right)
        var pulled = rightBase
        pulled.rightIndent = 300
        let flushRight = try XCTUnwrap(inkBounds(try renderText(rightBase)))
        let pulledInk = try XCTUnwrap(inkBounds(try renderText(pulled)))
        XCTAssertLessThan(
            pulledInk.maxX, flushRight.maxX - 120,
            "right indent must pull the trailing edge inward"
        )
    }

    func testPerLineIndentOverrideShiftsOnlyItsLine() throws {
        var text = StyledText(string: "HHHH\nHHHH", fontSize: 150, alignment: .left)
        text.lineOverrides = [TextLineOverride(lineIndex: 1, leftIndent: 300, rightIndent: 0)]
        let frame = try renderText(text)
        let topInk = try XCTUnwrap(inkBounds(frame, rows: 0..<(frame.height / 2)))
        let bottomInk = try XCTUnwrap(inkBounds(frame, rows: (frame.height / 2)..<frame.height))
        XCTAssertGreaterThan(
            bottomInk.minX, topInk.minX + 120,
            "the overridden line must indent while the first stays flush"
        )
    }

    func testParagraphSpacingSpreadsParagraphs() throws {
        let base = StyledText(string: "UP\nDOWN", fontSize: 150)
        var spaced = base
        spaced.paragraphSpacing = 120
        let tight = try XCTUnwrap(inkBounds(try renderText(base)))
        let spread = try XCTUnwrap(inkBounds(try renderText(spaced)))
        XCTAssertGreaterThan(
            spread.height, tight.height + 40,
            "paragraph spacing must open space between source lines"
        )
    }

    func testLineFillFullWidthBandReachesFrameEdge() throws {
        let base = StyledText(string: "GRACE", fontSize: 150)
        var banded = base
        banded.lineFill = TextLineFillStyle(fill: .solid(SceneColor(red: 1, green: 0, blue: 0)))
        let plain = try renderText(base)
        let filled = try renderText(banded)
        XCTAssertNotEqual(plain.data, filled.data, "a line fill must change rendered pixels")

        let bounds = try XCTUnwrap(inkBounds(filled))
        XCTAssertLessThan(bounds.minX, 3)
    }

    func testLineFillLineWidthHugsItsLine() throws {
        var fullWidth = StyledText(string: "GRACE", fontSize: 150)
        fullWidth.lineFill = TextLineFillStyle(
            fill: .solid(SceneColor(red: 1, green: 0, blue: 0)), widthMode: .fullWidth
        )
        var hugging = fullWidth
        hugging.lineFill?.widthMode = .lineWidth
        let wide = try XCTUnwrap(inkBounds(try renderText(fullWidth)))
        let hugged = try XCTUnwrap(inkBounds(try renderText(hugging)))
        XCTAssertLessThan(
            hugged.width, wide.width - 50,
            "a line-width band must hug the glyphs, not span the frame"
        )
    }

    func testLineFillPaddingGrowsBands() throws {
        var tight = StyledText(string: "GRACE", fontSize: 150)
        tight.lineFill = TextLineFillStyle(
            fill: .solid(SceneColor(red: 1, green: 0, blue: 0)), widthMode: .lineWidth
        )
        var padded = tight
        padded.lineFill?.verticalPadding = 40
        padded.lineFill?.horizontalPadding = 40
        let tightBounds = try XCTUnwrap(inkBounds(try renderText(tight)))
        let paddedBounds = try XCTUnwrap(inkBounds(try renderText(padded)))
        XCTAssertGreaterThan(paddedBounds.width, tightBounds.width + 20)
        XCTAssertGreaterThan(paddedBounds.height, tightBounds.height + 20)
    }

    func testLineFillCornerRadiusClearsBandCorners() throws {
        var square = StyledText(string: "GRACE", fontSize: 150)
        square.lineFill = TextLineFillStyle(fill: .solid(SceneColor(red: 1, green: 0, blue: 0)))
        var rounded = square
        rounded.lineFill?.cornerRadius = 60
        let squareFrame = try renderText(square)
        let roundedFrame = try renderText(rounded)
        let bounds = try XCTUnwrap(inkBounds(squareFrame))

        let cornerX = Int(bounds.minX) + 2
        let cornerY = Int(bounds.minY) + 2
        let squareCorner = pixel(squareFrame, x: cornerX, y: cornerY)
        XCTAssertGreaterThan(squareCorner.x, 0.5)
        let roundedCorner = pixel(roundedFrame, x: cornerX, y: cornerY)
        XCTAssertLessThan(max(roundedCorner.x, roundedCorner.y, roundedCorner.z), 0.05)
        let midEdge = pixel(roundedFrame, x: cornerX, y: Int(bounds.midY))
        XCTAssertGreaterThan(midEdge.x, 0.5)
    }

    func testLineFillSkipsBlankLines() throws {
        var text = StyledText(string: "UP\n\nDOWN", fontSize: 120)
        text.lineFill = TextLineFillStyle(fill: .solid(SceneColor(red: 1, green: 0, blue: 0)))
        let frame = try renderText(text)
        let bounds = try XCTUnwrap(inkBounds(frame))
        let topBand = pixel(frame, x: 5, y: Int(bounds.minY) + 2)
        XCTAssertGreaterThan(topBand.x, 0.5, "banded lines carry ink to the edge")
        let blankRow = pixel(frame, x: 5, y: frame.height / 2)
        XCTAssertLessThan(
            max(blankRow.x, blankRow.y, blankRow.z), 0.05,
            "a blank line gets no band — no ink, no bar"
        )
    }

    func testOutlineChangesRenderedPixels() throws {
        let base = StyledText(string: "EDGE", fontSize: 300)
        var outlined = base
        outlined.outline = TextOutline(color: SceneColor(red: 1, green: 0, blue: 0), width: 6)
        let a = try renderText(base)
        let b = try renderText(outlined)
        XCTAssertNotEqual(a.data, b.data, "an outline must change rendered glyph edges")
    }

    func testPerLineOverrideRestylesOnlyItsLine() throws {
        let base = StyledText(string: "FIRST\nSECOND", fontSize: 150)
        var overridden = base
        overridden.lineOverrides = [
            TextLineOverride(lineIndex: 1, color: SceneColor(red: 1, green: 0, blue: 0)),
        ]
        let plain = try renderText(base)
        let styled = try renderText(overridden)
        XCTAssertNotEqual(plain.data, styled.data)

        let splitRow = plain.height / 2
        let topBytes = { (frame: RenderedFrame) in
            frame.data.prefix(splitRow * frame.bytesPerRow)
        }
        XCTAssertEqual(topBytes(plain), topBytes(styled), "line 0 must be untouched")
        let bottomBytes = { (frame: RenderedFrame) in
            frame.data.suffix((frame.height - splitRow) * frame.bytesPerRow)
        }
        XCTAssertNotEqual(bottomBytes(plain), bottomBytes(styled), "line 1 must be restyled")
    }

    func testTabularFiguresEqualizeDigitAdvances() throws {

        let systemBold = NSFont.boldSystemFont(ofSize: 250).fontName
        func sentinelMaxX(_ digits: String, tabular: Bool) throws -> CGFloat {
            var text = StyledText(
                string: digits + "X", fontName: systemBold, fontSize: 250, alignment: .left
            )
            text.tabularFigures = tabular
            return try XCTUnwrap(inkBounds(try renderText(text))).maxX
        }
        let afterOnes = try sentinelMaxX("111", tabular: true)
        let afterZeros = try sentinelMaxX("000", tabular: true)
        XCTAssertEqual(afterOnes, afterZeros, accuracy: 2,
                       "tabular digits must align column-for-column")
        let proportional = try sentinelMaxX("111", tabular: false)
        XCTAssertLessThan(proportional, afterOnes - 5,
                          "the feature must actually change digit advances")
    }

    private func inkChannelSums(
        _ frame: RenderedFrame, xRange: Range<Int>
    ) -> (red: Float, blue: Float) {
        var red: Float = 0
        var blue: Float = 0
        for y in 0..<frame.height {
            for x in xRange {
                let p = pixel(frame, x: x, y: y)
                if p.w > 0.1 {
                    red += p.x
                    blue += p.z
                }
            }
        }
        return (red, blue)
    }

    func testGradientTextFillPaintsAlongItsAxis() throws {
        var text = StyledText(string: "WWWWWWWW", fontSize: 200)
        text.fill = .linearGradient(angleDegrees: 0, stops: [
            SceneGradientStop(color: SceneColor(red: 1, green: 0, blue: 0), position: 0),
            SceneGradientStop(color: SceneColor(red: 0, green: 0, blue: 1), position: 1),
        ])
        let frame = try renderText(text)
        let left = inkChannelSums(frame, xRange: 0..<(frame.width / 2))
        let right = inkChannelSums(frame, xRange: (frame.width / 2)..<frame.width)
        XCTAssertGreaterThan(left.red, left.blue, "left ink leans to the first stop")
        XCTAssertGreaterThan(right.blue, right.red, "right ink leans to the last stop")
    }

    func testSolidInkFillOverridesColor() throws {
        var text = StyledText(string: "INK", fontSize: 300, color: SceneColor(red: 1, green: 0, blue: 0))
        text.fill = .solid(SceneColor(red: 0, green: 0, blue: 1))
        let frame = try renderText(text)
        let sums = inkChannelSums(frame, xRange: 0..<frame.width)
        XCTAssertGreaterThan(sums.blue, sums.red * 10, "fill wins over color")
    }

    func testFilledTextKeepsOutlineAndShadow() throws {
        var text = StyledText(string: "EDGE", fontSize: 300)
        text.fill = .linearGradient(angleDegrees: 90, stops: [
            SceneGradientStop(color: .white, position: 0),
            SceneGradientStop(color: SceneColor(red: 0.5, green: 0.5, blue: 0.5), position: 1),
        ])
        var plain = text
        text.outline = TextOutline(color: SceneColor(red: 1, green: 0, blue: 0), width: 4)
        text.shadow = TextShadow(color: .black, blurRadius: 8, offsetX: 0, offsetY: 6)
        plain.outline = nil
        plain.shadow = nil
        let styled = try renderText(text)
        let bare = try renderText(plain)
        XCTAssertNotEqual(styled.data, bare.data, "outline + shadow must still apply over a fill")
        XCTAssertNotNil(inkBounds(styled))
    }

    func testFullFeaturedTextIsDeterministicAcrossEngineInstances() throws {

        let text = StyledText(
            string: "amazing grace\nhow sweet the sound",
            fontSize: 140,
            color: SceneColor(red: 1, green: 0.9, blue: 0.6),
            alignment: .center,
            shadow: TextShadow(color: .black, blurRadius: 10, offsetX: 0, offsetY: 6),
            tracking: 3,
            lineHeightMultiple: 1.2,
            verticalAlignment: .bottom,
            transform: .uppercase,
            autoShrink: true,
            outline: TextOutline(color: .black, width: 2),
            lineOverrides: [TextLineOverride(lineIndex: 1, fontSize: 90)]
        )
        var scene = RenderScene()
        scene.addItem(
            RenderItem(
                id: "t",
                frame: CGRect(x: 160, y: 540, width: 1600, height: 480),
                content: .text(text)
            ),
            to: .slide
        )
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("No Metal device available on this machine")
        }
        let first = try Compositor().renderFrame(scene: scene, width: 1920, height: 1080)
        let second = try Compositor().renderFrame(scene: scene, width: 1920, height: 1080)
        XCTAssertEqual(first.data, second.data)
        XCTAssertNotNil(inkBounds(first))
    }

    private func inkCount(_ frame: RenderedFrame, threshold: Float = 0.05) -> Int {
        var count = 0
        for y in 0..<frame.height {
            for x in 0..<frame.width {
                let p = pixel(frame, x: x, y: y)
                if max(p.x, p.y, p.z) > threshold { count += 1 }
            }
        }
        return count
    }

    func testUnderlineAddsInkBelowTheGlyphs() throws {
        var text = StyledText(string: "HELLO", fontSize: 200)
        let plain = try renderText(text)
        text.underline = true
        let underlined = try renderText(text)
        XCTAssertGreaterThan(
            inkCount(underlined), inkCount(plain) + 200,
            "the underline bar must add real ink"
        )

        let plainInk = try XCTUnwrap(inkBounds(plain))
        let decoratedInk = try XCTUnwrap(inkBounds(underlined))
        XCTAssertGreaterThan(decoratedInk.maxY, plainInk.maxY)
    }

    func testStrikethroughAddsInkWithoutGrowingTheBlock() throws {
        var text = StyledText(string: "HELLO", fontSize: 200)
        let plain = try renderText(text)
        text.strikethrough = true
        let struck = try renderText(text)
        XCTAssertGreaterThan(inkCount(struck), inkCount(plain) + 200)

        let plainInk = try XCTUnwrap(inkBounds(plain))
        let struckInk = try XCTUnwrap(inkBounds(struck))
        XCTAssertEqual(struckInk.maxY, plainInk.maxY, accuracy: 2)
    }

    func testStyleRunUnderlinesOnlyItsRange() throws {
        var text = StyledText(string: "AAA BBB CCC", fontSize: 150)
        let plain = try renderText(text)
        text.styleRuns = [StyleRun(line: 0, column: 4, length: 3, underline: true)]
        let runVersion = try renderText(text)
        text.styleRuns = []
        text.underline = true
        let fullVersion = try renderText(text)

        XCTAssertGreaterThan(inkCount(runVersion), inkCount(plain) + 100)
        XCTAssertGreaterThan(
            inkCount(fullVersion), inkCount(runVersion) + 100,
            "a one-word run must draw a shorter bar than the whole line"
        )
    }

    func testOverflowingLineDrawsShavedNotVanished() throws {
        var text = StyledText(string: "Adorable at 3", fontSize: 150, alignment: .left)
        text.verticalAlignment = .top
        let short = CGRect(x: 0, y: 0, width: 1920, height: 150)
        let rendered = try renderText(text, frame: short)
        XCTAssertGreaterThan(inkCount(rendered), 200, "a partially fitting line must still draw")
    }

    func testOverflowDetectionMatchesTheClip() {
        let long = Array(repeating: "Amazing grace how sweet the sound", count: 12)
            .joined(separator: "\n")
        let text = StyledText(string: long, fontSize: 96)
        let frame = CGSize(width: 800, height: 200)
        XCTAssertTrue(TextRasterizer.overflows(text, sceneFrame: frame))
        XCTAssertFalse(TextRasterizer.overflows(StyledText(string: "Hi", fontSize: 40), sceneFrame: frame))

        var shrink = text
        shrink.autoShrink = true
        shrink.minFontSize = 4
        XCTAssertFalse(TextRasterizer.overflows(shrink, sceneFrame: frame), "a fitting shrink is not clipped")
        shrink.minFontSize = 90
        XCTAssertTrue(TextRasterizer.overflows(shrink, sceneFrame: frame), "a floor that can't fit still clips")
    }

    private func dominantCount(
        _ frame: RenderedFrame,
        channel: KeyPath<SIMD4<Float>, Float>,
        others: [KeyPath<SIMD4<Float>, Float>],
        threshold: Float = 0.05
    ) -> Int {
        var count = 0
        for y in 0..<frame.height {
            for x in 0..<frame.width {
                let p = pixel(frame, x: x, y: y)
                if p[keyPath: channel] > threshold,
                   others.allSatisfy({ p[keyPath: $0] < threshold / 2 }) {
                    count += 1
                }
            }
        }
        return count
    }

    func testStyleRunColorTintsOnlyItsRange() throws {
        var text = StyledText(string: "AAA BBB CCC", fontSize: 150)
        let plain = try renderText(text)
        text.styleRuns = [StyleRun(
            line: 0, column: 4, length: 3, color: SceneColor(red: 1, green: 0, blue: 0)
        )]
        let tinted = try renderText(text)
        XCTAssertEqual(dominantCount(plain, channel: \.x, others: [\.y, \.z]), 0)
        let redInk = dominantCount(tinted, channel: \.x, others: [\.y, \.z])
        XCTAssertGreaterThan(redInk, 100, "the run's word must render in the run color")
        XCTAssertGreaterThan(
            inkCount(tinted), redInk + 100,
            "glyphs outside the run must keep the base color"
        )
    }

    func testStyleRunHighlightPaintsBandBehindItsWord() throws {
        var text = StyledText(string: "AAA BBB CCC", fontSize: 150)
        let plain = try renderText(text)
        text.styleRuns = [StyleRun(
            line: 0, column: 4, length: 3, highlightColor: SceneColor(red: 0, green: 1, blue: 0)
        )]
        let highlighted = try renderText(text)
        XCTAssertEqual(dominantCount(plain, channel: \.y, others: [\.x, \.z]), 0)
        XCTAssertGreaterThan(
            dominantCount(highlighted, channel: \.y, others: [\.x, \.z]), 500,
            "the highlight band must paint real ink behind the word"
        )
    }

    func testStyleRunFontSizeDrivesAutoShrink() {
        var text = StyledText(
            string: "one tiny word", fontSize: 40, autoShrink: true, minFontSize: 10
        )
        let frame = CGSize(width: 700, height: 200)
        XCTAssertEqual(TextRasterizer.fittedFontScale(for: text, sceneFrame: frame), 1)
        text.styleRuns = [StyleRun(line: 0, column: 4, length: 4, fontSize: 400)]
        XCTAssertLessThan(
            TextRasterizer.fittedFontScale(for: text, sceneFrame: frame), 1,
            "an oversized run must overflow the frame and trigger shrink"
        )
    }

    func testFlipHorizontalMirrorsContentInPlace() throws {
        let text = StyledText(string: "H", fontSize: 300, alignment: .left)
        let compositor = try makeCompositor()
        var scene = RenderScene()
        scene.background = .black
        scene.addItem(
            RenderItem(
                id: "t", frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                content: .text(text)
            ),
            to: .slide
        )
        let plain = try compositor.renderFrame(scene: scene, width: 960, height: 540)
        scene.layers[scene.layers.firstIndex { $0.kind == .slide }!].items[0].flipHorizontal = true
        let flipped = try compositor.renderFrame(scene: scene, width: 960, height: 540)

        let plainInk = try XCTUnwrap(inkBounds(plain))
        let flippedInk = try XCTUnwrap(inkBounds(flipped))

        XCTAssertLessThan(plainInk.midX, CGFloat(plain.width) / 2)
        XCTAssertGreaterThan(flippedInk.midX, CGFloat(flipped.width) / 2)
        XCTAssertEqual(
            flippedInk.midX, CGFloat(flipped.width) - plainInk.midX, accuracy: 3,
            "the flip must mirror about the frame center, not translate"
        )
    }
}

extension TextEngineTests {

    func testFittedScaleNeverOverflowsAtItsOwnScale() {
        let verse = "Blessed is the one     who does not walk in step with the wicked or stand in the way that sinners take     or sit in the company of mockers, 2 but whose delight is in the law of the Lord,     and who meditates on his law day and night. 3 That person is like a tree planted by streams of water,     which yields its fruit in season and whose leaf does not wither—     whatever they do prospers."
        let words = ["grace", "how", "sweet", "the", "sound", "that", "saved", "a", "wretch", "like", "me"]
        var cases = [verse]
        for count in stride(from: 30, through: 140, by: 3) {
            cases.append((0..<count).map { words[$0 % words.count] }.joined(separator: " "))
        }
        let frame = CGSize(width: 520, height: 520)
        var shrunk = 0
        for string in cases {
            var text = StyledText(string: string, fontSize: 40, autoShrink: true)
            text.fontName = "HelveticaNeue"
            text.lineHeightMultiple = 1.15
            let scale = TextRasterizer.fittedFontScale(for: text, sceneFrame: frame)
            let floor = text.minFontSize / text.fontSize
            guard scale > floor + 0.0005 else { continue }
            shrunk += scale < 1 ? 1 : 0
            XCTAssertFalse(TextRasterizer.overflows(text, sceneFrame: frame), "scale \(scale) fits by the fit's own math: \(string.prefix(30))")
        }
        XCTAssertGreaterThan(shrunk, 5, "the sweep exercised the shrink path")
    }
}

extension TextEngineTests {

    func testPagesCutWhereTheBoxRunsOutAndEachPageFits() {
        let words = ["grace", "how", "sweet", "the", "sound", "that", "saved", "a", "wretch", "like", "me"]
        let long = (0..<400).map { words[$0 % words.count] }.joined(separator: " ")
        var text = StyledText(string: long, fontSize: 40, autoShrink: true)
        text.fontName = "HelveticaNeue"
        text.lineHeightMultiple = 1.15
        let frame = CGSize(width: 520, height: 520)
        let pages = TextRasterizer.pages(for: text, sceneFrame: frame)
        XCTAssertGreaterThan(pages.count, 1)
        XCTAssertEqual(pages.joined(separator: " "), long, "pages join back to the text")
        for page in pages {
            var one = text
            one.string = page
            XCTAssertFalse(TextRasterizer.overflows(one, sceneFrame: frame), "each page fits on its own")
        }
        var short = text
        short.string = "Amazing grace"
        XCTAssertEqual(TextRasterizer.pages(for: short, sceneFrame: frame), ["Amazing grace"])
    }
}
