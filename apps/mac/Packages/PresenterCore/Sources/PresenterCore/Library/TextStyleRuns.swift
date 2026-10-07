import Foundation

public enum TextStyleRuns {

    public static func characterRange(fromUTF16 location: Int, length: Int, in text: String) -> Range<Int> {
        func characters(at utf16Offset: Int, roundDown: Bool) -> Int {
            let clamped = min(max(0, utf16Offset), text.utf16.count)
            let utf16Index = text.utf16.index(text.utf16.startIndex, offsetBy: clamped)
            if let index = String.Index(utf16Index, within: text) {
                return text.distance(from: text.startIndex, to: index)
            }

            let below = text.unicodeScalars.index(before: utf16Index.samePosition(in: text.unicodeScalars) ?? text.unicodeScalars.endIndex)
            let base = String.Index(below, within: text).map { text.distance(from: text.startIndex, to: $0) } ?? 0
            return roundDown ? base : base + 1
        }
        let start = characters(at: location, roundDown: true)
        let end = characters(at: location + length, roundDown: false)
        return start..<max(start, end)
    }

    struct RunStyle: Equatable {
        var underline: Bool?
        var strikethrough: Bool?
        var fontName: String?
        var fontSize: Double?
        var colorHex: String?
        var highlightColorHex: String?
        var tracking: Double?

        init() {}

        init(of run: TextStyleRun) {
            underline = run.underline
            strikethrough = run.strikethrough
            fontName = run.fontName
            fontSize = run.fontSize
            colorHex = run.colorHex
            highlightColorHex = run.highlightColorHex
            tracking = run.tracking
        }

        var isEmpty: Bool { self == RunStyle() }

        mutating func fold(_ other: RunStyle) {
            if let value = other.underline { underline = value }
            if let value = other.strikethrough { strikethrough = value }
            if let value = other.fontName { fontName = value }
            if let value = other.fontSize { fontSize = value }
            if let value = other.colorHex { colorHex = value }
            if let value = other.highlightColorHex { highlightColorHex = value }
            if let value = other.tracking { tracking = value }
        }

        func run(line: Int, column: Int, length: Int) -> TextStyleRun {
            TextStyleRun(
                line: line, column: column, length: length,
                underline: underline, strikethrough: strikethrough,
                fontName: fontName, fontSize: fontSize, colorHex: colorHex,
                highlightColorHex: highlightColorHex, tracking: tracking
            )
        }
    }

    private struct Segment {
        var range: Range<Int>
        var style: RunStyle
    }

    private static func lineStarts(of lines: [String]) -> [Int] {
        var starts: [Int] = []
        var running = 0
        for line in lines {
            starts.append(running)
            running += line.count + 1
        }
        return starts
    }

    private static func segments(of runs: [TextStyleRun], lines: [String], starts: [Int]) -> [Segment] {
        runs.compactMap { run in
            guard run.line >= 0, run.line < lines.count, run.length > 0 else { return nil }
            let count = lines[run.line].count
            let column = min(max(0, run.column), count)
            let end = min(column + run.length, count)
            guard end > column else { return nil }
            return Segment(
                range: (starts[run.line] + column)..<(starts[run.line] + end),
                style: RunStyle(of: run)
            )
        }
    }

    private static func runs(from segments: [Segment], lines: [String], starts: [Int]) -> [TextStyleRun] {
        var merged: [Segment] = []
        for segment in segments.sorted(by: { $0.range.lowerBound < $1.range.lowerBound }) {
            guard !segment.style.isEmpty, !segment.range.isEmpty else { continue }
            if var last = merged.last, last.range.upperBound == segment.range.lowerBound,
               last.style == segment.style {
                last.range = last.range.lowerBound..<segment.range.upperBound
                merged[merged.count - 1] = last
            } else {
                merged.append(segment)
            }
        }
        return merged.compactMap { segment in
            guard let line = starts.lastIndex(where: { $0 <= segment.range.lowerBound }) else { return nil }
            return segment.style.run(
                line: line,
                column: segment.range.lowerBound - starts[line],
                length: segment.range.count
            )
        }
    }

    public static func effectiveRun(at position: Int, runs: [TextStyleRun], in text: String) -> TextStyleRun? {
        let lines = text.components(separatedBy: "\n")
        let starts = lineStarts(of: lines)
        var folded = RunStyle()
        for segment in segments(of: runs, lines: lines, starts: starts)
        where segment.range.contains(position) {
            folded.fold(segment.style)
        }
        return folded.isEmpty ? nil : folded.run(line: 0, column: 0, length: 0)
    }

    public static func applying(
        _ mutate: (inout TextStyleRun) -> Void,
        to runs: [TextStyleRun],
        in text: String,
        selection: Range<Int>
    ) -> [TextStyleRun] {
        guard !selection.isEmpty else { return runs }
        let lines = text.components(separatedBy: "\n")
        let starts = lineStarts(of: lines)

        var passthrough: [TextStyleRun] = []
        var rebuilt: [Segment] = []
        for (index, line) in lines.enumerated() {
            let content = starts[index]..<(starts[index] + line.count)
            let selected = selection.clamped(to: content)
            let lineRuns = runs.filter { $0.line == index }
            if selected.isEmpty {
                passthrough.append(contentsOf: lineRuns)
                continue
            }
            let lineSegments = segments(of: lineRuns, lines: lines, starts: starts)
            var boundaries = Set([selected.lowerBound, selected.upperBound])
            for segment in lineSegments {
                boundaries.insert(segment.range.lowerBound)
                boundaries.insert(segment.range.upperBound)
            }
            let sorted = boundaries.sorted()
            for (start, end) in zip(sorted, sorted.dropFirst()) {
                let piece = start..<end
                var folded = RunStyle()
                for segment in lineSegments where segment.range.lowerBound <= start && end <= segment.range.upperBound {
                    folded.fold(segment.style)
                }
                if selected.lowerBound <= start, end <= selected.upperBound {
                    var run = folded.run(line: index, column: start - starts[index], length: piece.count)
                    mutate(&run)
                    folded = RunStyle(of: run)
                }
                rebuilt.append(Segment(range: piece, style: folded))
            }
        }
        let edited = self.runs(from: rebuilt, lines: lines, starts: starts)
        return (passthrough + edited).sorted { ($0.line, $0.column) < ($1.line, $1.column) }
    }

    public static func replacing(
        _ runs: [TextStyleRun],
        range replaced: Range<Int>,
        with replacement: String,
        in oldText: String
    ) -> [TextStyleRun] {
        let oldLines = oldText.components(separatedBy: "\n")
        let oldStarts = lineStarts(of: oldLines)
        let newText = splice(oldText, replacing: replaced, with: replacement)
        let newLines = newText.components(separatedBy: "\n")
        let newStarts = lineStarts(of: newLines)
        let delta = replacement.count - replaced.count

        var shifted: [Segment] = []
        for segment in segments(of: runs, lines: oldLines, starts: oldStarts) {
            let range = segment.range
            if range.lowerBound < replaced.lowerBound, replaced.upperBound < range.upperBound {

                shifted.append(Segment(
                    range: range.lowerBound..<(range.upperBound + delta), style: segment.style
                ))
                continue
            }
            let before = range.clamped(to: 0..<replaced.lowerBound)
            if !before.isEmpty { shifted.append(Segment(range: before, style: segment.style)) }
            let after = range.clamped(to: replaced.upperBound..<max(replaced.upperBound, range.upperBound))
            if !after.isEmpty {
                shifted.append(Segment(
                    range: (after.lowerBound + delta)..<(after.upperBound + delta),
                    style: segment.style
                ))
            }
        }

        var pieces: [Segment] = []
        for segment in shifted {
            for (index, line) in newLines.enumerated() {
                let content = newStarts[index]..<(newStarts[index] + line.count)
                let overlap = segment.range.clamped(to: content)
                if !overlap.isEmpty { pieces.append(Segment(range: overlap, style: segment.style)) }
            }
        }
        return self.runs(from: pieces, lines: newLines, starts: newStarts)
    }

    public static func replacing(
        _ chords: [ChordPlacement],
        range replaced: Range<Int>,
        with replacement: String,
        in oldText: String
    ) -> [ChordPlacement] {
        let oldLines = oldText.components(separatedBy: "\n")
        let oldStarts = lineStarts(of: oldLines)
        let newText = splice(oldText, replacing: replaced, with: replacement)
        let newLines = newText.components(separatedBy: "\n")
        let newStarts = lineStarts(of: newLines)
        let delta = replacement.count - replaced.count

        return chords.compactMap { chord in
            guard chord.line >= 0, chord.line < oldLines.count else { return chord }
            let position = oldStarts[chord.line] + min(max(0, chord.column), oldLines[chord.line].count)
            let moved: Int
            if position < replaced.lowerBound {
                moved = position
            } else if position >= replaced.upperBound {

                moved = position + delta
            } else {
                return nil
            }
            guard let line = newStarts.lastIndex(where: { $0 <= moved }) else { return nil }
            var updated = chord
            updated.line = line
            updated.column = min(moved - newStarts[line], newLines[line].count)
            return updated
        }
    }

    private static func splice(_ text: String, replacing range: Range<Int>, with replacement: String) -> String {
        let start = text.index(text.startIndex, offsetBy: min(range.lowerBound, text.count))
        let end = text.index(text.startIndex, offsetBy: min(range.upperBound, text.count))
        return text.replacingCharacters(in: start..<end, with: replacement)
    }
}

public enum AnimationRanges {

    public static func ranges(forSelection selection: Range<Int>, in text: String) -> [AnimationRange] {
        guard !selection.isEmpty else { return [] }
        let runs = TextStyleRuns.applying(
            { $0.underline = true }, to: [], in: text, selection: selection
        )
        return runs.map { AnimationRange(line: $0.line, column: $0.column, length: $0.length) }
    }

    public static func replacing(
        _ ranges: [AnimationRange], range replaced: Range<Int>, with replacement: String, in oldText: String
    ) -> [AnimationRange] {
        ranges.flatMap { range in
            TextStyleRuns.replacing(
                [TextStyleRun(line: range.line, column: range.column, length: range.length, underline: true)],
                range: replaced, with: replacement, in: oldText
            ).map { AnimationRange(line: $0.line, column: $0.column, length: $0.length) }
        }
    }

    public static func reanchor(
        _ animationSteps: [AnimationStep], range replaced: Range<Int>, with replacement: String, in oldText: String
    ) -> [AnimationStep] {
        animationSteps.compactMap { step in
            guard let ranges = step.ranges, !ranges.isEmpty else { return step }
            let moved = replacing(ranges, range: replaced, with: replacement, in: oldText)
            guard !moved.isEmpty else { return nil }
            var updated = step
            updated.ranges = moved
            return updated
        }
    }

    public static func words(in ranges: [AnimationRange], text: String) -> [AnimationRange] {
        let lines = text.components(separatedBy: "\n")
        var out: [AnimationRange] = []
        for range in ranges {
            guard range.line >= 0, range.line < lines.count else { continue }
            let line = Array(lines[range.line])
            let start = min(max(range.column, 0), line.count)
            let end = min(start + max(range.length, 0), line.count)
            var index = start
            while index < end {
                while index < end, line[index].isWhitespace { index += 1 }
                let wordStart = index
                while index < end, !line[index].isWhitespace { index += 1 }
                if index > wordStart {
                    out.append(AnimationRange(line: range.line, column: wordStart, length: index - wordStart))
                }
            }
        }
        return out
    }

    public enum Generator: Sendable { case line, word }

    public static func split(_ ranges: [AnimationRange], by generator: Generator, in text: String) -> [AnimationRange] {
        switch generator {
        case .line: ranges.filter { $0.length > 0 }
        case .word: words(in: ranges, text: text)
        }
    }

    public static func appendingToLastStep(
        _ ranges: [AnimationRange], in animationSteps: [AnimationStep]?
    ) -> (animationSteps: [AnimationStep], stepID: String)? {
        guard var animationSteps, let last = animationSteps.indices.last, animationSteps[last].ranges?.isEmpty == false
        else { return nil }
        animationSteps[last].ranges = (animationSteps[last].ranges ?? []) + ranges
        return (animationSteps, animationSteps[last].id)
    }

    public static func text(of range: AnimationRange, in text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        guard range.line >= 0, range.line < lines.count else { return "" }
        let line = lines[range.line]
        let start = min(max(0, range.column), line.count)
        let end = min(start + max(range.length, 0), line.count)
        guard end > start else { return "" }
        return String(line[line.index(line.startIndex, offsetBy: start)..<line.index(line.startIndex, offsetBy: end)])
    }
}
