import Metal
import XCTest
import simd
@testable import RenderEngine

@MainActor
final class MediaFillTests: XCTestCase {

    private final class RedSource: MediaTextureSource, @unchecked Sendable {
        let texture: MTLTexture
        var contentSize: (width: Int, height: Int) { (texture.width, texture.height) }

        init?(device: MTLDevice, width: Int = 8, height: Int = 8) {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false
            )
            descriptor.usage = .shaderRead
            guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }

            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            for i in stride(from: 0, to: bytes.count, by: 4) {
                bytes[i + 2] = 255
                bytes[i + 3] = 255
            }
            texture.replace(
                region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                withBytes: bytes, bytesPerRow: width * 4
            )
            self.texture = texture
        }

        func surface(for mediaID: String, hostTime: CFTimeInterval) -> MediaSurface? {
            guard mediaID == "clip" else { return nil }
            return .bgra(
                texture: texture,
                transform: VideoColorTransform(
                    ycbcrMatrix: matrix_identity_float3x3,
                    ycbcrOffset: .zero,
                    gamutToWorking: matrix_identity_float3x3,
                    premultipliedAlpha: false
                ),
                retained: []
            )
        }
    }

    private func makeCompositor() throws -> (Compositor, RedSource) {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("No Metal device available on this machine")
        }
        let compositor = try Compositor(device: device)
        guard let source = RedSource(device: device) else {
            throw XCTSkip("Could not create stub media texture")
        }
        compositor.mediaSource = source
        return (compositor, source)
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

    private func scene(with item: RenderItem) -> RenderScene {
        var scene = RenderScene(canvasSize: CGSize(width: 192, height: 108))
        scene.background = .black
        scene.addItem(item, to: .slide)
        return scene
    }

    func testMediaFillPaintsInsideSilhouetteOnly() throws {
        let (compositor, source) = try makeCompositor()
        let item = RenderItem(
            id: "s",
            frame: CGRect(x: 46, y: 4, width: 100, height: 100),
            content: .shape(ShapeStyle(
                kind: .ellipse,
                fill: .media(id: "clip", scaleMode: .stretch)
            ))
        )
        let frame = try compositor.renderFrame(scene: scene(with: item), width: 192, height: 108)
        let center = pixel(frame, x: 96, y: 54)
        XCTAssertEqual(center.x, 1, accuracy: 0.02, "ellipse center shows the media frame")
        XCTAssertEqual(center.y, 0, accuracy: 0.02)

        let corner = pixel(frame, x: 50, y: 8)
        XCTAssertEqual(corner.x, 0, accuracy: 0.02, "outside the silhouette stays background")
        withExtendedLifetime(source) {}
    }

    func testMediaFillStrokeCompositesOverMedia() throws {
        let (compositor, source) = try makeCompositor()
        let item = RenderItem(
            id: "s",
            frame: CGRect(x: 46, y: 14, width: 100, height: 80),
            content: .shape(ShapeStyle(
                kind: .rectangle,
                fill: .media(id: "clip", scaleMode: .stretch),
                stroke: SceneStroke(color: .white, width: 8)
            ))
        )
        let frame = try compositor.renderFrame(scene: scene(with: item), width: 192, height: 108)
        let center = pixel(frame, x: 96, y: 54)
        XCTAssertEqual(center.x, 1, accuracy: 0.02, "interior is media")
        XCTAssertEqual(center.y, 0, accuracy: 0.02)

        let edge = pixel(frame, x: 96, y: 14)
        XCTAssertEqual(edge.y, 1, accuracy: 0.05, "stroke chrome draws over the media")
        withExtendedLifetime(source) {}
    }

    func testMediaItemAndMediaFilledRectangleRenderIdentically() throws {
        let (compositor, source) = try makeCompositor()
        let frameRect = CGRect(x: 16, y: 10, width: 160, height: 80)
        let cases: [(SceneMediaScaleMode, SceneSourceRect?, Double)] = [
            (.fill, nil, 0),
            (.fit, nil, 0),
            (.stretch, nil, 0),
            (.fit, SceneSourceRect(x: 0.25, y: 0, width: 0.5, height: 1), 0),
            (.fit, nil, 30),
        ]
        for (mode, sourceRect, rotation) in cases {
            let mediaItem = RenderItem(
                id: "m", frame: frameRect,
                content: .media(id: "clip", scaleMode: mode, sourceRect: sourceRect),
                rotationDegrees: rotation
            )
            let shapeItem = RenderItem(
                id: "m", frame: frameRect,
                content: .shape(ShapeStyle(
                    kind: .rectangle,
                    fill: .media(id: "clip", scaleMode: mode, sourceRect: sourceRect)
                )),
                rotationDegrees: rotation
            )
            let a = try compositor.renderFrame(scene: scene(with: mediaItem), width: 192, height: 108)
            let b = try compositor.renderFrame(scene: scene(with: shapeItem), width: 192, height: 108)
            var mismatches = 0
            var samples = 0
            for y in stride(from: 0, to: 108, by: 2) {
                for x in stride(from: 0, to: 192, by: 2) {
                    let pa = pixel(a, x: x, y: y)
                    let pb = pixel(b, x: x, y: y)
                    samples += 1
                    if abs(pa.x - pb.x) > 0.06 || abs(pa.y - pb.y) > 0.06
                        || abs(pa.z - pb.z) > 0.06 {
                        mismatches += 1
                    }
                }
            }
            XCTAssertLessThan(
                Double(mismatches) / Double(samples), 0.02,
                "media item and media-filled rectangle diverged (mode \(mode), crop \(String(describing: sourceRect)), rotation \(rotation))"
            )
        }
        withExtendedLifetime(source) {}
    }

    func testMediaFillFitLetterboxIsTransparent() throws {
        let (compositor, source) = try makeCompositor()

        let item = RenderItem(
            id: "s",
            frame: CGRect(x: 16, y: 24, width: 160, height: 60),
            content: .shape(ShapeStyle(
                kind: .rectangle,
                fill: .media(id: "clip", scaleMode: .fit)
            ))
        )
        let frame = try compositor.renderFrame(scene: scene(with: item), width: 192, height: 108)
        let center = pixel(frame, x: 96, y: 54)
        XCTAssertEqual(center.x, 1, accuracy: 0.02, "fit content centers in the frame")
        let bar = pixel(frame, x: 24, y: 54)
        XCTAssertEqual(bar.x, 0, accuracy: 0.02, "letterbox bars are transparent")
        withExtendedLifetime(source) {}
    }

    func testUnresolvedMediaDrawsChromeAroundEmptyInterior() throws {
        let (compositor, source) = try makeCompositor()
        let item = RenderItem(
            id: "s",
            frame: CGRect(x: 46, y: 14, width: 100, height: 80),
            content: .shape(ShapeStyle(
                kind: .rectangle,
                fill: .media(id: "missing", scaleMode: .fill),
                stroke: SceneStroke(color: .white, width: 8)
            ))
        )
        let frame = try compositor.renderFrame(scene: scene(with: item), width: 192, height: 108)
        let center = pixel(frame, x: 96, y: 54)
        XCTAssertEqual(center.x, 0, accuracy: 0.02, "no player = empty interior, never an error")
        let edge = pixel(frame, x: 96, y: 14)
        XCTAssertEqual(edge.y, 1, accuracy: 0.05, "the stroke still frames the shape")
    }

    func testMovingMediaFillHoldsGeometryOnlyCacheEntries() throws {
        let (compositor, source) = try makeCompositor()
        let item = RenderItem(
            id: "s",
            frame: CGRect(x: 46, y: 14, width: 100, height: 80),
            content: .shape(ShapeStyle(
                kind: .roundedRectangle(cornerRadius: 12),
                fill: .media(id: "clip", scaleMode: .fill),
                stroke: SceneStroke(color: .white, width: 4)
            ))
        )
        let target = scene(with: item)
        for frameIndex in 0..<60 {
            _ = try compositor.renderFrame(
                scene: target, width: 192, height: 108,
                at: CFTimeInterval(frameIndex) / 60
            )
        }
        XCTAssertEqual(
            compositor.shapeTextureCount, 2,
            "60 frames of playing media = exactly one mask + one chrome entry"
        )
        withExtendedLifetime(source) {}
    }
}
