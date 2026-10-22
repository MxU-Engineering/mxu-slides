import Accelerate
import Foundation

public struct Waveform: Equatable, Sendable {

    public static let bucketsPerSecond = 100.0

    public var bucketsPerSecond: Double
    public var mins: [Float]
    public var maxs: [Float]

    public init(bucketsPerSecond: Double = Self.bucketsPerSecond, mins: [Float], maxs: [Float]) {
        self.bucketsPerSecond = bucketsPerSecond
        self.mins = mins
        self.maxs = maxs
    }

    public var count: Int { maxs.count }
    public var seconds: Double { Double(count) / bucketsPerSecond }

    public var fillScale: Float {
        let peak = max(maxs.max() ?? 0, -(mins.min() ?? 0))
        return peak > 0 ? 1 / peak : 0
    }

    public func reduced(by factor: Int) -> Waveform {
        guard factor > 1 else { return self }
        let buckets = stride(from: 0, to: count, by: factor)
        return Waveform(
            bucketsPerSecond: bucketsPerSecond / Double(factor),
            mins: buckets.map { mins[$0..<min($0 + factor, count)].min() ?? 0 },
            maxs: buckets.map { maxs[$0..<min($0 + factor, count)].max() ?? 0 })
    }

    private static let magic = Data("MXW1".utf8)

    public var encoded: Data {
        var data = Self.magic
        withUnsafeBytes(of: bucketsPerSecond) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: Int64(count)) { data.append(contentsOf: $0) }
        mins.withUnsafeBytes { data.append(contentsOf: $0) }
        maxs.withUnsafeBytes { data.append(contentsOf: $0) }
        return data
    }

    public init?(encoded data: Data) {
        let header = Self.magic.count + 16
        guard data.count >= header, data.prefix(Self.magic.count) == Self.magic else { return nil }
        let bytes = [UInt8](data)
        let rate = bytes[4..<12].withUnsafeBytes { $0.loadUnaligned(as: Double.self) }
        let count = Int(bytes[12..<20].withUnsafeBytes { $0.loadUnaligned(as: Int64.self) })
        let size = count * MemoryLayout<Float>.size
        guard rate > 0, count >= 0, bytes.count == header + size * 2 else { return nil }
        let floats = { (from: Int) in
            bytes[from..<from + size].withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        }
        self.init(bucketsPerSecond: rate, mins: floats(header), maxs: floats(header + size))
    }
}

public struct WaveformBucketer {
    private let framesPerBucket: Double
    private let bucketsPerSecond: Double
    private var mins: [Float] = []
    private var maxs: [Float] = []
    private var low = Float.infinity
    private var high = -Float.infinity

    private var frames = 0

    public init(sampleRate: Double, bucketsPerSecond: Double = Waveform.bucketsPerSecond) {
        framesPerBucket = sampleRate / bucketsPerSecond
        self.bucketsPerSecond = bucketsPerSecond
    }

    public mutating func add(_ channels: [UnsafeBufferPointer<Float>], frameCount: Int) {
        var start = 0
        while start < frameCount {

            let remaining = max(Int((Double(mins.count + 1) * framesPerBucket).rounded()) - frames, 1)
            let take = min(remaining, frameCount - start)
            for channel in channels {
                guard let base = channel.baseAddress else { continue }
                var lo: Float = 0
                var hi: Float = 0
                vDSP_minv(base + start, 1, &lo, vDSP_Length(take))
                vDSP_maxv(base + start, 1, &hi, vDSP_Length(take))
                low = min(low, lo)
                high = max(high, hi)
            }
            frames += take
            start += take
            if take == remaining { closeBucket() }
        }
    }

    private mutating func closeBucket() {
        mins.append(low.isFinite ? low : 0)
        maxs.append(high.isFinite ? high : 0)
        low = .infinity
        high = -.infinity
    }

    public func finished() -> Waveform {
        var done = self
        if done.low.isFinite { done.closeBucket() }
        return Waveform(bucketsPerSecond: bucketsPerSecond, mins: done.mins, maxs: done.maxs)
    }
}

public struct WaveformPart: Sendable {
    public var waveform: Waveform
    public var at: Double
    public var inPoint: Double
    public var duration: Double?

    public init(waveform: Waveform, at: Double, inPoint: Double = 0, duration: Double? = nil) {
        self.waveform = waveform
        self.at = at
        self.inPoint = inPoint
        self.duration = duration
    }
}

public enum Waveforms {

    public static func combined(_ parts: [WaveformPart], from origin: Double, length: Double) -> Waveform {
        let rate = parts.first?.waveform.bucketsPerSecond ?? Waveform.bucketsPerSecond
        let count = max(Int((length * rate).rounded(.up)), 0)
        var highs = [Float](repeating: 0, count: count)
        var lows = [Float](repeating: 0, count: count)
        for part in parts {
            let wave = part.waveform
            let playEnd = part.at + min(part.duration ?? .infinity, wave.seconds - part.inPoint)
            let first = max(Int(((part.at - origin) * rate).rounded(.down)), 0)
            let last = min(Int(((playEnd - origin) * rate).rounded(.up)), count)
            guard first < last else { continue }
            for index in first..<last {
                let time = origin + Double(index) / rate - part.at + part.inPoint
                let source = Int((time * wave.bucketsPerSecond).rounded(.down))
                guard source >= 0, source < wave.count else { continue }
                highs[index] += wave.maxs[source] * wave.maxs[source]
                lows[index] += wave.mins[source] * wave.mins[source]
            }
        }
        return Waveform(bucketsPerSecond: rate, mins: lows.map { -$0.squareRoot() }, maxs: highs.map { $0.squareRoot() })
    }

    public static func drawnWindow(visibleMinX: Double, visibleWidth: Double) -> ClosedRange<Double> {
        let step = max(visibleWidth / 2, 64)
        let margin = max(visibleWidth, 128)
        let base = (visibleMinX / step).rounded(.down) * step
        return (base - margin)...(base + visibleWidth + margin)
    }
}

public struct WaveformLevels: Sendable {
    public let levels: [Waveform]
    public let fillScale: Float

    public init(_ base: Waveform) {
        var levels = [base]
        while let last = levels.last, last.bucketsPerSecond / 2 >= 1, last.count > 1 {
            levels.append(last.reduced(by: 2))
        }
        self.levels = levels
        fillScale = base.fillScale
    }

    public func level(forPointsPerSecond pointsPerSecond: Double) -> Waveform {
        levels.last { $0.bucketsPerSecond >= pointsPerSecond } ?? levels[0]
    }
}
