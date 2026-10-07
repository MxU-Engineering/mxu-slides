import Foundation

public struct CaptureFormatChoice: Equatable, Sendable {

    public struct Candidate: Equatable, Sendable {
        public var index: Int
        public var width: Int
        public var height: Int
        public var subtype: UInt32

        public var frameRates: [Double]

        public init(index: Int, width: Int, height: Int, subtype: UInt32, frameRates: [Double]) {
            self.index = index
            self.width = width
            self.height = height
            self.subtype = subtype
            self.frameRates = frameRates
        }
    }

    public var index: Int
    public var frameRate: Double

    static let ceiling = 60.5

    public static func sharedRates(_ picks: [(device: String, rate: Double?)]) -> [String: Double] {
        picks.reduce(into: [:]) { shared, pick in
            if let rate = pick.rate, shared[pick.device] == nil { shared[pick.device] = rate }
        }
    }

    public static func rates(among candidates: [Candidate], active: Candidate) -> [Double] {
        let offered = candidates
            .filter { $0.width == active.width && $0.height == active.height }
            .flatMap(\.frameRates)
            .filter { $0 > 0 && $0 <= ceiling }
        return Array(Set(offered.map { ($0 * 100).rounded() / 100 })).sorted()
    }

    public static func best(
        among candidates: [Candidate], active: Candidate, preferred: Double? = nil
    ) -> CaptureFormatChoice? {
        let ranked = candidates
            .filter { $0.width == active.width && $0.height == active.height }
            .flatMap { candidate in
                candidate.frameRates
                    .filter { $0 > 0 && $0 <= ceiling }
                    .map { Ranked(candidate: candidate, frameRate: $0, active: active) }
            }
        let picked = ranked.filter { entry in
            preferred.map { abs(entry.frameRate - $0) < 0.01 } ?? false
        }
        return (picked.isEmpty ? ranked : picked).max(by: { $0.key.lexicographicallyPrecedes($1.key) })
            .map { CaptureFormatChoice(index: $0.candidate.index, frameRate: $0.frameRate) }
    }

    private struct Ranked {
        var candidate: Candidate
        var frameRate: Double
        var key: [Int]

        init(candidate: Candidate, frameRate: Double, active: Candidate) {
            self.candidate = candidate
            self.frameRate = frameRate
            let rateClass = Int(frameRate.rounded())
            key = [
                rateClass == 30 ? 1 : 0,
                rateClass,
                frameRate < Double(rateClass) ? 1 : 0,
                candidate.subtype == active.subtype ? 1 : 0,
                -candidate.index,
            ]
        }
    }
}
