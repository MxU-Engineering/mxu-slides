import Metal
import XCTest
import simd
@testable import RenderEngine

@MainActor
final class ObjectMaskTests: XCTestCase {
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

    private func scene(mode out: Bool) -> RenderScene {
        var scene = RenderScene(canvasSize: CGSize(width: 192, height: 108))
        scene.background = .black
        scene.addItem(
            RenderItem(
                id: "matte",
                frame: CGRect(x: 16, y: 14, width: 80, height: 80),
                content: .shape(ShapeStyle(kind: .ellipse, fill: .solid(SceneColor(red: 0, green: 1, blue: 0)))),
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
                maskOut: out
            ),
            to: .slide
        )
        return scene
    }

    func testMaskInKeepsPixelsInsideTheMatte() throws {
        let compositor = try makeCompositor()
        let frame = try compositor.renderFrame(scene: scene(mode: false), width: 192, height: 108)
        let inside = pixel(frame, x: 56, y: 54) 
        XCTAssertEqual(inside.x, 1, accuracy: 0.02, "inside the matte: subject shows")
        XCTAssertEqual(inside.y, 1, accuracy: 0.02, "…and it is the SUBJECT's white, not the matte's green")
        let outside = pixel(frame, x: 160, y: 54) 
        XCTAssertEqual(outside.x, 0, accuracy: 0.02, "outside the matte: masked away")
        let matteOnly = pixel(frame, x: 20, y: 18) 
        XCTAssertEqual(matteOnly.y, 0, accuracy: 0.02, "the matte never draws its own green")
    }

    func testKnockoutCutsPixelsInsideTheMatte() throws {
        let compositor = try makeCompositor()
        let frame = try compositor.renderFrame(scene: scene(mode: true), width: 192, height: 108)
        let inside = pixel(frame, x: 56, y: 54)
        XCTAssertEqual(inside.x, 0, accuracy: 0.02, "inside the matte: knocked out to background")
        let outside = pixel(frame, x: 160, y: 54)
        XCTAssertEqual(outside.x, 1, accuracy: 0.02, "outside the matte: subject survives")
    }

    func testRotatedMatteMasksAtItsRotatedPosition() throws {
        let compositor = try makeCompositor()
        var scene = RenderScene(canvasSize: CGSize(width: 192, height: 108))
        scene.background = .black

        scene.addItem(
            RenderItem(
                id: "matte",
                frame: CGRect(x: 46, y: 44, width: 100, height: 20),
                content: .shape(ShapeStyle(kind: .rectangle, fill: .solid(.white))),
                rotationDegrees: 90,
                matteGroup: "matte"
            ),
            to: .slide
        )
        scene.addItem(
            RenderItem(
                id: "subject",
                frame: CGRect(x: 0, y: 0, width: 192, height: 108),
                content: .solid(.white),
                maskedBy: "matte"
            ),
            to: .slide
        )
        let frame = try compositor.renderFrame(scene: scene, width: 192, height: 108)
        let center = pixel(frame, x: 96, y: 54)
        XCTAssertEqual(center.x, 1, accuracy: 0.02, "the rotated bar covers the center")
        let whereUnrotatedWas = pixel(frame, x: 50, y: 54)
        XCTAssertEqual(whereUnrotatedWas.x, 0, accuracy: 0.02, "the unrotated span is outside the rotated matte")
    }

    func testMaskInAgainstNoMatteShowsNothingAndKnockoutSurvives() throws {
        let compositor = try makeCompositor()
        var scene = RenderScene(canvasSize: CGSize(width: 192, height: 108))
        scene.background = .black
        scene.addItem(
            RenderItem(
                id: "subject",
                frame: CGRect(x: 0, y: 0, width: 192, height: 108),
                content: .solid(.white),
                maskedBy: "gone"
            ),
            to: .slide
        )
        scene.addItem(
            RenderItem(
                id: "knock",
                frame: CGRect(x: 0, y: 80, width: 192, height: 28),
                content: .solid(SceneColor(red: 1, green: 0, blue: 0)),
                maskedBy: "gone",
                maskOut: true
            ),
            to: .slide
        )
        let frame = try compositor.renderFrame(scene: scene, width: 192, height: 108)
        XCTAssertEqual(pixel(frame, x: 96, y: 40).x, 0, accuracy: 0.02, "mask-in against nothing = nothing")
        XCTAssertEqual(pixel(frame, x: 96, y: 94).x, 1, accuracy: 0.02, "knockout against nothing = untouched")
    }

    func testMaskIntermediatesRecycleAcrossFrames() throws {
        let compositor = try makeCompositor()
        let target = scene(mode: false)
        for frameIndex in 0..<60 {
            _ = try compositor.renderFrame(
                scene: target, width: 192, height: 108,
                at: CFTimeInterval(frameIndex) / 60
            )
        }
        XCTAssertLessThanOrEqual(
            compositor.scratchTextureCount, 4,
            "one matte + one content intermediate, pooled — never 60 of them"
        )
    }
}
