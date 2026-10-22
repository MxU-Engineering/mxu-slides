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

public enum SlideDropZone: Equatable, Sendable {
    case before
    case on
    case after

    public static let gutter: CGFloat = 26

    public static func tile(at point: CGPoint, width: CGFloat, reorder: Bool, insertOnly: Bool) -> SlideDropZone {
        if reorder {
            width > 0 && point.x > width / 2 ? .after : .before
        } else if point.x < gutter {
            .before
        } else if width > gutter * 3 && point.x > width - gutter {
            .after
        } else if insertOnly {
            .before
        } else {
            .on
        }
    }

    public static func row(at point: CGPoint, size: CGSize, insertOnly: Bool) -> SlideDropZone {
        let band = min(10, size.height / 4)
        return if point.x < gutter || point.y < band {
            .before
        } else if size.height > 0 && point.y > size.height - band {
            .after
        } else if insertOnly {
            .before
        } else {
            .on
        }
    }
}
