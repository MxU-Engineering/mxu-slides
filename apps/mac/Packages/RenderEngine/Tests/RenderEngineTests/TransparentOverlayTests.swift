import Metal
import XCTest
import simd
@testable import RenderEngine

@MainActor
final class TransparentOverlayTests: XCTestCase {

    private final class OverlaySource: MediaTextureSource, @unchecked Sendable {
        let texture: MTLTexture

        init?(device: MTLDevice, width: Int, height: Int) {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false
            )
            descriptor.usage = .shaderRead
            guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }

            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            for y in 0 ..< height / 2 {
                for x in 0 ..< width / 2 {
                    let i = (y * width + x) * 4
                    bytes[i + 2] = 255
                    bytes[i + 3] = 255
                }
            }
            texture.replace(
                region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                withBytes: bytes, bytesPerRow: width * 4
            )
            self.texture = texture
        }

        func surface(for mediaID: String, hostTime: CFTimeInterval) -> MediaSurface? {
            guard mediaID == "ink" else { return nil }
            return .bgra(
                texture: texture,
                transform: VideoColorTransform(
                    ycbcrMatrix: matrix_identity_float3x3,
                    ycbcrOffset: .zero,
                    gamutToWorking: matrix_identity_float3x3,
                    premultipliedAlpha: true
                ),
                retained: []
            )
        }

        func liveCadence(for mediaID: String) -> LiveCadence? { nil }
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

    func testTransparentRegionsLeaveTheSlideAndTopLeftStaysTopLeft() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("No Metal device available on this machine")
        }
        let compositor = try Compositor(device: device)
        guard let source = OverlaySource(device: device, width: 192, height: 108) else {
            throw XCTSkip("Could not create stub overlay texture")
        }
        compositor.mediaSource = source

        var scene = RenderScene(canvasSize: CGSize(width: 192, height: 108))
        scene.background = .black
        scene.addItem(
            RenderItem(
                id: "backdrop", frame: CGRect(x: 0, y: 0, width: 192, height: 108),
                content: .solid(SceneColor(red: 0, green: 0, blue: 1))),
            to: .slide)
        scene.addItem(
            RenderItem(
                id: "ink", frame: CGRect(x: 0, y: 0, width: 192, height: 108),
                content: .media(id: "ink", scaleMode: .fill)),
            to: .alerts)

        let frame = try compositor.renderFrame(scene: scene, width: 192, height: 108)
        let inked = pixel(frame, x: 20, y: 10)
        XCTAssertEqual(inked.x, 1, accuracy: 0.03, "opaque ink in the top-left covers the slide")
        XCTAssertEqual(inked.z, 0, accuracy: 0.03)

        let clear = pixel(frame, x: 150, y: 90)
        XCTAssertEqual(clear.x, 0, accuracy: 0.03, "transparent ink leaves the slide untouched")
        XCTAssertEqual(clear.z, 1, accuracy: 0.03)
        withExtendedLifetime(source) {}
    }
}
