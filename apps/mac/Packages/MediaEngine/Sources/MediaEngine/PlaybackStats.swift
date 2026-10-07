import Foundation

public struct PlaybackStats: Sendable, Equatable {
    public internal(set) var framesDisplayed = 0
    public internal(set) var framesDropped = 0

    public internal(set) var framesDroppedAtSeam = 0
    private var lastFrameSeconds: Double?

    public init() {}

    mutating func recordFrame(at seconds: Double, frameDuration: Double, loopDuration: Double?) {
        defer {
            lastFrameSeconds = seconds
            framesDisplayed += 1
        }
        guard let last = lastFrameSeconds, frameDuration > 0 else { return }
        var delta = seconds - last
        var wrapped = false
        if delta < 0, let loopDuration, loopDuration > 0 {
            delta += loopDuration
            wrapped = true
        }
        guard delta > 0 else { return }
        let sourceFramesElapsed = Int((delta / frameDuration).rounded())
        if sourceFramesElapsed > 1 {
            framesDropped += sourceFramesElapsed - 1
            if wrapped { framesDroppedAtSeam += sourceFramesElapsed - 1 }
        }
    }

    mutating func noteSeek() {
        lastFrameSeconds = nil
    }

    public static func + (lhs: PlaybackStats, rhs: PlaybackStats) -> PlaybackStats {
        var sum = PlaybackStats()
        sum.framesDisplayed = lhs.framesDisplayed + rhs.framesDisplayed
        sum.framesDropped = lhs.framesDropped + rhs.framesDropped
        sum.framesDroppedAtSeam = lhs.framesDroppedAtSeam + rhs.framesDroppedAtSeam
        return sum
    }
}
