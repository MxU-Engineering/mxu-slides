import simd

enum ColorMath {

    struct Primaries {
        var red: SIMD2<Double>
        var green: SIMD2<Double>
        var blue: SIMD2<Double>
        var white: SIMD2<Double>

        static let d65 = SIMD2(0.3127, 0.3290)

        static let bt709 = Primaries(
            red: SIMD2(0.640, 0.330), green: SIMD2(0.300, 0.600), blue: SIMD2(0.150, 0.060), white: d65
        )
        static let displayP3 = Primaries(
            red: SIMD2(0.680, 0.320), green: SIMD2(0.265, 0.690), blue: SIMD2(0.150, 0.060), white: d65
        )
        static let bt2020 = Primaries(
            red: SIMD2(0.708, 0.292), green: SIMD2(0.170, 0.797), blue: SIMD2(0.131, 0.046), white: d65
        )
    }

    static func rgbToXYZ(_ p: Primaries) -> double3x3 {
        func xyzColumn(_ c: SIMD2<Double>) -> SIMD3<Double> {
            SIMD3(c.x / c.y, 1.0, (1.0 - c.x - c.y) / c.y)
        }
        let unscaled = double3x3(columns: (xyzColumn(p.red), xyzColumn(p.green), xyzColumn(p.blue)))
        let scales = unscaled.inverse * xyzColumn(p.white)
        return double3x3(columns: (
            unscaled.columns.0 * scales.x,
            unscaled.columns.1 * scales.y,
            unscaled.columns.2 * scales.z
        ))
    }

    static func toDisplayP3(from source: Primaries) -> simd_float3x3 {
        let m = rgbToXYZ(.displayP3).inverse * rgbToXYZ(source)
        return simd_float3x3(columns: (
            SIMD3<Float>(m.columns.0), SIMD3<Float>(m.columns.1), SIMD3<Float>(m.columns.2)
        ))
    }

    static let bt709ToDisplayP3 = toDisplayP3(from: .bt709)
    static let bt2020ToDisplayP3 = toDisplayP3(from: .bt2020)
    static let identityGamut = matrix_identity_float3x3

    struct YCbCrCoefficients {
        var kr: Double
        var kb: Double

        static let bt709 = YCbCrCoefficients(kr: 0.2126, kb: 0.0722)
        static let bt601 = YCbCrCoefficients(kr: 0.299, kb: 0.114)
        static let bt2020 = YCbCrCoefficients(kr: 0.2627, kb: 0.0593)
    }

    static func ycbcrToRGB(_ c: YCbCrCoefficients, fullRange: Bool) -> (matrix: simd_float3x3, offset: SIMD3<Float>) {
        let kg = 1.0 - c.kr - c.kb
        let yScale = fullRange ? 1.0 : 255.0 / 219.0
        let cScale = fullRange ? 1.0 : 255.0 / 224.0
        let matrix = simd_float3x3(columns: (
            SIMD3<Float>(Float(yScale), Float(yScale), Float(yScale)),
            SIMD3<Float>(0, Float(-cScale * 2 * c.kb * (1 - c.kb) / kg), Float(cScale * 2 * (1 - c.kb))),
            SIMD3<Float>(Float(cScale * 2 * (1 - c.kr)), Float(-cScale * 2 * c.kr * (1 - c.kr) / kg), 0)
        ))
        let offset = SIMD3<Float>(fullRange ? 0 : 16.0 / 255.0, 128.0 / 255.0, 128.0 / 255.0)
        return (matrix, offset)
    }
}
