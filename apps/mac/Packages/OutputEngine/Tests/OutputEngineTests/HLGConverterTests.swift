import CoreVideo
import Metal
import RenderEngine
import XCTest
@testable import OutputEngine

final class HLGConverterTests: XCTestCase {
    func testHLGModeProducesTaggedTenBitBuffersWithReferenceWhite() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("no Metal device on this machine")
        }
        let converter = try XCTUnwrap(
            PixelBufferConverter(width: 8, height: 8, color: .hlg2020),
            "HLG vImage converter must materialize")

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: 8, height: 8, mipmapped: false)
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let one = Float16(1.0)
        var pixels = [Float16](repeating: one, count: 8 * 8 * 4)
        texture.replace(
            region: MTLRegionMake2D(0, 0, 8, 8), mipmapLevel: 0,
            withBytes: &pixels, bytesPerRow: 8 * 4 * MemoryLayout<Float16>.size)

        let buffer = try XCTUnwrap(converter.convert(texture: texture))

        XCTAssertEqual(
            CVPixelBufferGetPixelFormatType(buffer),
            kCVPixelFormatType_ARGB2101010LEPacked)
        XCTAssertEqual(
            CVBufferCopyAttachment(buffer, kCVImageBufferColorPrimariesKey, nil) as? String,
            kCVImageBufferColorPrimaries_ITU_R_2020 as String)
        XCTAssertEqual(
            CVBufferCopyAttachment(buffer, kCVImageBufferTransferFunctionKey, nil) as? String,
            kCVImageBufferTransferFunction_ITU_R_2100_HLG as String)

        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer))
        let word = base.assumingMemoryBound(to: UInt32.self).pointee

        let green = Double((word >> 10) & 0x3FF) / 1023.0
        let red = Double((word >> 20) & 0x3FF) / 1023.0

        XCTAssertEqual(green, 0.75, accuracy: 0.06)
        XCTAssertEqual(red, green, accuracy: 0.02, "white must stay neutral through the gamut map")
    }
}
