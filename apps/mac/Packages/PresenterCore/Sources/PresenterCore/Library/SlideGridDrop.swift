import CoreGraphics

public enum SlideGridDrop {
    public enum Spot: Equatable, Sendable {
        case before(Int)
        case after(Int)

        public var insertionIndex: Int {
            switch self {
            case .before(let index): index
            case .after(let index): index + 1
            }
        }
    }

    public static func spot(
        at point: CGPoint, tileFrames: [Int: CGRect], count: Int, rowGap: CGFloat
    ) -> Spot {
        let atOrBelow = tileFrames.filter { point.y <= $0.value.maxY + rowGap / 2 }
        if let rowTop = atOrBelow.map(\.value.minY).min() {
            let row = atOrBelow.filter { abs($0.value.minY - rowTop) < 1 }
            if let before = row.filter({ point.x < $0.value.midX }).map(\.key).min() {
                return .before(before)
            } else {
                return .after(row.map(\.key).max() ?? count - 1)
            }
        } else if count > 0 {
            return .after(count - 1)
        } else {
            return .before(0)
        }
    }
}
