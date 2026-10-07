import Foundation

enum PPTXPresetGeometry {

    static func pathData(forPreset preset: String) -> String? {
        switch preset {
        case "triangle":
            return polygonPath([(0.5, 0), (1, 1), (0, 1)])
        case "rtTriangle":
            return polygonPath([(0, 0), (0, 1), (1, 1)])
        case "diamond":
            return polygonPath([(0.5, 0), (1, 0.5), (0.5, 1), (0, 0.5)])
        case "parallelogram":
            return polygonPath([(0.25, 0), (1, 0), (0.75, 1), (0, 1)])
        case "trapezoid":
            return polygonPath([(0.25, 0), (0.75, 0), (1, 1), (0, 1)])
        case "pentagon":
            return polygonPath([(0.5, 0), (1, 0.38197), (0.80902, 1), (0.19098, 1), (0, 0.38197)])
        case "hexagon":
            return polygonPath([(0.25, 0), (0.75, 0), (1, 0.5), (0.75, 1), (0.25, 1), (0, 0.5)])
        case "octagon":
            return polygonPath([
                (0.29289, 0), (0.70711, 0), (1, 0.29289), (1, 0.70711),
                (0.70711, 1), (0.29289, 1), (0, 0.70711), (0, 0.29289),
            ])
        case "star5":

            return polygonPath([
                (0.5, 0), (0.38196, 0.38196), (0, 0.38196), (0.30902, 0.61803),
                (0.19098, 1), (0.5, 0.76393), (0.80902, 1), (0.69098, 0.61803),
                (1, 0.38196), (0.61803, 0.38196),
            ])
        case "chevron":
            return polygonPath([(0, 0), (0.75, 0), (1, 0.5), (0.75, 1), (0, 1), (0.25, 0.5)])
        case "rightArrow":
            return polygonPath([
                (0, 0.25), (0.6, 0.25), (0.6, 0), (1, 0.5), (0.6, 1), (0.6, 0.75), (0, 0.75),
            ])
        case "leftArrow":
            return polygonPath([
                (1, 0.25), (0.4, 0.25), (0.4, 0), (0, 0.5), (0.4, 1), (0.4, 0.75), (1, 0.75),
            ])
        case "upArrow":
            return polygonPath([
                (0.25, 1), (0.25, 0.4), (0, 0.4), (0.5, 0), (1, 0.4), (0.75, 0.4), (0.75, 1),
            ])
        case "downArrow":
            return polygonPath([
                (0.25, 0), (0.25, 0.6), (0, 0.6), (0.5, 1), (1, 0.6), (0.75, 0.6), (0.75, 0),
            ])
        case "line", "straightConnector1":
            return linePath
        default:
            return nil
        }
    }

    static let linePath = "M 0.0000 0.0000 C 0.0000 0.0000 1.0000 1.0000 1.0000 1.0000"

    static func format(_ value: Double) -> String {
        String(format: "%.4f", min(max(value, -4), 4))
    }

    static func coordinate(_ point: (x: Double, y: Double)) -> String {
        "\(format(point.x)) \(format(point.y))"
    }

    static func polygonPath(_ points: [(x: Double, y: Double)], closed: Bool = true) -> String {
        guard points.count >= 2 else { return "" }
        var commands = ["M \(coordinate(points[0]))"]
        for index in 1..<points.count {
            let previous = points[index - 1]
            let current = points[index]
            commands.append("C \(coordinate(previous)) \(coordinate(current)) \(coordinate(current))")
        }
        if closed, let first = points.first, let last = points.last {
            commands.append("C \(coordinate(last)) \(coordinate(first)) \(coordinate(first))")
            commands.append("Z")
        }
        return commands.joined(separator: " ")
    }
}
