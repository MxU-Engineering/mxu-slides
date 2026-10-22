import Foundation

public enum MediaTrimEdit {

    public static let edgeSlack = 0.05

    public static func window(inPoint: Double?, outPoint: Double?, duration: Double) -> ClosedRange<Double>? {
        let start = max(inPoint ?? 0, 0)
        let end = min(outPoint ?? duration, duration)
        return (start > edgeSlack || end < duration - edgeSlack) && end > start ? start ... end : nil
    }

    public static func fractions(inPoint: Double?, outPoint: Double?, duration: Double) -> ClosedRange<Double>? {
        if duration > 0, let window = window(inPoint: inPoint, outPoint: outPoint, duration: duration) {
            window.lowerBound / duration ... window.upperBound / duration
        } else {
            nil
        }
    }

    public static func points(
        fractions range: ClosedRange<Double>, duration: Double
    ) -> (inPoint: Double?, outPoint: Double?) {
        let start = range.lowerBound * duration
        let end = range.upperBound * duration
        return (start > edgeSlack ? tidy(start) : nil, end < duration - edgeSlack ? tidy(end) : nil)
    }

    public static func tidy(_ seconds: Double) -> Double {
        (seconds * 100).rounded() / 100
    }
}
