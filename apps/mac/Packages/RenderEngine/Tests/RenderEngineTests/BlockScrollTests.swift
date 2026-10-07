import Metal
import XCTest
@testable import RenderEngine

@MainActor
final class BlockScrollTests: XCTestCase {
    private let canvas = CGSize(width: 192, height: 108)

    private func credits(_ scroll: SceneBlockScroll, anchor: Double? = 0, context: AnimationContext? = nil) -> RenderItem {
        var text = StyledText(
            string: Array(repeating: "Line of credits", count: 12).joined(separator: "\n"),
            fontSize: 8, color: .white, alignment: .center
        )
        text.scroll = scroll
        return RenderItem(
            id: "credits", frame: CGRect(x: 20, y: 30, width: 152, height: 40),
            content: .text(text), tickerAnchorHostTime: anchor, animationContext: context
        )
    }

    func testContinuousRollWrapsAndRampEasesEachPass() {
        let scroll = SceneBlockScroll(axis: .up, speed: 50)

        XCTAssertEqual(BlockScrollRoll.pose(scroll, elapsed: 3, passLength: 100, restOffset: 60, anchored: true), .offset(50))
        var eased = scroll
        eased.ramp = .easeInOut

        XCTAssertEqual(BlockScrollRoll.pose(eased, elapsed: 1, passLength: 100, restOffset: 60, anchored: true), .offset(50))
        guard case .offset(let quarter) = BlockScrollRoll.pose(eased, elapsed: 0.5, passLength: 100, restOffset: 60, anchored: true)
        else { return XCTFail() }
        XCTAssertLessThan(quarter, 25)

        XCTAssertEqual(BlockScrollRoll.pose(SceneBlockScroll(speed: 0), elapsed: 9, passLength: 100, restOffset: 60, anchored: true), .offset(0))
    }

    func testFinitePassesRestOrLeaveOnlyWhenAnchored() {
        var scroll = SceneBlockScroll(axis: .up, speed: 50, passes: 1)
        XCTAssertEqual(BlockScrollRoll.pose(scroll, elapsed: 5, passLength: 100, restOffset: 60, anchored: true), .gone)
        scroll.restAtEnd = true
        XCTAssertEqual(BlockScrollRoll.pose(scroll, elapsed: 5, passLength: 100, restOffset: 60, anchored: true), .offset(60))

        XCTAssertEqual(BlockScrollRoll.pose(scroll, elapsed: 5, passLength: 100, restOffset: 60, anchored: false), .offset(50))
    }

    func testRollExpandsTheBlockAndClipsToTheFrame() throws {
        let item = credits(SceneBlockScroll(axis: .up, speed: 40, fadeTowardTop: 0.25))
        let text: StyledText = { if case .text(let t) = item.content { return t }; fatalError() }()
        let blockHeight = TextRasterizer.blockHeight(for: text, sceneWidth: 152)
        XCTAssertGreaterThan(blockHeight, 40, "twelve lines overflow a 40-unit box")

        let start = AnimationEvaluator.resolve(item, canvasSize: canvas, hostTime: 0)
        XCTAssertEqual(start.count, 1)
        XCTAssertEqual(start[0].item.frame.height, ceil(blockHeight), accuracy: 0.001)
        XCTAssertEqual(start[0].motion.translate.dy, 40, accuracy: 0.001)
        let clip = try XCTUnwrap(start[0].motion.clip)
        XCTAssertEqual(clip.minV, -40 / Double(ceil(blockHeight)), accuracy: 0.001)
        XCTAssertEqual(clip.maxV - clip.minV, 40 / Double(ceil(blockHeight)), accuracy: 0.001)
        XCTAssertEqual(clip.featherMinV, 0.25 * 40 / Double(ceil(blockHeight)), accuracy: 0.001)
        XCTAssertEqual(clip.featherMaxV, 0)
        if case .text(let rolled) = start[0].item.content {
            XCTAssertNil(rolled.scroll, "the raster never sees the clock")
            XCTAssertEqual(rolled.verticalAlignment, .top)
        } else { XCTFail() }

        let later = AnimationEvaluator.resolve(item, canvasSize: canvas, hostTime: 1)
        XCTAssertEqual(later[0].motion.translate.dy, 0, accuracy: 0.001)

        let settled = AnimationEvaluator.resolve(credits(SceneBlockScroll(axis: .up, speed: 40), context: .settled), canvasSize: canvas, hostTime: 7)
        XCTAssertEqual(settled.count, 1)
        XCTAssertNil(settled[0].motion.clip)
        XCTAssertEqual(settled[0].item.frame.height, 40)
    }

    func testFiniteRollLeavesOrRestsAndSidewaysKeepsTheFrame() {
        var one = SceneBlockScroll(axis: .up, speed: 400, passes: 1)
        XCTAssertTrue(AnimationEvaluator.resolve(credits(one), canvasSize: canvas, hostTime: 60).isEmpty, "rolled off after its pass")
        one.restAtEnd = true
        let rested = AnimationEvaluator.resolve(credits(one), canvasSize: canvas, hostTime: 60)
        XCTAssertEqual(rested.count, 1)

        XCTAssertEqual(rested[0].motion.translate.dy + rested[0].item.frame.height, 40, accuracy: 0.001)

        let left = AnimationEvaluator.resolve(credits(SceneBlockScroll(axis: .left, speed: 152)), canvasSize: canvas, hostTime: 0.5)
        XCTAssertEqual(left[0].item.frame.size, CGSize(width: 152, height: 40), "sideways rolls keep the frame-sized block")
        XCTAssertEqual(left[0].motion.translate.dx, 76, accuracy: 0.001)
        XCTAssertEqual(left[0].motion.clip?.minU ?? 9, -0.5, accuracy: 0.001)
    }

    func testStripKeyIgnoresRampAndScroll() {
        var a = StyledText(string: "Ticker", fontSize: 10)
        var b = a
        a.tickerRamp = .easeInOut
        b.scroll = SceneBlockScroll(speed: 3)
        XCTAssertEqual(PathTextStrip.normalizedText(a), PathTextStrip.normalizedText(b))
    }

    func testFiniteTickerRampEasesEachPass() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("No Metal device") }
        let compositor = try Compositor()
        func scene(repeats: Int, ramp: SceneAnimationRamp) -> RenderScene {
            var scene = RenderScene(canvasSize: CGSize(width: 384, height: 216))
            var text = StyledText(string: "RAMP TEST", fontSize: 18, pathData: PathPresets.line, tickerSpeed: 100, tickerRepeat: repeats)
            text.tickerRamp = ramp
            scene.addItem(RenderItem(id: "t", frame: CGRect(x: 64, y: 28, width: 256, height: 160), content: .text(text), tickerAnchorHostTime: 100), to: .slide)
            return scene
        }
        let linear = try compositor.renderFrame(scene: scene(repeats: 1, ramp: .none), width: 384, height: 216, at: 100.4)
        let eased = try compositor.renderFrame(scene: scene(repeats: 1, ramp: .easeIn), width: 384, height: 216, at: 100.4)
        XCTAssertNotEqual(linear.data, eased.data, "an eased pass lags the linear one early on")
        let freeLinear = try compositor.renderFrame(scene: scene(repeats: 0, ramp: .none), width: 384, height: 216, at: 100.4)
        let freeEased = try compositor.renderFrame(scene: scene(repeats: 0, ramp: .easeIn), width: 384, height: 216, at: 100.4)
        XCTAssertEqual(freeLinear.data, freeEased.data, "a continuous ticker has no pass edge to ease")
    }

    func testRollStaysInsideItsBoxAndEntersFromBelow() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("No Metal device") }
        let compositor = try Compositor()
        var scene = RenderScene(canvasSize: canvas)
        scene.addItem(credits(SceneBlockScroll(axis: .up, speed: 40, passes: 1)), to: .slide)

        func ink(_ frame: RenderedFrame, _ rect: CGRect) -> Int {
            var count = 0
            for y in Int(rect.minY)..<Int(rect.maxY) {
                for x in Int(rect.minX)..<Int(rect.maxX) {
                    var px = SIMD4<Float>()
                    frame.data.withUnsafeBytes { raw in
                        let base = raw.baseAddress! + y * frame.bytesPerRow + x * 8
                        let halves = base.assumingMemoryBound(to: Float16.self)
                        px = SIMD4(Float(halves[0]), Float(halves[1]), Float(halves[2]), Float(halves[3]))
                    }
                    if px.x > 0.2 { count += 1 }
                }
            }
            return count
        }
        let box = CGRect(x: 20, y: 30, width: 152, height: 40)
        let above = CGRect(x: 20, y: 0, width: 152, height: 30)
        let below = CGRect(x: 20, y: 70, width: 152, height: 38)

        let t0 = try compositor.renderFrame(scene: scene, width: 192, height: 108, at: 0.05)
        XCTAssertEqual(ink(t0, below), 0)
        XCTAssertEqual(ink(t0, above), 0)

        let mid = try compositor.renderFrame(scene: scene, width: 192, height: 108, at: 1.5)
        XCTAssertGreaterThan(ink(mid, box), 20)
        XCTAssertEqual(ink(mid, above), 0)
        XCTAssertEqual(ink(mid, below), 0)

        let done = try compositor.renderFrame(scene: scene, width: 192, height: 108, at: 60)
        XCTAssertEqual(ink(done, box), 0)
    }
}
