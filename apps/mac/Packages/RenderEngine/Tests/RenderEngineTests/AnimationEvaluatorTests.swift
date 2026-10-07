import Metal
import XCTest
import simd
@testable import RenderEngine

@MainActor
final class AnimationEvaluatorTests: XCTestCase {
    private func makeCompositor() throws -> Compositor {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("No Metal device available on this machine")
        }
        return try Compositor()
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

    private func inkFraction(_ frame: RenderedFrame, in rect: CGRect) -> Double {
        var ink = 0, total = 0
        for y in Int(rect.minY)..<Int(rect.maxY) {
            for x in Int(rect.minX)..<Int(rect.maxX) {
                total += 1
                if pixel(frame, x: x, y: y).x > 0.2 { ink += 1 }
            }
        }
        return total == 0 ? 0 : Double(ink) / Double(total)
    }

    private func box(_ id: String = "box", animationSteps: [SceneAnimationStep], context: AnimationContext? = AnimationContext(anchorHostTime: 0)) -> RenderItem {
        RenderItem(
            id: id, frame: CGRect(x: 76, y: 34, width: 40, height: 40),
            content: .solid(.white), animationSteps: animationSteps, animationContext: context
        )
    }

    private func linearIn(_ animation: SceneStepAnimation, duration: Double = 2, edge: SceneAnimationEdge? = nil,
                          fromScale: Double = 0.95, softEdge: Double = 0) -> SceneAnimationStep {
        SceneAnimationStep(
            id: "in", kind: .enter, animation: animation, group: .auto, duration: duration,
            ramp: .none, edge: edge, fromScale: fromScale, softEdge: softEdge
        )
    }

    func testPendingHidesDoneSettles() {
        let item = box(animationSteps: [SceneAnimationStep(id: "in", kind: .enter, animation: .fade, group: .click(0), duration: 1)])
        XCTAssertTrue(AnimationEvaluator.resolve(item, canvasSize: CGSize(width: 192, height: 108), hostTime: 5).isEmpty,
                      "In pending = not drawn")
        var clicked = item
        clicked.animationContext = AnimationContext(anchorHostTime: 0, clickHostTimes: [10])
        let settled = AnimationEvaluator.resolve(clicked, canvasSize: CGSize(width: 192, height: 108), hostTime: 20)
        XCTAssertEqual(settled.count, 1)
        XCTAssertEqual(settled[0].item.opacity, 1)
        XCTAssertTrue(settled[0].motion.isIdentity)
        let mid = AnimationEvaluator.resolve(clicked, canvasSize: CGSize(width: 192, height: 108), hostTime: 10.5)
        XCTAssertEqual(mid[0].item.opacity, 0.75, accuracy: 0.001, "fade at eased 0.75")
    }

    func testMoveFromEdgeAndScaleFoldIntoMotion() {
        let canvas = CGSize(width: 192, height: 108)
        let move = box(animationSteps: [linearIn(.move, edge: .left)])
        let m = AnimationEvaluator.resolve(move, canvasSize: canvas, hostTime: 1)[0].motion
        XCTAssertEqual(m.translate.dx, -58, accuracy: 0.001, "halfway back from just past the left edge (frame.maxX = 116)")
        XCTAssertEqual(m.translate.dy, 0)
        let scale = box(animationSteps: [linearIn(.scale, fromScale: 0.5)])
        XCTAssertEqual(AnimationEvaluator.resolve(scale, canvasSize: canvas, hostTime: 1)[0].motion.scale, 0.75, accuracy: 0.001)
        let wipe = box(animationSteps: [linearIn(.wipe, edge: .top, softEdge: 4)])
        let w = AnimationEvaluator.resolve(wipe, canvasSize: canvas, hostTime: 0.5)[0].motion.wipe
        XCTAssertEqual(w?.edge, .top)
        XCTAssertEqual(w?.progress ?? 0, 0.25, accuracy: 0.001)
        XCTAssertEqual(w?.feather, 4)

        var out = linearIn(.move, edge: .right)
        out.kind = .exit
        let o = AnimationEvaluator.resolve(box(animationSteps: [out]), canvasSize: canvas, hostTime: 1)[0].motion
        XCTAssertEqual(o.translate.dx, (192 - 76) * 0.5, accuracy: 0.001)

        var tilted = box(animationSteps: [])
        tilted.tilt = 30
        XCTAssertEqual(AnimationEvaluator.resolve(tilted, canvasSize: canvas, hostTime: 0)[0].motion.tilt, 30)

        tilted.swing = -20
        tilted.tiltPivot = .bottom
        let still = AnimationEvaluator.resolve(tilted, canvasSize: canvas, hostTime: 0)[0].motion
        XCTAssertEqual(still.swing, -20)
        XCTAssertEqual(still.tiltPivot, .bottom)
        XCTAssertFalse(AnimationMotion(swing: 5).isIdentity)
    }

    func testQuadCornersSwingAndPivot() {
        let rect = CGRect(x: 100, y: 100, width: 200, height: 100)
        let target = CGSize(width: 1920, height: 1080)
        let flat = Compositor.buildQuadCorners(contentRect: rect, motion: .identity, sceneScale: 1, targetSize: target)
        XCTAssertEqual(flat[0], CGPoint(x: 100, y: 100))
        XCTAssertEqual(flat[3], CGPoint(x: 300, y: 200))

        let swung = Compositor.buildQuadCorners(
            contentRect: rect, motion: AnimationMotion(swing: 30), sceneScale: 1, targetSize: target)

        let leftHeight = swung[2].y - swung[0].y
        let rightHeight = swung[3].y - swung[1].y
        XCTAssertLessThan(rightHeight, leftHeight)
        XCTAssertLessThan(swung[1].x, 300)

        let bottomPivot = Compositor.buildQuadCorners(
            contentRect: rect, motion: AnimationMotion(tilt: 40, tiltPivot: .bottom), sceneScale: 1, targetSize: target)
        XCTAssertEqual(bottomPivot[2].x, 100, accuracy: 0.001)
        XCTAssertEqual(bottomPivot[2].y, 200, accuracy: 0.001)
        XCTAssertEqual(bottomPivot[3].x, 300, accuracy: 0.001)

        XCTAssertGreaterThan(bottomPivot[0].x, 100)
        XCTAssertGreaterThan(bottomPivot[0].y, 100)

        let keyed = Compositor.buildQuadCorners(
            contentRect: rect, motion: AnimationMotion(keystoneTop: 0.5), sceneScale: 1, targetSize: target)
        XCTAssertEqual(keyed[0], CGPoint(x: 150, y: 100))
        XCTAssertEqual(keyed[1], CGPoint(x: 250, y: 100))
        XCTAssertEqual(keyed[2], CGPoint(x: 100, y: 200))
        XCTAssertEqual(keyed[3], CGPoint(x: 300, y: 200))
        XCTAssertFalse(AnimationMotion(keystoneBottom: 1.2).isIdentity)

        let sheared = Compositor.buildQuadCorners(
            contentRect: rect, motion: AnimationMotion(skewX: 45), sceneScale: 1, targetSize: target)
        XCTAssertEqual(sheared[0].x, 150, accuracy: 0.001) 
        XCTAssertEqual(sheared[1].x, 350, accuracy: 0.001) 
        XCTAssertEqual(sheared[2].x, 50, accuracy: 0.001)  
        XCTAssertEqual(sheared[0].y, 100, accuracy: 0.001)
        XCTAssertFalse(AnimationMotion(skewY: 5).isIdentity)
    }

    func testStretchKeystoneStripMesh() {
        let rect = CGRect(x: 100, y: 100, width: 200, height: 100)
        let target = CGSize(width: 1920, height: 1080)
        let motion = AnimationMotion(keystoneTop: 0.5, keystoneBottom: 1, keystoneStretch: true)
        XCTAssertTrue(motion.usesStretchKeystone)
        XCTAssertFalse(AnimationMotion(keystoneTop: 0.5, keystoneStretch: false).usesStretchKeystone)
        XCTAssertFalse(AnimationMotion(keystoneStretch: true).usesStretchKeystone, "flat trapezoid = plain quad")
        let vertices = Compositor.stretchKeystoneVertices(contentRect: rect, motion: motion, sceneScale: 1, targetSize: target)
        XCTAssertEqual(vertices.count, Compositor.stretchKeystoneStrips * 6)
        func px(_ v: Compositor.OutputWarpVertexData) -> CGPoint {
            let nx = CGFloat(v.posUV.x), ny = CGFloat(v.posUV.y)
            let x = (nx + 1) / 2 * target.width
            let y = (1 - ny) / 2 * target.height
            return CGPoint(x: x, y: y)
        }

        XCTAssertEqual(px(vertices[0]).x, 150, accuracy: 0.01)
        XCTAssertEqual(px(vertices[5]).x, 250, accuracy: 0.01)
        XCTAssertEqual(px(vertices[0]).y, 100, accuracy: 0.01)

        let mid = Compositor.stretchKeystoneStrips / 2
        let midTL = px(vertices[mid * 6])
        XCTAssertEqual(midTL.y, 150, accuracy: 0.01)
        let expectedMidX: CGFloat = 125 
        XCTAssertEqual(midTL.x, expectedMidX, accuracy: 0.01)
        XCTAssertEqual(vertices[mid * 6].posUV.w, 0.5, accuracy: 0.001, "v rides linearly")
        XCTAssertEqual(vertices[0].q.x, 1, "affine strips, no projective q")
    }

    func testTextRangesSplitIntoHiddenBaseAndPiece() {
        let text = StyledText(string: "one two\nthree", fontName: "Helvetica", fontSize: 40, color: .white)
        let r1 = SceneAnimationRange(line: 0, column: 4, length: 3) 
        let r2 = SceneAnimationRange(line: 1, column: 0, length: 5) 
        let steps = [
            SceneAnimationStep(id: "a", kind: .enter, animation: .fade, group: .click(0), duration: 1, ramp: .none, ranges: [r1], placeholderUnderline: true),
            SceneAnimationStep(id: "b", kind: .enter, animation: .move, group: .click(1), duration: 1, ranges: [r2], offset: CGVector(dx: 0, dy: 20)),
        ]
        var item = RenderItem(id: "t", frame: CGRect(x: 0, y: 0, width: 400, height: 200), content: .text(text), animationSteps: steps)
        item.animationContext = AnimationContext(anchorHostTime: 0)

        let before = AnimationEvaluator.resolve(item, canvasSize: CGSize(width: 400, height: 200), hostTime: 1)
        XCTAssertEqual(before.count, 1)
        guard case .text(let baseText) = before[0].item.content else { return XCTFail("text") }
        XCTAssertEqual(baseText.styleRuns.filter { $0.hidden == true }.count, 2)
        XCTAssertEqual(baseText.styleRuns.first { $0.column == 4 }?.placeholderUnderline, true)

        item.animationContext = AnimationContext(anchorHostTime: 0, clickHostTimes: [10])
        let running = AnimationEvaluator.resolve(item, canvasSize: CGSize(width: 400, height: 200), hostTime: 10.5)
        XCTAssertEqual(running.count, 2)
        guard case .text(let base2) = running[0].item.content, case .text(let piece) = running[1].item.content else {
            return XCTFail("text")
        }
        XCTAssertEqual(base2.styleRuns.filter { $0.hidden == true }.map(\.column).sorted(), [0, 4])
        XCTAssertNil(base2.styleRuns.first { $0.column == 4 }?.placeholderUnderline)
        XCTAssertEqual(running[1].item.opacity, 0.5, accuracy: 0.001)

        let hiddenOnPiece = piece.styleRuns.filter { $0.hidden == true }
        XCTAssertEqual(hiddenOnPiece.map { ($0.line, $0.column, $0.length) }.map { "\($0)/\($1)/\($2)" }.sorted(), ["0/0/4", "1/0/5"])
        XCTAssertTrue(running[1].item.id.hasPrefix("t#step"))
    }

    func testComplementRunsMergeAndClamp() {
        let runs = AnimationEvaluator.complementRuns(
            of: [SceneAnimationRange(line: 0, column: 2, length: 3), SceneAnimationRange(line: 0, column: 4, length: 10)],
            in: "abcdefghij\n"
        )
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs[0].column, 0)
        XCTAssertEqual(runs[0].length, 2, "kept 2…10 (merged, clamped) → hidden 0…2 only")
    }

    func testItemMidMoveRendersAtInterpolatedPosition() throws {
        let compositor = try makeCompositor()
        var scene = RenderScene(canvasSize: CGSize(width: 192, height: 108))
        scene.addItem(box(animationSteps: [linearIn(.move, edge: .left)]), to: .slide)

        let frame = try compositor.renderFrame(scene: scene, width: 192, height: 108, at: 1)
        XCTAssertGreaterThan(pixel(frame, x: 38, y: 54).x, 0.9, "box heart at the interpolated position")
        XCTAssertLessThan(pixel(frame, x: 96, y: 54).x, 0.05, "home position still empty")
        let settled = try compositor.renderFrame(scene: scene, width: 192, height: 108, at: 5)
        XCTAssertGreaterThan(pixel(settled, x: 96, y: 54).x, 0.9, "done = home")
        XCTAssertLessThan(pixel(settled, x: 38, y: 54).x, 0.05)
    }

    func testMovingItemKeepsItsMatteInPlace() throws {
        let compositor = try makeCompositor()
        var scene = RenderScene(canvasSize: CGSize(width: 192, height: 108))
        scene.addItem(
            RenderItem(
                id: "matte", frame: CGRect(x: 56, y: 14, width: 80, height: 80),
                content: .shape(ShapeStyle(kind: .rectangle, fill: .solid(SceneColor(red: 0, green: 1, blue: 0)))),
                matteGroup: "matte"
            ),
            to: .slide
        )
        var subject = RenderItem(
            id: "subject", frame: CGRect(x: 0, y: 0, width: 192, height: 108),
            content: .solid(.white), maskedBy: "matte"
        )
        subject.animationSteps = [linearIn(.move, edge: .bottom)]
        subject.animationContext = AnimationContext(anchorHostTime: 0)
        scene.addItem(subject, to: .slide)

        let frame = try compositor.renderFrame(scene: scene, width: 192, height: 108, at: 1)
        XCTAssertGreaterThan(pixel(frame, x: 96, y: 80).x, 0.9, "inside matte AND under the risen subject = white")
        XCTAssertLessThan(pixel(frame, x: 96, y: 30).x, 0.05, "inside matte but the subject hasn't risen there yet")
        XCTAssertLessThan(pixel(frame, x: 20, y: 80).x, 0.05, "outside the matte stays masked while moving")
    }

    func testWipeRevealsFromTheEdge() throws {
        let compositor = try makeCompositor()
        var scene = RenderScene(canvasSize: CGSize(width: 192, height: 108))
        scene.addItem(box(animationSteps: [linearIn(.wipe, edge: .left)]), to: .slide)
        let frame = try compositor.renderFrame(scene: scene, width: 192, height: 108, at: 1)
        XCTAssertGreaterThan(pixel(frame, x: 80, y: 54).x, 0.9, "left part revealed")
        XCTAssertLessThan(pixel(frame, x: 112, y: 54).x, 0.05, "right part still hidden")
    }

    func testScaleGrowsAboutTheCenter() throws {
        let compositor = try makeCompositor()
        var scene = RenderScene(canvasSize: CGSize(width: 192, height: 108))
        scene.addItem(box(animationSteps: [linearIn(.scale, fromScale: 0.5)]), to: .slide)

        let frame = try compositor.renderFrame(scene: scene, width: 192, height: 108, at: 1)
        XCTAssertGreaterThan(pixel(frame, x: 96, y: 54).x, 0.9)
        XCTAssertGreaterThan(pixel(frame, x: 84, y: 54).x, 0.9, "inside the shrunken box")
        XCTAssertLessThan(pixel(frame, x: 78, y: 54).x, 0.05, "inside the home frame but outside the shrunken box")
    }

    func testTiltNarrowsTheFarEdge() throws {
        let compositor = try makeCompositor()
        var scene = RenderScene(canvasSize: CGSize(width: 192, height: 108))
        var item = RenderItem(id: "plane", frame: CGRect(x: 36, y: 14, width: 120, height: 80), content: .solid(.white))
        item.tilt = 60
        scene.addItem(item, to: .slide)
        let frame = try compositor.renderFrame(scene: scene, width: 192, height: 108)

        XCTAssertGreaterThan(pixel(frame, x: 96, y: 54).x, 0.9, "center survives")
        XCTAssertLessThan(pixel(frame, x: 38, y: 42).x, 0.05, "top edge narrows: x = 38 is outside the receded top")
        XCTAssertGreaterThan(pixel(frame, x: 38, y: 66).x, 0.9, "…but inside the advanced bottom")
        XCTAssertLessThan(pixel(frame, x: 96, y: 22).x, 0.05, "top edge moved down toward the center line (y ≈ 36)")
    }

    func testHiddenRangeDrawsNoInkAndPlaceholderUnderlines() throws {
        let compositor = try makeCompositor()
        var scene = RenderScene(canvasSize: CGSize(width: 400, height: 120))
        var text = StyledText(string: "AAAA BBBB", fontName: "Helvetica-Bold", fontSize: 60, color: .white)
        text.alignment = .left
        text.verticalAlignment = .top
        let full = RenderItem(id: "t", frame: CGRect(x: 0, y: 0, width: 400, height: 120), content: .text(text))
        scene.addItem(full, to: .slide)
        let plain = try compositor.renderFrame(scene: scene, width: 400, height: 120)
        let leftInk = inkFraction(plain, in: CGRect(x: 0, y: 5, width: 150, height: 60))
        let rightInk = inkFraction(plain, in: CGRect(x: 200, y: 5, width: 150, height: 60))
        XCTAssertGreaterThan(leftInk, 0.1)
        XCTAssertGreaterThan(rightInk, 0.1)

        text.styleRuns = [StyleRun(line: 0, column: 5, length: 4, hidden: true, placeholderUnderline: true)]
        var hidden = RenderScene(canvasSize: CGSize(width: 400, height: 120))
        hidden.addItem(RenderItem(id: "t", frame: CGRect(x: 0, y: 0, width: 400, height: 120), content: .text(text)), to: .slide)
        let masked = try compositor.renderFrame(scene: hidden, width: 400, height: 120)
        XCTAssertGreaterThan(inkFraction(masked, in: CGRect(x: 0, y: 5, width: 150, height: 60)), 0.1, "AAAA still draws")
        XCTAssertLessThan(inkFraction(masked, in: CGRect(x: 200, y: 5, width: 150, height: 40)), 0.005, "BBBB glyphs are gone")
        XCTAssertGreaterThan(inkFraction(masked, in: CGRect(x: 200, y: 40, width: 150, height: 40)), 0.005, "…but the blank underlines")
    }

    func testDrawTracesTheOutlineClockwiseFromTopLeft() throws {
        let compositor = try makeCompositor()
        var scene = RenderScene(canvasSize: CGSize(width: 192, height: 108))
        var item = RenderItem(
            id: "frame", frame: CGRect(x: 46, y: 24, width: 100, height: 60),
            content: .shape(ShapeStyle(kind: .rectangle, fill: .solid(.clear), stroke: SceneStroke(color: .white, width: 4)))
        )
        item.animationSteps = [linearIn(.draw)] 
        item.animationContext = AnimationContext(anchorHostTime: 0)
        scene.addItem(item, to: .slide)

        let quarter = try compositor.renderFrame(scene: scene, width: 192, height: 108, at: 0.5)
        XCTAssertGreaterThan(pixel(quarter, x: 100, y: 24).x, 0.5, "top edge drawn")
        XCTAssertLessThan(pixel(quarter, x: 140, y: 24).x, 0.05, "…but not past 80 units")
        XCTAssertLessThan(pixel(quarter, x: 100, y: 84).x, 0.05, "bottom edge not yet")
        let done = try compositor.renderFrame(scene: scene, width: 192, height: 108, at: 5)
        XCTAssertGreaterThan(pixel(done, x: 100, y: 84).x, 0.5, "closed outline once done")

        var reversed = item
        var step = linearIn(.draw)
        step.reverse = true
        reversed.animationSteps = [step]
        var scene2 = RenderScene(canvasSize: CGSize(width: 192, height: 108))
        scene2.addItem(reversed, to: .slide)
        let back = try compositor.renderFrame(scene: scene2, width: 192, height: 108, at: 0.5)
        XCTAssertGreaterThan(pixel(back, x: 46, y: 60).x, 0.5, "left edge drawn (counter-clockwise)")
        XCTAssertLessThan(pixel(back, x: 140, y: 24).x, 0.05)
    }

    func testTypeRevealsCharactersInOrderWithACaret() throws {
        let compositor = try makeCompositor()
        var text = StyledText(string: "AAAAAAAA", fontName: "Helvetica-Bold", fontSize: 60, color: .white)
        text.alignment = .left
        text.verticalAlignment = .top
        var item = RenderItem(id: "t", frame: CGRect(x: 0, y: 0, width: 400, height: 120), content: .text(text))
        item.animationSteps = [linearIn(.type)] 
        item.animationContext = AnimationContext(anchorHostTime: 0)
        var scene = RenderScene(canvasSize: CGSize(width: 400, height: 120))
        scene.addItem(item, to: .slide)
        let half = try compositor.renderFrame(scene: scene, width: 400, height: 120, at: 1)
        XCTAssertGreaterThan(inkFraction(half, in: CGRect(x: 0, y: 5, width: 120, height: 60)), 0.1, "first letters typed")
        XCTAssertLessThan(inkFraction(half, in: CGRect(x: 250, y: 5, width: 140, height: 60)), 0.005, "tail not yet")

        let runs = AnimationEvaluator.typeRuns(
            revealing: 0.5, of: [SceneAnimationRange(line: 0, column: 0, length: 8)], in: "AAAAAAAA", caret: true, reverse: false
        )
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs[0].column, 4)
        XCTAssertEqual(runs[0].length, 4)
        XCTAssertEqual(runs[0].caret, true)

        let two = AnimationEvaluator.typeRuns(
            revealing: 0.5,
            of: [SceneAnimationRange(line: 0, column: 0, length: 4), SceneAnimationRange(line: 1, column: 0, length: 4)],
            in: "AAAA\nBBBB", caret: false, reverse: false
        )
        XCTAssertEqual(two.map { "\($0.line):\($0.column):\($0.length)" }, ["1:0:4"])
    }

    private func morphStep(to target: RenderItem, duration: Double = 2) -> SceneAnimationStep {
        SceneAnimationStep(id: "m", kind: .morph, animation: .fade, group: .auto, duration: duration, ramp: .none, toItem: target)
    }

    func testMorphTweensFrameAndColorAndCrossFadesShapeKind() throws {
        let compositor = try makeCompositor()
        let start = RenderItem(
            id: "s", frame: CGRect(x: 20, y: 20, width: 40, height: 40),
            content: .shape(ShapeStyle(kind: .rectangle, fill: .solid(SceneColor(red: 1, green: 0, blue: 0))))
        )
        let end = RenderItem(
            id: "s", frame: CGRect(x: 120, y: 40, width: 60, height: 60),
            content: .shape(ShapeStyle(kind: .ellipse, fill: .solid(SceneColor(red: 0, green: 0, blue: 1))))
        )
        var item = start
        item.animationSteps = [morphStep(to: end)]
        item.animationContext = AnimationContext(anchorHostTime: 0)

        let state = AnimationEvaluator.morphState(of: item, context: item.animationContext, now: 1)
        XCTAssertEqual(state.base.frame.midX, 95, accuracy: 0.6)
        XCTAssertEqual(state.base.frame.width, 50, accuracy: 0.6)
        XCTAssertNotNil(state.partner, "rectangle → ellipse can't tween: cross-fade")
        XCTAssertEqual(state.base.opacity, 0.5, accuracy: 0.01)
        XCTAssertEqual(state.partner?.opacity ?? 0, 0.5, accuracy: 0.01)

        var scene = RenderScene(canvasSize: CGSize(width: 192, height: 108))
        scene.addItem(item, to: .slide)
        let mid = try compositor.renderFrame(scene: scene, width: 192, height: 108, at: 1)
        let center = pixel(mid, x: 95, y: 55)
        XCTAssertGreaterThan(center.x, 0.2, "red half")
        XCTAssertGreaterThan(center.z, 0.2, "blue half")
        XCTAssertLessThan(pixel(mid, x: 30, y: 30).x, 0.05, "left the start")

        let done = try compositor.renderFrame(scene: scene, width: 192, height: 108, at: 5)
        XCTAssertGreaterThan(pixel(done, x: 150, y: 70).z, 0.9)
        XCTAssertLessThan(pixel(done, x: 150, y: 70).x, 0.05)
        XCTAssertLessThan(pixel(done, x: 40, y: 40).x, 0.05)

        var rounded = end
        rounded.content = .shape(ShapeStyle(kind: .roundedRectangle(cornerRadius: 20), fill: .solid(SceneColor(red: 0, green: 0, blue: 1))))
        var item2 = start
        item2.animationSteps = [morphStep(to: rounded)]
        item2.animationContext = AnimationContext(anchorHostTime: 0)
        let s2 = AnimationEvaluator.morphState(of: item2, context: item2.animationContext, now: 1)
        XCTAssertNil(s2.partner)
        if case .shape(let style) = s2.base.content, case .roundedRectangle(let r) = style.kind {
            XCTAssertEqual(r, 10, accuracy: 0.2)
        } else { XCTFail("expected a tweened rounded rectangle") }
    }

    func testTextMorphScalesOnTheQuadAndChainedMorphsFold() {
        let text = StyledText(string: "Hi", fontName: "Helvetica", fontSize: 40, color: .white)
        let a = RenderItem(id: "t", frame: CGRect(x: 0, y: 0, width: 100, height: 40), content: .text(text))
        var b = a
        b.frame = CGRect(x: 50, y: 20, width: 200, height: 80)
        var c = a
        c.frame = CGRect(x: 300, y: 0, width: 100, height: 40)
        var item = a
        item.animationSteps = [
            SceneAnimationStep(id: "m1", kind: .morph, animation: .fade, group: .auto, duration: 2, ramp: .none, toItem: b),
            SceneAnimationStep(id: "m2", kind: .morph, animation: .fade, group: .click(0), duration: 2, ramp: .none, toItem: c),
        ]
        item.animationContext = AnimationContext(anchorHostTime: 0)
        let mid = AnimationEvaluator.morphState(of: item, context: item.animationContext, now: 1)
        XCTAssertEqual(mid.base.frame, a.frame, "text keeps its raster frame…")
        XCTAssertEqual(mid.motion.scale, 1.5, accuracy: 0.001, "…and scales on the quad")
        XCTAssertEqual(mid.motion.scaleY ?? 0, 1.5, accuracy: 0.001)
        XCTAssertEqual(mid.motion.translate.dx, 50, accuracy: 0.001, "center 50 → 100")

        item.animationContext = AnimationContext(anchorHostTime: 0, clickHostTimes: [10])
        let settled = AnimationEvaluator.morphState(of: item, context: item.animationContext, now: 9)
        XCTAssertEqual(settled.base.frame, b.frame)
        let second = AnimationEvaluator.morphState(of: item, context: item.animationContext, now: 11)
        XCTAssertEqual(second.base.frame, b.frame, "chained morph starts from the previous end state")
        XCTAssertEqual(second.motion.translate.dx, (350 - 150) * 0.5, accuracy: 0.001)
    }

    func testEnterFromCustomStartPoseTweensIn() throws {
        let compositor = try makeCompositor()
        let home = RenderItem(id: "b", frame: CGRect(x: 76, y: 34, width: 40, height: 40), content: .solid(.white))
        var from = home
        from.frame = CGRect(x: -60, y: 34, width: 20, height: 20)
        var item = home
        item.animationSteps = [SceneAnimationStep(id: "in", kind: .enter, animation: .move, group: .auto, duration: 2, ramp: .none, fromItem: from)]
        item.animationContext = AnimationContext(anchorHostTime: 0)
        var scene = RenderScene(canvasSize: CGSize(width: 192, height: 108))
        scene.addItem(item, to: .slide)

        let mid = try compositor.renderFrame(scene: scene, width: 192, height: 108, at: 1)
        XCTAssertGreaterThan(pixel(mid, x: 23, y: 49).x, 0.9)
        XCTAssertLessThan(pixel(mid, x: 96, y: 54).x, 0.05, "not home yet")
        let done = try compositor.renderFrame(scene: scene, width: 192, height: 108, at: 3)
        XCTAssertGreaterThan(pixel(done, x: 96, y: 54).x, 0.9, "home")
    }

    func testBlurBurnGlitchResolveIntoTheChainAndSettleClean() throws {
        let compositor = try makeCompositor()
        let canvas = CGSize(width: 192, height: 108)
        for animation in [SceneStepAnimation.blur, .burn, .glitch] {
            let item = box(animationSteps: [linearIn(animation)]) 
            let mid = AnimationEvaluator.resolve(item, canvasSize: canvas, hostTime: 1)
            XCTAssertEqual(mid.count, 1)
            XCTAssertFalse(mid[0].item.effects.isEmpty, "\(animation) rides the effect slot mid-way")
            let done = AnimationEvaluator.resolve(item, canvasSize: canvas, hostTime: 5)
            XCTAssertTrue(done[0].item.effects.isEmpty, "\(animation) leaves no pass once settled")
            XCTAssertEqual(done[0].item.opacity, 1)
            var scene = RenderScene(canvasSize: canvas)
            scene.addItem(item, to: .slide)
            let frame = try compositor.renderFrame(scene: scene, width: 192, height: 108, at: 1)
            XCTAssertGreaterThan(pixel(frame, x: 96, y: 54).x + pixel(frame, x: 96, y: 54).y, 0.3, "\(animation) mid: the box is there")
            let settled = try compositor.renderFrame(scene: scene, width: 192, height: 108, at: 5)
            XCTAssertGreaterThan(pixel(settled, x: 96, y: 54).x, 0.9)
            XCTAssertLessThan(pixel(settled, x: 60, y: 54).x, 0.05, "\(animation) settled: nothing bleeds")
        }

        var blurStep = linearIn(.blur)
        blurStep.amount = 24 
        let blurred = box(animationSteps: [blurStep])
        var scene = RenderScene(canvasSize: canvas)
        scene.addItem(blurred, to: .slide)
        let mid = try compositor.renderFrame(scene: scene, width: 192, height: 108, at: 0.5)
        XCTAssertGreaterThan(pixel(mid, x: 72, y: 54).x, 0.02, "blur bleeds past the edge (x 76) at 75% radius")
    }

    func testColorEmphasisTintsOnTheEnvelopeAndSettlesClean() throws {
        let canvas = CGSize(width: 192, height: 108)
        let step = SceneAnimationStep(
            id: "em", kind: .emphasis, animation: .color, group: .auto, duration: 2,
            ramp: .none, amount: 1, color: SceneColor(red: 1, green: 0, blue: 0)
        )
        let item = box(animationSteps: [step])

        let mid = AnimationEvaluator.resolve(item, canvasSize: canvas, hostTime: 1)
        XCTAssertEqual(mid.count, 1)
        guard case .tint(let color, let amount)? = mid[0].item.effects.first?.kind else {
            return XCTFail("color emphasis rides the effect slot mid-step")
        }
        XCTAssertEqual(color, SceneColor(red: 1, green: 0, blue: 0))
        XCTAssertEqual(amount, 1, accuracy: 0.01, "sin(π/2) peak × amount 1")

        if case .tint(_, let early)? = AnimationEvaluator.resolve(item, canvasSize: canvas, hostTime: 0.5)[0].item.effects.first?.kind {
            XCTAssertEqual(early, sin(0.25 * .pi), accuracy: 0.01)
        } else {
            XCTFail("tint present while running")
        }

        let done = AnimationEvaluator.resolve(item, canvasSize: canvas, hostTime: 5)
        XCTAssertTrue(done[0].item.effects.isEmpty)
        XCTAssertEqual(done[0].item.opacity, 1)

        var bare = step
        bare.color = nil
        XCTAssertTrue(AnimationEvaluator.resolve(box(animationSteps: [bare]), canvasSize: canvas, hostTime: 1)[0].item.effects.isEmpty)

        let compositor = try makeCompositor()
        var scene = RenderScene(canvasSize: canvas)
        scene.addItem(item, to: .slide)
        let frame = try compositor.renderFrame(scene: scene, width: 192, height: 108, at: 1)
        let center = pixel(frame, x: 96, y: 54)
        XCTAssertGreaterThan(center.x, 0.9, "red stays under a red tint")
        XCTAssertLessThan(center.y, 0.05, "green tinted away at full strength")
        let settled = try compositor.renderFrame(scene: scene, width: 192, height: 108, at: 5)
        XCTAssertGreaterThan(pixel(settled, x: 96, y: 54).y, 0.9, "settles back to white")
    }

    func testFilmBurnTransitionSweepsAWarmLeak() throws {
        let compositor = try makeCompositor()
        func gray(_ id: String) -> RenderScene {
            var scene = RenderScene(canvasSize: CGSize(width: 192, height: 108))
            scene.addItem(RenderItem(id: id, frame: CGRect(x: 0, y: 0, width: 192, height: 108),
                                     content: .solid(SceneColor(red: 0.2, green: 0.2, blue: 0.2))), to: .slide)
            return scene
        }
        let engine = SceneTransitionEngine(initial: gray("a"))
        engine.push(gray("b"), transition: SceneTransition(kind: .filmBurn, duration: 4))
        let mid = engine.scene(at: Date().addingTimeInterval(2))
        let items = mid.layers.first { $0.kind == .slide }?.items ?? []
        XCTAssertTrue(items.contains { $0.effects.contains { if case .burn = $0.kind { return true }; return false } }, "burn passes ride both sides")
        XCTAssertTrue(items.contains { $0.id.hasPrefix("transition-plate") }, "warm plate at the peak")
        let frame = try compositor.renderFrame(scene: mid, width: 192, height: 108)
        let center = pixel(frame, x: 96, y: 54)
        XCTAssertGreaterThan(center.x, center.z + 0.05, "warm: red over blue at mid-sweep")
        let settled = engine.scene(at: Date().addingTimeInterval(10))
        XCTAssertFalse(settled.layers.first { $0.kind == .slide }?.items.contains { $0.id.hasPrefix("transition-plate") } ?? true)
    }

    func testMorphBlendRidesBothSidesAndPeaksMidway() {
        let start = RenderItem(id: "s", frame: CGRect(x: 20, y: 20, width: 40, height: 40),
                               content: .shape(ShapeStyle(kind: .rectangle, fill: .solid(.white))))
        var end = start
        end.content = .shape(ShapeStyle(kind: .ellipse, fill: .solid(.white)))
        var step = morphStep(to: end)
        step.animation = .glitch
        step.amount = 1
        var item = start
        item.animationSteps = [step]
        item.animationContext = AnimationContext(anchorHostTime: 0)
        let mid = AnimationEvaluator.morphState(of: item, context: item.animationContext, now: 1)
        XCTAssertTrue(mid.base.effects.contains { if case .glitch(let a, _) = $0.kind { return a > 0.9 }; return false })
        XCTAssertTrue(mid.partner?.effects.contains { if case .glitch = $0.kind { return true }; return false } ?? false)
        let early = AnimationEvaluator.morphState(of: item, context: item.animationContext, now: 0.1)
        if case .glitch(let a, _)? = early.base.effects.first?.kind { XCTAssertLessThan(a, 0.2) }
        let done = AnimationEvaluator.morphState(of: item, context: item.animationContext, now: 5)
        XCTAssertTrue(done.base.effects.isEmpty)
    }

    func testSettledContextShowsTheEndOfTheSequence() {
        let canvas = CGSize(width: 192, height: 108)

        let start = RenderItem(id: "s", frame: CGRect(x: 20, y: 20, width: 40, height: 40), content: .solid(.white))
        var end = start
        end.frame = CGRect(x: 120, y: 40, width: 60, height: 60)
        var item = start
        item.animationSteps = [
            SceneAnimationStep(id: "in", kind: .enter, animation: .move, group: .click(2), duration: 1),
            SceneAnimationStep(id: "m", kind: .morph, animation: .fade, group: .click(4), duration: 1, toItem: end),
            SceneAnimationStep(id: "out", kind: .exit, animation: .fade, group: .exit, duration: 1),
        ]
        item.animationContext = .settled
        let resolved = AnimationEvaluator.resolve(item, canvasSize: canvas, hostTime: 0)
        XCTAssertEqual(resolved.count, 1, "shown (In done, Out on dismiss pending)")
        XCTAssertEqual(resolved[0].item.frame, end.frame, "morph folded")
        XCTAssertTrue(resolved[0].motion.isIdentity)

        var leaves = start
        leaves.animationSteps = [SceneAnimationStep(id: "out", kind: .exit, animation: .fade, group: .click(0), duration: 1)]
        leaves.animationContext = .settled
        XCTAssertTrue(AnimationEvaluator.resolve(leaves, canvasSize: canvas, hostTime: 0).isEmpty)
    }
}
