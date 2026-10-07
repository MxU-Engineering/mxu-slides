import AVFoundation
import Metal
import RenderEngine
import XCTest
@testable import MediaEngine

@MainActor
final class CodecPipelineTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("No Metal device available on this machine")
        }
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MediaEngineTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
    }

    private func expectedLinearP3(_ srgb: SIMD3<Double>) -> SIMD3<Float> {
        func linear(_ c: Double) -> Float {
            Float(c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4))
        }
        return ColorMath.bt709ToDisplayP3 * SIMD3<Float>(linear(srgb.x), linear(srgb.y), linear(srgb.z))
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

    private func writeMovie(
        codec: MediaAuthoring.Codec,
        size: CGSize = CGSize(width: 320, height: 180),
        draw: @escaping @Sendable (CGContext, Int) -> Void
    ) async throws -> URL {
        let url = tempDir.appendingPathComponent("\(codec.rawValue).mov")
        do {
            try await MediaAuthoring.writeMovie(
                to: url, codec: codec, size: size, frameCount: 12, draw: draw
            )
        } catch {

            throw XCTSkip("\(codec.rawValue) encoder unavailable: \(error)")
        }
        return url
    }

    private func decodeFirstSurface(url: URL, hasAlpha: Bool) async throws -> MediaSurface {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw MediaEngineError.noVideoTrack(url)
        }
        let media = PreparedMedia(
            url: url, duration: 0, frameDuration: 1.0 / 30.0,
            naturalSize: .zero, hasAlpha: hasAlpha, asset: asset
        )
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: media.outputPixelBufferAttributes
        )
        reader.add(output)
        XCTAssertTrue(reader.startReading(), "reader failed: \(String(describing: reader.error))")
        guard let sample = output.copyNextSampleBuffer(),
              let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else {
            throw MediaEngineError.authoringFailed("no decodable frame in \(url.lastPathComponent)")
        }
        let factory = try SurfaceFactory(device: MTLCreateSystemDefaultDevice()!)
        guard let surface = factory.makeSurface(from: pixelBuffer) else {
            throw MediaEngineError.authoringFailed("SurfaceFactory rejected the decoded frame")
        }
        return surface
    }

    private func render(
        surface: MediaSurface,
        background: SceneColor = .black,
        width: Int = 320,
        height: Int = 180
    ) throws -> RenderedFrame {
        final class StubSource: MediaTextureSource {
            let surface: MediaSurface
            init(_ surface: MediaSurface) { self.surface = surface }
            func surface(for mediaID: String, hostTime: CFTimeInterval) -> MediaSurface? { surface }
        }
        let compositor = try Compositor()
        let source = StubSource(surface)
        compositor.mediaSource = source

        var scene = RenderScene(canvasSize: CGSize(width: width, height: height))
        scene.background = background
        scene.addItem(
            RenderItem(
                id: "video",
                frame: CGRect(x: 0, y: 0, width: width, height: height),
                content: .media(id: "test")
            ),
            to: .videos
        )
        return try compositor.renderFrame(scene: scene, width: width, height: height)
    }

    private func assertOpaqueCodecRoundTrips(_ codec: MediaAuthoring.Codec) async throws {
        let srgb = SIMD3<Double>(0.8, 0.2, 0.1)
        let url = try await writeMovie(codec: codec) { context, _ in
            context.setFillColor(CGColor(srgbRed: srgb.x, green: srgb.y, blue: srgb.z, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 320, height: 180))
        }

        let surface = try await decodeFirstSurface(url: url, hasAlpha: false)
        guard case .ycbcrBiplanar = surface else {
            return XCTFail("\(codec.rawValue) must decode onto the biplanar Y'CbCr path")
        }

        let frame = try render(surface: surface)
        let center = pixel(frame, x: 160, y: 90)
        let expected = expectedLinearP3(srgb)

        XCTAssertEqual(center.x, expected.x, accuracy: 0.03, "\(codec.rawValue) red")
        XCTAssertEqual(center.y, expected.y, accuracy: 0.03, "\(codec.rawValue) green")
        XCTAssertEqual(center.z, expected.z, accuracy: 0.03, "\(codec.rawValue) blue")
        XCTAssertEqual(center.w, 1.0, accuracy: 0.005, "\(codec.rawValue) opaque")
    }

    func testH264DecodesToWorkingSpace() async throws {
        try await assertOpaqueCodecRoundTrips(.h264)
    }

    func testHEVCDecodesToWorkingSpace() async throws {
        try await assertOpaqueCodecRoundTrips(.hevc)
    }

    private func assertAlphaCodecComposites(_ codec: MediaAuthoring.Codec) async throws {
        let url = try await writeMovie(codec: codec) { context, _ in

            context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 0.5))
            context.fill(CGRect(x: 80, y: 45, width: 160, height: 90))
        }

        let surface = try await decodeFirstSurface(url: url, hasAlpha: true)
        guard case .bgra = surface else {
            return XCTFail("\(codec.rawValue) must decode onto the BGRA alpha path")
        }

        let frame = try render(surface: surface)

        let expected = 0.5 * expectedLinearP3(SIMD3(1, 0, 0))
        let center = pixel(frame, x: 160, y: 90)
        XCTAssertEqual(center.x, expected.x, accuracy: 0.02, "\(codec.rawValue) red")
        XCTAssertEqual(center.y, expected.y, accuracy: 0.02, "\(codec.rawValue) green")
        XCTAssertEqual(center.z, expected.z, accuracy: 0.02, "\(codec.rawValue) blue")

        let corner = pixel(frame, x: 10, y: 10)
        XCTAssertEqual(corner.x, 0, accuracy: 0.01, "\(codec.rawValue) transparent region leaks color")
        XCTAssertEqual(corner.y, 0, accuracy: 0.01)
        XCTAssertEqual(corner.z, 0, accuracy: 0.01)
    }

    func testProRes4444AlphaComposites() async throws {
        try await assertAlphaCodecComposites(.proRes4444Alpha)
    }

    func testHEVCAlphaComposites() async throws {
        try await assertAlphaCodecComposites(.hevcAlpha)
    }

    func testPrepareDetectsAlphaAndFrameTiming() async throws {
        let opaque = try await writeMovie(codec: .h264) { context, _ in
            context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 320, height: 180))
        }
        let alpha = try await writeMovie(codec: .proRes4444Alpha) { context, _ in
            context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.5))
            context.fill(CGRect(x: 0, y: 0, width: 320, height: 180))
        }

        let engine = try MediaEngine(device: MTLCreateSystemDefaultDevice()!)
        let opaqueMedia = try await engine.prepare(url: opaque)
        let alphaMedia = try await engine.prepare(url: alpha)

        XCTAssertFalse(opaqueMedia.hasAlpha)
        XCTAssertTrue(alphaMedia.hasAlpha, "ProRes 4444 must ride the alpha path")
        XCTAssertEqual(opaqueMedia.frameDuration, 1.0 / 30.0, accuracy: 0.001)
        XCTAssertEqual(opaqueMedia.duration, 0.4, accuracy: 0.05, "12 frames at 30fps")
    }

    func testVideoFrameRendersDeterministically() async throws {
        let url = try await writeMovie(codec: .h264) { context, _ in
            context.setFillColor(CGColor(srgbRed: 0.3, green: 0.6, blue: 0.9, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 320, height: 180))
        }
        let surface = try await decodeFirstSurface(url: url, hasAlpha: false)
        let first = try render(surface: surface)
        let second = try render(surface: surface)
        XCTAssertEqual(first.data, second.data, "editor canvas and output must agree on video pixels")
    }
}
