import CoreVideo
import XCTest
@testable import OutputEngine

final class SyncTestReaderTests: XCTestCase {
    static let gridSize = SyncTestReader.gridRows * SyncTestReader.gridColumns

    private func run(
        soundLeadMs: Double, floodSamples: Int = SyncTestReaderTests.gridSize, symbolSamples: Int = 38,
        seconds: Int = 6, noise: Float = 0.01
    ) -> SyncTestReader {
        let reader = SyncTestReader()
        var generator = SystemRandomNumberGenerator()
        let frame = 1001.0 / 30000
        var time = 50.0
        while time < 50 + Double(seconds) {
            let sinceBeat = (time - 50.2).truncatingRemainder(dividingBy: 0.5)
            let beat = Int(((time - 50.2) / 0.5).rounded(.down))
            let flashing = time >= 50.2 && sinceBeat < 0.1
            let lit = flashing ? (beat % 4 == 0 ? floodSamples : symbolSamples) : 0
            let lumas = (0..<Self.gridSize).map { index in
                (index < lit ? 0.9 : 0.2) + Double.random(in: -0.02...0.02, using: &generator)
            }
            reader.picture(hostSeconds: time, lumas: lumas)
            time += frame
        }
        let rate = 48_000.0
        for buffer in 0..<(seconds * 100) {
            let start = 50 + Double(buffer) * 0.010
            let samples = (0..<480).map { index -> Float in
                let t = start + Double(index) / rate + soundLeadMs / 1000
                let sinceBeat = (t - 50.2).truncatingRemainder(dividingBy: 0.5)
                let beat = Int(((t - 50.2) / 0.5).rounded(.down))
                let hertz = beat % 4 == 0 ? 1_500.0 : 1_000.0
                let click = t >= 50.2 && sinceBeat < 0.04 ? Float(0.5 * sin(2 * .pi * hertz * sinceBeat)) : 0
                return click + Float.random(in: -noise...noise, using: &generator)
            }
            reader.sound(startSeconds: start, samples: samples, sampleRate: rate)
        }
        return reader
    }

    func testSoundBehindPictureReadsPositiveWithinAFrame() throws {
        let verdict = try XCTUnwrap(run(soundLeadMs: -300).verdict)
        XCTAssertGreaterThanOrEqual(verdict.pairs, 2)
        XCTAssertEqual(verdict.offsetMs, 300, accuracy: 34)
    }

    func testSoundFarAheadOfPictureStillPairsWithItsOwnFlash() throws {
        let verdict = try XCTUnwrap(run(soundLeadMs: 700).verdict)
        XCTAssertEqual(verdict.offsetMs, -700, accuracy: 34)
    }

    func testAProjectorSeenThroughACameraStillReads() throws {
        let verdict = try XCTUnwrap(run(soundLeadMs: 120, floodSamples: 400, symbolSamples: 4).verdict)
        XCTAssertEqual(verdict.offsetMs, -120, accuracy: 34)
        XCTAssertGreaterThanOrEqual(verdict.pairs, 2)
    }

    func testOnlyFloodsVisibleStillReads() throws {
        let verdict = try XCTUnwrap(run(soundLeadMs: 120, floodSamples: 300, symbolSamples: 0).verdict)
        XCTAssertEqual(verdict.offsetMs, -120, accuracy: 34)
    }

    func testOrdinaryProgrammeGivesNoVerdict() {
        let reader = SyncTestReader()
        var generator = SystemRandomNumberGenerator()
        for frame in 0..<180 {
            let lumas = (0..<Self.gridSize).map { _ in 0.4 + Double.random(in: -0.05...0.05, using: &generator) }
            reader.picture(hostSeconds: Double(frame) / 30, lumas: lumas)
        }
        for buffer in 0..<600 {
            let samples = (0..<480).map { _ in Float.random(in: -0.2...0.2, using: &generator) }
            reader.sound(startSeconds: Double(buffer) * 0.010, samples: samples, sampleRate: 48_000)
        }
        XCTAssertNil(reader.verdict)
    }

    func testGridLumaReadsAFrameOnTheGrid() throws {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 960, 540, kCVPixelFormatType_32BGRA, nil, &buffer)
        let made = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(made, [])
        let pixels = try XCTUnwrap(CVPixelBufferGetBaseAddress(made)).assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRow(made)
        for y in 0..<540 {
            for x in 0..<960 {
                let pixel = pixels + y * rowBytes + x * 4
                let bright: UInt8 = x < 480 ? 255 : 0
                pixel[0] = bright; pixel[1] = bright; pixel[2] = bright; pixel[3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(made, [])
        let lumas = try XCTUnwrap(SyncTestReader.gridLuma(made))
        XCTAssertEqual(lumas.count, Self.gridSize)
        XCTAssertEqual(lumas[0], 1, accuracy: 0.01, "left half white")
        XCTAssertEqual(lumas[SyncTestReader.gridColumns - 1], 0, accuracy: 0.01, "right half black")
        XCTAssertEqual(lumas.filter { $0 > 0.5 }.count, Self.gridSize / 2)
    }
}
