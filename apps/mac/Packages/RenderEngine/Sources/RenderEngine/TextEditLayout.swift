import CoreGraphics
import CoreText
import Foundation

public struct TextEditLayout {
    struct Line {
        var line: CTLine

        var origin: CGPoint
        var ascent: CGFloat
        var descent: CGFloat

        var start: Int
        var end: Int

        var isVirtual = false

        var softWrapped = false

        var lastOffset: Int { softWrapped ? max(end - 1, start) : end }

        var top: CGFloat { origin.y - ascent }
        var bottom: CGFloat { origin.y + descent }
    }

    let lines: [Line]

    let sourceToLayout: [Int]

    let source: String

    public struct Chord: Equatable, Sendable {
        public var index: Int
        public var rect: CGRect
    }

    public let chords: [Chord]

    public var sourceLength: Int { sourceToLayout.count - 1 }

    public init(text: StyledText, sceneFrame: CGSize) {
        let fontScale = TextRasterizer.fittedFontScale(for: text, sceneFrame: sceneFrame)
        let width = max(sceneFrame.width, 1)
        let height = max(sceneFrame.height, 1)

        let standIn = "\u{200B}"
        var probe = text
        if text.string.isEmpty { probe.string = standIn }
        let layout = TextRasterizer.frameLayout(
            for: probe, width: width, height: height, scale: 1, fontScale: fontScale, colorSpace: nil
        )
        var lines = Self.lines(of: layout, boxHeight: height)
        source = text.string
        chords = layout.chorded.map { chorded in
            TextRasterizer.chordPlacements(
                chorded, frame: layout.frame, frameRect: layout.frameRect, text: layout.text,
                fontScale: fontScale, pixelScale: 1, colorSpace: nil
            ).map { placed in
                Chord(index: placed.source, rect: CGRect(
                    x: placed.origin.x, y: height - (placed.origin.y + placed.ascent),
                    width: placed.width, height: placed.ascent + placed.descent
                ))
            }
        } ?? []
        let layoutString = CFAttributedStringGetString(layout.attributed) as String
        let layoutLength = (layoutString as NSString).length

        if text.string.isEmpty {

            lines = lines.prefix(1).map { line in
                var line = line
                line.end = 0
                return line
            }
            sourceToLayout = [0]
        } else {
            let chordRows = layout.chorded?.rows ?? []
            let spacerStarts = Set(chordRows.map { Self.lineStart($0.spacerLine, in: layoutString) })
            lines.removeAll { spacerStarts.contains($0.start) && !chordRows.isEmpty }

            if layoutString.hasSuffix("\n"), layout.chorded == nil, let last = lines.last {
                var extended = text
                extended.string += standIn
                let next = TextRasterizer.frameLayout(
                    for: extended, width: width, height: height, scale: 1, fontScale: fontScale, colorSpace: nil
                )
                let nextLines = Self.lines(of: next, boxHeight: height)
                if nextLines.count >= 2 {
                    let before = nextLines[nextLines.count - 2]
                    var virtual = nextLines[nextLines.count - 1]
                    virtual.origin.y = last.origin.y + (virtual.origin.y - before.origin.y)
                    virtual.start = layoutLength
                    virtual.end = layoutLength
                    virtual.isVirtual = true
                    lines.append(virtual)
                }
            }
            sourceToLayout = Self.sourceMap(
                source: text.string, transform: text.transform,
                chordRows: chordRows, layoutString: layoutString
            )
        }
        self.lines = lines
    }

    public func caretRect(at index: Int) -> CGRect {
        if let lineIndex = lineIndex(forLayout: layoutOffset(index)) {
            let line = lines[lineIndex]
            let x = xOffset(layoutOffset(index), in: line)
            return CGRect(x: x, y: line.top, width: 0, height: line.ascent + line.descent)
        } else {
            return .zero
        }
    }

    public func selectionRects(for range: NSRange) -> [CGRect] {
        guard range.length > 0 else { return [] }
        let start = layoutOffset(range.location)
        let end = layoutOffset(range.location + range.length)
        return lines.compactMap { line in
            let from = max(start, line.start)
            let to = min(end, line.end)

            let runsOn = end > line.end && start <= line.end && !line.isVirtual
            guard to > from || (runsOn && from <= line.end) else { return nil }
            let x1 = xOffset(from, in: line)
            var x2 = xOffset(max(to, from), in: line)
            if runsOn { x2 += (line.ascent + line.descent) * 0.25 }
            return CGRect(x: x1, y: line.top, width: max(x2 - x1, 1), height: line.ascent + line.descent)
        }
    }

    public func index(at point: CGPoint) -> Int {
        lineIndex(atY: point.y).map { index(onLine: $0, x: point.x) } ?? 0
    }

    public func index(from index: Int, movingLines delta: Int, goalX: CGFloat) -> Int {
        let target = lineIndex(forLayout: layoutOffset(index)).map { $0 + delta }
        if let target, lines.indices.contains(target) {
            return self.index(onLine: target, x: goalX)
        } else if let target, target >= lines.count {
            return sourceLength
        } else if target != nil {
            return 0
        } else {
            return index
        }
    }

    public func lineBoundary(of index: Int, end: Bool) -> Int {
        lineIndex(forLayout: layoutOffset(index)).map { lineIndex in
            let line = lines[lineIndex]
            return sourceIndex(forLayout: end ? line.lastOffset : line.start)
        } ?? index
    }

    public func chord(at point: CGPoint, slop: CGFloat) -> Int? {
        chords
            .filter { $0.rect.insetBy(dx: -slop, dy: -slop).contains(point) }
            .min { abs($0.rect.midX - point.x) < abs($1.rect.midX - point.x) }?
            .index
    }

    public func anchor(at point: CGPoint) -> (line: Int, column: Int) {
        let utf16 = index(at: point)
        let position = String.Index(utf16Offset: min(utf16, source.utf16.count), in: source)
        let before = source[..<position]
        let line = before.reduce(0) { $1 == "\n" ? $0 + 1 : $0 }
        let lineStart = before.lastIndex(of: "\n").map { source.index(after: $0) } ?? source.startIndex
        return (line, source.distance(from: lineStart, to: position))
    }

    public func caretRect(line: Int, column: Int) -> CGRect {
        let sourceLines = source.components(separatedBy: "\n")
        let clampedLine = min(max(line, 0), max(sourceLines.count - 1, 0))
        let lineStart = sourceLines.prefix(clampedLine).reduce(0) { $0 + $1.utf16.count + 1 }
        let text = sourceLines.indices.contains(clampedLine) ? sourceLines[clampedLine] : ""
        let column = text.prefix(max(column, 0)).utf16.count
        return caretRect(at: lineStart + column)
    }

    private func layoutOffset(_ index: Int) -> Int {
        sourceToLayout[min(max(index, 0), sourceLength)]
    }

    private func sourceIndex(forLayout offset: Int) -> Int {
        var low = 0
        var high = sourceLength
        while low < high {
            let mid = (low + high + 1) / 2
            if sourceToLayout[mid] <= offset { low = mid } else { high = mid - 1 }
        }
        return low
    }

    private func lineIndex(forLayout offset: Int) -> Int? {
        lines.isEmpty ? nil : (lines.lastIndex { $0.start <= offset } ?? 0)
    }

    private func lineIndex(atY y: CGFloat) -> Int? {

        let splits = zip(lines, lines.dropFirst()).map { ($0.bottom + $1.top) / 2 }
        return lines.isEmpty ? nil : (splits.firstIndex { y < $0 } ?? lines.count - 1)
    }

    private func index(onLine lineIndex: Int, x: CGFloat) -> Int {
        let line = lines[lineIndex]
        if line.isVirtual {
            return sourceLength
        } else {
            let hit = CTLineGetStringIndexForPosition(line.line, CGPoint(x: x - line.origin.x, y: 0))
            let offset = hit == kCFNotFound ? line.start : hit
            return sourceIndex(forLayout: min(max(offset, line.start), line.lastOffset))
        }
    }

    private func xOffset(_ offset: Int, in line: Line) -> CGFloat {
        let local = line.isVirtual ? CTLineGetStringRange(line.line).location : min(max(offset, line.start), line.end)
        return line.origin.x + CTLineGetOffsetForStringIndex(line.line, local, nil)
    }

    private static func lines(of layout: TextRasterizer.FrameLayout, boxHeight: CGFloat) -> [Line] {
        let ctLines = CTFrameGetLines(layout.frame) as? [CTLine] ?? []
        var origins = [CGPoint](repeating: .zero, count: ctLines.count)
        CTFrameGetLineOrigins(layout.frame, CFRange(location: 0, length: 0), &origins)
        let string = CFAttributedStringGetString(layout.attributed) as NSString
        return zip(ctLines, origins).enumerated().map { index, pair in
            let (line, origin) = pair
            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            CTLineGetTypographicBounds(line, &ascent, &descent, nil)
            let range = CTLineGetStringRange(line)
            let rangeEnd = range.location + range.length
            let endsWithNewline = rangeEnd > range.location && string.character(at: rangeEnd - 1) == 0x0A
            return Line(
                line: line,

                origin: CGPoint(
                    x: layout.frameRect.minX + origin.x,
                    y: boxHeight - (layout.frameRect.minY + origin.y)
                ),
                ascent: ascent, descent: descent,
                start: range.location, end: endsWithNewline ? rangeEnd - 1 : rangeEnd,
                softWrapped: !endsWithNewline && index < ctLines.count - 1
            )
        }
    }

    private static func lineStart(_ lineNumber: Int, in string: String) -> Int {
        var offset = 0
        for (index, line) in string.components(separatedBy: "\n").enumerated() {
            if index == lineNumber { return offset }
            offset += (line as NSString).length + 1
        }
        return offset
    }

    static func sourceMap(
        source: String, transform: SceneTextTransform,
        chordRows: [TextRasterizer.ChordedLayout.Row], layoutString: String
    ) -> [Int] {
        var sourceToDisplay: [Int] = []
        sourceToDisplay.reserveCapacity(source.utf16.count + 1)
        var display = 0
        for character in source {
            let sourceWidth = character.utf16.count
            let displayWidth = switch transform {
            case .none: sourceWidth
            case .uppercase: String(character).uppercased().utf16.count
            }

            sourceToDisplay.append(contentsOf: repeatElement(display, count: sourceWidth))
            display += displayWidth
        }
        sourceToDisplay.append(display)
        guard !chordRows.isEmpty else { return sourceToDisplay }

        let lyricStarts = chordRows.map { lineStart($0.lyricLine, in: layoutString) }
        return sourceToDisplay.map { offset in

            let row = chordRows.lastIndex { $0.displayRange.location <= offset } ?? 0
            let range = chordRows[row].displayRange
            return lyricStarts[row] + min(max(offset - range.location, 0), range.length)
        }
    }
}
