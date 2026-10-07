import Metal
import XCTest
@testable import RenderEngine

@MainActor
final class OutputMaskTests: XCTestCase {
    private func makeCompositor() throws -> Compositor {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("No Metal device available on this machine")
        }
        return try Compositor()
    }

    private let centerBand = "M 0.25 0 L 0.75 0 L 0.75 1 L 0.25 1 Z"

    private let leftHalf = "M 0 0 L 0.5 0 L 0.5 1 L 0 1 Z"

    private func coverage(_ texture: MTLTexture, x: Int, y: Int) -> UInt8 {
        var value: UInt8 = 0
        texture.getBytes(
            &value, bytesPerRow: texture.width,
            from: MTLRegionMake2D(x, y, 1, 1), mipmapLevel: 0
        )
        return value
    }

    func testRasterModeOutBlacksInsideThePath() throws {
        let compositor = try makeCompositor()
        let mask = OutputMask(name: "Band", pathData: centerBand, mode: .out)
        let texture = try XCTUnwrap(OutputMaskRaster.texture(
            masks: [mask], width: 192, height: 108, device: compositor.device))
        XCTAssertEqual(coverage(texture, x: 96, y: 54), 0, "inside the path = blacked out")
        XCTAssertEqual(coverage(texture, x: 10, y: 54), 255, "outside stays shown")
        XCTAssertEqual(coverage(texture, x: 182, y: 54), 255)
    }

    func testRasterModeInShowsOnlyInsideThePath() throws {
        let compositor = try makeCompositor()
        let mask = OutputMask(name: "Window", pathData: centerBand, mode: .in)
        let texture = try XCTUnwrap(OutputMaskRaster.texture(
            masks: [mask], width: 192, height: 108, device: compositor.device))
        XCTAssertEqual(coverage(texture, x: 96, y: 54), 255, "inside the window shows")
        XCTAssertEqual(coverage(texture, x: 10, y: 54), 0, "outside goes black")
    }

    func testRasterFeatherSoftensTheEdge() throws {
        let compositor = try makeCompositor()
        let mask = OutputMask(name: "Soft", pathData: centerBand, mode: .out, feather: 0.15)
        let texture = try XCTUnwrap(OutputMaskRaster.texture(
            masks: [mask], width: 192, height: 108, device: compositor.device))
        let edge = coverage(texture, x: 48, y: 54)  
        XCTAssertGreaterThan(edge, 20, "feather ramps instead of stepping")
        XCTAssertLessThan(edge, 235)
    }

    func testMasksCombine() throws {

        let compositor = try makeCompositor()
        let texture = try XCTUnwrap(OutputMaskRaster.texture(
            masks: [
                OutputMask(name: "Band", pathData: centerBand, mode: .out),
                OutputMask(name: "Left", pathData: leftHalf, mode: .out),
            ],
            width: 192, height: 108, device: compositor.device))
        XCTAssertEqual(coverage(texture, x: 96, y: 54), 0, "band blacked")
        XCTAssertEqual(coverage(texture, x: 10, y: 54), 0, "left half blacked")
        XCTAssertEqual(coverage(texture, x: 182, y: 54), 255, "right quarter shows")
        XCTAssertNil(OutputMaskRaster.texture(
            masks: [], width: 192, height: 108, device: compositor.device))
    }

    func testMaskAloneTriggersThePassAndBlacksTheRegion() throws {

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
        let target = try XCTUnwrap(compositor.device.makeTexture(descriptor: descriptor))
        let mask = try XCTUnwrap(OutputMaskRaster.texture(
            masks: [OutputMask(name: "Band", pathData: centerBand, mode: .out)],
            width: 192, height: 108, device: compositor.device))
        compositor.render(scene: scene, into: target, at: 0, mask: mask)
        let frame = try compositor.readback(texture: target)
        func pixel(_ x: Int, _ y: Int) -> SIMD4<Float> {
            var out = SIMD4<Float>()
            frame.data.withUnsafeBytes { raw in
                let base = raw.baseAddress! + y * frame.bytesPerRow + x * 8
                let halves = base.assumingMemoryBound(to: Float16.self)
                out = SIMD4(
                    Float(halves[0]), Float(halves[1]), Float(halves[2]), Float(halves[3]))
            }
            return out
        }
        XCTAssertLessThan(pixel(96, 54).x, 0.05, "masked region is black")
        XCTAssertLessThan(pixel(96, 54).w, 0.05, "…and carries no key")
        XCTAssertGreaterThan(pixel(10, 54).x, 0.9, "unmasked region untouched")
    }

    func testMaskIsCanvasSpaceAcrossSlices() throws {

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
            pixelFormat: Compositor.pixelFormat, width: 96, height: 108, mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        let target = try XCTUnwrap(compositor.device.makeTexture(descriptor: descriptor))
        let mask = try XCTUnwrap(OutputMaskRaster.texture(
            masks: [OutputMask(name: "Left", pathData: leftHalf, mode: .out)],
            width: 192, height: 108, device: compositor.device))
        compositor.render(
            scene: scene, into: target, at: 0,
            sourceRect: CGRect(x: 0.5, y: 0, width: 0.5, height: 1), mask: mask
        )
        let frame = try compositor.readback(texture: target)
        var center = SIMD4<Float>()
        frame.data.withUnsafeBytes { raw in
            let base = raw.baseAddress! + 54 * frame.bytesPerRow + 48 * 8
            let halves = base.assumingMemoryBound(to: Float16.self)
            center = SIMD4(
                Float(halves[0]), Float(halves[1]), Float(halves[2]), Float(halves[3]))
        }
        XCTAssertGreaterThan(center.x, 0.9, "a left-half mask leaves the right slice alone")
    }
}
