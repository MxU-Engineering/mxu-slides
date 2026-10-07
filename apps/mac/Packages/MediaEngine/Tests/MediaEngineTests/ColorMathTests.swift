import simd
import XCTest
@testable import MediaEngine

final class ColorMathTests: XCTestCase {

    func testBT709ToDisplayP3MatchesReference() {
        let m = ColorMath.bt709ToDisplayP3

        let expected: [[Float]] = [
            [0.8225, 0.1774, 0.0000],
            [0.0332, 0.9669, 0.0000],
            [0.0171, 0.0724, 0.9108],
        ]
        for row in 0..<3 {
            for col in 0..<3 {
                XCTAssertEqual(m[col][row], expected[row][col], accuracy: 0.001,
                               "mismatch at row \(row) col \(col)")
            }
        }
    }

    func testWhitePreservedAcrossGamutConversion() {
        let white = ColorMath.bt709ToDisplayP3 * SIMD3<Float>(1, 1, 1)
        XCTAssertEqual(white.x, 1.0, accuracy: 0.001)
        XCTAssertEqual(white.y, 1.0, accuracy: 0.001)
        XCTAssertEqual(white.z, 1.0, accuracy: 0.001)
    }

    func testBT709VideoRangeYCbCrCoefficients() {
        let (m, offset) = ColorMath.ycbcrToRGB(.bt709, fullRange: false)
        let yScale = Float(255.0 / 219.0)
        let cScale = Float(255.0 / 224.0)

        XCTAssertEqual(m[0][0], yScale, accuracy: 0.0001)
        XCTAssertEqual(m[2][0], cScale * 1.5748, accuracy: 0.001)
        XCTAssertEqual(m[1][2], cScale * 1.8556, accuracy: 0.001)
        XCTAssertEqual(offset.x, 16.0 / 255.0, accuracy: 0.0001)
        XCTAssertEqual(offset.y, 128.0 / 255.0, accuracy: 0.0001)
    }

    func testYCbCrRoundTrip() {
        let rgb = SIMD3<Double>(0.7, 0.3, 0.15)
        let (kr, kb) = (0.2126, 0.0722)
        let y = kr * rgb.x + (1 - kr - kb) * rgb.y + kb * rgb.z
        let cb = (rgb.z - y) / (2 * (1 - kb))
        let cr = (rgb.x - y) / (2 * (1 - kr))

        let sample = SIMD3<Float>(
            Float((16 + y * 219).rounded() / 255),
            Float((128 + cb * 224).rounded() / 255),
            Float((128 + cr * 224).rounded() / 255)
        )
        let (m, offset) = ColorMath.ycbcrToRGB(.bt709, fullRange: false)
        let decoded = m * (sample - offset)
        XCTAssertEqual(decoded.x, Float(rgb.x), accuracy: 0.01)
        XCTAssertEqual(decoded.y, Float(rgb.y), accuracy: 0.01)
        XCTAssertEqual(decoded.z, Float(rgb.z), accuracy: 0.01)
    }
}
