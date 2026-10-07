import Metal
import XCTest
import simd
@testable import RenderEngine

@MainActor
final class EffectChainTests: XCTestCase {
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

    func testBlurSpreadsInkPastTheFrame() throws {
        let compositor = try makeCompositor()
        var scene = RenderScene(canvasSize: CGSize(width: 192, height: 108))
        scene.background = .black
        scene.addItem(
            RenderItem(
                id: "box",
                frame: CGRect(x: 76, y: 34, width: 40, height: 40),
                content: .solid(.white),
                effects: [.blur(radius: 8)]
            ),
            to: .slide
        )
        let frame = try compositor.renderFrame(scene: scene, width: 192, height: 108)
        let center = pixel(frame, x: 96, y: 54)
        XCTAssertGreaterThan(center.x, 0.6, "the box's heart survives the blur")
        let justOutside = pixel(frame, x: 70, y: 54) 
        XCTAssertGreaterThan(justOutside.x, 0.02, "ink bleeds past where the hard edge was")
        XCTAssertLessThan(justOutside.x, 0.6, "…softly")
        let farAway = pixel(frame, x: 10, y: 54)
        XCTAssertEqual(farAway.x, 0, accuracy: 0.01, "blur is local")
    }

    func testColorAdjustDesaturatesAndDarkens() throws {
        let compositor = try makeCompositor()
        var scene = RenderScene(canvasSize: CGSize(width: 192, height: 108))
        scene.background = .black
        scene.addItem(
            RenderItem(
                id: "red",
                frame: CGRect(x: 0, y: 0, width: 192, height: 108),
                content: .solid(SceneColor(red: 1, green: 0, blue: 0)),
                effects: [.colorAdjust(brightness: -0.2, contrast: 0, saturation: 0)]
            ),
            to: .slide
        )
        let frame = try compositor.renderFrame(scene: scene, width: 192, height: 108)
        let center = pixel(frame, x: 96, y: 54)
        XCTAssertEqual(center.x, center.y, accuracy: 0.02, "saturation 0 = gray (r == g)")
        XCTAssertEqual(center.y, center.z, accuracy: 0.02, "…and g == b")
        XCTAssertGreaterThan(center.x, 0.0, "brightness floor did not crush to black")
        XCTAssertLessThan(center.x, 0.22, "red's linear luma (~0.21) minus brightness")
    }

    func testAdjustmentLayerProcessesOnlyItsRegion() throws {
        let compositor = try makeCompositor()
        var scene = RenderScene(canvasSize: CGSize(width: 192, height: 108))
        scene.background = .black

        scene.addItem(
            RenderItem(
                id: "below",
                frame: CGRect(x: 0, y: 0, width: 192, height: 108),
                content: .solid(SceneColor(red: 1, green: 0, blue: 0))
            ),
            to: .stillGraphics
        )

        scene.addItem(
            RenderItem(
                id: "adjust",
                frame: CGRect(x: 0, y: 0, width: 96, height: 108),
                content: .shape(ShapeStyle(kind: .rectangle, fill: .none)),
                effects: [.colorAdjust(brightness: 0, contrast: 0, saturation: 0)],
                effectsApplyBelow: true
            ),
            to: .slide
        )
        let frame = try compositor.renderFrame(scene: scene, width: 192, height: 108)
        let left = pixel(frame, x: 48, y: 54)
        XCTAssertEqual(left.x, left.y, accuracy: 0.02, "left half is desaturated")
        let right = pixel(frame, x: 150, y: 54)
        XCTAssertEqual(right.x, 1, accuracy: 0.02, "right half is untouched red")
        XCTAssertEqual(right.y, 0, accuracy: 0.02)
    }

    func testBlurredMaskedItemStaysInsideItsMatte() throws {
        let compositor = try makeCompositor()
        var scene = RenderScene(canvasSize: CGSize(width: 192, height: 108))
        scene.background = .black
        scene.addItem(
            RenderItem(
                id: "matte",
                frame: CGRect(x: 46, y: 4, width: 100, height: 100),
                content: .shape(ShapeStyle(kind: .ellipse, fill: .solid(.white))),
                matteGroup: "matte"
            ),
            to: .slide
        )
        scene.addItem(
            RenderItem(
                id: "subject",
                frame: CGRect(x: 0, y: 0, width: 192, height: 108),
                content: .solid(.white),
                maskedBy: "matte",
                effects: [.blur(radius: 6)]
            ),
            to: .slide
        )
        let frame = try compositor.renderFrame(scene: scene, width: 192, height: 108)
        XCTAssertGreaterThan(pixel(frame, x: 96, y: 54).x, 0.8, "inside the matte")
        XCTAssertEqual(pixel(frame, x: 175, y: 54).x, 0, accuracy: 0.02,
                       "effects run BEFORE the mask — nothing escapes the matte")
    }
}

extension EffectChainTests {

    func testV48InvertAndVignetteRender() throws {
        let compositor = try makeCompositor()
        var scene = RenderScene(canvasSize: CGSize(width: 192, height: 108))
        scene.background = .black
        var item = RenderItem(
            id: "field",
            frame: CGRect(x: 0, y: 0, width: 192, height: 108),
            content: .solid(SceneColor(red: 1, green: 0, blue: 0))
        )
        item.effects = [
            SceneEffect(kind: .invert),
            SceneEffect(kind: .vignette(strength: 1)),
        ]
        scene.addItem(item, to: .slide)
        let frame = try compositor.renderFrame(scene: scene, width: 192, height: 108)

        let center = pixel(frame, x: 96, y: 54)
        XCTAssertEqual(center.x, 0, accuracy: 0.03)
        XCTAssertGreaterThan(center.y, 0.9)
        XCTAssertGreaterThan(center.z, 0.9)

        let corner = pixel(frame, x: 4, y: 4)
        XCTAssertLessThan(corner.y, center.y - 0.25, "vignette darkens the corner")
    }

    func testV48PosterizeAndHueRotateRender() throws {
        let compositor = try makeCompositor()
        var scene = RenderScene(canvasSize: CGSize(width: 192, height: 108))
        scene.background = .black
        var item = RenderItem(
            id: "field",
            frame: CGRect(x: 0, y: 0, width: 192, height: 108),
            content: .solid(SceneColor(red: 1, green: 0, blue: 0))
        )
        item.effects = [SceneEffect(kind: .hueRotate(degrees: 180))]
        scene.addItem(item, to: .slide)
        let frame = try compositor.renderFrame(scene: scene, width: 192, height: 108)
        let center = pixel(frame, x: 96, y: 54)
        XCTAssertLessThan(center.x, 0.5, "180° hue rotation leaves little red")
    }
}

extension EffectChainTests {

    func testV79WarpDisplacesEdges() throws {
        let compositor = try makeCompositor()
        var scene = RenderScene(canvasSize: CGSize(width: 192, height: 108))
        scene.background = .black
        var item = RenderItem(
            id: "box",
            frame: CGRect(x: 56, y: 24, width: 80, height: 60),
            content: .solid(SceneColor(red: 1, green: 0, blue: 0))
        )
        item.effects = [SceneEffect(kind: .warp(amount: 12, scale: 30, speed: 1))]
        scene.addItem(item, to: .slide)
        let frame = try compositor.renderFrame(scene: scene, width: 192, height: 108, at: 3.7)
        XCTAssertGreaterThan(pixel(frame, x: 96, y: 54).x, 0.9, "the heart of the box is untouched")
        XCTAssertEqual(pixel(frame, x: 8, y: 8).x, 0, accuracy: 0.01, "warp is local")

        var outsideInk = 0, insideHoles = 0
        for y in stride(from: 26, to: 82, by: 2) {
            if pixel(frame, x: 52, y: y).x > 0.2 { outsideInk += 1 }
            if pixel(frame, x: 140, y: y).x > 0.2 { outsideInk += 1 }
            if pixel(frame, x: 60, y: y).x < 0.8 { insideHoles += 1 }
            if pixel(frame, x: 132, y: y).x < 0.8 { insideHoles += 1 }
        }
        XCTAssertGreaterThan(outsideInk, 0, "displacement pulled ink past the frame edge")
        XCTAssertGreaterThan(insideHoles, 0, "…and pushed some off it")
    }

    func testV79StainedGlassAndGrainRender() throws {
        let compositor = try makeCompositor()
        var scene = RenderScene(canvasSize: CGSize(width: 192, height: 108))
        scene.background = .black
        var field = RenderItem(
            id: "field", frame: CGRect(x: 0, y: 0, width: 192, height: 108),
            content: .solid(SceneColor(red: 0.5, green: 0.5, blue: 0.5))
        )
        field.effects = [SceneEffect(kind: .stainedGlass(cellSize: 24, leading: 3, jitter: 0.8, speed: 0))]
        scene.addItem(field, to: .slide)
        let glass = try compositor.renderFrame(scene: scene, width: 192, height: 108)

        let mid: Float = 0.214
        var seams = 0, panes = 0
        for y in stride(from: 4, to: 104, by: 3) {
            for x in stride(from: 4, to: 188, by: 3) {
                let v = pixel(glass, x: x, y: y).x
                if v < 0.03 { seams += 1 } else if abs(v - mid) < 0.03 { panes += 1 }
            }
        }
        XCTAssertGreaterThan(seams, 20, "leading draws dark")
        XCTAssertGreaterThan(panes, seams, "panes keep the source color")

        var grainScene = RenderScene(canvasSize: CGSize(width: 192, height: 108))
        grainScene.background = .black
        field.effects = [SceneEffect(kind: .grain(amount: 0.3, size: 1, speed: 1))]
        grainScene.addItem(field, to: .slide)
        let grainy = try compositor.renderFrame(scene: grainScene, width: 192, height: 108, at: 2)
        var lighter = 0, darker = 0, sum: Float = 0, count: Float = 0
        for y in stride(from: 4, to: 104, by: 2) {
            for x in stride(from: 4, to: 188, by: 2) {
                let v = pixel(grainy, x: x, y: y).x
                sum += v; count += 1
                if v > mid + 0.03 { lighter += 1 } else if v < mid - 0.03 { darker += 1 }
            }
        }
        XCTAssertGreaterThan(lighter, 100); XCTAssertGreaterThan(darker, 100)
        XCTAssertEqual(sum / count, mid, accuracy: 0.03, "grain is centered on the mean")
    }

    func testV79GhostTrailsDriftTheTrail() throws {
        let compositor = try makeCompositor()
        var clock: CFTimeInterval = 100
        compositor.cacheClockOverride = { clock }
        func scene(color: SceneColor) -> RenderScene {
            var scene = RenderScene(canvasSize: CGSize(width: 192, height: 108))
            scene.background = .black
            var item = RenderItem(
                id: "mover", frame: CGRect(x: 60, y: 30, width: 40, height: 40), content: .solid(color)
            )
            item.effects = [SceneEffect(kind: .ghostTrails(fade: 3, drift: 8, scale: 30, speed: 1))]
            scene.addItem(item, to: .slide)
            return scene
        }
        _ = try compositor.renderFrame(scene: scene(color: .white), width: 192, height: 108, at: 1)
        var faded = scene(color: .clear)
        var outside = 0
        for step in 1 ... 6 {
            clock += 1.0 / 60
            let frame = try compositor.renderFrame(scene: faded, width: 192, height: 108, at: 1 + Double(step) / 60)
            for y in 20 ..< 90 where pixel(frame, x: 54, y: y).x > 0.05 || pixel(frame, x: 106, y: y).x > 0.05 { outside += 1 }
            faded = scene(color: .clear)
        }
        XCTAssertGreaterThan(outside, 0, "the trail wandered past the box's old edge")
        let inside = pixel(try compositor.renderFrame(scene: faded, width: 192, height: 108, at: 1.2), x: 80, y: 50).x
        XCTAssertGreaterThan(inside, 0.2, "…and is still there, decaying")
    }

    func testV79ScatterSpecklesEdges() throws {
        let compositor = try makeCompositor()
        var scene = RenderScene(canvasSize: CGSize(width: 192, height: 108))
        scene.background = .black
        var item = RenderItem(
            id: "box",
            frame: CGRect(x: 56, y: 24, width: 80, height: 60),
            content: .solid(SceneColor(red: 1, green: 0, blue: 0))
        )
        item.effects = [SceneEffect(kind: .scatter(amount: 6, size: 1, speed: 1, smooth: 0))]
        scene.addItem(item, to: .slide)
        let frame = try compositor.renderFrame(scene: scene, width: 192, height: 108, at: 3.7)
        XCTAssertGreaterThan(pixel(frame, x: 96, y: 54).x, 0.9, "the heart survives")
        XCTAssertEqual(pixel(frame, x: 8, y: 8).x, 0, accuracy: 0.01, "scatter is local")

        var outsideInk = 0, insideHoles = 0
        for y in 26 ..< 82 {
            if pixel(frame, x: 53, y: y).x > 0.2 { outsideInk += 1 }
            if pixel(frame, x: 59, y: y).x < 0.8 { insideHoles += 1 }
        }
        XCTAssertGreaterThan(outsideInk, 3, "grain throws ink outward")
        XCTAssertGreaterThan(insideHoles, 3, "…and punches holes inward")

        var glass = RenderScene(canvasSize: CGSize(width: 192, height: 108))
        glass.background = .black
        item.effects = [SceneEffect(kind: .scatter(amount: 6, size: 12, speed: 0, smooth: 1))]
        glass.addItem(item, to: .slide)
        let frosted = try compositor.renderFrame(scene: glass, width: 192, height: 108, at: 3.7)
        XCTAssertGreaterThan(pixel(frosted, x: 96, y: 54).x, 0.9)
        var moved = 0
        for y in 26 ..< 82 where pixel(frosted, x: 53, y: y).x > 0.2 || pixel(frosted, x: 59, y: y).x < 0.8 { moved += 1 }
        XCTAssertGreaterThan(moved, 0, "the smooth field still bends the edge")
    }

    func testV79EchoKeepsADecayingTrailAndResetsOnGap() throws {
        let compositor = try makeCompositor()
        var clock: CFTimeInterval = 100
        compositor.cacheClockOverride = { clock }
        func scene(x: CGFloat, color: SceneColor = .white) -> RenderScene {
            var scene = RenderScene(canvasSize: CGSize(width: 192, height: 108))
            scene.background = .black
            var item = RenderItem(
                id: "mover",
                frame: CGRect(x: x, y: 24, width: 40, height: 60),
                content: .solid(color)
            )

            item.effects = [SceneEffect(kind: .echo(fade: 0.1))]
            scene.addItem(item, to: .slide)
            return scene
        }
        _ = try compositor.renderFrame(scene: scene(x: 20), width: 192, height: 108)
        XCTAssertEqual(compositor.effectHistoryCount, 1)
        clock += 1.0 / 60

        var frame = try compositor.renderFrame(scene: scene(x: 20), width: 192, height: 108)
        XCTAssertGreaterThan(pixel(frame, x: 40, y: 54).x, 0.95, "fresh ink wins")

        let faded = scene(x: 20, color: .clear)
        clock += 1.0 / 60
        frame = try compositor.renderFrame(scene: faded, width: 192, height: 108)
        let trail = pixel(frame, x: 40, y: 54)
        XCTAssertEqual(trail.x, 0.681, accuracy: 0.08, "one frame of decay at 0.1s-to-10%")

        clock += 2.0 / 60
        frame = try compositor.renderFrame(scene: faded, width: 192, height: 108)
        XCTAssertEqual(pixel(frame, x: 40, y: 54).x, 0.316, accuracy: 0.06, "frame-rate compensated")

        clock += Compositor.historyGap + 0.1
        frame = try compositor.renderFrame(scene: faded, width: 192, height: 108)
        XCTAssertEqual(pixel(frame, x: 40, y: 54).x, 0, accuracy: 0.01, "cut looks like a cut")
    }
}
