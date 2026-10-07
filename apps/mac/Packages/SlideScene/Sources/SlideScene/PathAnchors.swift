import CoreGraphics
import Foundation

public struct PathAnchor: Equatable, Sendable {
    public var point: CGPoint

    public var handleIn: CGPoint?

    public var handleOut: CGPoint?

    public init(point: CGPoint, handleIn: CGPoint? = nil, handleOut: CGPoint? = nil) {
        self.point = point
        self.handleIn = handleIn
        self.handleOut = handleOut
    }
}

public enum PathAnchorCodec {

    public static func parse(_ data: String, in frame: CGRect) -> (anchors: [PathAnchor], closed: Bool)? {
        var scanner = Scanner(string: data)
        scanner.charactersToBeSkipped = CharacterSet.whitespacesAndNewlines.union(
            CharacterSet(charactersIn: ",")
        )
        var anchors: [PathAnchor] = []
        var closed = false
        var sawMove = false
        var lastCommand: Character?

        func absolute(_ x: CGFloat, _ y: CGFloat, relativeTo current: CGPoint?, relative: Bool) -> CGPoint {
            if relative, let current {
                return CGPoint(x: current.x + x * frame.width, y: current.y + y * frame.height)
            }
            return CGPoint(x: frame.minX + x * frame.width, y: frame.minY + y * frame.height)
        }

        func scanPoint(relativeTo current: CGPoint?, relative: Bool) -> CGPoint? {
            var x = 0.0, y = 0.0
            guard scanner.scanDouble(&x), scanner.scanDouble(&y) else { return nil }
            return absolute(CGFloat(x), CGFloat(y), relativeTo: current, relative: relative)
        }

        while !scanner.isAtEnd {
            let command: Character
            if let letter = scanner.scanCharacter(), letter.isLetter {
                command = letter
            } else if let last = lastCommand {
                scanner.currentIndex = scanner.string.index(before: scanner.currentIndex)
                command = last == "M" ? "L" : (last == "m" ? "l" : last)
            } else {
                return nil
            }
            lastCommand = command
            let relative = command.isLowercase
            let current = anchors.last?.point

            switch Character(command.uppercased()) {
            case "M":

                guard !sawMove else { return nil }
                sawMove = true
                guard let p = scanPoint(relativeTo: current, relative: relative) else { return nil }
                anchors.append(PathAnchor(point: p))
            case "L":
                guard let p = scanPoint(relativeTo: current, relative: relative) else { return nil }
                anchors.append(PathAnchor(point: p))
            case "H":
                var x = 0.0
                guard scanner.scanDouble(&x), let current else { return nil }
                let p = relative
                    ? CGPoint(x: current.x + CGFloat(x) * frame.width, y: current.y)
                    : CGPoint(x: frame.minX + CGFloat(x) * frame.width, y: current.y)
                anchors.append(PathAnchor(point: p))
            case "V":
                var y = 0.0
                guard scanner.scanDouble(&y), let current else { return nil }
                let p = relative
                    ? CGPoint(x: current.x, y: current.y + CGFloat(y) * frame.height)
                    : CGPoint(x: current.x, y: frame.minY + CGFloat(y) * frame.height)
                anchors.append(PathAnchor(point: p))
            case "C":
                guard let c1 = scanPoint(relativeTo: current, relative: relative),
                      let c2 = scanPoint(relativeTo: current, relative: relative),
                      let p = scanPoint(relativeTo: current, relative: relative),
                      !anchors.isEmpty
                else { return nil }
                anchors[anchors.count - 1].handleOut = c1
                anchors.append(PathAnchor(point: p, handleIn: c2))
            case "Q":

                guard let q = scanPoint(relativeTo: current, relative: relative),
                      let p = scanPoint(relativeTo: current, relative: relative),
                      let p0 = current, !anchors.isEmpty
                else { return nil }
                let c1 = CGPoint(x: p0.x + (q.x - p0.x) * 2 / 3, y: p0.y + (q.y - p0.y) * 2 / 3)
                let c2 = CGPoint(x: p.x + (q.x - p.x) * 2 / 3, y: p.y + (q.y - p.y) * 2 / 3)
                anchors[anchors.count - 1].handleOut = c1
                anchors.append(PathAnchor(point: p, handleIn: c2))
            case "Z":
                closed = true
            default:
                return nil 
            }
        }
        guard anchors.count >= 2 else { return nil }

        if closed, anchors.count > 2, let last = anchors.last {
            let first = anchors[0]
            let tolerance = max(frame.width, frame.height) * 0.002
            if abs(last.point.x - first.point.x) <= tolerance,
               abs(last.point.y - first.point.y) <= tolerance {
                anchors[0].handleIn = last.handleIn
                anchors.removeLast()
            }
        }
        return (anchors, closed)
    }

    public static func encode(anchors: [PathAnchor], closed: Bool) -> (pathData: String, frame: CGRect)? {
        guard anchors.count >= 2 else { return nil }
        var points: [CGPoint] = []
        for anchor in anchors {
            points.append(anchor.point)
            if let h = anchor.handleIn { points.append(h) }
            if let h = anchor.handleOut { points.append(h) }
        }
        let xs = points.map(\.x)
        let ys = points.map(\.y)
        var bounds = CGRect(
            x: xs.min()!, y: ys.min()!,
            width: max(xs.max()! - xs.min()!, 1),
            height: max(ys.max()! - ys.min()!, 1)
        )
        bounds = bounds.integral

        func unit(_ p: CGPoint) -> String {
            let u = (p.x - bounds.minX) / bounds.width
            let v = (p.y - bounds.minY) / bounds.height
            return "\(format(u)) \(format(v))"
        }

        var out = "M \(unit(anchors[0].point))"
        let segmentCount = closed ? anchors.count : anchors.count - 1
        for i in 0..<segmentCount {
            let from = anchors[i]
            let to = anchors[(i + 1) % anchors.count]
            if from.handleOut == nil, to.handleIn == nil {
                out += " L \(unit(to.point))"
            } else {
                let c1 = from.handleOut ?? from.point
                let c2 = to.handleIn ?? to.point
                out += " C \(unit(c1)) \(unit(c2)) \(unit(to.point))"
            }
        }
        if closed { out += " Z" }
        return (out, bounds)
    }

    public static func encodeAbsolute(anchors: [PathAnchor], closed: Bool) -> String? {
        guard anchors.count >= 2 else { return nil }
        func unit(_ p: CGPoint) -> String {
            "\(format(p.x)) \(format(p.y))"
        }
        var out = "M \(unit(anchors[0].point))"
        let segmentCount = closed ? anchors.count : anchors.count - 1
        for i in 0..<segmentCount {
            let from = anchors[i]
            let to = anchors[(i + 1) % anchors.count]
            if from.handleOut == nil, to.handleIn == nil {
                out += " L \(unit(to.point))"
            } else {
                let c1 = from.handleOut ?? from.point
                let c2 = to.handleIn ?? to.point
                out += " C \(unit(c1)) \(unit(c2)) \(unit(to.point))"
            }
        }
        if closed { out += " Z" }
        return out
    }

    private static func format(_ value: CGFloat) -> String {
        String(format: "%.4f", value)
    }
}
