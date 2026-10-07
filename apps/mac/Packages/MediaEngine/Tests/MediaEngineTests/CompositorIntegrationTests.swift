import AVFoundation
import Metal
import RenderEngine
import XCTest
@testable import MediaEngine

@MainActor
final class CompositorIntegrationTests: XCTestCase {
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

    func testPrefixScopedStopLeavesOtherNamespacesAlone() async throws {

        let context = CGContext(
            data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let image = context.makeImage()!

        let engine = try MediaEngine(device: device)
        _ = try await engine.showStill(image: image, cacheKey: "w", id: "edit::a")
        _ = try await engine.showStill(image: image, cacheKey: "w", id: "thumb::b")
        XCTAssertTrue(engine.hasStill(id: "edit::a"))
        XCTAssertTrue(engine.hasStill(id: "thumb::b"))

        engine.stopAll(withPrefix: "edit::")
        XCTAssertFalse(engine.hasStill(id: "edit::a"))
        XCTAssertTrue(engine.hasStill(id: "thumb::b"), "other namespaces survive")

        engine.stopAll()
        XCTAssertFalse(engine.hasStill(id: "thumb::b"))
    }

    func testStillSourceRectCropsThroughTheCompositor() async throws {

        let width = 64, height = 64
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 64))
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 32, y: 0, width: 32, height: 64))
        let image = context.makeImage()!

        let compositor = try Compositor(device: device)
        let engine = try MediaEngine(device: device)
        compositor.mediaSource = engine
        _ = try await engine.showStill(image: image, cacheKey: "half", id: "still")

        var scene = RenderScene(canvasSize: CGSize(width: 64, height: 64))
        scene.addItem(
            RenderItem(
                id: "pic", frame: CGRect(x: 0, y: 0, width: 64, height: 64),
                content: .media(
                    id: "still", scaleMode: .stretch,
                    sourceRect: SceneSourceRect(x: 0.5, y: 0, width: 0.5, height: 1)
                )
            ),
            to: .slide
        )

        let frame = try compositor.renderFrame(
            scene: scene, width: 64, height: 64, at: CACurrentMediaTime()
        )
        var red: Float = 0, blue: Float = 0
        frame.data.withUnsafeBytes { raw in
            let halves = raw.baseAddress!.assumingMemoryBound(to: Float16.self)
            let px = (32 * 64 + 16) * 4  
            red = Float(halves[px])
            blue = Float(halves[px + 2])
        }
        XCTAssertLessThan(red, 0.1, "left half of the SOURCE must be cropped away")
        XCTAssertGreaterThan(blue, 0.5, "the right-half crop fills the frame")

        scene.layers = RenderScene.defaultLayerStack()
        scene.addItem(
            RenderItem(
                id: "pic2", frame: CGRect(x: 0, y: 0, width: 64, height: 64),
                content: .media(
                    id: "still", scaleMode: .stretch,
                    sourceRect: SceneSourceRect(x: 0.5, y: 0, width: 1, height: 1)
                )
            ),
            to: .slide
        )
        let outset = try compositor.renderFrame(
            scene: scene, width: 64, height: 64, at: CACurrentMediaTime()
        )
        var leftBlue: Float = 0, rightBlue: Float = 0, rightRed: Float = 0
        outset.data.withUnsafeBytes { raw in
            let halves = raw.baseAddress!.assumingMemoryBound(to: Float16.self)
            let left = (32 * 64 + 16) * 4   
            let right = (32 * 64 + 48) * 4  
            leftBlue = Float(halves[left + 2])
            rightBlue = Float(halves[right + 2])
            rightRed = Float(halves[right])
        }
        XCTAssertGreaterThan(leftBlue, 0.5, "in-source part of the window shows the media")
        XCTAssertLessThan(rightBlue, 0.05, "out-of-source part must not edge-smear blue")
        XCTAssertLessThan(rightRed, 0.05, "out-of-source part must not edge-smear red")
    }

    func testTwoLayerPlaybackThroughTheCompositor() async throws {
        let alphaURL = tempDir.appendingPathComponent("alpha.mov")
        try await MediaAuthoring.writeMovie(
            to: alphaURL, codec: .proRes4444Alpha, size: CGSize(width: 640, height: 360), frameCount: 30
        ) { context, frame in
            context.setFillColor(CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 0.5))
            context.fill(CGRect(x: CGFloat(frame) * 20, y: 0, width: 20, height: 360))
        }
        let opaqueURL = tempDir.appendingPathComponent("opaque.mov")
        try await MediaAuthoring.writeMovie(
            to: opaqueURL, codec: .h264, size: CGSize(width: 640, height: 360), frameCount: 30
        ) { context, _ in
            context.setFillColor(CGColor(srgbRed: 0.5, green: 0.1, blue: 0.1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 640, height: 360))
        }

        let compositor = try Compositor(device: device)
        let engine = try MediaEngine(device: device)
        compositor.mediaSource = engine

        var scene = RenderScene(canvasSize: CGSize(width: 640, height: 360))
        scene.addItem(
            RenderItem(id: "under", frame: CGRect(x: 0, y: 0, width: 640, height: 360),
                       content: .media(id: "opaque")),
            to: .loopingVideos
        )
        scene.addItem(
            RenderItem(id: "over", frame: CGRect(x: 0, y: 0, width: 640, height: 360),
                       content: .media(id: "alpha")),
            to: .videos
        )

        let opaque = try await engine.prepare(url: opaqueURL)
        let alpha = try await engine.prepare(url: alphaURL)
        engine.play(opaque, id: "opaque", loop: true)
        engine.play(alpha, id: "alpha", loop: true)

        let deadline = Date(timeIntervalSinceNow: 10)
        var sawVideoPixels = false
        while Date() < deadline {
            let frame = try compositor.renderFrame(
                scene: scene, width: 640, height: 360, at: CACurrentMediaTime()
            )

            var red: Float = 0
            frame.data.withUnsafeBytes { raw in
                let halves = raw.baseAddress!.assumingMemoryBound(to: Float16.self)
                red = Float(halves[(180 * 640 + 320) * 4])
            }
            if red > 0.05 { sawVideoPixels = true }

            let alphaShown = engine.stats(for: "alpha")?.framesDisplayed ?? 0
            let opaqueShown = engine.stats(for: "opaque")?.framesDisplayed ?? 0
            if sawVideoPixels, alphaShown >= 10, opaqueShown >= 10 { break }
            try await Task.sleep(for: .milliseconds(16))
        }

        XCTAssertTrue(sawVideoPixels, "video pixels never reached the render target")
        XCTAssertGreaterThanOrEqual(engine.stats(for: "alpha")?.framesDisplayed ?? 0, 10)
        XCTAssertGreaterThanOrEqual(engine.stats(for: "opaque")?.framesDisplayed ?? 0, 10)
        engine.stopAll()
    }
}
