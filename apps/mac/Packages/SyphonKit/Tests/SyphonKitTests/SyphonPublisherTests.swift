import CoreVideo
import Metal
import Syphon
import XCTest
@testable import SyphonKit

final class SyphonPublisherTests: XCTestCase {
    private func device() throws -> MTLDevice {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("no Metal device on this machine")
        }
        return device
    }

    private func pixelBuffer(
        width: Int, height: Int, bgra: [UInt8], bottom: [UInt8]? = nil
    ) throws -> CVPixelBuffer {
        let attributes: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(
            kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
            attributes as CFDictionary, &buffer), kCVReturnSuccess)
        let pixelBuffer = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(pixelBuffer))
        let rowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)
        for row in 0..<height {
            let line = base.advanced(by: row * rowBytes).assumingMemoryBound(to: UInt8.self)
            let color = row >= height / 2 ? bottom ?? bgra : bgra
            for column in 0..<width {
                for channel in 0..<4 { line[column * 4 + channel] = color[channel] }
            }
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        return pixelBuffer
    }

    private func spin(until condition: () -> Bool, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        return condition()
    }

    func testClientReceivesPublishedPixels() throws {
        let device = try device()
        let name = "MxU Test \(UUID().uuidString.prefix(8))"
        let publisher = try XCTUnwrap(SyphonPublisher(name: name, device: device))
        defer { publisher.stop() }
        let top: [UInt8] = [20, 140, 230, 255]
        let bottom: [UInt8] = [200, 40, 10, 255]
        let frame = try pixelBuffer(width: 64, height: 36, bgra: top, bottom: bottom)

        XCTAssertTrue(spin {
            !SyphonServerDirectory.shared().servers(matchingName: name, appName: nil).isEmpty
        }, "server must announce itself by name")

        let client = try XCTUnwrap(SyphonMetalClient(
            serverDescription: publisher.serverDescription, device: device,
            options: nil, newFrameHandler: nil))
        defer { client.stop() }
        XCTAssertTrue(spin { publisher.hasClients }, "client must attach")

        XCTAssertTrue(publisher.publish(frame))
        XCTAssertTrue(spin { client.hasNewFrame }, "client must see the frame")
        let texture = try XCTUnwrap(client.newFrameImage())
        XCTAssertEqual(texture.width, 64)
        XCTAssertEqual(texture.height, 36)
        XCTAssertEqual(texture.pixelFormat, .bgra8Unorm)
        func pixel(row: Int) -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: 4)
            texture.getBytes(
                &bytes, bytesPerRow: 64 * 4,
                from: MTLRegionMake2D(10, row, 1, 1), mipmapLevel: 0)
            return bytes
        }

        XCTAssertEqual(pixel(row: 2), bottom)
        XCTAssertEqual(pixel(row: 33), top)
    }

    func testNothingIsCopiedWithoutClients() throws {
        let publisher = try XCTUnwrap(SyphonPublisher(name: "MxU Idle", device: device()))
        defer { publisher.stop() }
        let frame = try pixelBuffer(width: 8, height: 8, bgra: [0, 0, 0, 255])
        XCTAssertFalse(publisher.publish(frame))
        XCTAssertEqual(publisher.framesPublished, 0)
    }

    func testStopRetiresTheServer() throws {
        let name = "MxU Retire \(UUID().uuidString.prefix(8))"
        let publisher = try XCTUnwrap(SyphonPublisher(name: name, device: device()))
        let directory = SyphonServerDirectory.shared()
        XCTAssertTrue(spin { !directory.servers(matchingName: name, appName: nil).isEmpty })
        publisher.stop()
        XCTAssertTrue(spin { directory.servers(matchingName: name, appName: nil).isEmpty })

        XCTAssertFalse(publisher.publish(try pixelBuffer(width: 8, height: 8, bgra: [0, 0, 0, 255])))
    }
}
