import Foundation

public struct IconShape: Identifiable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var pathData: String
}

public enum IconCatalog {
    public static let all: [IconShape] = [
        IconShape(id: "search", name: "Search", pathData: search),
        IconShape(id: "cross", name: "Cross", pathData: cross),
        IconShape(id: "heart", name: "Heart", pathData: heart),
        IconShape(id: "check", name: "Check", pathData: check),
        IconShape(id: "arrow", name: "Arrow", pathData: arrow),
        IconShape(id: "play", name: "Play", pathData: play),
        IconShape(id: "pin", name: "Location Pin", pathData: pin),
        IconShape(id: "star", name: "Star", pathData: star),
        IconShape(id: "ring", name: "Ring", pathData: ring(cx: 0.5, cy: 0.5, outer: 0.5, inner: 0.38)),
        IconShape(id: "dot", name: "Dot", pathData: circle(cx: 0.5, cy: 0.5, r: 0.5)),
        IconShape(id: "chat", name: "Chat Bubble", pathData: chat),
        IconShape(id: "calendar", name: "Calendar", pathData: calendar),
        IconShape(id: "clock", name: "Clock", pathData: clock),
        IconShape(id: "bell", name: "Bell", pathData: bell),
        IconShape(id: "music", name: "Music Note", pathData: music),
        IconShape(id: "mail", name: "Mail", pathData: mail),
    ]

    public static func shape(id: String) -> IconShape? { all.first { $0.id == id } }

    public static func icon(matching pathData: String?) -> IconShape? {
        guard let pathData else { return nil }
        return all.first { $0.pathData == pathData }
    }

    private static func f(_ v: Double) -> String { String(format: "%.4f", v) }
    private static let kappa = 0.5522847498

    static func circle(cx: Double, cy: Double, r: Double, clockwise: Bool = true) -> String {
        let k = kappa * r
        let s = clockwise ? 1.0 : -1.0

        return "M \(f(cx + r)) \(f(cy)) "
            + "C \(f(cx + r)) \(f(cy + s * k)) \(f(cx + k)) \(f(cy + s * r)) \(f(cx)) \(f(cy + s * r)) "
            + "C \(f(cx - k)) \(f(cy + s * r)) \(f(cx - r)) \(f(cy + s * k)) \(f(cx - r)) \(f(cy)) "
            + "C \(f(cx - r)) \(f(cy - s * k)) \(f(cx - k)) \(f(cy - s * r)) \(f(cx)) \(f(cy - s * r)) "
            + "C \(f(cx + k)) \(f(cy - s * r)) \(f(cx + r)) \(f(cy - s * k)) \(f(cx + r)) \(f(cy)) Z"
    }

    static func ring(cx: Double, cy: Double, outer: Double, inner: Double) -> String {
        circle(cx: cx, cy: cy, r: outer) + " " + circle(cx: cx, cy: cy, r: inner, clockwise: false)
    }

    static func polygon(_ points: [(Double, Double)]) -> String {
        guard let first = points.first else { return "" }
        return "M \(f(first.0)) \(f(first.1)) " + points.dropFirst().map { "L \(f($0.0)) \(f($0.1))" }.joined(separator: " ") + " Z"
    }

    static func bar(from a: (Double, Double), to b: (Double, Double), width: Double) -> String {
        let dx = b.0 - a.0, dy = b.1 - a.1
        let len = max((dx * dx + dy * dy).squareRoot(), 1e-6)
        let nx = -dy / len * width / 2, ny = dx / len * width / 2
        return polygon([(a.0 + nx, a.1 + ny), (b.0 + nx, b.1 + ny), (b.0 - nx, b.1 - ny), (a.0 - nx, a.1 - ny)])
    }

    static func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double, clockwise: Bool = true) -> String {
        clockwise ? polygon([(x, y), (x + w, y), (x + w, y + h), (x, y + h)]) : polygon([(x, y), (x, y + h), (x + w, y + h), (x + w, y)])
    }

    static func roundedRect(_ x: Double, _ y: Double, _ w: Double, _ h: Double, r: Double, clockwise: Bool = true) -> String {
        let k = kappa * r
        let cw = "M \(f(x + r)) \(f(y)) L \(f(x + w - r)) \(f(y)) C \(f(x + w - r + k)) \(f(y)) \(f(x + w)) \(f(y + r - k)) \(f(x + w)) \(f(y + r)) "
            + "L \(f(x + w)) \(f(y + h - r)) C \(f(x + w)) \(f(y + h - r + k)) \(f(x + w - r + k)) \(f(y + h)) \(f(x + w - r)) \(f(y + h)) "
            + "L \(f(x + r)) \(f(y + h)) C \(f(x + r - k)) \(f(y + h)) \(f(x)) \(f(y + h - r + k)) \(f(x)) \(f(y + h - r)) "
            + "L \(f(x)) \(f(y + r)) C \(f(x)) \(f(y + r - k)) \(f(x + r - k)) \(f(y)) \(f(x + r)) \(f(y)) Z"
        if clockwise { return cw }
        return "M \(f(x + r)) \(f(y)) C \(f(x + r - k)) \(f(y)) \(f(x)) \(f(y + r - k)) \(f(x)) \(f(y + r)) L \(f(x)) \(f(y + h - r)) "
            + "C \(f(x)) \(f(y + h - r + k)) \(f(x + r - k)) \(f(y + h)) \(f(x + r)) \(f(y + h)) L \(f(x + w - r)) \(f(y + h)) "
            + "C \(f(x + w - r + k)) \(f(y + h)) \(f(x + w)) \(f(y + h - r + k)) \(f(x + w)) \(f(y + h - r)) L \(f(x + w)) \(f(y + r)) "
            + "C \(f(x + w)) \(f(y + r - k)) \(f(x + w - r + k)) \(f(y)) \(f(x + w - r)) \(f(y)) Z"
    }

    static let search = ring(cx: 0.4, cy: 0.4, outer: 0.36, inner: 0.26) + " " + bar(from: (0.66, 0.66), to: (0.94, 0.94), width: 0.14)

    static let cross = rect(0.4, 0, 0.2, 1) + " " + rect(0.08, 0.26, 0.84, 0.2)

    static let heart =
        "M 0.5 0.95 C 0.5 0.95 0.02 0.62 0.02 0.32 C 0.02 0.14 0.16 0.04 0.3 0.04 C 0.4 0.04 0.47 0.1 0.5 0.18 "
        + "C 0.53 0.1 0.6 0.04 0.7 0.04 C 0.84 0.04 0.98 0.14 0.98 0.32 C 0.98 0.62 0.5 0.95 0.5 0.95 Z"

    static let check = polygon([(0.06, 0.55), (0.2, 0.41), (0.4, 0.61), (0.8, 0.2), (0.94, 0.34), (0.4, 0.88)])

    static let arrow = polygon([(0.04, 0.42), (0.58, 0.42), (0.58, 0.2), (0.96, 0.5), (0.58, 0.8), (0.58, 0.58), (0.04, 0.58)])

    static let play = polygon([(0.14, 0.04), (0.94, 0.5), (0.14, 0.96)])

    static let pin =
        "M 0.5 0.98 C 0.5 0.98 0.12 0.6 0.12 0.38 C 0.12 0.17 0.29 0.02 0.5 0.02 C 0.71 0.02 0.88 0.17 0.88 0.38 C 0.88 0.6 0.5 0.98 0.5 0.98 Z "
        + circle(cx: 0.5, cy: 0.38, r: 0.14, clockwise: false)

    static let star: String = {
        var points: [(Double, Double)] = []
        for i in 0..<10 {
            let angle = -Double.pi / 2 + Double(i) * Double.pi / 5
            let r = i % 2 == 0 ? 0.5 : 0.21
            points.append((0.5 + r * cos(angle), 0.5 + r * sin(angle)))
        }
        return polygon(points)
    }()

    static let chat = roundedRect(0.02, 0.06, 0.96, 0.66, r: 0.16) + " " + polygon([(0.22, 0.66), (0.5, 0.66), (0.2, 0.96)])

    static let calendar = roundedRect(0.04, 0.1, 0.92, 0.86, r: 0.1) + " " + roundedRect(0.12, 0.36, 0.76, 0.52, r: 0.04, clockwise: false)
        + " " + rect(0.2, 0.02, 0.1, 0.16) + " " + rect(0.7, 0.02, 0.1, 0.16)

    static let clock = ring(cx: 0.5, cy: 0.5, outer: 0.5, inner: 0.4) + " " + bar(from: (0.5, 0.5), to: (0.5, 0.2), width: 0.08) + " " + bar(from: (0.5, 0.5), to: (0.72, 0.62), width: 0.08)

    static let bell =
        "M 0.5 0.04 C 0.3 0.04 0.18 0.2 0.18 0.4 L 0.18 0.62 L 0.06 0.78 L 0.94 0.78 L 0.82 0.62 L 0.82 0.4 C 0.82 0.2 0.7 0.04 0.5 0.04 Z "
        + circle(cx: 0.5, cy: 0.88, r: 0.1)

    static let music = circle(cx: 0.28, cy: 0.8, r: 0.16) + " " + rect(0.38, 0.04, 0.1, 0.76) + " " + polygon([(0.38, 0.04), (0.92, 0.18), (0.92, 0.4), (0.48, 0.28), (0.48, 0.16)])

    static let mail = rect(0.02, 0.16, 0.96, 0.68) + " " + rect(0.1, 0.24, 0.8, 0.52, clockwise: false)
        + " " + bar(from: (0.06, 0.2), to: (0.5, 0.54), width: 0.09) + " " + bar(from: (0.5, 0.54), to: (0.94, 0.2), width: 0.09)
}
