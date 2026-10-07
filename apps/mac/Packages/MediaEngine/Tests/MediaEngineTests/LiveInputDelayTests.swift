import CoreVideo
import XCTest
@testable import MediaEngine

final class LiveInputDelayTests: XCTestCase {

    private func makeFrame(fill: UInt8) throws -> CVPixelBuffer {
        var out: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(
            kCFAllocatorDefault, 4, 4, kCVPixelFormatType_32BGRA,
            nil, &out), kCVReturnSuccess)
        let frame = try XCTUnwrap(out)
        CVPixelBufferLockBaseAddress(frame, [])
        defer { CVPixelBufferUnlockBaseAddress(frame, []) }
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(frame))
        memset(base, Int32(fill), CVPixelBufferGetBytesPerRow(frame) * 4)
        return frame
    }

    private func firstByte(_ frame: CVPixelBuffer) throws -> UInt8 {
        CVPixelBufferLockBaseAddress(frame, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(frame, .readOnly) }
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(frame))
        return base.assumingMemoryBound(to: UInt8.self)[0]
    }

    func testZeroDelayPassesTheFrameThrough() throws {
        let delay = LiveInputDelay()
        let frame = try makeFrame(fill: 7)
        XCTAssertTrue(delay.delayed(frame, id: "cam") === frame)
    }

    func testDelayedPullAnswersTheOldestHeldFrame() throws {
        let delay = LiveInputDelay()
        delay.setDelay(id: "cam", frames: 2)
        let first = try makeFrame(fill: 10)
        let second = try makeFrame(fill: 20)
        let third = try makeFrame(fill: 30)
        let fourth = try makeFrame(fill: 40)

        XCTAssertEqual(try firstByte(delay.delayed(first, id: "cam")), 10)
        XCTAssertEqual(try firstByte(delay.delayed(second, id: "cam")), 10)
        XCTAssertEqual(try firstByte(delay.delayed(third, id: "cam")), 10)

        XCTAssertEqual(try firstByte(delay.delayed(fourth, id: "cam")), 20)
    }

    func testSameInstanceRePullDoesNotAdvanceTheRing() throws {

        let delay = LiveInputDelay()
        delay.setDelay(id: "cam", frames: 1)
        let first = try makeFrame(fill: 10)
        let second = try makeFrame(fill: 20)
        _ = delay.delayed(first, id: "cam")
        _ = delay.delayed(first, id: "cam")
        _ = delay.delayed(first, id: "cam")
        XCTAssertEqual(try firstByte(delay.delayed(second, id: "cam")), 10,
                       "re-pulls of one source frame count once")
    }

    func testHeldFramesAreCopiesNotTheSourceBuffers() throws {

        let delay = LiveInputDelay()
        delay.setDelay(id: "cam", frames: 1)
        let first = try makeFrame(fill: 10)
        let held = delay.delayed(first, id: "cam")
        XCTAssertFalse(held === first)
        XCTAssertEqual(try firstByte(held), 10)
    }

    func testClearDropsHeldFramesButKeepsTheSetting() throws {
        let delay = LiveInputDelay()
        delay.setDelay(id: "cam", frames: 2)
        _ = delay.delayed(try makeFrame(fill: 10), id: "cam")
        delay.clear(id: "cam")
        XCTAssertEqual(delay.delay(id: "cam"), 2)
        XCTAssertEqual(try firstByte(delay.delayed(try makeFrame(fill: 30), id: "cam")), 30,
                       "a restarted input refills from its first frame")
    }

    func testSetDelayClampsToTheCeiling() {
        let delay = LiveInputDelay()
        delay.setDelay(id: "cam", frames: 999)
        XCTAssertEqual(delay.delay(id: "cam"), LiveInputDelay.maxFrames)
        delay.setDelay(id: "cam", frames: -1)
        XCTAssertEqual(delay.delay(id: "cam"), 0)
    }
}
