import Foundation

public enum PanelResize {
    public static func width(
        start: Double, moved: Double, leadingEdge: Bool, range: ClosedRange<Double>
    ) -> Double {
        min(max(leadingEdge ? start - moved : start + moved, range.lowerBound), range.upperBound)
    }
}
