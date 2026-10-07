import CoreGraphics
import Foundation
import Metal

enum ShapeRasterizer {
    struct Key: Hashable {
        let style: ShapeStyle
        let pixelWidth: Int
        let pixelHeight: Int
        let scaleMilli: Int

        let padMilli: Int
    }

    static func padding(for style: ShapeStyle) -> Double {
        var pad = 0.0
        if let stroke = style.stroke {
            pad = stroke.width / 2
        }
        if let shadow = style.shadow {
            pad = max(pad, pad + shadow.blurRadius + max(abs(shadow.offsetX), abs(shadow.offsetY)))
        }
        return pad.rounded(.up)
    }

    static func makeTexture(
        style: ShapeStyle,
        pixelWidth: Int,
        pixelHeight: Int,
        pixelPad: CGFloat,
        scale: CGFloat,
        device: MTLDevice
    ) -> MTLTexture? {
        guard let context = LinearRaster.makeContext(pixelWidth: pixelWidth, pixelHeight: pixelHeight)
        else { return nil }

        let frameRect = CGRect(
            x: pixelPad,
            y: pixelPad,
            width: CGFloat(pixelWidth) - pixelPad * 2,
            height: CGFloat(pixelHeight) - pixelPad * 2
        )
        guard frameRect.width > 0, frameRect.height > 0,
              let path = makePath(kind: style.kind, in: frameRect, scale: scale)
        else { return nil }

        context.translateBy(x: 0, y: CGFloat(pixelHeight))
        context.scaleBy(x: 1, y: -1)

        if let shadow = style.shadow {
            context.setShadow(

                offset: CGSize(width: shadow.offsetX * scale, height: -shadow.offsetY * scale),
                blur: shadow.blurRadius * scale,
                color: LinearRaster.cgColor(shadow.color)
            )

            context.beginTransparencyLayer(auxiliaryInfo: nil)
        }

        if style.fillOpacity > 0 {

            if style.fillOpacity < 1 {
                context.saveGState()
                context.setAlpha(style.fillOpacity)
                drawFill(style.fill, path: path, in: frameRect, context: context)
                context.restoreGState()
            } else {
                drawFill(style.fill, path: path, in: frameRect, context: context)
            }
        }

        if let stroke = style.stroke, stroke.width > 0,
           let strokeColor = LinearRaster.cgColor(stroke.color) {
            context.addPath(path)
            context.setStrokeColor(strokeColor)
            context.setLineWidth(stroke.width * scale)
            applyDash(stroke, scale: scale, context: context)
            applyTrim(style.strokeTrim, path: path, context: context)
            context.strokePath()
            context.setLineDash(phase: 0, lengths: [])
            context.setLineCap(.butt)
        }

        if style.shadow != nil {
            context.endTransparencyLayer()
        }

        return LinearRaster.makeTexture(from: context, device: device)
    }

    private static func applyTrim(_ trim: ShapeStyle.StrokeTrim?, path: CGPath, context: CGContext) {
        guard let trim else { return }
        let total = path.approximateLength()
        guard total > 0 else { return }
        let visible = max(0, min(trim.length, 1)) * total
        if visible <= 0 {

            context.setLineDash(phase: 0, lengths: [0, total * 2])
            return
        }
        if visible >= total { context.setLineDash(phase: 0, lengths: []); return }
        let start = (trim.start - trim.start.rounded(.down)) * total

        var intervals: [(CGFloat, CGFloat)] = []
        let from = trim.reversed ? start - visible : start
        let to = from + visible
        if from < 0 {
            intervals = [(0, to), (from + total, total)]
        } else if to > total {
            intervals = [(from, total), (0, to - total)]
        } else {
            intervals = [(from, to)]
        }
        intervals.sort { $0.0 < $1.0 }
        var lengths: [CGFloat] = [0]
        var cursor: CGFloat = 0
        for (a, b) in intervals where b > a {
            lengths.append(max(a - cursor, 0)) 
            lengths.append(b - a)              
            cursor = b
        }
        lengths.append(total * 2) 
        context.setLineDash(phase: 0, lengths: lengths)
        context.setLineCap(.butt)
    }

    static func makeChromeTexture(
        style: ShapeStyle,
        pixelWidth: Int,
        pixelHeight: Int,
        pixelPad: CGFloat,
        scale: CGFloat,
        device: MTLDevice
    ) -> MTLTexture? {
        guard style.stroke != nil || style.shadow != nil,
              let context = LinearRaster.makeContext(pixelWidth: pixelWidth, pixelHeight: pixelHeight)
        else { return nil }

        let frameRect = CGRect(
            x: pixelPad,
            y: pixelPad,
            width: CGFloat(pixelWidth) - pixelPad * 2,
            height: CGFloat(pixelHeight) - pixelPad * 2
        )
        guard frameRect.width > 0, frameRect.height > 0,
              let path = makePath(kind: style.kind, in: frameRect, scale: scale)
        else { return nil }

        context.translateBy(x: 0, y: CGFloat(pixelHeight))
        context.scaleBy(x: 1, y: -1)

        if let shadow = style.shadow {

            let shift = CGFloat(pixelWidth) + CGFloat(pixelHeight)
            context.saveGState()
            context.setShadow(

                offset: CGSize(width: shadow.offsetX * scale - shift, height: -shadow.offsetY * scale),
                blur: shadow.blurRadius * scale,
                color: LinearRaster.cgColor(shadow.color)
            )
            context.translateBy(x: shift, y: 0)
            context.addPath(path)
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            context.fillPath()
            context.restoreGState()

            context.setBlendMode(.clear)
            context.addPath(path)
            context.fillPath()
            context.setBlendMode(.normal)
        }

        if let stroke = style.stroke, stroke.width > 0,
           let strokeColor = LinearRaster.cgColor(stroke.color) {
            context.addPath(path)
            context.setStrokeColor(strokeColor)
            context.setLineWidth(stroke.width * scale)
            applyDash(stroke, scale: scale, context: context)
            applyTrim(style.strokeTrim, path: path, context: context)
            context.strokePath()
            context.setLineDash(phase: 0, lengths: [])
            context.setLineCap(.butt)
        }

        return LinearRaster.makeTexture(from: context, device: device)
    }

    private static func applyDash(_ stroke: SceneStroke, scale: CGFloat, context: CGContext) {
        let width = stroke.width * scale
        switch stroke.dash {
        case .solid:
            break
        case .dashed:
            context.setLineDash(phase: 0, lengths: [width * 3, width * 2])
        case .dotted:
            context.setLineCap(.round)
            context.setLineDash(phase: 0, lengths: [0.001, width * 2.5])
        }
    }

    private static func drawFill(
        _ fill: SceneFill,
        path: CGPath,
        in rect: CGRect,
        context: CGContext
    ) {
        switch fill {
        case .none:
            return
        case .media:

            return
        case .solid(let color):
            guard let cgColor = LinearRaster.cgColor(color) else { return }
            context.addPath(path)
            context.setFillColor(cgColor)
            context.fillPath()
        case .linearGradient(let angleDegrees, let stops):
            guard stops.count >= 2, let space = LinearRaster.colorSpace else { return }
            let sorted = stops.sorted { $0.position < $1.position }
            let colors = sorted.compactMap { LinearRaster.cgColor($0.color) }
            guard colors.count == sorted.count,
                  let gradient = CGGradient(
                    colorsSpace: space,
                    colors: colors as CFArray,
                    locations: sorted.map { CGFloat($0.position) }
                  )
            else { return }

            let radians = angleDegrees * .pi / 180
            let direction = CGVector(dx: cos(radians), dy: sin(radians))
            let center = CGPoint(x: rect.midX, y: rect.midY)
            let halfSpan = (abs(direction.dx) * rect.width + abs(direction.dy) * rect.height) / 2
            let start = CGPoint(
                x: center.x - direction.dx * halfSpan,
                y: center.y - direction.dy * halfSpan
            )
            let end = CGPoint(
                x: center.x + direction.dx * halfSpan,
                y: center.y + direction.dy * halfSpan
            )
            context.saveGState()
            context.addPath(path)
            context.clip()
            context.drawLinearGradient(gradient, start: start, end: end, options: [])
            context.restoreGState()
        }
    }

    private static func makePath(kind: SceneShapeKind, in rect: CGRect, scale: CGFloat) -> CGPath? {
        switch kind {
        case .rectangle:
            return CGPath(rect: rect, transform: nil)
        case .roundedRectangle(let cornerRadius):
            let radius = min(cornerRadius * scale, min(rect.width, rect.height) / 2)
            return CGPath(
                roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil
            )
        case .ellipse:
            return CGPath(ellipseIn: rect, transform: nil)
        case .path(let data):
            return SVGPathParser.path(from: data, in: rect)
        }
    }
}

enum SVGPathParser {
    static func path(from data: String, in rect: CGRect) -> CGPath? {
        var scanner = Scanner(string: data)
        scanner.charactersToBeSkipped = CharacterSet.whitespacesAndNewlines.union(
            CharacterSet(charactersIn: ",")
        )
        let path = CGMutablePath()
        var current = CGPoint.zero
        var subpathStart = CGPoint.zero
        var lastCommand: Character?

        func point(_ x: CGFloat, _ y: CGFloat, relative: Bool) -> CGPoint {
            let unit = relative
                ? CGPoint(x: current.x + x * rect.width, y: current.y + y * rect.height)
                : CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height)
            return unit
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

            switch Character(command.uppercased()) {
            case "M":
                guard let x = scanner.scanUnit(), let y = scanner.scanUnit() else { return nil }
                current = point(x, y, relative: relative)
                subpathStart = current
                path.move(to: current)
            case "L":
                guard let x = scanner.scanUnit(), let y = scanner.scanUnit() else { return nil }
                current = point(x, y, relative: relative)
                path.addLine(to: current)
            case "H":
                guard let x = scanner.scanUnit() else { return nil }
                current = relative
                    ? CGPoint(x: current.x + x * rect.width, y: current.y)
                    : CGPoint(x: rect.minX + x * rect.width, y: current.y)
                path.addLine(to: current)
            case "V":
                guard let y = scanner.scanUnit() else { return nil }
                current = relative
                    ? CGPoint(x: current.x, y: current.y + y * rect.height)
                    : CGPoint(x: current.x, y: rect.minY + y * rect.height)
                path.addLine(to: current)
            case "C":
                guard let x1 = scanner.scanUnit(), let y1 = scanner.scanUnit(),
                      let x2 = scanner.scanUnit(), let y2 = scanner.scanUnit(),
                      let x = scanner.scanUnit(), let y = scanner.scanUnit()
                else { return nil }
                let c1 = point(x1, y1, relative: relative)
                let c2 = point(x2, y2, relative: relative)
                current = point(x, y, relative: relative)
                path.addCurve(to: current, control1: c1, control2: c2)
            case "Q":
                guard let x1 = scanner.scanUnit(), let y1 = scanner.scanUnit(),
                      let x = scanner.scanUnit(), let y = scanner.scanUnit()
                else { return nil }
                let c = point(x1, y1, relative: relative)
                current = point(x, y, relative: relative)
                path.addQuadCurve(to: current, control: c)
            case "Z":
                path.closeSubpath()
                current = subpathStart
            default:
                return nil
            }
        }
        return path.isEmpty ? nil : path
    }

    private static func scanDoubleHelper(_ scanner: Scanner) -> CGFloat? {
        scanner.scanUnit().map { CGFloat($0) }
    }
}

private extension Scanner {

    func scanUnit() -> CGFloat? {
        var value = 0.0
        return scanDouble(&value) ? CGFloat(value) : nil
    }
}


extension CGPath {

    func approximateLength() -> CGFloat {
        var length: CGFloat = 0
        var current = CGPoint.zero
        var subpathStart = CGPoint.zero
        func dist(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(b.x - a.x, b.y - a.y) }
        applyWithBlock { element in
            let e = element.pointee
            switch e.type {
            case .moveToPoint:
                current = e.points[0]
                subpathStart = current
            case .addLineToPoint:
                length += dist(current, e.points[0])
                current = e.points[0]
            case .addQuadCurveToPoint:
                let c = e.points[0], end = e.points[1]
                var previous = current
                for i in 1...16 {
                    let t = CGFloat(i) / 16, u = 1 - t
                    let point = CGPoint(
                        x: u * u * current.x + 2 * u * t * c.x + t * t * end.x,
                        y: u * u * current.y + 2 * u * t * c.y + t * t * end.y
                    )
                    length += dist(previous, point)
                    previous = point
                }
                current = end
            case .addCurveToPoint:
                let c1 = e.points[0], c2 = e.points[1], end = e.points[2]
                var previous = current
                for i in 1...16 {
                    let t = CGFloat(i) / 16, u = 1 - t
                    let point = CGPoint(
                        x: u * u * u * current.x + 3 * u * u * t * c1.x + 3 * u * t * t * c2.x + t * t * t * end.x,
                        y: u * u * u * current.y + 3 * u * u * t * c1.y + 3 * u * t * t * c2.y + t * t * t * end.y
                    )
                    length += dist(previous, point)
                    previous = point
                }
                current = end
            case .closeSubpath:
                length += dist(current, subpathStart)
                current = subpathStart
            @unknown default:
                break
            }
        }
        return length
    }
}
