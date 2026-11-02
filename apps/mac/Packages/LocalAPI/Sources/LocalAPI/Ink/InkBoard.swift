import Foundation

public struct InkStroke: Equatable, Sendable {
    public var id: String
    public var colorHex: String

    public var width: Double
    public var alpha: Double
    public var roundCap: Bool

    public var glow: Double
    public var erase: Bool

    public var points: [Double]
    public var isOpen: Bool

    public init(
        id: String, colorHex: String, width: Double, alpha: Double = 1,
        roundCap: Bool = true, glow: Double = 0, erase: Bool = false,
        points: [Double] = [], isOpen: Bool = true
    ) {
        self.id = id
        self.colorHex = colorHex
        self.width = width
        self.alpha = alpha
        self.roundCap = roundCap
        self.glow = glow
        self.erase = erase
        self.points = points
        self.isOpen = isOpen
    }
}

public struct InkBoard: Equatable, Sendable {
    public static let maxStrokes = 600
    public static let maxPointsPerStroke = 40_000

    public private(set) var strokes: [InkStroke] = []
    public private(set) var hidden = false
    public private(set) var revision = 0

    public init() {}

    public var isVisible: Bool { !hidden && strokes.contains { !$0.erase && !$0.points.isEmpty } }

    public static func clamp(_ points: [Double]) -> [Double] {
        var out: [Double] = []
        out.reserveCapacity(points.count - points.count % 2)
        var index = 0
        while index + 1 < points.count {
            let x = points[index], y = points[index + 1]
            if x.isFinite, y.isFinite {
                out.append(min(1, max(0, x)))
                out.append(min(1, max(0, y)))
            }
            index += 2
        }
        return out
    }

    @discardableResult
    public mutating func begin(_ stroke: InkStroke) -> Bool {
        guard !stroke.id.isEmpty, !strokes.contains(where: { $0.id == stroke.id }) else { return false }
        var stroke = stroke
        stroke.points = Self.clamp(stroke.points)
        guard !stroke.points.isEmpty else { return false }
        stroke.isOpen = true
        strokes.append(stroke)
        if strokes.count > Self.maxStrokes {
            if let index = strokes.firstIndex(where: { !$0.isOpen }) {
                strokes.remove(at: index)
            }
        }
        revision += 1
        return true
    }

    @discardableResult
    public mutating func append(id: String, points: [Double]) -> [Double]? {
        guard let index = strokes.lastIndex(where: { $0.id == id && $0.isOpen }) else { return nil }
        let room = Self.maxPointsPerStroke - strokes[index].points.count
        guard room > 0 else { return nil }
        var added = Self.clamp(points)
        if added.count > room { added = Array(added.prefix(room - room % 2)) }
        guard !added.isEmpty else { return nil }
        strokes[index].points.append(contentsOf: added)
        revision += 1
        return added
    }

    @discardableResult
    public mutating func end(id: String) -> Bool {
        guard let index = strokes.lastIndex(where: { $0.id == id && $0.isOpen }) else { return false }
        strokes[index].isOpen = false
        revision += 1
        return true
    }

    @discardableResult
    public mutating func closeStrokes(withPrefix prefix: String) -> [String] {
        var closed: [String] = []
        for index in strokes.indices where strokes[index].isOpen && strokes[index].id.hasPrefix(prefix) {
            strokes[index].isOpen = false
            closed.append(strokes[index].id)
        }
        if !closed.isEmpty { revision += 1 }
        return closed
    }

    public mutating func clear() {
        guard !strokes.isEmpty else { return }
        strokes.removeAll()
        revision += 1
    }

    @discardableResult
    public mutating func undo() -> String? {
        guard let index = strokes.lastIndex(where: { !$0.isOpen }) else { return nil }
        let id = strokes[index].id
        strokes.remove(at: index)
        revision += 1
        return id
    }

    @discardableResult
    public mutating func setHidden(_ value: Bool) -> Bool {
        guard hidden != value else { return false }
        hidden = value
        revision += 1
        return true
    }
}
