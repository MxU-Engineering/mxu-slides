import CoreVideo
import XCTest
@testable import NDIKit

final class NDILoopbackTests: XCTestCase {
    private func loadedLibrary() throws -> NDILibrary {
        do {
            return try NDILibrary.load()
        } catch {
            throw XCTSkip("NDI runtime not installed: \(error)")
        }
    }

    private func makeBlueBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
        var out: CVPixelBuffer?
        XCTAssertEqual(
            CVPixelBufferCreate(
                kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary,
                &out),
            kCVReturnSuccess)
        let buffer = try XCTUnwrap(out)
        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
            for row in 0..<height {
                let pixels = base.advanced(by: row * rowBytes).assumingMemoryBound(to: UInt8.self)
                for column in 0..<width {
                    pixels[column * 4 + 0] = 255  
                    pixels[column * 4 + 1] = 0    
                    pixels[column * 4 + 2] = 0    
                    pixels[column * 4 + 3] = 255  
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }

    func testRuntimeLoadsAndReportsATable() throws {
        let library = try loadedLibrary()
        XCTAssertNotNil(library.table.send_create)
        XCTAssertNotNil(library.table.recv_capture_v3)
    }

    func testSenderIsReceivableOnThisMachine() throws {
        let library = try loadedLibrary()
        let sourceName = "MxU Loopback \(ProcessInfo.processInfo.processIdentifier)"
        let sender = try XCTUnwrap(NDISender(library: library, name: sourceName))
        nonisolated(unsafe) let buffer = try makeBlueBuffer(width: 320, height: 180)

        let pumping = Locked(true)
        let pump = Thread {
            while pumping.withLock({ $0 }) {
                sender.send(pixelBuffer: buffer)
                Thread.sleep(forTimeInterval: 1.0 / 30.0)
            }
        }
        pump.start()
        defer { pumping.withLock { $0 = false } }

        let receiver = try XCTUnwrap(NDIReceiver(library: library))
        let connected = receiver.connect(toSourceContaining: sourceName, timeout: 15)
        XCTAssertNotNil(connected, "loopback source never appeared in NDI discovery")

        let frame = try XCTUnwrap(
            receiver.captureVideoFrame(timeout: 10),
            "connected but no video frame arrived")
        XCTAssertEqual(frame.width, 320)
        XCTAssertEqual(frame.height, 180)

        let offset = (frame.height / 2) * frame.bytesPerRow + (frame.width / 2) * 4
        XCTAssertGreaterThan(frame.data[offset], 200, "blue channel")
        XCTAssertLessThan(frame.data[offset + 2], 60, "red channel")
        XCTAssertGreaterThan(sender.sent, 0)
    }

    func testInputRecoversWhenTheSourceReturns() throws {
        let library = try loadedLibrary()
        let sourceName = "MxU Rehunt \(ProcessInfo.processInfo.processIdentifier)"
        nonisolated(unsafe) let buffer = try makeBlueBuffer(width: 320, height: 180)

        let pumping = Locked(true)
        func pump(_ sender: NDISender) -> Thread {
            let thread = Thread {
                while pumping.withLock({ $0 }) {
                    sender.send(pixelBuffer: buffer)
                    Thread.sleep(forTimeInterval: 1.0 / 30.0)
                }
            }
            thread.start()
            return thread
        }

        var sender: NDISender? = try XCTUnwrap(NDISender(library: library, name: sourceName))
        _ = pump(sender!)

        let input = NDIInputSource(
            library: library, sourceNameContaining: sourceName,
            quietSecondsBeforeRehunt: 2)
        defer { input.stop() }

        func waitForFrames(deadline: TimeInterval) -> Bool {
            let until = Date(timeIntervalSinceNow: deadline)
            while Date() < until {
                if case .receiving = input.state, input.latestFrame() != nil { return true }
                Thread.sleep(forTimeInterval: 0.25)
            }
            return false
        }

        XCTAssertTrue(waitForFrames(deadline: 15), "never connected the first time")

        pumping.withLock { $0 = false }
        sender = nil
        Thread.sleep(forTimeInterval: 4)
        input.clearLatestFrameForTesting()

        pumping.withLock { $0 = true }
        sender = try XCTUnwrap(NDISender(library: library, name: sourceName))
        _ = pump(sender!)
        defer { pumping.withLock { $0 = false } }

        XCTAssertTrue(waitForFrames(deadline: 30), "input never re-hunted the returned source")
    }
}
