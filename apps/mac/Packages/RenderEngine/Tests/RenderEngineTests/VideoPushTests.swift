import Metal
import XCTest
@testable import RenderEngine

@MainActor
final class VideoPushTests: XCTestCase {
    private let canvas = CGSize(width: 1920, height: 1080)

    private func panel(_ id: String = "panel", push: SceneVideoPush?, kind: SceneAnimationKind = .enter,
                       exitPush: SceneVideoPush? = nil, context: AnimationContext? = AnimationContext(anchorHostTime: 0)) -> RenderItem {
        var animationSteps: [SceneAnimationStep] = [
            SceneAnimationStep(id: "\(id)-in", kind: kind, animation: .move, group: .auto, duration: 1, ramp: .none, edge: .right, videoPush: push),
        ]
        if let exitPush {
            animationSteps.append(SceneAnimationStep(id: "\(id)-out", kind: .exit, animation: .move, group: .exit, duration: 1, ramp: .none, edge: .right, videoPush: exitPush))
        }
        return RenderItem(
            id: id, frame: CGRect(x: 1280, y: 0, width: 640, height: 1080),
            content: .solid(.white), animationSteps: animationSteps, animationContext: context
        )
    }

    private func video(_ id: String = "cam") -> RenderItem {
        RenderItem(id: id, frame: CGRect(origin: .zero, size: canvas), content: .solid(SceneColor(red: 1, green: 0, blue: 0)))
    }

    func testFreeRectPicksTheLargestSideBand() {
        XCTAssertEqual(VideoPushEvaluator.freeRect(around: CGRect(x: 1280, y: 0, width: 640, height: 1080), canvas: canvas, margin: 0),
                       CGRect(x: 0, y: 0, width: 1280, height: 1080), "side third → the left band")
        XCTAssertEqual(VideoPushEvaluator.freeRect(around: CGRect(x: 0, y: 760, width: 1920, height: 240), canvas: canvas, margin: 40),
                       CGRect(x: 40, y: 40, width: 1840, height: 680), "lower band → above it, margin inset")
        XCTAssertEqual(VideoPushEvaluator.freeRect(around: CGRect(origin: .zero, size: canvas), canvas: canvas, margin: 0),
                       CGRect(origin: .zero, size: canvas), "full-frame object degrades to the canvas")
    }

    func testTransformFillFitAlignmentAndZoom() {
        let target = CGRect(x: 0, y: 0, width: 1280, height: 1080)
        let state = VideoPushEvaluator.State(push: SceneVideoPush(), amount: 1, target: target)

        let fill = VideoPushEvaluator.transform(canvas: canvas, state: state)
        XCTAssertEqual(fill.scale, 1, accuracy: 0.0001)
        XCTAssertEqual(fill.offset.dx, (1280 - 1920) / 2, accuracy: 0.001)
        XCTAssertEqual(fill.clip, target)

        var left = state; left.push.alignment = .left
        XCTAssertEqual(VideoPushEvaluator.transform(canvas: canvas, state: left).offset.dx, 0, accuracy: 0.001, "left keeps the left of the picture")

        var fit = state; fit.push.mode = .fit
        let fitT = VideoPushEvaluator.transform(canvas: canvas, state: fit)
        XCTAssertEqual(fitT.scale, 1280.0 / 1920.0, accuracy: 0.0001, "fit letterboxes")

        var zoomed = state; zoomed.push.zoom = 1.2
        XCTAssertEqual(VideoPushEvaluator.transform(canvas: canvas, state: zoomed).scale, 1.2, accuracy: 0.0001)

        var mid = state; mid.amount = 0.5
        XCTAssertEqual(VideoPushEvaluator.transform(canvas: canvas, state: mid).clip,
                       CGRect(x: 0, y: 0, width: 1600, height: 1080))

        var blur = state; blur.push = SceneVideoPush(mode: .blurBackground, zoom: 1.3, blurRadius: 40); blur.amount = 0.5
        let blurT = VideoPushEvaluator.transform(canvas: canvas, state: blur)
        XCTAssertEqual(blurT.scale, 1.15, accuracy: 0.0001)
        XCTAssertNil(blurT.clip)
        XCTAssertEqual(blurT.blurRadius, 20, accuracy: 0.001)
    }

    func testInPushesSettledHoldsOutReturnsAndRecencyWins() {
        var scene = RenderScene(canvasSize: canvas)
        scene.addItem(video(), to: .videoInput)
        scene.addItem(panel(push: SceneVideoPush(), exitPush: SceneVideoPush()), to: .overlays)

        func clip(at t: Double, dismissAt: Double? = nil) -> AnimationMotion.Clip? {
            var s = scene
            if let dismissAt {
                s.layers[s.layers.firstIndex(where: { $0.kind == .overlays })!].items[0].animationContext =
                    AnimationContext(anchorHostTime: 0, dismissHostTime: dismissAt)
            }
            return AnimationEvaluator.resolve(s, hostTime: t).motions["cam"]?.clip
        }

        let mid = try! XCTUnwrap(clip(at: 0.5))
        XCTAssertEqual(mid.maxU, 1760.0 / 1920.0, accuracy: 0.001)

        let settled = try! XCTUnwrap(clip(at: 10))
        XCTAssertEqual(settled.minU, 320.0 / 1920.0, accuracy: 0.001)
        XCTAssertEqual(settled.maxU, 1600.0 / 1920.0, accuracy: 0.001)

        let returning = try! XCTUnwrap(clip(at: 10.5, dismissAt: 10))
        XCTAssertEqual(returning.maxU, 1760.0 / 1920.0, accuracy: 0.001)

        XCTAssertNil(clip(at: 12, dismissAt: 10))

        var two = scene
        var second = panel("late", push: SceneVideoPush(margin: 100), context: AnimationContext(anchorHostTime: 100))
        second.frame = CGRect(x: 0, y: 760, width: 1920, height: 240)
        two.addItem(second, to: .slide)
        let winner = try! XCTUnwrap(AnimationEvaluator.resolve(two, hostTime: 200).motions["cam"]?.clip)
        XCTAssertEqual(winner.maxV, 0.7894, accuracy: 0.001, "the later lower-band push owns the picture")
    }

    func testBackdropCloneAndBlurBackground() {
        var scene = RenderScene(canvasSize: canvas)
        scene.addItem(video(), to: .videoInput)
        scene.addItem(panel(push: SceneVideoPush(zoom: 1.05, backdrop: true, blurRadius: 30)), to: .overlays)
        let resolved = AnimationEvaluator.resolve(scene, hostTime: 10)
        let layer = resolved.scene.layers.first { $0.kind == .videoInput }!
        XCTAssertEqual(layer.items.map(\.id), ["cam#pushbg", "cam"], "the blurred copy rides under the pushed picture")
        let clone = layer.items[0]
        XCTAssertEqual(clone.effects.first?.kind, .blur(radius: 30))
        XCTAssertNil(resolved.motions["cam#pushbg"]?.clip, "the backdrop is unclipped")
        XCTAssertNotNil(resolved.motions["cam"]?.clip)

        var blurScene = RenderScene(canvasSize: canvas)
        blurScene.addItem(video(), to: .videoInput)
        blurScene.addItem(panel(push: SceneVideoPush(mode: .blurBackground, zoom: 1.25, blurRadius: 44)), to: .overlays)
        let blurred = AnimationEvaluator.resolve(blurScene, hostTime: 10)
        let cam = blurred.scene.layers.first { $0.kind == .videoInput }!.items[0]
        XCTAssertEqual(cam.effects.first?.kind, .blur(radius: 44))
        XCTAssertEqual(blurred.motions["cam"]?.scale ?? 0, 1.25, accuracy: 0.0001)
        XCTAssertNil(blurred.motions["cam"]?.clip)
    }

    func testMidPushRendersTheVideoClippedToTheWalkingWindow() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("No Metal device") }
        let compositor = try Compositor()
        var scene = RenderScene(canvasSize: canvas)
        scene.addItem(video(), to: .videoInput)

        var ghost = panel(push: SceneVideoPush())
        ghost.content = .solid(.clear)
        scene.addItem(ghost, to: .overlays)
        func red(_ frame: RenderedFrame, x: Int, y: Int) -> Float {
            var out: Float = 0
            frame.data.withUnsafeBytes { raw in
                let base = raw.baseAddress! + y * frame.bytesPerRow + x * 8
                out = Float(base.assumingMemoryBound(to: Float16.self)[0])
            }
            return out
        }

        let settled = try compositor.renderFrame(scene: scene, width: 480, height: 270, at: 10)
        XCTAssertGreaterThan(red(settled, x: 160, y: 135), 0.9, "picture inside the window")
        XCTAssertLessThan(red(settled, x: 350, y: 135), 0.1, "clipped outside the settled window")

        let mid = try compositor.renderFrame(scene: scene, width: 480, height: 270, at: 0.5)
        XCTAssertGreaterThan(red(mid, x: 395, y: 20), 0.9, "window still wide mid-push")
        XCTAssertLessThan(red(mid, x: 470, y: 135), 0.1, "already clipped past the walking edge")
    }
}
