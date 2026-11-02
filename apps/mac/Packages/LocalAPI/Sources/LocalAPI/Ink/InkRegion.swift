import Foundation

public struct InkRegion: Equatable, Sendable {
    public static let full = InkRegion(x: 0, y: 0, width: 1, height: 1)

    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        let w = min(1, max(0.02, width.isFinite ? width : 1))
        let h = min(1, max(0.02, height.isFinite ? height : 1))
        self.width = w
        self.height = h
        self.x = min(1 - w, max(0, x.isFinite ? x : 0))
        self.y = min(1 - h, max(0, y.isFinite ? y : 0))
    }

    public var isFull: Bool { self == .full }

    public func clamp(_ points: [Double]) -> [Double] {
        var out = points
        var index = 0
        while index + 1 < out.count {
            out[index] = min(x + width, max(x, out[index]))
            out[index + 1] = min(y + height, max(y, out[index + 1]))
            index += 2
        }
        return out
    }
}
