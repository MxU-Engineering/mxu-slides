import Foundation

public struct ClipEnvelope: Codable, Equatable, Sendable {

    public enum Shape: String, Codable, CaseIterable, Sendable {
        case linear, sCurve, equalPower, fast, slow

        public func rising(_ x: Double, out: Bool = false) -> Double {
            let x = min(max(x, 0), 1)
            switch self {
            case .linear: return x
            case .sCurve: return 0.5 * (1 - cos(.pi * x))
            case .equalPower: return sin(.pi / 2 * x)

            case .fast: return out ? x * x : 1 - (1 - x) * (1 - x)
            case .slow: return out ? 1 - (1 - x) * (1 - x) : x * x
            }
        }
    }

    public struct Fade: Codable, Equatable, Sendable {
        public var seconds: Double
        public var shape: Shape

        public var midpoint: Double

        public init(seconds: Double, shape: Shape = .linear, midpoint: Double = 0.5) {
            self.seconds = seconds; self.shape = shape; self.midpoint = midpoint
        }

        public func level(_ x: Double, out: Bool = false) -> Double {
            let m = min(max(out ? 1 - midpoint : midpoint, 0.05), 0.95)
            let warped = m == 0.5 ? x : pow(min(max(x, 0), 1), log(0.5) / log(m))
            return shape.rising(warped, out: out)
        }
    }

    public var fadeIn: Fade?
    public var fadeOut: Fade?

    public var edge: Double
    public var edgeIn: Bool
    public var edgeOut: Bool

    public static let edgeSeconds = 0.005

    public init(fadeIn: Fade? = nil, fadeOut: Fade? = nil, edge: Double = ClipEnvelope.edgeSeconds, edgeIn: Bool = true, edgeOut: Bool = true) {
        self.fadeIn = fadeIn; self.fadeOut = fadeOut; self.edge = edge; self.edgeIn = edgeIn; self.edgeOut = edgeOut
    }

    public func gain(at t: Double, length: Double) -> Float {
        var level = 1.0
        if let fadeIn, fadeIn.seconds > 0, t < fadeIn.seconds { level *= fadeIn.level(t / fadeIn.seconds) }
        let left = length - t
        if let fadeOut, fadeOut.seconds > 0, left < fadeOut.seconds { level *= fadeOut.level(left / fadeOut.seconds, out: true) }
        if edge > 0 {
            if edgeIn, t < edge { level *= max(t, 0) / edge }
            if edgeOut, left < edge { level *= max(left, 0) / edge }
        }
        return Float(level)
    }

    func flat(from t: Double, to end: Double, length: Double) -> Bool {
        let inEnd = max(fadeIn?.seconds ?? 0, edgeIn ? edge : 0)
        let outStart = length - max(fadeOut?.seconds ?? 0, edgeOut ? edge : 0)
        return t >= inEnd && end <= outStart
    }

    func apply(_ channels: [UnsafeMutablePointer<Float>], count: Int, from t0: Double, rate: Double, length: Double) {
        guard count > 0, !flat(from: t0, to: t0 + Double(count) / rate, length: length) else { return }
        for index in 0 ..< count {
            let gain = gain(at: t0 + Double(index) / rate, length: length)
            if gain == 1 { continue }
            for channel in channels { channel[index] *= gain }
        }
    }
}
