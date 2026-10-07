import Foundation

public enum MixerStripLayout {

    public static let minimumFaderHeight: Double = 92

    public static let fixedChrome: Double = 225

    public static func faderHeight(viewportHeight: Double, scrollerHeight: Double) -> Double {
        guard viewportHeight > 0 else { return minimumFaderHeight }
        return max(minimumFaderHeight, viewportHeight - fixedChrome - scrollerHeight)
    }

    public static let grabBarReach: Double = 4

    public static func grabBarY(_ y: Double, barMinY: Double, barMaxY: Double) -> Double {
        min(max(y, barMinY + 1), barMaxY - 1)
    }
}
