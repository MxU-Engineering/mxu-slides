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

    public static func typedIn(
        _ seconds: Double?, outPoint: Double?, duration: Double
    ) -> (inPoint: Double?, outPoint: Double?) {
        let start = min(max(seconds ?? 0, 0), duration)
        let keepsOut = outPoint.map { start < $0 } ?? true
        return (start > edgeSlack ? tidy(start) : nil, keepsOut ? outPoint : nil)
    }

    public static func typedOut(
        _ seconds: Double?, inPoint: Double?, duration: Double
    ) -> (inPoint: Double?, outPoint: Double?)? {
        let end = min(max(seconds ?? duration, 0), duration)
        return end > (inPoint ?? 0) + edgeSlack
            ? (inPoint, end < duration - edgeSlack ? tidy(end) : nil)
            : nil
    }

    public static func seconds(fromTimecode text: String) -> Double? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":", omittingEmptySubsequences: false)
        let numbers = parts.map { Double($0.trimmingCharacters(in: .whitespaces)) }
        return if (1 ... 3).contains(parts.count), numbers.allSatisfy({ ($0 ?? -1) >= 0 }) {
            numbers.reduce(0) { $0 * 60 + ($1 ?? 0) }
        } else {
            nil
        }
    }

    public static func timecode(_ seconds: Double) -> String {
        let total = max(0, seconds)
        let minutes = Int(total) / 60
        return String(format: "%d:%04.1f", minutes, total - Double(minutes * 60))
    }

    public static func tidy(_ seconds: Double) -> Double {
        (seconds * 100).rounded() / 100
    }
}
