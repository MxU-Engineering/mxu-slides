import Foundation

public struct SyncMonitorAudioTimeline: Sendable {

    public static let reanchorThreshold = 0.010

    static let smoothing = 0.05

    public struct Stamp: Equatable, Sendable {

        public var seconds: Double

        public var reanchored: Bool
    }

    private var anchor: Double?
    private var frames: Int64 = 0
    private var sampleRate = 0.0
    private var averageOffset = 0.0

    public init() {}

    public mutating func stamp(hostSeconds: Double, frameCount: Int, sampleRate: Double) -> Stamp {
        let expected = anchor.map { $0 + Double(frames) / self.sampleRate }
        let offset = expected.map { hostSeconds - $0 } ?? 0
        averageOffset += (offset - averageOffset) * Self.smoothing
        let holds = expected != nil && sampleRate == self.sampleRate
            && abs(averageOffset) <= Self.reanchorThreshold
        if !holds {
            anchor = hostSeconds
            frames = 0
            self.sampleRate = sampleRate
            averageOffset = 0
        }
        let seconds = holds ? expected ?? hostSeconds : hostSeconds
        frames += Int64(frameCount)
        return Stamp(seconds: seconds, reanchored: !holds)
    }
}
