import CoreGraphics
import Foundation

public struct OutputPlacement: Codable, Equatable, Sendable {

    public var frameWidth: Int
    public var frameHeight: Int

    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(
        frameWidth: Int, frameHeight: Int,
        x: Double, y: Double, width: Double, height: Double
    ) {
        self.frameWidth = frameWidth
        self.frameHeight = frameHeight
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var unitRect: CGRect {
        let w = Double(max(frameWidth, 1))
        let h = Double(max(frameHeight, 1))
        return CGRect(x: x / w, y: y / h, width: width / w, height: height / h)
    }

    public var isFill: Bool {
        let unit = unitRect
        return abs(unit.minX) < 0.0001 && abs(unit.minY) < 0.0001
            && abs(unit.width - 1) < 0.0001 && abs(unit.height - 1) < 0.0001
    }
}

public struct OutputSliceState: Identifiable, Equatable, Sendable {
    public let id: UUID

    public var name: String?

    public var sourceRect: CGRect

    public init(id: UUID, name: String?, sourceRect: CGRect) {
        self.id = id
        self.name = name
        self.sourceRect = sourceRect
    }
}
