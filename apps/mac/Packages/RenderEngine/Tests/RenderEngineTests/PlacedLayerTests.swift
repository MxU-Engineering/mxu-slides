import Metal
import XCTest
import simd
@testable import RenderEngine

@MainActor
final class PlacedLayerTests: XCTestCase {
    private let canvas = CGSize(width: 192, height: 108)

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

    private func channel(_ frame: RenderedFrame, x: Int, y: Int) -> String {
        let p = pixel(frame, x: x, y: y)
        if p.x > 0.5, p.y < 0.1 { return "red" }
        if p.y > 0.5, p.x < 0.1 { return "green" }
        if p.z > 0.5, p.x < 0.1 { return "blue" }
        if p.x < 0.05, p.y < 0.05, p.z < 0.05 { return "black" }
        return "other \(p)"
    }

    private func stripes(placed: PlacedLayer?) -> RenderScene {
        var scene = RenderScene(canvasSize: canvas)
        let third = canvas.width / 3
        for (index, color) in [SceneColor(red: 1, green: 0, blue: 0, alpha: 1),
                               SceneColor(red: 0, green: 1, blue: 0, alpha: 1),
                               SceneColor(red: 0, green: 0, blue: 1, alpha: 1)].enumerated() {
            scene.addItem(RenderItem(
                id: "stripe\(index)",
                frame: CGRect(x: CGFloat(index) * third, y: 0, width: third, height: canvas.height),
                content: .solid(color)), to: .loopingVideos)
        }
        scene.layers[scene.layers.firstIndex { $0.kind == .loopingVideos }!].placed = placed
        return scene
    }

    func testASpanAcrossTwoScreensShowsEachHalf() throws {
        let compositor = try makeCompositor()

        let span = CGRect(x: 0, y: 0, width: 384, height: 108)
        let left = try compositor.renderFrame(
            scene: stripes(placed: PlacedLayer(canvasSize: canvas, frames: [.init(rect: span, fill: true)])),
            width: 192, height: 108)
        let right = try compositor.renderFrame(
            scene: stripes(placed: PlacedLayer(canvasSize: canvas, frames: [.init(rect: span.offsetBy(dx: -192, dy: 0), fill: true)])),
            width: 192, height: 108)
        XCTAssertEqual(channel(left, x: 20, y: 54), "red")
        XCTAssertEqual(channel(left, x: 170, y: 54), "green", "the left screen ends mid-green")
        XCTAssertEqual(channel(right, x: 20, y: 54), "green", "the right screen starts mid-green")
        XCTAssertEqual(channel(right, x: 170, y: 54), "blue")
    }

    func testFitLetterboxesAndFillCropsInsideTheFrame() throws {
        let compositor = try makeCompositor()
        let square = CGRect(x: 0, y: 0, width: 108, height: 108)
        let fit = try compositor.renderFrame(
            scene: stripes(placed: PlacedLayer(canvasSize: canvas, frames: [.init(rect: square, fill: false)])),
            width: 192, height: 108)
        XCTAssertEqual(channel(fit, x: 54, y: 5), "black", "fit leaves a bar above the picture")
        XCTAssertEqual(channel(fit, x: 54, y: 54), "green")
        XCTAssertEqual(channel(fit, x: 150, y: 54), "black", "nothing lands outside the frame")
        let fill = try compositor.renderFrame(
            scene: stripes(placed: PlacedLayer(canvasSize: canvas, frames: [.init(rect: square, fill: true)])),
            width: 192, height: 108)
        XCTAssertEqual(channel(fill, x: 54, y: 5), "green", "fill covers the frame, cropping the sides")
        XCTAssertEqual(channel(fill, x: 5, y: 54), "red")
        XCTAssertEqual(channel(fill, x: 150, y: 54), "black")
    }

    func testPlacedNowhereDrawsNothingAndDuplicatesDrawTwice() throws {
        let compositor = try makeCompositor()
        let nowhere = try compositor.renderFrame(
            scene: stripes(placed: PlacedLayer(canvasSize: canvas, frames: [])), width: 192, height: 108)
        XCTAssertEqual(channel(nowhere, x: 96, y: 54), "black")
        let twice = try compositor.renderFrame(
            scene: stripes(placed: PlacedLayer(canvasSize: canvas, frames: [
                .init(rect: CGRect(x: 0, y: 0, width: 96, height: 54)),
                .init(rect: CGRect(x: 96, y: 54, width: 96, height: 54)),
            ])), width: 192, height: 108)
        XCTAssertEqual(channel(twice, x: 10, y: 27), "red")
        XCTAssertEqual(channel(twice, x: 106, y: 81), "red", "the duplicate starts red again")
        XCTAssertEqual(channel(twice, x: 106, y: 27), "black")
    }

    private final class RedSource: MediaTextureSource, @unchecked Sendable {
        let texture: MTLTexture
        init?(device: MTLDevice) {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm, width: 16, height: 8, mipmapped: false)
            descriptor.usage = .shaderRead
            guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
            var bytes = [UInt8](repeating: 0, count: 16 * 8 * 4)
            for i in stride(from: 0, to: bytes.count, by: 4) { bytes[i + 2] = 255; bytes[i + 3] = 255 }
            texture.replace(region: MTLRegionMake2D(0, 0, 16, 8), mipmapLevel: 0, withBytes: bytes, bytesPerRow: 64)
            self.texture = texture
        }
        func surface(for mediaID: String, hostTime: CFTimeInterval) -> MediaSurface? {
            guard mediaID == "clip" else { return nil }
            return .bgra(texture: texture, transform: VideoColorTransform(
                ycbcrMatrix: matrix_identity_float3x3, ycbcrOffset: .zero,
                gamutToWorking: matrix_identity_float3x3, premultipliedAlpha: false), retained: [])
        }
    }

    func testAPlacedFullCanvasMediaKeepsItsOwnShape() throws {
        let compositor = try makeCompositor()
        let source = try XCTUnwrap(RedSource(device: compositor.device))
        compositor.mediaSource = source

        var scene = RenderScene(canvasSize: canvas)
        scene.addItem(RenderItem(id: "bg", frame: CGRect(origin: .zero, size: canvas), content: .media(id: "clip")), to: .loopingVideos)
        scene.layers[scene.layers.firstIndex { $0.kind == .loopingVideos }!].placed =
            PlacedLayer(canvasSize: canvas, frames: [.init(rect: CGRect(x: 0, y: 0, width: 108, height: 108))])
        let frame = try compositor.renderFrame(scene: scene, width: 192, height: 108)
        XCTAssertEqual(channel(frame, x: 54, y: 22), "black", "the 2:1 band starts 27 px down")
        XCTAssertEqual(channel(frame, x: 54, y: 32), "red")
        XCTAssertEqual(channel(frame, x: 54, y: 76), "red")
        XCTAssertEqual(channel(frame, x: 54, y: 86), "black")
    }

    func testOnePictureServesEveryCanvasThisTickAndSweeps() throws {
        let compositor = try makeCompositor()
        let scene = stripes(placed: PlacedLayer(canvasSize: canvas, frames: [.init(rect: CGRect(x: 0, y: 0, width: 384, height: 108))]))
        let shifted = stripes(placed: PlacedLayer(canvasSize: canvas, frames: [.init(rect: CGRect(x: -192, y: 0, width: 384, height: 108))]))
        _ = try compositor.renderFrame(scene: scene, width: 192, height: 108, at: 1)
        _ = try compositor.renderFrame(scene: shifted, width: 192, height: 108, at: 1)
        XCTAssertEqual(compositor.placedPictureCount, 1, "both screens sample the one 384-wide picture")
        compositor.sweepCaches(at: CACurrentMediaTime() + Compositor.cacheTTL + 1)
        XCTAssertEqual(compositor.placedPictureCount, 0)
    }
}
