import Foundation

public final class RenderPulse: @unchecked Sendable {
    public static let shared = RenderPulse()

    public struct Snapshot: Sendable {
        public var placeholderFrames = 0
        public var placeholderSkips = 0
        public var placeholderEncodeMS = 0.0
        public var mirrorFrames = 0
        public var mirrorResends = 0
        public var mirrorDrops = 0
        public var mirrorReadbackMS = 0.0
        public var mirrorConvertMS = 0.0
        public var textRasterizations = 0
        public var textRasterizeMS = 0.0
        public var hitches = 0
        public var worstHitchMS = 0.0

        public var captureFrames: [String: Int] = [:]

        public var mirrorSteeredTicks = 0
        public var mirrorClosestEdgeMS = Double.infinity

        public var mirrorEdgeMSTotal = 0.0
        public var mirrorNearEdgeTicks = 0

        public var cardTimings: [String: CardTiming] = [:]
    }

    public struct CardTiming: Equatable, Sendable {

        public var repeats = 0
        public var skips = 0

        public var late = 0
        public var dropped = 0

        public var jumps = 0

        public var held = 0

        public init(
            repeats: Int = 0, skips: Int = 0, late: Int = 0, dropped: Int = 0,
            jumps: Int = 0, held: Int = 0
        ) {
            self.repeats = repeats
            self.skips = skips
            self.late = late
            self.dropped = dropped
            self.jumps = jumps
            self.held = held
        }

        static func + (lhs: CardTiming, rhs: CardTiming) -> CardTiming {
            CardTiming(
                repeats: lhs.repeats + rhs.repeats, skips: lhs.skips + rhs.skips,
                late: lhs.late + rhs.late, dropped: lhs.dropped + rhs.dropped,
                jumps: lhs.jumps + rhs.jumps, held: lhs.held + rhs.held)
        }
    }

    private let state = Locked(Snapshot())

    public func placeholderFrame(encodeMS: Double) {
        state.withLock {
            $0.placeholderFrames += 1
            $0.placeholderEncodeMS += encodeMS
        }
    }

    public func placeholderSkip() {
        state.withLock { $0.placeholderSkips += 1 }
    }

    public func mirrorResend() {
        state.withLock { $0.mirrorResends += 1 }
    }

    public func mirrorFrame(readbackMS: Double, convertMS: Double) {
        state.withLock {
            $0.mirrorFrames += 1
            $0.mirrorReadbackMS += readbackMS
            $0.mirrorConvertMS += convertMS
        }
    }

    public func mirrorDrop() {
        state.withLock { $0.mirrorDrops += 1 }
    }

    public func textRasterized(ms: Double) {
        state.withLock {
            $0.textRasterizations += 1
            $0.textRasterizeMS += ms
        }
    }

    public func hitch(ms: Double) {
        state.withLock {
            $0.hitches += 1
            $0.worstHitchMS = max($0.worstHitchMS, ms)
        }
    }

    public func mirrorSteered(edgeDistanceMS: Double, periodMS: Double) {
        state.withLock {
            $0.mirrorSteeredTicks += 1
            $0.mirrorClosestEdgeMS = min($0.mirrorClosestEdgeMS, edgeDistanceMS)
            $0.mirrorEdgeMSTotal += edgeDistanceMS
            if edgeDistanceMS < periodMS / 10 { $0.mirrorNearEdgeTicks += 1 }
        }
    }

    public func cardTiming(device: String, _ delta: CardTiming) {
        state.withLock { snapshot in
            snapshot.cardTimings[device] = snapshot.cardTimings[device, default: CardTiming()] + delta
        }
    }

    public func captureFrame(source: String) {
        state.withLock { $0.captureFrames[source, default: 0] += 1 }
    }

    public func drain() -> Snapshot {
        state.withLock { current in
            defer { current = Snapshot() }
            return current
        }
    }
}
