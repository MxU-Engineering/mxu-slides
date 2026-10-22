import Foundation
import RenderEngine

public struct CardClock: Sendable {

    static let window = 4.0

    static let minimumSpan = 1.0

    private struct Sample {
        var completions: Int
        var time: CFTimeInterval
    }

    private var samples: [Sample] = []

    private var reported = RenderPulse.CardTiming()

    public init() {}

    public mutating func record(
        completions: Int, lastCompletion: CFTimeInterval, counters: RenderPulse.CardTiming
    ) -> RenderPulse.CardTiming {
        if let last = samples.last, completions < last.completions {
            samples.removeAll()
            reported = RenderPulse.CardTiming()
        }
        if completions > 0, samples.last?.completions != completions {
            samples.append(Sample(completions: completions, time: lastCompletion))
            samples.removeAll { lastCompletion - $0.time > Self.window }
        }
        let delta = RenderPulse.CardTiming(
            repeats: counters.repeats - reported.repeats,
            skips: counters.skips - reported.skips,
            late: counters.late - reported.late,
            dropped: counters.dropped - reported.dropped,
            jumps: counters.jumps - reported.jumps)
        reported = counters
        return delta
    }

    public var cadence: LiveCadence? {
        if let first = samples.first, let last = samples.last,
           last.time - first.time >= Self.minimumSpan {

            let count = Double(samples.count)
            let meanCount = samples.reduce(0) { $0 + Double($1.completions) } / count
            let meanTime = samples.reduce(0) { $0 + $1.time } / count
            let covariance = samples.reduce(0) {
                $0 + (Double($1.completions) - meanCount) * ($1.time - meanTime)
            }
            let variance = samples.reduce(0) {
                $0 + (Double($1.completions) - meanCount) * (Double($1.completions) - meanCount)
            }
            let period = covariance / variance
            return LiveCadence(
                lastArrival: meanTime + (Double(last.completions) - meanCount) * period,
                period: period)
        } else {
            return nil
        }
    }
}
