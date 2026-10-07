import Foundation

public enum SlidesAcross {
    public static let key = "slideGrid.slidesAcross"
    public static let range = 1 ... 6

    public static let fallback = 4

    public static func clamped(_ count: Int) -> Int {
        min(max(count, range.lowerBound), range.upperBound)
    }

    public static func cell(
        width: CGFloat, across: Int, spacing: CGFloat, aspect: CGFloat, labelGap: CGFloat, labelHeight: CGFloat
    ) -> CGSize? {
        let across = clamped(across)
        let tileWidth = ((width - spacing * CGFloat(across - 1)) / CGFloat(across)).rounded(.down)
        if tileWidth > 0, aspect > 0 {
            return CGSize(width: tileWidth, height: (tileWidth / aspect).rounded(.up) + labelGap + labelHeight)
        } else {
            return nil
        }
    }

    public static func nearRows(
        gridTop: CGFloat, rowPitch: CGFloat, rowCount: Int, viewport: CGFloat, margin: CGFloat
    ) -> Range<Int> {
        if rowPitch > 0, rowCount > 0 {
            let first = Int(((-gridTop - margin) / rowPitch).rounded(.down))
            let last = Int(((-gridTop + viewport + margin) / rowPitch).rounded(.down))
            let lower = min(max(first, 0), rowCount)
            let upper = min(max(last + 1, 0), rowCount)
            return lower < upper ? lower ..< upper : 0 ..< 0
        } else {
            return 0 ..< 0
        }
    }

    public static func tileAspect(canvas: CGSize) -> CGFloat {
        if canvas.width > 0, canvas.height > 0 {
            canvas.width / canvas.height
        } else {
            16 / 9
        }
    }

    public struct Row: Equatable, Sendable {
        public let indices: Range<Int>
        public let fillers: Int
    }

    public static func rows(count: Int, across: Int) -> [Row] {
        let across = clamped(across)
        return stride(from: 0, to: max(count, 0), by: across).map { start in
            let end = min(start + across, count)
            return Row(indices: start ..< end, fillers: across - (end - start))
        }
    }
}
