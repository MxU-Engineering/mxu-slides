import CoreVideo
import Metal
import RenderEngine
import XCTest
@testable import OutputEngine

final class SRGBConverterTests: XCTestCase {
    private func device() throws -> MTLDevice {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("no Metal device on this machine")
        }
        return device
    }

    private func privateTexture(_ rgba: SIMD4<Float>, device: MTLDevice) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: Compositor.pixelFormat, width: 4, height: 4, mipmapped: false)
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        let staging = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        var pixels = [Float16](repeating: 0, count: 4 * 4 * 4)
        for index in stride(from: 0, to: pixels.count, by: 4) {
            for channel in 0..<4 { pixels[index + channel] = Float16(rgba[channel]) }
        }
        staging.replace(
            region: MTLRegionMake2D(0, 0, 4, 4), mipmapLevel: 0,
            withBytes: &pixels, bytesPerRow: 4 * 4 * MemoryLayout<Float16>.size)
        descriptor.storageMode = .private
        let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let commandBuffer = try XCTUnwrap(queue.makeCommandBuffer())
        let blit = try XCTUnwrap(commandBuffer.makeBlitCommandEncoder())
        blit.copy(from: staging, to: texture)
        blit.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        return texture
    }

    private func firstPixelBGRA(_ buffer: CVPixelBuffer) throws -> [Int] {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer))
            .assumingMemoryBound(to: UInt8.self)
        return (0..<4).map { Int(base[$0]) }
    }

    func testEncodesSRGBOnTheGPUWithItsTags() throws {
        let device = try device()
        let converter = try XCTUnwrap(
            PixelBufferConverter(width: 4, height: 4, color: .srgb, device: device))

        let red = try privateTexture(SIMD4(0.8224621, 0.0331941, 0.0170827, 1), device: device)

        let buffer = try XCTUnwrap(converter.convert(texture: red))

        XCTAssertEqual(CVPixelBufferGetPixelFormatType(buffer), kCVPixelFormatType_32BGRA)
        XCTAssertNotNil(CVPixelBufferGetIOSurface(buffer), "Syphon blits from the IOSurface")
        XCTAssertEqual(
            CVBufferCopyAttachment(buffer, kCVImageBufferColorPrimariesKey, nil) as? String,
            kCVImageBufferColorPrimaries_ITU_R_709_2 as String)
        XCTAssertEqual(
            CVBufferCopyAttachment(buffer, kCVImageBufferTransferFunctionKey, nil) as? String,
            kCVImageBufferTransferFunction_sRGB as String)
        let pixel = try firstPixelBGRA(buffer)
        XCTAssertEqual(pixel[2], 255, accuracy: 1, "red")
        XCTAssertEqual(pixel[1], 0, accuracy: 1, "green")
        XCTAssertEqual(pixel[0], 0, accuracy: 1, "blue")
        XCTAssertEqual(pixel[3], 255, "opaque")
    }

    func testMidGrayLandsOnTheSRGBCurve() throws {
        let device = try device()
        let converter = try XCTUnwrap(
            PixelBufferConverter(width: 4, height: 4, color: .srgb, device: device))

        let gray = try privateTexture(SIMD4(0.2140, 0.2140, 0.2140, 1), device: device)
        let pixel = try firstPixelBGRA(try XCTUnwrap(converter.convert(texture: gray)))
        for channel in 0..<3 { XCTAssertEqual(pixel[channel], 128, accuracy: 1) }
    }

    func testSRGBNeedsADevice() {
        XCTAssertNil(PixelBufferConverter(width: 4, height: 4, color: .srgb))
    }

    func testMirrorDeliversSRGBFrames() throws {
        let compositor: Compositor
        do {
            compositor = try Compositor()
        } catch CompositorError.noMetalDevice {
            throw XCTSkip("no Metal device on this machine")
        }
        var scene = RenderScene(canvasSize: CGSize(width: 64, height: 36))
        scene.addItem(
            RenderItem(
                id: "fill", frame: CGRect(x: 0, y: 0, width: 64, height: 36),
                content: .solid(.white)),
            to: .stillGraphics)
        let delivered = Locked<CVPixelBuffer?>(nil)
        let frozen = scene
        let mirror = try XCTUnwrap(OutputMirror(
            compositor: compositor, width: 64, height: 36, color: .srgb,
            provider: { frozen },
            sink: { buffer, _ in delivered.value = buffer }))
        mirror.startWithoutTimerForTesting()
        mirror.tick(at: 0)
        let deadline = Date().addingTimeInterval(5)
        while delivered.value == nil, Date() < deadline { usleep(5000) }
        mirror.stop()

        let buffer = try XCTUnwrap(delivered.value, "the mirror delivers in .srgb mode")
        XCTAssertEqual(CVPixelBufferGetWidth(buffer), 64)
        let pixel = try firstPixelBGRA(buffer)
        for channel in 0..<4 { XCTAssertGreaterThan(pixel[channel], 250) }
    }
}
