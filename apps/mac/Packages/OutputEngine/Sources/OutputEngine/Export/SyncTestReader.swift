import CoreVideo
import Foundation

public final class SyncTestReader: @unchecked Sendable {
    public struct Verdict: Equatable, Sendable {

        public var offsetMs: Double
        public var pairs: Int
    }

    static let gridColumns = 96
    static let gridRows = 54

    static let jump = 0.2

    static let flashRise = 2

    static let floodRatio = 3
    static let clickHertz = 1_000.0
    static let downbeatHertz = 1_500.0

    static let hopSeconds = 0.005

    static let pairWindow = 1.0
    static let keptFlashes = 16

    private let lock = NSLock()

    private var flashes: [(at: Double, size: Int)] = []
    private var clicks: [Double] = []
    private var wasFlashing = false

    private var reference: [Double]?
    private var hop: [Float] = []
    private var hopStart = 0.0
    private var floorPower = 0.0
    private var wasLoud = false
    private var quietHops = 0

    public init() {}

    public static func gridLuma(_ pixelBuffer: CVPixelBuffer) -> [Double]? {
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA else { return nil }
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let pixels = base.assumingMemoryBound(to: UInt8.self)
        var lumas = [Double](repeating: 0, count: gridRows * gridColumns)
        for row in 0..<gridRows {
            let y = min(height - 1, (row * 2 + 1) * height / (gridRows * 2))
            for column in 0..<gridColumns {
                let x = min(width - 1, (column * 2 + 1) * width / (gridColumns * 2))
                let pixel = pixels + y * rowBytes + x * 4
                lumas[row * gridColumns + column] =
                    (0.0722 * Double(pixel[0]) + 0.7152 * Double(pixel[1]) + 0.2126 * Double(pixel[2])) / 255
            }
        }
        return lumas
    }

    public func picture(hostSeconds: Double, lumas: [Double]) {
        lock.withLock {
            let jumped = reference.map { reference in
                reference.count == lumas.count
                    ? zip(lumas, reference).reduce(0) { $0 + ($1.0 - $1.1 >= Self.jump ? 1 : 0) }
                    : 0
            } ?? 0
            let flashing = jumped >= Self.flashRise
            if flashing, !wasFlashing {
                flashes.append((hostSeconds, jumped))
                if flashes.count > Self.keptFlashes { flashes.removeFirst(flashes.count - Self.keptFlashes) }
            }
            wasFlashing = flashing

            if !flashing { reference = lumas }
        }
    }

    public func sound(startSeconds: Double, samples: [Float], sampleRate: Double) {
        lock.withLock {
            let hopFrames = max(1, Int(Self.hopSeconds * sampleRate))
            var cursor = 0
            if hop.isEmpty { hopStart = startSeconds }
            while cursor < samples.count {
                let take = min(hopFrames - hop.count, samples.count - cursor)
                hop.append(contentsOf: samples[cursor..<(cursor + take)])
                cursor += take
                if hop.count == hopFrames {
                    finishHop(sampleRate: sampleRate)
                    hopStart = startSeconds + Double(cursor) / sampleRate
                }
            }
        }
    }

    private func finishHop(sampleRate: Double) {
        let downbeat = Self.tonePower(hop, hertz: Self.downbeatHertz, sampleRate: sampleRate)
        let click = Self.tonePower(hop, hertz: Self.clickHertz, sampleRate: sampleRate)
        hop.removeAll(keepingCapacity: true)

        let loud = downbeat > max(floorPower * 8, 1e-7) && downbeat > click * 3

        if loud, !wasLoud, quietHops >= 10 {
            clicks.append(hopStart)
            if clicks.count > Self.keptFlashes * 2 { clicks.removeFirst(clicks.count - Self.keptFlashes * 2) }
        }
        quietHops = loud ? 0 : quietHops + 1
        wasLoud = loud
        if !loud { floorPower += (downbeat - floorPower) * 0.05 }
    }

    static func tonePower(_ samples: [Float], hertz: Double, sampleRate: Double) -> Double {
        let coefficient = 2 * cos(2 * .pi * hertz / sampleRate)
        var previous = 0.0, beforeThat = 0.0
        for sample in samples {
            let next = Double(sample) + coefficient * previous - beforeThat
            beforeThat = previous
            previous = next
        }
        let power = previous * previous + beforeThat * beforeThat - coefficient * previous * beforeThat
        return power / Double(max(samples.count, 1) * max(samples.count, 1))
    }

    var downbeats: [Double] {
        let flashes = lock.withLock { self.flashes }
        let smallest = flashes.map(\.size).min() ?? 0
        let largest = flashes.map(\.size).max() ?? 0
        return largest >= smallest * Self.floodRatio
            ? flashes.filter { $0.size >= smallest * Self.floodRatio }.map(\.at)
            : flashes.map(\.at)
    }

    public var verdict: Verdict? {
        let flashes = downbeats
        let clicks = lock.withLock { self.clicks }
        let offsets = flashes.compactMap { flash -> Double? in
            clicks.map { $0 - flash }.filter { abs($0) <= Self.pairWindow }
                .min { abs($0) < abs($1) }
        }.sorted()
        if offsets.count >= 2 {
            return Verdict(offsetMs: offsets[offsets.count / 2] * 1000, pairs: offsets.count)
        } else {
            return nil
        }
    }
}
