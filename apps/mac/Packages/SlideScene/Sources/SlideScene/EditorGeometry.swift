import CoreGraphics
import PresenterCore
import RenderEngine

public enum EditorGeometry {

    public static func hitObject(
        at point: CGPoint,
        in objects: [SlideObject],
        template: Slide? = nil
    ) -> SlideObject? {
        objectsUnder(point, in: objects, template: template).first
    }

    public static func pressTarget(
        at point: CGPoint,
        in objects: [SlideObject],
        selected: Set<String>,
        template: Slide? = nil
    ) -> SlideObject? {
        let under = objectsUnder(point, in: objects, template: template)
        return under.first { selected.contains($0.id) } ?? under.first
    }

    private static func objectsUnder(
        _ point: CGPoint,
        in objects: [SlideObject],
        template: Slide?
    ) -> [SlideObject] {
        let placeholders = SlideSceneBuilder.placeholderAssignments(for: objects, in: template)

        return SlideSceneBuilder.composedOrder(for: objects, in: template).reversed().filter { object in
            let frame = SlideSceneBuilder.frame(for: object, placeholder: placeholders[object.id])
            let local = unrotate(
                point,
                around: CGPoint(x: frame.midX, y: frame.midY),
                degrees: object.rotationDegrees ?? 0
            )
            return frame.contains(local)
        }
    }

    static func unrotate(_ point: CGPoint, around center: CGPoint, degrees: Double) -> CGPoint {
        guard degrees != 0 else { return point }
        let radians = -degrees * .pi / 180
        let dx = point.x - center.x
        let dy = point.y - center.y
        return CGPoint(
            x: center.x + dx * CGFloat(cos(radians)) - dy * CGFloat(sin(radians)),
            y: center.y + dx * CGFloat(sin(radians)) + dy * CGFloat(cos(radians))
        )
    }

    public static func rotatedBounds(_ frame: CGRect, degrees: Double) -> CGRect {
        guard degrees.truncatingRemainder(dividingBy: 360) != 0 else { return frame }
        let center = CGPoint(x: frame.midX, y: frame.midY)
        let corners = [
            CGPoint(x: frame.minX, y: frame.minY),
            CGPoint(x: frame.maxX, y: frame.minY),
            CGPoint(x: frame.maxX, y: frame.maxY),
            CGPoint(x: frame.minX, y: frame.maxY),
        ].map { unrotate($0, around: center, degrees: -degrees) }
        let xs = corners.map(\.x)
        let ys = corners.map(\.y)
        return CGRect(
            x: xs.min()!, y: ys.min()!,
            width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!
        )
    }

    public static let pasteboardInset: CGFloat = 32

    public static func letterbox(
        canvas: CGSize, in view: CGSize, inset: CGFloat = 0
    ) -> (scale: CGFloat, origin: CGPoint) {
        if canvas.width > 0, canvas.height > 0, view.width > 0, view.height > 0 {
            let scale = min(
                max(view.width - 2 * inset, 1) / canvas.width,
                max(view.height - 2 * inset, 1) / canvas.height)
            return (scale, CGPoint(
                x: (view.width - canvas.width * scale) / 2,
                y: (view.height - canvas.height * scale) / 2))
        } else {
            return (1, .zero)
        }
    }

    public static func scenePoint(
        fromView point: CGPoint, viewSize: CGSize, canvas: CGSize, inset: CGFloat = 0
    ) -> CGPoint {
        let (scale, origin) = letterbox(canvas: canvas, in: viewSize, inset: inset)
        return CGPoint(x: (point.x - origin.x) / scale, y: (point.y - origin.y) / scale)
    }

    public static func sweptObjectIDs(
        band: CGRect, in objects: [SlideObject], frame: (SlideObject) -> CGRect
    ) -> Set<String> {
        Set(objects.filter { object in
            object.hidden != true
                && rotatedBounds(frame(object), degrees: object.rotationDegrees ?? 0).intersects(band)
        }.map(\.id))
    }

    public static func allObjectIDs(in objects: [SlideObject], includingHidden: Bool) -> Set<String> {
        Set(objects.filter { includingHidden || $0.hidden != true }.map(\.id))
    }

    public static func perspectiveMotion(for object: SlideObject) -> AnimationMotion {
        let pivot: SceneTiltPivot = switch object.tiltPivot {
        case .none, .center: .center
        case .top: .top
        case .bottom: .bottom
        }
        return AnimationMotion(
            tilt: object.tilt ?? 0, swing: object.swing ?? 0, tiltPivot: pivot,
            keystoneTop: (object.keystoneTop ?? 100) / 100,
            keystoneBottom: (object.keystoneBottom ?? 100) / 100,
            keystoneStretch: object.keystoneMode == .stretch,
            skewX: object.skewX ?? 0, skewY: object.skewY ?? 0
        )
    }

    public static func perspectiveCorners(
        frame: CGRect, object: SlideObject, canvasSize: CGSize
    ) -> [CGPoint]? {
        let motion = perspectiveMotion(for: object)
        let rotation = object.rotationDegrees ?? 0
        guard !motion.isIdentity || rotation.truncatingRemainder(dividingBy: 360) != 0 else { return nil }
        let projected = Compositor.buildQuadCorners(
            contentRect: frame, motion: motion, sceneScale: 1, targetSize: canvasSize
        )
        guard rotation != 0 else { return projected }
        let center = CGPoint(x: frame.midX, y: frame.midY)

        return projected.map { unrotate($0, around: center, degrees: -rotation) }
    }

    public struct Homography: Equatable, Sendable {
        public var a, b, c, d, e, f, g, h: Double

        public init?(from rect: CGRect, to corners: [CGPoint]) {
            guard corners.count == 4, rect.width > 0, rect.height > 0 else { return nil }

            let (x0, y0) = (Double(corners[0].x), Double(corners[0].y))
            let (x1, y1) = (Double(corners[1].x), Double(corners[1].y))
            let (x2, y2) = (Double(corners[3].x), Double(corners[3].y))
            let (x3, y3) = (Double(corners[2].x), Double(corners[2].y))
            let dx1 = x1 - x2, dx2 = x3 - x2, dx3 = x0 - x1 + x2 - x3
            let dy1 = y1 - y2, dy2 = y3 - y2, dy3 = y0 - y1 + y2 - y3
            var a, b, c, d, e, f, g, h: Double
            if abs(dx3) < 1e-9, abs(dy3) < 1e-9 {
                a = x1 - x0; b = x2 - x1; c = x0
                d = y1 - y0; e = y2 - y1; f = y0
                g = 0; h = 0
            } else {
                let den = dx1 * dy2 - dx2 * dy1
                guard abs(den) > 1e-12 else { return nil }
                g = (dx3 * dy2 - dx2 * dy3) / den
                h = (dx1 * dy3 - dx3 * dy1) / den
                a = x1 - x0 + g * x1; b = x3 - x0 + h * x3; c = x0
                d = y1 - y0 + g * y1; e = y3 - y0 + h * y3; f = y0
            }

            let sx = 1 / Double(rect.width), sy = 1 / Double(rect.height)
            let ox = Double(rect.minX), oy = Double(rect.minY)

            self.a = a * sx; self.b = b * sy; self.c = c - a * sx * ox - b * sy * oy
            self.d = d * sx; self.e = e * sy; self.f = f - d * sx * ox - e * sy * oy
            self.g = g * sx; self.h = h * sy

            self.w0 = 1 - g * sx * ox - h * sy * oy
        }

        public var w0: Double = 1

        public func apply(_ p: CGPoint) -> CGPoint {
            let x = Double(p.x), y = Double(p.y)
            let w = g * x + h * y + w0
            guard abs(w) > 1e-12 else { return p }
            return CGPoint(x: (a * x + b * y + c) / w, y: (d * x + e * y + f) / w)
        }

        public func inverseApply(_ p: CGPoint) -> CGPoint {

            let m = [[a, d, g], [b, e, h], [c, f, w0]]
            let det = m[0][0] * (m[1][1] * m[2][2] - m[1][2] * m[2][1])
                - m[0][1] * (m[1][0] * m[2][2] - m[1][2] * m[2][0])
                + m[0][2] * (m[1][0] * m[2][1] - m[1][1] * m[2][0])
            guard abs(det) > 1e-12 else { return p }
            func cof(_ r: Int, _ c: Int) -> Double {
                let rows = [0, 1, 2].filter { $0 != r }, cols = [0, 1, 2].filter { $0 != c }
                let minor = m[rows[0]][cols[0]] * m[rows[1]][cols[1]] - m[rows[0]][cols[1]] * m[rows[1]][cols[0]]
                return ((r + c) % 2 == 0 ? 1 : -1) * minor
            }

            var inv = [[Double]](repeating: [0, 0, 0], count: 3)
            for r in 0..<3 { for c in 0..<3 { inv[c][r] = cof(r, c) / det } }
            let x = Double(p.x), y = Double(p.y)
            let ox = x * inv[0][0] + y * inv[1][0] + inv[2][0]
            let oy = x * inv[0][1] + y * inv[1][1] + inv[2][1]
            let ow = x * inv[0][2] + y * inv[1][2] + inv[2][2]
            guard abs(ow) > 1e-12 else { return p }
            return CGPoint(x: ox / ow, y: oy / ow)
        }
    }

    public static func expandSelectionToGroups(
        _ ids: Set<String>,
        in objects: [SlideObject]
    ) -> Set<String> {
        func group(of object: SlideObject) -> String? {
            object.groupId.flatMap { $0.isEmpty ? nil : $0 }
        }
        let groups = Set(objects.filter { ids.contains($0.id) }.compactMap(group(of:)))
        guard !groups.isEmpty else { return ids }
        return ids.union(
            objects.filter { group(of: $0).map(groups.contains) ?? false }.map(\.id)
        )
    }

    public enum Handle: CaseIterable, Sendable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

        public var resizesX: Bool {
            self != .top && self != .bottom
        }

        public var resizesY: Bool {
            self != .left && self != .right
        }
    }

    public static func handlePosition(_ handle: Handle, in frame: CGRect) -> CGPoint {
        switch handle {
        case .topLeft: CGPoint(x: frame.minX, y: frame.minY)
        case .top: CGPoint(x: frame.midX, y: frame.minY)
        case .topRight: CGPoint(x: frame.maxX, y: frame.minY)
        case .right: CGPoint(x: frame.maxX, y: frame.midY)
        case .bottomRight: CGPoint(x: frame.maxX, y: frame.maxY)
        case .bottom: CGPoint(x: frame.midX, y: frame.maxY)
        case .bottomLeft: CGPoint(x: frame.minX, y: frame.maxY)
        case .left: CGPoint(x: frame.minX, y: frame.midY)
        }
    }

    public static func resize(
        _ frame: CGRect,
        dragging handle: Handle,
        by delta: CGSize,
        minSize: CGFloat = 16
    ) -> CGRect {
        var result = frame
        if handle.resizesX {
            switch handle {
            case .topLeft, .left, .bottomLeft:
                let dx = min(delta.width, frame.width - minSize)
                result.origin.x += dx
                result.size.width -= dx
            default:
                result.size.width = max(minSize, frame.width + delta.width)
            }
        }
        if handle.resizesY {
            switch handle {
            case .topLeft, .top, .topRight:
                let dy = min(delta.height, frame.height - minSize)
                result.origin.y += dy
                result.size.height -= dy
            default:
                result.size.height = max(minSize, frame.height + delta.height)
            }
        }
        return result
    }

    public enum Guide: Equatable, Sendable {
        case vertical(CGFloat)
        case horizontal(CGFloat)
    }

    public struct SnapResult: Equatable, Sendable {
        public var frame: CGRect
        public var guides: [Guide]
    }

    static func targets(canvasSize: CGSize, others: [CGRect]) -> (x: [CGFloat], y: [CGFloat]) {
        var xs: [CGFloat] = [0, canvasSize.width / 2, canvasSize.width]
        var ys: [CGFloat] = [0, canvasSize.height / 2, canvasSize.height]
        for rect in others {
            xs += [rect.minX, rect.midX, rect.maxX]
            ys += [rect.minY, rect.midY, rect.maxY]
        }
        return (xs, ys)
    }

    public static func snapMove(
        _ frame: CGRect,
        canvasSize: CGSize = SlideSceneBuilder.canvasSize,
        others: [CGRect],
        threshold: CGFloat = 8
    ) -> SnapResult {
        let (xTargets, yTargets) = targets(canvasSize: canvasSize, others: others)
        var result = frame
        var guides: [Guide] = []

        if let best = bestSnap(
            candidates: [frame.minX, frame.midX, frame.maxX], targets: xTargets, threshold: threshold
        ) {
            result.origin.x += best.correction
            guides.append(.vertical(best.target))
        }
        if let best = bestSnap(
            candidates: [frame.minY, frame.midY, frame.maxY], targets: yTargets, threshold: threshold
        ) {
            result.origin.y += best.correction
            guides.append(.horizontal(best.target))
        }
        return SnapResult(frame: result, guides: guides)
    }

    public static func snapResize(
        _ frame: CGRect,
        handle: Handle,
        rotationDegrees: Double = 0,
        canvasSize: CGSize = SlideSceneBuilder.canvasSize,
        others: [CGRect],
        threshold: CGFloat = 8
    ) -> SnapResult {
        guard rotationDegrees.truncatingRemainder(dividingBy: 360) == 0 else {
            return SnapResult(frame: frame, guides: [])
        }
        let (xTargets, yTargets) = targets(canvasSize: canvasSize, others: others)
        var result = frame
        var guides: [Guide] = []

        if handle.resizesX {
            let leading = handle == .topLeft || handle == .left || handle == .bottomLeft
            let edge = leading ? frame.minX : frame.maxX
            if let best = bestSnap(candidates: [edge], targets: xTargets, threshold: threshold) {
                if leading {
                    result.origin.x += best.correction
                    result.size.width -= best.correction
                } else {
                    result.size.width += best.correction
                }
                guides.append(.vertical(best.target))
            }
        }
        if handle.resizesY {
            let leading = handle == .topLeft || handle == .top || handle == .topRight
            let edge = leading ? frame.minY : frame.maxY
            if let best = bestSnap(candidates: [edge], targets: yTargets, threshold: threshold) {
                if leading {
                    result.origin.y += best.correction
                    result.size.height -= best.correction
                } else {
                    result.size.height += best.correction
                }
                guides.append(.horizontal(best.target))
            }
        }
        return SnapResult(frame: result, guides: guides)
    }

    public enum AlignEdge: Sendable {
        case left, centerX, right, top, centerY, bottom
    }

    public struct AlignUnit: Sendable {
        public var ids: [String]
        public var frame: CGRect

        public init(ids: [String], frame: CGRect) {
            self.ids = ids
            self.frame = frame
        }
    }

    public static func alignDeltas(
        units: [AlignUnit],
        edge: AlignEdge,
        reference: CGRect
    ) -> [String: CGVector] {
        var deltas: [String: CGVector] = [:]
        for unit in units {
            let frame = unit.frame
            var delta = CGVector.zero
            switch edge {
            case .left: delta.dx = reference.minX - frame.minX
            case .centerX: delta.dx = reference.midX - frame.midX
            case .right: delta.dx = reference.maxX - frame.maxX
            case .top: delta.dy = reference.minY - frame.minY
            case .centerY: delta.dy = reference.midY - frame.midY
            case .bottom: delta.dy = reference.maxY - frame.maxY
            }
            guard delta.dx != 0 || delta.dy != 0 else { continue }
            for id in unit.ids { deltas[id] = delta }
        }
        return deltas
    }

    public static func distributeDeltas(
        units: [AlignUnit],
        horizontally: Bool
    ) -> [String: CGVector] {
        guard units.count >= 3 else { return [:] }
        let sorted = units.sorted {
            horizontally ? $0.frame.minX < $1.frame.minX : $0.frame.minY < $1.frame.minY
        }
        let first = sorted.first!.frame
        let last = sorted.last!.frame
        let span = horizontally ? last.maxX - first.minX : last.maxY - first.minY
        let extent = sorted.reduce(CGFloat(0)) {
            $0 + (horizontally ? $1.frame.width : $1.frame.height)
        }
        let gap = (span - extent) / CGFloat(sorted.count - 1)

        var deltas: [String: CGVector] = [:]
        var cursor = horizontally ? first.minX : first.minY
        for unit in sorted {
            let position = horizontally ? unit.frame.minX : unit.frame.minY
            let offset = cursor - position
            if offset != 0 {
                let delta = horizontally
                    ? CGVector(dx: offset, dy: 0) : CGVector(dx: 0, dy: offset)
                for id in unit.ids { deltas[id] = delta }
            }
            cursor += (horizontally ? unit.frame.width : unit.frame.height) + gap
        }
        return deltas
    }

    private static func bestSnap(
        candidates: [CGFloat],
        targets: [CGFloat],
        threshold: CGFloat
    ) -> (correction: CGFloat, target: CGFloat)? {
        var best: (correction: CGFloat, target: CGFloat)?
        for candidate in candidates {
            for target in targets {
                let correction = target - candidate
                if abs(correction) <= threshold,
                   abs(correction) < abs(best?.correction ?? .greatestFiniteMagnitude) {
                    best = (correction, target)
                }
            }
        }
        return best
    }
}
