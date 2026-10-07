import Metal
import XCTest
@testable import RenderEngine

@MainActor
final class OutputAdjustTests: XCTestCase {
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

    private func renderWhite(
        adjustments: OutputAdjustments?, width: Int = 192, height: Int = 108
    ) throws -> RenderedFrame {
        let compositor = try makeCompositor()
        var scene = RenderScene(canvasSize: CGSize(width: width, height: height))
        scene.background = .black
        scene.addItem(
            RenderItem(
                id: "fill",
                frame: CGRect(x: 0, y: 0, width: width, height: height),
                content: .solid(.white)
            ),
            to: .slide
        )
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: Compositor.pixelFormat, width: width, height: height, mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        let texture = try XCTUnwrap(compositor.device.makeTexture(descriptor: descriptor))
        compositor.render(scene: scene, into: texture, at: 0, adjustments: adjustments)
        return try compositor.readback(texture: texture)
    }

    func testNeutralAdjustmentsPassThrough() throws {
        let frame = try renderWhite(adjustments: OutputAdjustments())
        let center = pixel(frame, x: 96, y: 54)
        XCTAssertGreaterThan(center.x, 0.95)
        XCTAssertGreaterThan(center.z, 0.95)
    }

    private func halvesScene(width: Int = 192, height: Int = 108) -> RenderScene {
        var scene = RenderScene(canvasSize: CGSize(width: width, height: height))
        scene.background = .black
        scene.addItem(
            RenderItem(
                id: "left",
                frame: CGRect(x: 0, y: 0, width: width / 2, height: height),
                content: .solid(SceneColor(red: 1, green: 0, blue: 0))
            ),
            to: .slide
        )
        scene.addItem(
            RenderItem(
                id: "right",
                frame: CGRect(x: width / 2, y: 0, width: width - width / 2, height: height),
                content: .solid(SceneColor(red: 0, green: 0, blue: 1))
            ),
            to: .slide
        )
        return scene
    }

    private func makeTarget(_ compositor: Compositor, width: Int, height: Int) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: Compositor.pixelFormat, width: width, height: height, mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        return try XCTUnwrap(compositor.device.makeTexture(descriptor: descriptor))
    }

    func testSourceRectShowsTheSliceEdgeToEdge() throws {

        let compositor = try makeCompositor()
        let target = try makeTarget(compositor, width: 96, height: 108)
        compositor.render(
            scene: halvesScene(), into: target, at: 0,
            sourceRect: CGRect(x: 0, y: 0, width: 0.5, height: 1)
        )
        let frame = try compositor.readback(texture: target)
        let center = pixel(frame, x: 48, y: 54)
        let nearRight = pixel(frame, x: 92, y: 54)
        XCTAssertGreaterThan(center.x, 0.9, "slice shows red")
        XCTAssertLessThan(center.z, 0.1)
        XCTAssertGreaterThan(nearRight.x, 0.9, "red runs to the slice's edge — no mid-canvas cut")
        XCTAssertLessThan(nearRight.z, 0.1, "no blue leak from the neighbor slice")
    }

    func testBlendRampSitsAtTheSliceEdge() throws {

        let compositor = try makeCompositor()
        let target = try makeTarget(compositor, width: 96, height: 108)
        var adjustments = OutputAdjustments()
        adjustments.blendRight = OutputEdgeBlend(width: 0.3, curve: 2)
        compositor.render(
            scene: halvesScene(), into: target, at: 0,
            adjustments: adjustments,
            sourceRect: CGRect(x: 0, y: 0, width: 0.5, height: 1)
        )
        let frame = try compositor.readback(texture: target)
        let center = pixel(frame, x: 30, y: 54)
        let nearSeam = pixel(frame, x: 94, y: 54)
        XCTAssertGreaterThan(center.x, 0.9, "outside the ramp stays full")
        XCTAssertLessThan(nearSeam.x, 0.2, "the seam edge ramps toward black")
    }

    func testQuarterTurnRotationFillsTheFrame() throws {

        let compositor = try makeCompositor()
        var scene = RenderScene(canvasSize: CGSize(width: 192, height: 108))
        scene.background = .black
        scene.addItem(
            RenderItem(
                id: "top",
                frame: CGRect(x: 0, y: 0, width: 192, height: 54),
                content: .solid(SceneColor(red: 1, green: 0, blue: 0))
            ),
            to: .slide
        )
        scene.addItem(
            RenderItem(
                id: "bottom",
                frame: CGRect(x: 0, y: 54, width: 192, height: 54),
                content: .solid(SceneColor(red: 0, green: 0, blue: 1))
            ),
            to: .slide
        )
        let target = try makeTarget(compositor, width: 192, height: 108)
        var adjustments = OutputAdjustments()
        adjustments.rotationDegrees = 90
        compositor.render(scene: scene, into: target, at: 0, adjustments: adjustments)
        let frame = try compositor.readback(texture: target)
        let right = pixel(frame, x: 170, y: 54)
        let left = pixel(frame, x: 20, y: 54)
        XCTAssertGreaterThan(right.x, 0.9, "canvas top rotates onto the right")
        XCTAssertLessThan(right.z, 0.1)
        XCTAssertGreaterThan(left.z, 0.9, "canvas bottom rotates onto the left")
        XCTAssertLessThan(left.x, 0.1)
    }

    func testAdjustedPassPreservesAlpha() throws {

        let compositor = try makeCompositor()
        var scene = RenderScene(canvasSize: CGSize(width: 192, height: 108))
        scene.addItem(
            RenderItem(
                id: "lowerThird",
                frame: CGRect(x: 0, y: 0, width: 96, height: 108),
                content: .solid(.white)
            ),
            to: .slide
        )
        let target = try makeTarget(compositor, width: 192, height: 108)
        var adjustments = OutputAdjustments()
        adjustments.brightness = 0.2
        let rendered = expectation(description: "GPU complete")
        compositor.render(
            scene: scene, into: target, at: 0,
            transparentBackground: true, adjustments: adjustments
        ) {
            rendered.fulfill()
        }
        wait(for: [rendered], timeout: 5)
        let frame = try compositor.readback(texture: target)
        let covered = pixel(frame, x: 40, y: 54)
        let empty = pixel(frame, x: 150, y: 54)
        XCTAssertGreaterThan(covered.w, 0.95, "content keeps its key")
        XCTAssertLessThan(empty.w, 0.05, "the keyer still cuts where nothing rendered")
        XCTAssertLessThan(empty.x, 0.05, "a brightness lift never paints the transparent region")
    }

    func testBlendIntensityBacksTheRampOff() throws {

        var adjustments = OutputAdjustments()
        adjustments.blendRight = OutputEdgeBlend(width: 0.3, curve: 1, intensity: 0.5)
        let frame = try renderWhite(adjustments: adjustments)
        let seam = pixel(frame, x: 191, y: 54)
        let center = pixel(frame, x: 60, y: 54)
        XCTAssertEqual(seam.x, 0.5, accuracy: 0.06, "half-depth ramp bottoms out at half")
        XCTAssertGreaterThan(center.x, 0.95, "outside the ramp untouched")
    }

    func testBlackLiftCompensatesOutsideTheOverlap() throws {

        let compositor = try makeCompositor()
        var scene = RenderScene(canvasSize: CGSize(width: 192, height: 108))
        scene.background = .black
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: Compositor.pixelFormat, width: 192, height: 108, mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        let target = try XCTUnwrap(compositor.device.makeTexture(descriptor: descriptor))
        var adjustments = OutputAdjustments()
        adjustments.blendRight = OutputEdgeBlend(width: 0.3, curve: 1, blackLift: 0.2)
        compositor.render(scene: scene, into: target, at: 0, adjustments: adjustments)
        let frame = try compositor.readback(texture: target)
        XCTAssertEqual(pixel(frame, x: 40, y: 54).x, 0.2, accuracy: 0.02,
                       "non-overlap black lifts to match the doubled seam black")
        XCTAssertLessThan(pixel(frame, x: 190, y: 54).x, 0.03,
                          "at the seam the lift tapers out — the neighbor supplies it")
    }

    func testPlacementLandsContentInTheFrameRect() throws {

        let compositor = try makeCompositor()
        var scene = RenderScene(canvasSize: CGSize(width: 96, height: 54))
        scene.background = .black
        scene.addItem(
            RenderItem(
                id: "wall",
                frame: CGRect(x: 0, y: 0, width: 96, height: 54),
                content: .solid(SceneColor(red: 1, green: 0, blue: 0))
            ),
            to: .slide
        )
        let target = try makeTarget(compositor, width: 192, height: 108)

        compositor.render(
            scene: scene, into: target, at: 0,
            placement: CGRect(x: 0, y: 0, width: 0.5, height: 0.5)
        )
        let frame = try compositor.readback(texture: target)
        XCTAssertGreaterThan(pixel(frame, x: 40, y: 25).x, 0.9, "content inside the placed rect")
        XCTAssertLessThan(pixel(frame, x: 150, y: 25).x, 0.05, "outside the rect is black")
        XCTAssertLessThan(pixel(frame, x: 150, y: 25).w, 0.05, "…and carries no key")
        XCTAssertLessThan(pixel(frame, x: 40, y: 80).x, 0.05)
    }

    func testPlacementComposesWithSliceAndRotation() throws {

        let compositor = try makeCompositor()
        let target = try makeTarget(compositor, width: 192, height: 108)
        var adjustments = OutputAdjustments()
        adjustments.rotationDegrees = 180
        compositor.render(
            scene: halvesScene(), into: target, at: 0,
            adjustments: adjustments,
            sourceRect: CGRect(x: 0, y: 0, width: 0.5, height: 1),
            placement: CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5)
        )
        let frame = try compositor.readback(texture: target)

        XCTAssertGreaterThan(pixel(frame, x: 150, y: 25).x, 0.9, "placed region carries the slice")
        XCTAssertLessThan(pixel(frame, x: 40, y: 25).x, 0.05, "outside stays black")
        XCTAssertLessThan(pixel(frame, x: 150, y: 80).x, 0.05)
    }

    func testCompositePacksLayersIntoOneFrame() throws {

        let compositor = try makeCompositor()
        func solid(_ color: SceneColor, canvas: CGSize) -> RenderScene {
            var scene = RenderScene(canvasSize: canvas)
            scene.background = .black
            scene.addItem(
                RenderItem(
                    id: "fill", frame: CGRect(origin: .zero, size: canvas),
                    content: .solid(color)),
                to: .slide
            )
            return scene
        }
        let target = try makeTarget(compositor, width: 192, height: 108)
        let layers = [
            Compositor.OutputCompositeLayer(
                scene: solid(SceneColor(red: 1, green: 0, blue: 0),
                             canvas: CGSize(width: 96, height: 54)),
                placement: CGRect(x: 0, y: 0, width: 0.5, height: 0.5)
            ),
            Compositor.OutputCompositeLayer(
                scene: solid(SceneColor(red: 0, green: 0, blue: 1),
                             canvas: CGSize(width: 48, height: 96)),
                placement: CGRect(x: 0.75, y: 0, width: 0.25, height: 0.9)
            ),
        ]
        let rendered = expectation(description: "GPU complete")
        compositor.render(composite: layers, into: target, at: 0) { rendered.fulfill() }
        wait(for: [rendered], timeout: 5)
        let frame = try compositor.readback(texture: target)
        XCTAssertGreaterThan(pixel(frame, x: 40, y: 25).x, 0.9, "first layer lands at its rect")
        XCTAssertGreaterThan(pixel(frame, x: 170, y: 40).z, 0.9, "second layer lands at its rect")
        XCTAssertLessThan(pixel(frame, x: 120, y: 25).x, 0.05, "between the regions is black")
        XCTAssertLessThan(pixel(frame, x: 120, y: 25).z, 0.05)
        XCTAssertLessThan(pixel(frame, x: 40, y: 90).x, 0.05, "below the first region is black")
    }

    func testCompletionOverloadAppliesAdjustments() throws {

        let compositor = try makeCompositor()
        var scene = RenderScene(canvasSize: CGSize(width: 192, height: 108))
        scene.background = .black
        scene.addItem(
            RenderItem(
                id: "fill",
                frame: CGRect(x: 0, y: 0, width: 192, height: 108),
                content: .solid(.white)
            ),
            to: .slide
        )
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: Compositor.pixelFormat, width: 192, height: 108, mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        let texture = try XCTUnwrap(compositor.device.makeTexture(descriptor: descriptor))
        var adjustments = OutputAdjustments()
        adjustments.brightness = -1
        let rendered = expectation(description: "GPU complete")
        compositor.render(scene: scene, into: texture, at: 0, adjustments: adjustments) {
            rendered.fulfill()
        }
        wait(for: [rendered], timeout: 5)
        let frame = try compositor.readback(texture: texture)
        let center = pixel(frame, x: 96, y: 54)
        XCTAssertLessThan(center.x, 0.05, "brightness -1 zeroes a white frame on the feed path")
        XCTAssertLessThan(center.z, 0.05)
    }

    func testColorMathLandsWhereTheSlidersSay() throws {
        var adjustments = OutputAdjustments()
        adjustments.brightness = -0.5
        var frame = try renderWhite(adjustments: adjustments)
        XCTAssertEqual(pixel(frame, x: 96, y: 54).x, 0.5, accuracy: 0.02)

        adjustments = OutputAdjustments()
        adjustments.blueLevel = -1
        frame = try renderWhite(adjustments: adjustments)
        let trimmed = pixel(frame, x: 96, y: 54)
        XCTAssertGreaterThan(trimmed.x, 0.95, "red untouched")
        XCTAssertEqual(trimmed.z, 0, accuracy: 0.02, "blue gain -1 = channel off")

        adjustments = OutputAdjustments()
        adjustments.gamma = 1  
        frame = try renderWhite(adjustments: adjustments)
        XCTAssertEqual(pixel(frame, x: 96, y: 54).x, 1, accuracy: 0.02)
    }

    func testCornerPinLeavesProjectorBlackOutsideTheQuad() throws {
        var adjustments = OutputAdjustments()
        adjustments.topLeft = CGPoint(x: 60, y: 40)
        let frame = try renderWhite(adjustments: adjustments)
        let outside = pixel(frame, x: 4, y: 4)
        XCTAssertEqual(outside.x, 0, accuracy: 0.01, "outside the pinned quad is black")

        XCTAssertEqual(outside.w, 0, accuracy: 0.01, "…and carries no key")
        XCTAssertGreaterThan(pixel(frame, x: 96, y: 54).x, 0.9, "center still content")
        XCTAssertGreaterThan(pixel(frame, x: 186, y: 102).x, 0.9, "unpinned corner untouched")
    }

    func testEdgeBlendRampsTheEdge() throws {
        var adjustments = OutputAdjustments()
        adjustments.blendLeft = OutputEdgeBlend(width: 0.5, curve: 1)
        let frame = try renderWhite(adjustments: adjustments)
        let nearEdge = pixel(frame, x: 19, y: 54).x   
        let midRamp = pixel(frame, x: 48, y: 54).x    
        let center = pixel(frame, x: 130, y: 54).x    
        XCTAssertEqual(nearEdge, 0.2, accuracy: 0.05)
        XCTAssertEqual(midRamp, 0.5, accuracy: 0.05)
        XCTAssertGreaterThan(center, 0.95)
        XCTAssertLessThan(nearEdge, midRamp)
    }

    func testHomographyIdentityAndDegenerateFallback() {
        let corners = [
            CGPoint(x: -1, y: 1), CGPoint(x: 1, y: 1),
            CGPoint(x: -1, y: -1), CGPoint(x: 1, y: -1),
        ]
        let sources = [
            CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0),
            CGPoint(x: 0, y: 1), CGPoint(x: 1, y: 1),
        ]
        let identity = OutputWarp.projectiveUVs(destinations: corners, sources: sources)
        XCTAssertNotNil(identity)
        for (uvq, source) in zip(identity!, sources) {
            XCTAssertEqual(uvq.x / uvq.z, Double(source.x), accuracy: 1e-6)
            XCTAssertEqual(uvq.y / uvq.z, Double(source.y), accuracy: 1e-6)
        }

        let collapsed = [CGPoint](repeating: .zero, count: 4)
        XCTAssertNil(OutputWarp.projectiveUVs(destinations: collapsed, sources: sources))
    }
}
