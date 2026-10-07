import Foundation
import CoreVideo
import Metal
import RenderEngine
import XCTest
@testable import OutputEngine

final class OutputMirrorTests: XCTestCase {
    private func makeCompositor() throws -> Compositor {
        do {
            return try Compositor()
        } catch CompositorError.noMetalDevice {
            throw XCTSkip("no Metal device on this machine")
        }
    }

    private func solidWhiteScene(canvas: CGSize) -> RenderScene {
        var scene = RenderScene(canvasSize: canvas)
        scene.addItem(
            RenderItem(
                id: "fill",
                frame: CGRect(origin: .zero, size: canvas),
                content: .solid(.white)
            ),
            to: .stillGraphics
        )
        return scene
    }

    func testMirrorDeliversConvertedFrames() throws {
        let compositor = try makeCompositor()
        let expectation = expectation(description: "frames delivered")
        expectation.expectedFulfillmentCount = 3

        let delivered = Locked<[CVPixelBuffer]>([])
        let scene = solidWhiteScene(canvas: CGSize(width: 320, height: 180))
        let mirror = try XCTUnwrap(OutputMirror(
            compositor: compositor, width: 320, height: 180, framesPerSecond: 30,
            provider: { scene },
            sink: { buffer, _ in
                let count = delivered.withLock { buffers -> Int in
                    buffers.append(buffer)
                    return buffers.count
                }
                if count <= 3 { expectation.fulfill() }
            }
        ))

        mirror.start()
        wait(for: [expectation], timeout: 10)
        mirror.stop()

        let buffer = try XCTUnwrap(delivered.value.first)
        XCTAssertEqual(CVPixelBufferGetPixelFormatType(buffer), kCVPixelFormatType_32BGRA)
        XCTAssertEqual(CVPixelBufferGetWidth(buffer), 320)
        XCTAssertEqual(CVPixelBufferGetHeight(buffer), 180)

        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer))
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let center = base.advanced(by: 90 * rowBytes + 160 * 4)
            .assumingMemoryBound(to: UInt8.self)
        XCTAssertGreaterThan(center[0], 250, "blue channel of a white frame")
        XCTAssertGreaterThan(center[1], 250, "green channel of a white frame")
        XCTAssertGreaterThan(center[2], 250, "red channel of a white frame")

        let primaries = CVBufferCopyAttachment(buffer, kCVImageBufferColorPrimariesKey, nil)
        XCTAssertEqual(
            primaries as? String,
            kCVImageBufferColorPrimaries_P3_D65 as String,
            "delivered buffers carry their real color tags")
    }

    func testMirrorTicksDirectlyForDeterministicTests() throws {
        let compositor = try makeCompositor()
        let expectation = expectation(description: "one frame")
        let scene = solidWhiteScene(canvas: CGSize(width: 160, height: 90))
        let mirror = try XCTUnwrap(OutputMirror(
            compositor: compositor, width: 160, height: 90, framesPerSecond: 30,
            provider: { scene },
            sink: { _, _ in expectation.fulfill() }
        ))
        mirror.start()
        defer { mirror.stop() }
        mirror.tick(at: 0)
        wait(for: [expectation], timeout: 5)
        XCTAssertGreaterThanOrEqual(mirror.framesDelivered, 1)
    }

    func testAdjustmentsReachTheFeedAndInvalidateTheStaticResend() throws {

        let compositor = try makeCompositor()
        let scene = solidWhiteScene(canvas: CGSize(width: 160, height: 90))
        let adjustments = Locked<OutputAdjustments?>(nil)
        let delivered = Locked<[CVPixelBuffer]>([])
        let firstDelivery = expectation(description: "raw frame")
        let secondDelivery = expectation(description: "corrected frame")
        let mirror = try XCTUnwrap(OutputMirror(
            compositor: compositor, width: 160, height: 90, framesPerSecond: 30,
            provider: { scene },
            adjustments: { adjustments.value },
            sink: { buffer, _ in
                let count = delivered.withLock { buffers -> Int in
                    buffers.append(buffer)
                    return buffers.count
                }
                if count == 1 { firstDelivery.fulfill() }
                if count == 2 { secondDelivery.fulfill() }
            }
        ))
        mirror.startWithoutTimerForTesting()
        defer { mirror.stop() }

        func centerLuma(_ buffer: CVPixelBuffer) -> UInt8 {
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            guard let base = CVPixelBufferGetBaseAddress(buffer) else { return 0 }
            let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
            let pixels = base.advanced(by: 45 * rowBytes + 80 * 4)
                .assumingMemoryBound(to: UInt8.self)
            return pixels[1]  
        }

        mirror.tick(at: 0)
        wait(for: [firstDelivery], timeout: 5)
        XCTAssertGreaterThan(centerLuma(delivered.value[0]), 250, "neutral feed stays white")

        var dark = OutputAdjustments()
        dark.brightness = -1
        adjustments.value = dark

        mirror.tick(at: 0.1)
        wait(for: [secondDelivery], timeout: 5)
        XCTAssertLessThan(
            centerLuma(delivered.value[1]), 10,
            "correction tweak re-renders the static scene on the feed")
    }

    func testSourceRectCarriesTheSlice() throws {

        let compositor = try makeCompositor()
        var scene = RenderScene(canvasSize: CGSize(width: 320, height: 180))
        scene.addItem(
            RenderItem(
                id: "left",
                frame: CGRect(x: 0, y: 0, width: 160, height: 180),
                content: .solid(SceneColor(red: 1, green: 0, blue: 0))
            ),
            to: .stillGraphics
        )
        scene.addItem(
            RenderItem(
                id: "right",
                frame: CGRect(x: 160, y: 0, width: 160, height: 180),
                content: .solid(SceneColor(red: 0, green: 0, blue: 1))
            ),
            to: .stillGraphics
        )
        let card = scene
        let delivery = expectation(description: "slice frame")
        let delivered = Locked<CVPixelBuffer?>(nil)
        let mirror = try XCTUnwrap(OutputMirror(
            compositor: compositor, width: 160, height: 180, framesPerSecond: 30,
            provider: { card },
            sourceRect: CGRect(x: 0, y: 0, width: 0.5, height: 1),
            sink: { buffer, _ in
                let first = delivered.withLock { held -> Bool in
                    guard held == nil else { return false }
                    held = buffer
                    return true
                }
                if first { delivery.fulfill() }
            }
        ))
        mirror.startWithoutTimerForTesting()
        defer { mirror.stop() }
        mirror.tick(at: 0)
        wait(for: [delivery], timeout: 5)

        let buffer = try XCTUnwrap(delivered.value)
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer))
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        func bgra(x: Int, y: Int) -> (b: UInt8, r: UInt8) {
            let pixels = base.advanced(by: y * rowBytes + x * 4)
                .assumingMemoryBound(to: UInt8.self)
            return (pixels[0], pixels[2])
        }
        let center = bgra(x: 80, y: 90)
        let nearRight = bgra(x: 156, y: 90)
        XCTAssertGreaterThan(center.r, 200, "the slice is red")
        XCTAssertLessThan(center.b, 60)
        XCTAssertGreaterThan(nearRight.r, 200, "red runs to the slice edge")
        XCTAssertLessThan(nearRight.b, 60, "no blue leak from the neighbor slice")
    }

    func testStaticSceneConvertsOnceThenResends() throws {
        try XCTSkipIf(isVirtualMachine(), "a virtual machine has no real-time cadence: the resend count only holds on a real Mac")

        let compositor = try makeCompositor()
        let threeDeliveries = expectation(description: "three deliveries")
        threeDeliveries.expectedFulfillmentCount = 3
        let delivered = Locked<[CVPixelBuffer]>([])
        let scene = solidWhiteScene(canvas: CGSize(width: 160, height: 90))
        let mirror = try XCTUnwrap(OutputMirror(
            compositor: compositor, width: 160, height: 90, framesPerSecond: 30,
            provider: { scene },
            sink: { buffer, _ in
                let count = delivered.withLock { buffers -> Int in
                    buffers.append(buffer)
                    return buffers.count
                }
                if count <= 3 { threeDeliveries.fulfill() }
            }
        ))
        mirror.start()
        defer { mirror.stop() }

        mirror.tick(at: 0)
        let firstConverted = expectation(description: "first frame converted")
        DispatchQueue.global().async {
            while delivered.withLock({ $0.isEmpty }) { usleep(10_000) }
            firstConverted.fulfill()
        }
        wait(for: [firstConverted], timeout: 5)
        mirror.tick(at: 1)
        mirror.tick(at: 2)
        wait(for: [threeDeliveries], timeout: 5)

        let buffers = delivered.value
        XCTAssertEqual(mirror.framesDelivered, 3, "resends count as delivered — cadence holds")
        XCTAssertTrue(buffers[1] === buffers[0], "second delivery reuses the converted buffer")
        XCTAssertTrue(buffers[2] === buffers[0], "third delivery reuses the converted buffer")
    }

    func testDelayHoldsFramesThenSlidesTheWindow() throws {

        let compositor = try makeCompositor()
        let delay = Locked(2)
        let sunk = Locked(0)
        let scene = solidWhiteScene(canvas: CGSize(width: 160, height: 90))
        let mirror = try XCTUnwrap(OutputMirror(
            compositor: compositor, width: 160, height: 90, framesPerSecond: 30,
            provider: { scene },
            delayFrames: { delay.value },
            sink: { _, _ in sunk.withLock { $0 += 1 } }
        ))
        mirror.startWithoutTimerForTesting()
        defer { mirror.stop() }

        func tick(at time: CFTimeInterval, expectSunk: Int) {
            let before = mirror.framesDelivered
            mirror.tick(at: time)
            let deadline = Date().addingTimeInterval(5)
            while (mirror.framesDelivered == before || sunk.value < expectSunk),
                  Date() < deadline { usleep(10_000) }
            XCTAssertEqual(mirror.framesDelivered, before + 1)
            XCTAssertEqual(sunk.value, expectSunk)
        }

        tick(at: 0, expectSunk: 0)  
        tick(at: 1, expectSunk: 0)  
        tick(at: 2, expectSunk: 1)  
        tick(at: 3, expectSunk: 2)  

        delay.value = 0
        tick(at: 4, expectSunk: 3)
        tick(at: 5, expectSunk: 4)
        tick(at: 6, expectSunk: 5)
    }

    func testStoppedMirrorStopsDelivering() throws {
        let compositor = try makeCompositor()
        let scene = solidWhiteScene(canvas: CGSize(width: 160, height: 90))
        let mirror = try XCTUnwrap(OutputMirror(
            compositor: compositor, width: 160, height: 90, framesPerSecond: 30,
            provider: { scene },
            sink: { _, _ in }
        ))

        mirror.tick(at: 0)
        XCTAssertEqual(mirror.framesDelivered, 0)
        XCTAssertEqual(mirror.framesDropped, 0)
    }
}

private func isVirtualMachine() -> Bool {
    var present: Int32 = 0
    var size = MemoryLayout<Int32>.size
    let read = sysctlbyname("kern.hv_vmm_present", &present, &size, nil, 0)
    return read == 0 && present != 0
}
