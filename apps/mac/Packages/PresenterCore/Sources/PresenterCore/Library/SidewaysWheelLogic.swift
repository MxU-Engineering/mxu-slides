import Foundation

public enum SidewaysWheelLogic {

    public static let pointsPerNotch: Double = 30

    public static func sidewaysTravel(
        deltaX: Double,
        deltaY: Double,
        precise: Bool,
        contentWidth: Double,
        visibleWidth: Double
    ) -> Double? {
        guard !precise, deltaX == 0, deltaY != 0 else { return nil }
        guard contentWidth > visibleWidth else { return nil }

        return -deltaY * pointsPerNotch
    }

    public static func clampedOrigin(
        current: Double,
        travel: Double,
        contentWidth: Double,
        visibleWidth: Double
    ) -> Double {
        let maxOrigin = max(0, contentWidth - visibleWidth)
        return min(maxOrigin, max(0, current + travel))
    }
}
