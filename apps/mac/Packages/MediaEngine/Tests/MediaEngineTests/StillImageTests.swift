import CoreGraphics
import ImageIO
import Metal
import RenderEngine
import simd
import UniformTypeIdentifiers
import XCTest
@testable import MediaEngine

@MainActor
final class StillImageTests: XCTestCase {
    private var tempDir: URL!
    private var device: MTLDevice!

    override func setUp() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("No Metal device available on this machine")
        }
        self.device = device
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MediaEngineTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
    }

    private func makeTestPNG(name: String = "still.png") throws -> URL {
        let width = 64, height = 40
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        let image = try XCTUnwrap(context.makeImage())

        let url = tempDir.appendingPathComponent(name)
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
        ))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    private func bgraPixel(of texture: MTLTexture, x: Int, y: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 4)
        texture.getBytes(&bytes, bytesPerRow: 4, from: MTLRegionMake2D(x, y, 1, 1), mipmapLevel: 0)
        return bytes
    }

    func testShowStillVendsABGRASurfaceAtNaturalSize() async throws {
        let engine = try MediaEngine(device: device)
        let size = try await engine.showStill(url: makeTestPNG(), id: "still")
        XCTAssertEqual(size, CGSize(width: 64, height: 40))

        let surface = try XCTUnwrap(engine.surface(for: "still", hostTime: CACurrentMediaTime()))
        guard case .bgra(let texture, let transform, _) = surface else {
            return XCTFail("still must vend through the .bgra path")
        }
        XCTAssertEqual(texture.width, 64)
        XCTAssertEqual(texture.height, 40)
        XCTAssertTrue(transform.premultipliedAlpha)

        XCTAssertEqual(transform.gamutToWorking, matrix_identity_float3x3)
    }

    func testAlphaAndChannelOrderSurviveDecode() async throws {
        let engine = try MediaEngine(device: device)
        try await engine.showStill(url: makeTestPNG(), id: "still")
        guard case .bgra(let texture, _, _)? = engine.surface(for: "still", hostTime: 0) else {
            return XCTFail("no .bgra surface")
        }

        XCTAssertEqual(bgraPixel(of: texture, x: 56, y: 20), [0, 0, 0, 0])

        let red = bgraPixel(of: texture, x: 8, y: 20)
        XCTAssertEqual(red[3], 255, "opaque pixel lost alpha")
        XCTAssertGreaterThan(red[2], 200, "red channel missing — channel order wrong?")
        XCTAssertLessThan(red[0], 80, "blue channel too high — channel order wrong?")
    }

    func testStillIsTimeIndependentAndIdempotent() async throws {
        let engine = try MediaEngine(device: device)
        let url = try makeTestPNG()
        try await engine.showStill(url: url, id: "still")
        guard case .bgra(let first, _, _)? = engine.surface(for: "still", hostTime: 0) else {
            return XCTFail("no .bgra surface")
        }
        try await engine.showStill(url: url, id: "still")
        guard case .bgra(let again, _, _)? = engine.surface(for: "still", hostTime: 1234.5) else {
            return XCTFail("no .bgra surface after re-show")
        }
        XCTAssertTrue(first === again, "re-showing the same id/url must keep the texture")
    }

    func testStopReleasesTheStill() async throws {
        let engine = try MediaEngine(device: device)
        try await engine.showStill(url: makeTestPNG(), id: "still")
        engine.stop(id: "still")
        XCTAssertNil(engine.surface(for: "still", hostTime: CACurrentMediaTime()))

        try await engine.showStill(url: makeTestPNG(name: "second.png"), id: "still")
        engine.stopAll()
        XCTAssertNil(engine.surface(for: "still", hostTime: CACurrentMediaTime()))
    }

    func testUnknownIDReturnsNil() async throws {
        let engine = try MediaEngine(device: device)
        XCTAssertNil(engine.surface(for: "nope", hostTime: CACurrentMediaTime()))
    }

    func testUnreadableFileThrows() async throws {
        let engine = try MediaEngine(device: device)
        let missing = tempDir.appendingPathComponent("missing.png")
        do {
            try await engine.showStill(url: missing, id: "still")
            XCTFail("expected imageDecodeFailed")
        } catch MediaEngineError.imageDecodeFailed { }
        XCTAssertNil(engine.surface(for: "still", hostTime: CACurrentMediaTime()))
    }
}
