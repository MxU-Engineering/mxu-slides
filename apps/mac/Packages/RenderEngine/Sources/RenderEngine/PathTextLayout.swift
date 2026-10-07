import CoreGraphics
import CoreText
import Foundation

enum PathTextLayout {

    struct GlyphCell: Equatable {

        let centerAdvancePx: CGFloat

        let uv: CGRect

        let tileWidthPx: CGFloat
    }

    struct Run: Equatable {
        let cells: [GlyphCell]

        let runLengthPx: CGFloat
        let stripWidthPx: Int
        let stripHeightPx: Int

        let baselineFromBottomPx: CGFloat

        let padXPx: CGFloat

        var separatorStartPx: CGFloat? = nil
    }

    static func run(
        line: CTLine,
        stripWidthPx: Int,
        stripHeightPx: Int,
        baselineFromBottomPx: CGFloat,
        padXPx: CGFloat
    ) -> Run? {
        var positions: [CGFloat] = []
        guard let runs = CTLineGetGlyphRuns(line) as? [CTRun] else { return nil }
        for run in runs {
            let count = CTRunGetGlyphCount(run)
            guard count > 0 else { continue }
            var runPositions = [CGPoint](repeating: .zero, count: count)
            CTRunGetPositions(run, CFRange(location: 0, length: 0), &runPositions)
            positions.append(contentsOf: runPositions.map(\.x))
        }
        guard !positions.isEmpty else { return nil }

        positions.sort()

        let width = CGFloat(stripWidthPx)
        let runLength = width - 2 * padXPx

        var edges: [CGFloat] = [0]
        edges.append(contentsOf: positions.dropFirst().map { padXPx + $0 })
        edges.append(width)

        var cells: [GlyphCell] = []
        cells.reserveCapacity(positions.count)
        for index in 0..<positions.count {
            let left = edges[index]
            let right = edges[index + 1]
            let tileWidth = right - left
            guard tileWidth > 0 else { continue }
            cells.append(
                GlyphCell(
                    centerAdvancePx: (left + right) / 2 - padXPx,
                    uv: CGRect(
                        x: left / width, y: 0,
                        width: tileWidth / width, height: 1
                    ),
                    tileWidthPx: tileWidth
                )
            )
        }
        guard !cells.isEmpty else { return nil }
        return Run(
            cells: cells,
            runLengthPx: runLength,
            stripWidthPx: stripWidthPx,
            stripHeightPx: stripHeightPx,
            baselineFromBottomPx: baselineFromBottomPx,
            padXPx: padXPx
        )
    }

    static let curveSubdivisions = 24

    struct FlatPath: Equatable {
        let points: [CGPoint]

        let cumulative: [CGFloat]

        let tangents: [CGVector]
        let totalLength: CGFloat

        let isClosed: Bool

        func sample(at arcLength: CGFloat) -> (point: CGPoint, tangentRadians: CGFloat) {
            guard points.count >= 2 else {
                return (points.first ?? .zero, 0)
            }
            let target = min(max(arcLength, 0), totalLength)

            var low = 1
            var high = points.count - 1
            while low < high {
                let mid = (low + high) / 2
                if cumulative[mid] < target { low = mid + 1 } else { high = mid }
            }
            let start = points[low - 1]
            let end = points[low]
            let segment = cumulative[low] - cumulative[low - 1]
            let t = segment > 0 ? (target - cumulative[low - 1]) / segment : 0
            let point = CGPoint(
                x: start.x + (end.x - start.x) * t,
                y: start.y + (end.y - start.y) * t
            )
            let from = tangents[low - 1]
            let to = tangents[low]
            let dx = from.dx + (to.dx - from.dx) * t
            let dy = from.dy + (to.dy - from.dy) * t

            if dx * dx + dy * dy < 1e-9 {
                return (point, atan2(end.y - start.y, end.x - start.x))
            }
            return (point, atan2(dy, dx))
        }
    }

    static func flatten(_ path: CGPath) -> FlatPath? {
        var points: [CGPoint] = []
        var subpathStart: CGPoint?
        var sawClose = false

        func append(_ point: CGPoint) {
            if let last = points.last, hypot(point.x - last.x, point.y - last.y) < 0.001 {
                return
            }
            points.append(point)
        }

        path.applyWithBlock { elementPointer in
            let element = elementPointer.pointee
            switch element.type {
            case .moveToPoint:
                let point = element.points[0]
                subpathStart = point
                append(point)
            case .addLineToPoint:
                append(element.points[0])
            case .addQuadCurveToPoint:
                guard let from = points.last else { return }
                let control = element.points[0]
                let to = element.points[1]
                for step in 1...curveSubdivisions {
                    let t = CGFloat(step) / CGFloat(curveSubdivisions)
                    let mt = 1 - t
                    append(CGPoint(
                        x: mt * mt * from.x + 2 * mt * t * control.x + t * t * to.x,
                        y: mt * mt * from.y + 2 * mt * t * control.y + t * t * to.y
                    ))
                }
            case .addCurveToPoint:
                guard let from = points.last else { return }
                let c1 = element.points[0]
                let c2 = element.points[1]
                let to = element.points[2]
                for step in 1...curveSubdivisions {
                    let t = CGFloat(step) / CGFloat(curveSubdivisions)
                    let mt = 1 - t
                    let a = mt * mt * mt
                    let b = 3 * mt * mt * t
                    let c = 3 * mt * t * t
                    let d = t * t * t
                    append(CGPoint(
                        x: a * from.x + b * c1.x + c * c2.x + d * to.x,
                        y: a * from.y + b * c1.y + c * c2.y + d * to.y
                    ))
                }
            case .closeSubpath:
                sawClose = true
                if let start = subpathStart { append(start) }
            @unknown default:
                break
            }
        }

        guard points.count >= 2 else { return nil }
        var cumulative: [CGFloat] = [0]
        cumulative.reserveCapacity(points.count)
        for index in 1..<points.count {
            let previous = points[index - 1]
            let point = points[index]
            cumulative.append(cumulative[index - 1] + hypot(point.x - previous.x, point.y - previous.y))
        }
        let total = cumulative[cumulative.count - 1]
        guard total > 0 else { return nil }
        let endsAtStart: Bool = {
            guard let first = points.first, let last = points.last else { return false }
            return hypot(last.x - first.x, last.y - first.y) < 0.01
        }()
        let closed = sawClose || endsAtStart

        func segmentDirection(_ index: Int) -> CGVector {
            let a = points[index]
            let b = points[index + 1]
            let length = hypot(b.x - a.x, b.y - a.y)
            guard length > 0 else { return CGVector(dx: 1, dy: 0) }
            return CGVector(dx: (b.x - a.x) / length, dy: (b.y - a.y) / length)
        }
        func averaged(_ a: CGVector, _ b: CGVector) -> CGVector {
            let dx = a.dx + b.dx
            let dy = a.dy + b.dy
            let length = hypot(dx, dy)

            guard length > 1e-6 else { return a }
            return CGVector(dx: dx / length, dy: dy / length)
        }
        var tangents = [CGVector](repeating: CGVector(dx: 1, dy: 0), count: points.count)
        let lastSegment = points.count - 2
        for index in 0..<points.count {
            if index == 0 {
                tangents[0] = closed
                    ? averaged(segmentDirection(lastSegment), segmentDirection(0))
                    : segmentDirection(0)
            } else if index == points.count - 1 {
                tangents[index] = closed ? tangents[0] : segmentDirection(lastSegment)
            } else {
                tangents[index] = averaged(segmentDirection(index - 1), segmentDirection(index))
            }
        }

        return FlatPath(
            points: points,
            cumulative: cumulative,
            tangents: tangents,
            totalLength: total,
            isClosed: closed
        )
    }

    struct PlacedGlyph: Equatable {
        let uv: CGRect

        let center: CGPoint
        let tangentRadians: CGFloat
        let tileWidthPx: CGFloat
    }

    static func place(
        run: Run,
        along path: FlatPath,
        phasePx: CGFloat,
        alignment: SceneTextAlignment,
        isScrolling: Bool,
        reversed: Bool = false,
        offsetPx: CGFloat = 0,
        stream: Bool = false,
        gapPx: CGFloat = 0
    ) -> [PlacedGlyph] {
        var placed: [PlacedGlyph] = []
        placed.reserveCapacity(run.cells.count)

        func resolvedSample(at arc: CGFloat) -> (point: CGPoint, tangentRadians: CGFloat) {
            var sample: (point: CGPoint, tangentRadians: CGFloat)
            if reversed {
                let raw = path.sample(at: path.totalLength - arc)
                sample = (raw.point, raw.tangentRadians + .pi)
            } else {
                sample = path.sample(at: arc)
            }
            if offsetPx != 0 {

                sample.point.x += sin(sample.tangentRadians) * offsetPx
                sample.point.y -= cos(sample.tangentRadians) * offsetPx
            }
            return sample
        }

        let total = path.totalLength

        func emit(copyOffset: CGFloat, wrap: Bool, separatorShiftPx: CGFloat = 0) {
            for cell in run.cells {
                var arc = copyOffset + cell.centerAdvancePx
                if separatorShiftPx > 0, let separatorStart = run.separatorStartPx,
                   cell.centerAdvancePx >= separatorStart {
                    arc += separatorShiftPx
                }
                if wrap {
                    let raw = arc.truncatingRemainder(dividingBy: total)
                    arc = raw < 0 ? raw + total : raw
                    let sample = resolvedSample(at: arc)
                    placed.append(
                        PlacedGlyph(
                            uv: cell.uv,
                            center: sample.point,
                            tangentRadians: sample.tangentRadians,
                            tileWidthPx: cell.tileWidthPx
                        )
                    )
                    continue
                }
                let width = cell.tileWidthPx
                let leftEdge = arc - width / 2
                let rightEdge = arc + width / 2

                guard rightEdge > 0, leftEdge < total else { continue }

                let cutLeft = max(0, -leftEdge)
                let cutRight = max(0, rightEdge - total)
                let visibleWidth = width - cutLeft - cutRight
                guard visibleWidth > 0.01 else { continue }
                var uv = cell.uv
                uv.origin.x += uv.size.width * (cutLeft / width)
                uv.size.width *= visibleWidth / width

                let sample = resolvedSample(at: arc + (cutLeft - cutRight) / 2)
                placed.append(
                    PlacedGlyph(
                        uv: uv,
                        center: sample.point,
                        tangentRadians: sample.tangentRadians,
                        tileWidthPx: visibleWidth
                    )
                )
            }
        }

        if path.isClosed {
            if stream {

                let requested = max(run.runLengthPx + gapPx, 1)
                let mostThatFit = max(1, Int(total / max(run.runLengthPx, 1)))
                let copies = max(1, min(Int((total / requested).rounded()), mostThatFit))
                let stride = total / CGFloat(copies)

                let separatorShift = max(0, stride - run.runLengthPx) / 2
                placed.reserveCapacity(run.cells.count * copies)
                for copy in 0..<copies {
                    emit(
                        copyOffset: CGFloat(copy) * stride + phasePx, wrap: true,
                        separatorShiftPx: separatorShift
                    )
                }
            } else {
                emit(copyOffset: phasePx, wrap: true)
            }
            return placed
        }

        if stream, isScrolling {

            let stride = max(run.runLengthPx + gapPx, 1)
            let looped = phasePx.truncatingRemainder(dividingBy: stride)
            var offset = (looped < 0 ? looped + stride : looped) - stride - run.runLengthPx
            placed.reserveCapacity(run.cells.count * (Int(total / stride) + 3))
            while offset < total + run.padXPx {
                emit(copyOffset: offset, wrap: false, separatorShiftPx: gapPx / 2)
                offset += stride
            }
            return placed
        }

        let baseOffset: CGFloat
        if isScrolling {

            let period = total + run.runLengthPx + 2 * run.padXPx
            let looped = phasePx.truncatingRemainder(dividingBy: period)
            baseOffset = -(run.runLengthPx + run.padXPx) + (looped < 0 ? looped + period : looped)
        } else {

            baseOffset = switch alignment {
            case .left: 0
            case .center: (total - run.runLengthPx) / 2
            case .right: total - run.runLengthPx
            }
        }
        emit(copyOffset: baseOffset, wrap: false)
        return placed
    }
}
