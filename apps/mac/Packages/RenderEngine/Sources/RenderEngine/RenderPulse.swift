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
