import Foundation

public struct DirectInputBacklog: Equatable, Sendable {
    public static let jumpSeconds = 0.1
    public static let windowSeconds = 10.0

    public struct Window: Equatable, Sendable {
        public var offsetLow: Double?
        public var offsetHigh: Double?
        public var queuedAudioFrames = 0
        public var queuedVideoFrames = 0
        public var stampAge = 0.0

        public var staleStamps = 0
        public var droppedPictures: Int64 = 0

        public var summary: String {
            let offset = offsetLow.map { low in
                String(format: "cardAV=%+.3f..%+.3fs ", low, offsetHigh ?? low)
            } ?? ""
            return offset
                + "queued=a\(queuedAudioFrames * 1000 / 48_000)ms/v\(queuedVideoFrames) "
                + "stampAge=\(Int(stampAge * 1000))ms stale=\(staleStamps) drops=\(droppedPictures)"
        }
    }

    private var windowStart = -Double.infinity
    private var current = Window()
    private var droppedBefore: Int64?

    private var settledOffset: Double?

    public private(set) var last: Window?

    public init() {}

    public mutating func record(
        audioMinusVideo: Double?, queuedAudioFrames: Int?, queuedVideoFrames: Int?,
        stampAge: Double?, droppedPictures: Int64, at now: Double
    ) -> (from: Double, to: Double)? {
        if now - windowStart >= Self.windowSeconds {
            if windowStart.isFinite { last = current }
            windowStart = now
            current = Window()
            droppedBefore = nil
        }
        let before = droppedBefore ?? droppedPictures
        droppedBefore = before
        current.droppedPictures = droppedPictures - before
        current.queuedAudioFrames = max(current.queuedAudioFrames, queuedAudioFrames ?? 0)
        current.queuedVideoFrames = max(current.queuedVideoFrames, queuedVideoFrames ?? 0)
        if let stampAge {
            current.stampAge = max(current.stampAge, stampAge)
            if stampAge >= 1 { current.staleStamps += 1 }
        }
        guard let offset = audioMinusVideo else { return nil }
        current.offsetLow = min(current.offsetLow ?? offset, offset)
        current.offsetHigh = max(current.offsetHigh ?? offset, offset)
        guard let settled = settledOffset else {
            settledOffset = offset
            return nil
        }
        guard abs(offset - settled) >= Self.jumpSeconds else { return nil }
        settledOffset = offset
        return (settled, offset)
    }
}
