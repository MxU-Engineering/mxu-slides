import Accelerate
import Foundation

final class MultitrackVarispeed: @unchecked Sendable {
    static let taps = 32
    static let phases = 256

    nonisolated(unsafe) static let kernel: UnsafeMutablePointer<Float> = {
        let table = UnsafeMutablePointer<Float>.allocate(capacity: (phases + 1) * taps)
        let cutoff = 0.9, beta = 8.0
        func i0(_ x: Double) -> Double {
            var sum = 1.0, term = 1.0
            for k in 1 ..< 40 {
                term *= (x / 2) * (x / 2) / Double(k * k)
                sum += term
            }
            return sum
        }
        for p in 0 ... phases {
            let fraction = Double(p) / Double(phases)
            var row = (0 ..< taps).map { m -> Double in
                let u = 15 + fraction - Double(m)
                guard abs(u) < 16 else { return 0 }
                let sinc = u == 0 ? 1 : sin(.pi * cutoff * u) / (.pi * cutoff * u)
                return cutoff * sinc * i0(beta * (1 - (u / 16) * (u / 16)).squareRoot()) / i0(beta)
            }
            let sum = row.reduce(0, +)
            row = row.map { $0 / sum }
            for m in 0 ..< taps { table[p * taps + m] = Float(row[m]) }
        }
        return table
    }()

    private let stems: Int
    private let stride: Int

    private let windows: UnsafeMutablePointer<Float>

    private let kernels: UnsafeMutablePointer<Float>
    private let bases: UnsafeMutablePointer<Int>
    private var fraction: Double = 0
    private var primed = false

    init(stems: Int, maxFrames: Int) {
        _ = Self.kernel
        self.stems = stems
        stride = Self.taps + maxFrames * 2 + 8
        windows = .allocate(capacity: max(1, stems * 2 * stride))
        windows.initialize(repeating: 0, count: max(1, stems * 2 * stride))
        kernels = .allocate(capacity: maxFrames * Self.taps)
        bases = .allocate(capacity: maxFrames)
    }

    deinit { windows.deallocate(); kernels.deallocate(); bases.deallocate() }

    func plan(count: Int, speed: Double) -> Int {
        for j in 0 ..< count {
            let t = fraction + Double(j) * speed
            let base = Int(t)
            let phase = (t - Double(base)) * Double(Self.phases)
            let p = min(Int(phase), Self.phases - 1)
            var a = Float(phase - Double(p))
            let low = Self.kernel + p * Self.taps
            vDSP_vintb(low, 1, low + Self.taps, 1, &a, kernels + j * Self.taps, 1, vDSP_Length(Self.taps))
            bases[j] = base
        }
        return Int(fraction + Double(count) * speed)
    }

    func render(stem: Int, ring: StemRing, count: Int, advance: Int, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>) {
        let windowLeft = windows + stem * 2 * stride, windowRight = windowLeft + stride
        if !primed {

            ring.read(into: windowLeft + 15, windowRight + 15, count: Self.taps - 15)
        }
        ring.read(into: windowLeft + Self.taps, windowRight + Self.taps, count: advance)
        convolve(windowLeft, into: left, count: count)
        convolve(windowRight, into: right, count: count)
        memmove(windowLeft, windowLeft + advance, Self.taps * MemoryLayout<Float>.size)
        memmove(windowRight, windowRight + advance, Self.taps * MemoryLayout<Float>.size)
    }

    func finish(count: Int, speed: Double, advance: Int) {
        fraction = fraction + Double(count) * speed - Double(advance)
        primed = true
    }

    private func convolve(_ window: UnsafeMutablePointer<Float>, into output: UnsafeMutablePointer<Float>, count: Int) {
        for j in 0 ..< count {
            vDSP_dotpr(window + bases[j], 1, kernels + j * Self.taps, 1, output + j, vDSP_Length(Self.taps))
        }
    }
}
