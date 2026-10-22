import Foundation

public enum MediaAutoAdvance {

    public static func leadSeconds(fromDelay delay: Double) -> Double {
        max(0, -delay)
    }

    public static func shouldPreFire(remainingWallClock: Double, delay: Double) -> Bool {
        let lead = leadSeconds(fromDelay: delay)
        return lead > 0 && remainingWallClock <= lead
    }
}
