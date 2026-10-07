import Accelerate
import CoreGraphics
import CoreText
import Foundation
import Metal
import QuartzCore

public enum TextRasterizer {

    struct Key: Hashable {
        let text: StyledText
        let pixelWidth: Int
        let pixelHeight: Int

        let scaleMilli: Int

        let fontScaleMilli: Int
    }

    private struct FitKey: Hashable {
        let text: StyledText
        let widthMilli: Int
        let heightMilli: Int
    }

    private static let fitCache = Locked<[FitKey: Double]>([:])

    static func fittedFontScale(for text: StyledText, sceneFrame: CGSize) -> Double {
        guard text.autoShrink, !text.string.isEmpty,
              sceneFrame.width > 0, sceneFrame.height > 0,
              text.fontSize > 0
        else { return 1 }
        let key = FitKey(
            text: text,
            widthMilli: Int(sceneFrame.width * 1000),
            heightMilli: Int(sceneFrame.height * 1000)
        )
        if let cached = fitCache.value[key] { return cached }

        let fitted = computeFittedFontScale(for: text, sceneFrame: insetLayoutSize(for: text, frame: sceneFrame))
        fitCache.withLock { cache in

            if cache.count >= 512 { cache.removeAll(keepingCapacity: true) }
            cache[key] = fitted
        }
        return fitted
    }

    public static func overflows(_ text: StyledText, sceneFrame: CGSize) -> Bool {
        guard !text.string.isEmpty, sceneFrame.width > 0, sceneFrame.height > 0,
              text.fontSize > 0
        else { return false }
        let inset = insetLayoutSize(for: text, frame: sceneFrame)
        let scale = fittedFontScale(for: text, sceneFrame: sceneFrame)

        var probe = text
        probe.keepLinesWhole = false
        return !fitsFrame(probe, fontScale: scale, sceneFrame: inset)
    }

    private static let pagesCache = Locked<[FitKey: [String]]>([:])

    public static func pages(for text: StyledText, sceneFrame: CGSize) -> [String] {
        guard !text.string.isEmpty, sceneFrame.width > 0, sceneFrame.height > 0, text.fontSize > 0,
              text.pathData == nil, text.tickerSpeed == 0, text.scroll == nil
        else { return [text.string] }
        let key = FitKey(text: text, widthMilli: Int(sceneFrame.width * 1000), heightMilli: Int(sceneFrame.height * 1000))
        if let cached = pagesCache.value[key] { return cached }
        let scale = fittedFontScale(for: text, sceneFrame: sceneFrame)
        let inset = insetLayoutSize(for: text, frame: sceneFrame)

        var plain = text
        plain.chords = []
        plain.balancedLineInsets = []
        plain.transform = .none
        let attributed = attributedString(for: plain, fontScale: scale, pixelScale: 1)
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let source = text.string as NSString
        var pages: [String] = []
        var start = 0
        while start < source.length {
            var fit = CFRange()
            _ = CTFramesetterSuggestFrameSizeWithConstraints(
                framesetter, CFRange(location: start, length: source.length - start), nil, inset, &fit)

            let length = fit.length > 0 ? fit.length : source.length - start
            let page = source.substring(with: NSRange(location: start, length: length))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !page.isEmpty { pages.append(page) }
            start += length
        }
        let result = pages.isEmpty ? [text.string] : pages
        pagesCache.withLock { cache in
            if cache.count >= 512 { cache.removeAll(keepingCapacity: true) }
            cache[key] = result
        }
        return result
    }

    private static let blockHeightCache = Locked<[FitKey: CGFloat]>([:])

    public static func blockHeight(for text: StyledText, sceneWidth: CGFloat) -> CGFloat {
        guard !text.string.isEmpty, sceneWidth > 0, text.fontSize > 0 else { return 0 }
        let key = FitKey(text: text, widthMilli: Int(sceneWidth * 1000), heightMilli: 0)
        if let cached = blockHeightCache.value[key] { return cached }
        let width = max(sceneWidth - CGFloat(text.insetLeft + text.insetRight), 1)
        let measured = measuredHeight(text, fontScale: 1, width: width)
            + CGFloat(text.insetTop + text.insetBottom)
        blockHeightCache.withLock { cache in
            if cache.count >= 512 { cache.removeAll(keepingCapacity: true) }
            cache[key] = measured
        }
        return measured
    }

    static func insetLayoutSize(for text: StyledText, frame: CGSize) -> CGSize {
        CGSize(
            width: max(frame.width - CGFloat(text.insetLeft + text.insetRight), 1),
            height: max(frame.height - CGFloat(text.insetTop + text.insetBottom), 1)
        )
    }

    private static func computeFittedFontScale(for text: StyledText, sceneFrame: CGSize) -> Double {
        if fitsFrame(text, fontScale: 1, sceneFrame: sceneFrame) {
            return 1
        }
        let floorScale = min(1, max(0.01, text.minFontSize / text.fontSize))
        var lo = floorScale
        var hi = 1.0
        for _ in 0..<10 {
            let mid = (lo + hi) / 2
            if fitsFrame(text, fontScale: mid, sceneFrame: sceneFrame) {
                lo = mid
            } else {
                hi = mid
            }
        }

        return (lo * 1000).rounded(.down) / 1000
    }

    private static func widthConstrained(_ text: StyledText) -> Bool {
        !text.chords.isEmpty || text.keepLinesWhole
    }

    private static func fitsFrame(_ text: StyledText, fontScale: Double, sceneFrame: CGSize) -> Bool {

        if widthConstrained(text),
           maxUnwrappedLineWidth(text, fontScale: fontScale) > sceneFrame.width - 1 {
            return false
        }
        return measuredHeight(text, fontScale: fontScale, width: sceneFrame.width) <= sceneFrame.height
    }

    private static func maxUnwrappedLineWidth(_ text: StyledText, fontScale: Double) -> CGFloat {
        var plain = text
        plain.chords = []
        let attributed = attributedString(for: plain, fontScale: fontScale, pixelScale: 1)
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let unconstrained = CGSize(
            width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude
        )
        return CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter, CFRange(location: 0, length: 0), nil, unconstrained, nil
        ).width
    }

    private static func measuredHeight(_ text: StyledText, fontScale: Double, width: CGFloat) -> CGFloat {
        let measured = chordedLayout(for: text, sceneWidth: width, fontScale: fontScale)?.text ?? text
        let attributed = attributedString(for: measured, fontScale: fontScale, pixelScale: 1)
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let constraint = CGSize(width: width, height: .greatestFiniteMagnitude)
        return CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter, CFRange(location: 0, length: 0), nil, constraint, nil
        ).height
    }

    static func balancedLineInsets(
        for text: StyledText, sceneWidth: CGFloat, fontScale: Double
    ) -> [BalancedLineInset] {
        guard text.balancedWrap, text.pathData == nil, !text.string.isEmpty,
              sceneWidth > 1, text.fontSize > 0
        else { return [] }

        var plain = text
        plain.chords = []
        plain.balancedLineInsets = []
        let attributed = attributedString(for: plain, fontScale: fontScale, pixelScale: 1)
            as NSAttributedString
        let displayString: String = switch text.transform {
        case .none: text.string
        case .uppercase: text.string.uppercased()
        }
        var insets: [BalancedLineInset] = []
        var location = 0
        for (index, line) in displayString.components(separatedBy: "\n").enumerated() {
            let length = (line as NSString).length
            defer { location += length + 1 }
            guard length > 0, location + length <= attributed.length else { continue }
            let paragraph = attributed.attributedSubstring(
                from: NSRange(location: location, length: length))
            func lineCount(at width: CGFloat) -> Int {
                let framesetter = CTFramesetterCreateWithAttributedString(paragraph)
                let path = CGPath(
                    rect: CGRect(x: 0, y: 0, width: width, height: .greatestFiniteMagnitude / 2),
                    transform: nil
                )
                let frame = CTFramesetterCreateFrame(
                    framesetter, CFRange(location: 0, length: 0), path, nil)
                return CFArrayGetCount(CTFrameGetLines(frame))
            }
            let rows = lineCount(at: sceneWidth)

            guard rows > 1, lineCount(at: 1) > rows else { continue }
            var lo: CGFloat = 1          
            var hi = sceneWidth          
            for _ in 0..<20 {
                let mid = (lo + hi) / 2
                if lineCount(at: mid) == rows { hi = mid } else { lo = mid }
            }

            let balanced = (hi * 1000).rounded(.up) / 1000
            let delta = Double(sceneWidth - balanced)
            guard delta >= 1 else { continue }
            let inset: BalancedLineInset = switch text.alignment {
            case .center: BalancedLineInset(line: index, left: delta / 2, right: delta / 2)
            case .left: BalancedLineInset(line: index, left: 0, right: delta)
            case .right: BalancedLineInset(line: index, left: delta, right: 0)
            }
            insets.append(inset)
        }
        return insets
    }

    static let chordSizeFactor: Double = 0.7

    static let defaultChordColor = SceneColor(red: 1.0, green: 0.72, blue: 0.15)

    private static let chordGapEms: CGFloat = 0.35

    static let chordOnlyLyric = "\u{200B}"

    struct ChordedLayout {

        struct Row {
            var spacerLine: Int
            var lyricLine: Int

            var displayRange: NSRange
            var chords: [(utf16Column: Int, symbol: String, source: Int)]
        }

        var text: StyledText
        var rows: [Row]
    }

    static func chordedLayout(for text: StyledText, sceneWidth: CGFloat, fontScale: Double) -> ChordedLayout? {
        guard !text.chords.isEmpty, text.pathData == nil, sceneWidth > 0 else { return nil }

        var plain = text
        plain.chords = []
        let attributed = attributedString(for: plain, fontScale: fontScale, pixelScale: 1)
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let path = CGPath(
            rect: CGRect(x: 0, y: 0, width: sceneWidth, height: .greatestFiniteMagnitude / 2),
            transform: nil
        )
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)

        let ctLines = (CTFrameGetLines(frame) as? [CTLine]) ?? []
        guard !ctLines.isEmpty || text.string.isEmpty else { return nil }

        let displayString: String = switch text.transform {
        case .none: text.string
        case .uppercase: text.string.uppercased()
        }
        let display = displayString as NSString
        let sourceLines = displayString.components(separatedBy: "\n")
        var sourceStartUTF16: [Int] = []
        var running = 0
        for line in sourceLines {
            sourceStartUTF16.append(running)
            running += (line as NSString).length + 1
        }

        struct Fragment {
            var sourceLine: Int
            var range: NSRange
            var text: String
            var chords: [(utf16Column: Int, symbol: String, source: Int)] = []
        }
        var fragments: [Fragment] = ctLines.map { line in
            let cfRange = CTLineGetStringRange(line)
            var range = NSRange(location: cfRange.location, length: cfRange.length)

            if range.length > 0, display.character(at: range.location + range.length - 1) == 0x0A {
                range.length -= 1
            }
            let sourceLine = (sourceStartUTF16.lastIndex { $0 <= range.location }) ?? 0
            return Fragment(sourceLine: sourceLine, range: range, text: display.substring(with: range))
        }

        let lastSourceLine = sourceLines.count - 1
        if !fragments.contains(where: { $0.sourceLine == lastSourceLine }) {
            fragments.append(Fragment(
                sourceLine: lastSourceLine, range: NSRange(location: display.length, length: 0), text: ""
            ))
        }

        for (source, chord) in text.chords.enumerated() {
            guard chord.line >= 0, chord.line < sourceLines.count else { continue }
            let line = sourceLines[chord.line]
            let columnUTF16: Int
            if chord.column >= line.count {
                columnUTF16 = (line as NSString).length
            } else {
                let index = line.index(line.startIndex, offsetBy: max(0, chord.column))
                columnUTF16 = line.utf16.distance(from: line.utf16.startIndex, to: index)
            }
            let global = sourceStartUTF16[chord.line] + columnUTF16

            guard let fragmentIndex = fragments.lastIndex(where: {
                $0.sourceLine == chord.line && $0.range.location <= global
            }) ?? fragments.firstIndex(where: { $0.sourceLine == chord.line }) else { continue }
            let within = min(max(0, global - fragments[fragmentIndex].range.location), fragments[fragmentIndex].range.length)
            fragments[fragmentIndex].chords.append((utf16Column: within, symbol: chord.symbol, source: source))
        }

        let overridesBySource = Dictionary(
            text.lineOverrides.map { ($0.lineIndex, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        func fragmentRuns(for fragment: Fragment) -> [(column: Int, length: Int, source: StyleRun)] {
            text.styleRuns.compactMap { run in
                guard run.line == fragment.sourceLine,
                      run.line >= 0, run.line < sourceLines.count, run.length > 0 else { return nil }
                let line = sourceLines[run.line]
                let startChar = min(max(0, run.column), line.count)
                let endChar = min(startChar + run.length, line.count)
                guard endChar > startChar else { return nil }
                func utf16Offset(_ characters: Int) -> Int {
                    let index = line.index(line.startIndex, offsetBy: characters)
                    return line.utf16.distance(from: line.utf16.startIndex, to: index.samePosition(in: line.utf16) ?? line.utf16.startIndex)
                }
                let global = NSRange(
                    location: sourceStartUTF16[run.line] + utf16Offset(startChar),
                    length: utf16Offset(endChar) - utf16Offset(startChar)
                )
                let overlap = NSIntersectionRange(global, fragment.range)
                guard overlap.length > 0 else { return nil }
                let local = fragment.text
                func charOffset(_ utf16: Int) -> Int {
                    let utf16Index = local.utf16.index(local.utf16.startIndex, offsetBy: min(utf16, local.utf16.count))
                    return String.Index(utf16Index, within: local)
                        .map { local.distance(from: local.startIndex, to: $0) } ?? local.count
                }
                let start = charOffset(overlap.location - fragment.range.location)
                let end = charOffset(overlap.location + overlap.length - fragment.range.location)
                guard end > start else { return nil }
                return (column: start, length: end - start, source: run)
            }
        }
        let chordFontSize = text.fontSize * chordSizeFactor
        var interleavedLines: [String] = []
        var overrides: [TextLineOverride] = []
        var remappedRuns: [StyleRun] = []
        var rows: [ChordedLayout.Row] = []
        for fragment in fragments {
            let spacerIndex = interleavedLines.count
            interleavedLines.append("")
            overrides.append(TextLineOverride(lineIndex: spacerIndex, fontSize: chordFontSize))
            let lyricIndex = interleavedLines.count

            interleavedLines.append(
                fragment.text.isEmpty && !fragment.chords.isEmpty ? Self.chordOnlyLyric : fragment.text
            )
            if var override = overridesBySource[fragment.sourceLine] {
                override.lineIndex = lyricIndex
                overrides.append(override)
            }
            for piece in fragmentRuns(for: fragment) {
                var remapped = piece.source
                remapped.line = lyricIndex
                remapped.column = piece.column
                remapped.length = piece.length
                remappedRuns.append(remapped)
            }
            rows.append(ChordedLayout.Row(
                spacerLine: spacerIndex, lyricLine: lyricIndex, displayRange: fragment.range,
                chords: fragment.chords.sorted { $0.utf16Column < $1.utf16Column }
            ))
        }

        var interleaved = text
        interleaved.chords = []

        interleaved.string = interleavedLines.joined(separator: "\n")
        interleaved.lineOverrides = overrides
        interleaved.styleRuns = remappedRuns
        return ChordedLayout(text: interleaved, rows: rows)
    }

    struct PlacedChord {
        var source: Int
        var run: CTLine
        var origin: CGPoint
        var width: CGFloat
        var ascent: CGFloat
        var descent: CGFloat
    }

    static func chordPlacements(
        _ layout: ChordedLayout,
        frame: CTFrame,
        frameRect: CGRect,
        text: StyledText,
        fontScale: Double,
        pixelScale: CGFloat,
        colorSpace: CGColorSpace?
    ) -> [PlacedChord] {
        guard let lines = CTFrameGetLines(frame) as? [CTLine], !lines.isEmpty else { return [] }
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)

        var lineStartUTF16: [Int] = []
        var running = 0
        for line in layout.text.string.components(separatedBy: "\n") {
            lineStartUTF16.append(running)
            running += (line as NSString).length + 1
        }
        var ctLineForInterleavedLine: [Int: Int] = [:]
        for (index, line) in lines.enumerated() {
            let location = CTLineGetStringRange(line).location
            if let lineNumber = lineStartUTF16.lastIndex(where: { $0 <= location }),
               ctLineForInterleavedLine[lineNumber] == nil {
                ctLineForInterleavedLine[lineNumber] = index
            }
        }

        let chordFontSize = text.fontSize * chordSizeFactor * fontScale * pixelScale
        let font = makeFont(name: text.fontName, size: chordFontSize, tabularFigures: false)
        let color = colorSpace.flatMap { cgColor(text.chordColor ?? defaultChordColor, in: $0) }
        let gap = chordFontSize * chordGapEms

        var placed: [PlacedChord] = []
        for row in layout.rows {
            guard !row.chords.isEmpty,
                  let spacerIndex = ctLineForInterleavedLine[row.spacerLine],
                  let lyricIndex = ctLineForInterleavedLine[row.lyricLine]
            else { continue }
            let lyricLine = lines[lyricIndex]
            let lyricOrigin = origins[lyricIndex]
            let baselineY = frameRect.minY + origins[spacerIndex].y
            let lyricStart = lineStartUTF16[row.lyricLine]

            var attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
            ]
            if let color {
                attributes[NSAttributedString.Key(kCTForegroundColorAttributeName as String)] = color
            }
            let runs = row.chords.map { chord in
                let run = CTLineCreateWithAttributedString(
                    NSAttributedString(string: chord.symbol, attributes: attributes)
                )
                var ascent: CGFloat = 0
                var descent: CGFloat = 0
                let width = CGFloat(CTLineGetTypographicBounds(run, &ascent, &descent, nil))
                return (chord: chord, run: run, width: width, ascent: ascent, descent: descent)
            }

            let wordless = row.displayRange.length == 0
            var cursor = -CGFloat.greatestFiniteMagnitude
            if wordless {
                let rowWidth = runs.map(\.width).reduce(0, +) + gap * CGFloat(max(runs.count - 1, 0))
                let alignmentFactor: CGFloat = switch text.alignment {
                case .left: 0
                case .center: 0.5
                case .right: 1
                }
                cursor = frameRect.minX + lyricOrigin.x - rowWidth * alignmentFactor
            }
            for entry in runs {
                let anchorX = frameRect.minX + lyricOrigin.x + CTLineGetOffsetForStringIndex(
                    lyricLine, lyricStart + entry.chord.utf16Column, nil
                )
                let x = wordless ? cursor : max(anchorX, cursor)
                placed.append(PlacedChord(
                    source: entry.chord.source, run: entry.run, origin: CGPoint(x: x, y: baselineY),
                    width: entry.width, ascent: entry.ascent, descent: entry.descent
                ))
                cursor = x + entry.width + gap
            }
        }
        return placed
    }

    private static func drawChords(
        _ layout: ChordedLayout,
        frame: CTFrame,
        frameRect: CGRect,
        text: StyledText,
        fontScale: Double,
        pixelScale: CGFloat,
        colorSpace: CGColorSpace,
        context: CGContext
    ) {
        for chord in chordPlacements(
            layout, frame: frame, frameRect: frameRect, text: text,
            fontScale: fontScale, pixelScale: pixelScale, colorSpace: colorSpace
        ) {
            context.textPosition = chord.origin
            CTLineDraw(chord.run, context)
        }
    }

    private static func makeParagraphStyle(
        alignment: CTTextAlignment,
        lineHeightMultiple: CGFloat,
        firstLineHeadIndent: CGFloat,
        headIndent: CGFloat,
        tailIndent: CGFloat,
        paragraphSpacing: CGFloat
    ) -> CTParagraphStyle {
        var settings: [CTParagraphStyleSetting] = []
        var storage: [UnsafeMutableRawPointer] = []
        defer { storage.forEach { $0.deallocate() } }
        func add<T>(_ spec: CTParagraphStyleSpecifier, _ value: T) {
            let pointer = UnsafeMutablePointer<T>.allocate(capacity: 1)
            pointer.initialize(to: value)
            storage.append(UnsafeMutableRawPointer(pointer))
            settings.append(CTParagraphStyleSetting(
                spec: spec, valueSize: MemoryLayout<T>.size, value: pointer
            ))
        }
        add(.alignment, alignment)
        add(.lineHeightMultiple, lineHeightMultiple)
        add(.firstLineHeadIndent, firstLineHeadIndent)
        add(.headIndent, headIndent)
        add(.tailIndent, tailIndent)
        add(.paragraphSpacing, paragraphSpacing)
        return CTParagraphStyleCreate(&settings, settings.count)
    }

    private static func makeFont(name: String, size: CGFloat, tabularFigures: Bool) -> CTFont {
        let base = CTFontCreateWithName(name as CFString, size, nil)
        guard tabularFigures else { return base }
        let features: [[CFString: Any]] = [
            [
                kCTFontFeatureTypeIdentifierKey: kNumberSpacingType,
                kCTFontFeatureSelectorIdentifierKey: kMonospacedNumbersSelector,
            ],
        ]
        let descriptor = CTFontDescriptorCreateWithAttributes(
            [kCTFontFeatureSettingsAttribute: features] as CFDictionary
        )
        return CTFontCreateCopyWithAttributes(base, size, nil, descriptor)
    }

    private static func cgColor(_ color: SceneColor, in space: CGColorSpace) -> CGColor? {
        LinearRaster.cgColor(color)
    }

    static func attributedString(
        for text: StyledText,
        fontScale: Double,
        pixelScale: CGFloat,
        colorSpace: CGColorSpace? = nil,
        includeOutline: Bool = true
    ) -> CFAttributedString {
        let displayString: String = switch text.transform {
        case .none: text.string
        case .uppercase: text.string.uppercased()
        }
        let lines = displayString.components(separatedBy: "\n")
        let overridesByLine = Dictionary(
            text.lineOverrides.map { ($0.lineIndex, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let balanceByLine = Dictionary(
            text.balancedLineInsets.map { ($0.line, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        let ctAlignment: CTTextAlignment = switch text.alignment {
        case .left: .left
        case .center: .center
        case .right: .right
        }

        let sharedParagraphStyle = makeParagraphStyle(
            alignment: ctAlignment,
            lineHeightMultiple: CGFloat(text.lineHeightMultiple),
            firstLineHeadIndent: CGFloat(text.leftIndent + text.firstLineIndent) * pixelScale,
            headIndent: CGFloat(text.leftIndent) * pixelScale,

            tailIndent: CGFloat(-text.rightIndent) * pixelScale,
            paragraphSpacing: CGFloat(text.paragraphSpacing) * pixelScale
        )

        let result = NSMutableAttributedString()
        for (index, line) in lines.enumerated() {
            let override = overridesByLine[index]
            let fontName = override?.fontName ?? text.fontName
            let fontSize = (override?.fontSize ?? text.fontSize) * fontScale * pixelScale
            let tracking = (override?.tracking ?? text.tracking) * fontScale * pixelScale
            let color = override?.color ?? text.color
            let font = makeFont(name: fontName, size: fontSize, tabularFigures: text.tabularFigures)

            let balance = balanceByLine[index]
            let paragraphStyle: CTParagraphStyle
            if override?.firstLineIndent != nil || override?.leftIndent != nil
                || override?.rightIndent != nil || balance != nil {
                let left = (override?.leftIndent ?? text.leftIndent) + (balance?.left ?? 0)
                let first = override?.firstLineIndent ?? text.firstLineIndent
                let right = (override?.rightIndent ?? text.rightIndent) + (balance?.right ?? 0)
                paragraphStyle = makeParagraphStyle(
                    alignment: ctAlignment,
                    lineHeightMultiple: CGFloat(text.lineHeightMultiple),
                    firstLineHeadIndent: CGFloat(left + first) * pixelScale,
                    headIndent: CGFloat(left) * pixelScale,
                    tailIndent: CGFloat(-right) * pixelScale,
                    paragraphSpacing: CGFloat(text.paragraphSpacing) * pixelScale
                )
            } else {
                paragraphStyle = sharedParagraphStyle
            }

            var attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTParagraphStyleAttributeName as String): paragraphStyle,
                NSAttributedString.Key(kCTKernAttributeName as String): tracking as CFNumber,
            ]
            if let space = colorSpace {
                if let fill = cgColor(color, in: space) {
                    attributes[NSAttributedString.Key(kCTForegroundColorAttributeName as String)] = fill
                }
                if includeOutline, let outline = text.outline, fontSize > 0,
                   let strokeColor = cgColor(outline.color, in: space) {

                    let percent = outline.width * fontScale * pixelScale / fontSize * 100
                    attributes[NSAttributedString.Key(kCTStrokeWidthAttributeName as String)] =
                        -percent as CFNumber
                    attributes[NSAttributedString.Key(kCTStrokeColorAttributeName as String)] = strokeColor
                }
            }
            let content = index == lines.count - 1 ? line : line + "\n"
            let segmentStart = result.length
            result.append(NSAttributedString(string: content, attributes: attributes))

            let lineLength = (line as NSString).length
            if lineLength > 0 {
                let lineRange = NSRange(location: segmentStart, length: lineLength)
                if text.underline { result.addAttribute(underlineMarkKey, value: true, range: lineRange) }
                if text.strikethrough { result.addAttribute(strikethroughMarkKey, value: true, range: lineRange) }
                for run in text.styleRuns where run.line == index && run.length > 0 {

                    let startChar = min(max(0, run.column), line.count)
                    let endChar = min(startChar + run.length, line.count)
                    guard endChar > startChar else { continue }
                    let startIndex = line.index(line.startIndex, offsetBy: startChar)
                    let endIndex = line.index(line.startIndex, offsetBy: endChar)
                    let utf16Start = line.utf16.distance(from: line.utf16.startIndex, to: startIndex.samePosition(in: line.utf16) ?? line.utf16.startIndex)
                    let utf16End = line.utf16.distance(from: line.utf16.startIndex, to: endIndex.samePosition(in: line.utf16) ?? line.utf16.endIndex)
                    guard utf16End > utf16Start else { continue }
                    let range = NSRange(location: segmentStart + utf16Start, length: utf16End - utf16Start)
                    if run.underline == true { result.addAttribute(underlineMarkKey, value: true, range: range) }
                    if run.strikethrough == true { result.addAttribute(strikethroughMarkKey, value: true, range: range) }
                    if run.fontName != nil || run.fontSize != nil {
                        let runSize = run.fontSize.map { $0 * fontScale * pixelScale } ?? fontSize
                        let runFont = makeFont(
                            name: run.fontName ?? fontName, size: runSize,
                            tabularFigures: text.tabularFigures
                        )
                        result.addAttribute(
                            NSAttributedString.Key(kCTFontAttributeName as String),
                            value: runFont, range: range
                        )

                        if let space = colorSpace, includeOutline, let outline = text.outline,
                           runSize > 0, cgColor(outline.color, in: space) != nil {
                            let percent = outline.width * fontScale * pixelScale / runSize * 100
                            result.addAttribute(
                                NSAttributedString.Key(kCTStrokeWidthAttributeName as String),
                                value: -percent as CFNumber, range: range
                            )
                        }
                    }
                    if let runTracking = run.tracking {
                        result.addAttribute(
                            NSAttributedString.Key(kCTKernAttributeName as String),
                            value: (runTracking * fontScale * pixelScale) as CFNumber,
                            range: range
                        )
                    }
                    if let space = colorSpace, let runColor = run.color,
                       let fill = cgColor(runColor, in: space) {
                        result.addAttribute(
                            NSAttributedString.Key(kCTForegroundColorAttributeName as String),
                            value: fill, range: range
                        )
                    }
                    if let highlight = run.highlightColor {

                        result.addAttribute(highlightMarkKey, value: highlight, range: range)
                    }
                    if run.hidden == true {

                        result.addAttribute(hiddenMarkKey, value: true, range: range)
                        result.removeAttribute(underlineMarkKey, range: range)
                        result.removeAttribute(strikethroughMarkKey, range: range)
                        result.removeAttribute(highlightMarkKey, range: range)
                        if run.placeholderUnderline == true {
                            result.addAttribute(placeholderUnderlineKey, value: run.color ?? color, range: range)
                        }
                        if run.caret == true {
                            result.addAttribute(caretKey, value: run.color ?? color, range: range)
                        }
                    }
                }
            }

            let wordSpacing = text.wordSpacing * fontScale * pixelScale
            if wordSpacing != 0 {
                let segment = content as NSString
                let kernKey = NSAttributedString.Key(kCTKernAttributeName as String)
                var searchRange = NSRange(location: 0, length: segment.length)
                while true {
                    let found = segment.range(of: " ", options: [], range: searchRange)
                    guard found.location != NSNotFound else { break }
                    let location = segmentStart + found.location
                    let existing = (result.attribute(kernKey, at: location, effectiveRange: nil) as? NSNumber)
                        .map(\.doubleValue) ?? tracking
                    result.addAttribute(
                        kernKey,
                        value: (existing + wordSpacing) as CFNumber,
                        range: NSRange(location: location, length: found.length)
                    )
                    let next = found.location + found.length
                    searchRange = NSRange(location: next, length: segment.length - next)
                }
            }
        }
        return result
    }

    static let underlineMarkKey = NSAttributedString.Key("MxUUnderline")
    static let strikethroughMarkKey = NSAttributedString.Key("MxUStrikethrough")

    static let highlightMarkKey = NSAttributedString.Key("MxUHighlight")

    static let hiddenMarkKey = NSAttributedString.Key("MxUBuildHidden")

    static let placeholderUnderlineKey = NSAttributedString.Key("MxUBuildPlaceholder")

    static let caretKey = NSAttributedString.Key("MxUBuildCaret")

    static func drawFrameGlyphs(_ frame: CTFrame, frameRect: CGRect, skippingHidden: Bool, context: CGContext) {
        guard skippingHidden else {
            CTFrameDraw(frame, context)
            return
        }
        guard let lines = CTFrameGetLines(frame) as? [CTLine], !lines.isEmpty else { return }
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)
        for (line, origin) in zip(lines, origins) {
            guard let runs = CTLineGetGlyphRuns(line) as? [CTRun] else { continue }
            for run in runs {
                let attributes = CTRunGetAttributes(run) as NSDictionary
                if attributes[hiddenMarkKey] as? Bool == true { continue }
                context.textPosition = CGPoint(x: frameRect.minX + origin.x, y: frameRect.minY + origin.y)
                CTRunDraw(run, context, CFRange(location: 0, length: 0))
            }
        }
    }

    private static func drawHighlightBands(
        frame: CTFrame,
        frameRect: CGRect,
        context: CGContext
    ) {
        guard let lines = CTFrameGetLines(frame) as? [CTLine], !lines.isEmpty else { return }
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)

        for (line, origin) in zip(lines, origins) {
            guard let runs = CTLineGetGlyphRuns(line) as? [CTRun] else { continue }
            for run in runs {
                let attributes = CTRunGetAttributes(run) as NSDictionary
                guard attributes[hiddenMarkKey] as? Bool != true,
                      let highlight = attributes[highlightMarkKey] as? SceneColor,
                      let color = LinearRaster.cgColor(highlight) else { continue }

                let stringRange = CTRunGetStringRange(run)
                let xStart = CTLineGetOffsetForStringIndex(line, stringRange.location, nil)
                let xEnd = CTLineGetOffsetForStringIndex(line, stringRange.location + stringRange.length, nil)
                guard xEnd > xStart else { continue }

                var ascent: CGFloat = 0
                var descent: CGFloat = 0
                CTRunGetTypographicBounds(run, CFRange(location: 0, length: 0), &ascent, &descent, nil)
                context.setFillColor(color)
                context.fill(CGRect(
                    x: frameRect.minX + origin.x + xStart,
                    y: frameRect.minY + origin.y - descent,
                    width: xEnd - xStart,
                    height: ascent + descent
                ))
            }
        }
    }

    private static func drawDecorations(
        frame: CTFrame,
        frameRect: CGRect,
        fill: SceneFill?,
        context: CGContext
    ) {
        guard let lines = CTFrameGetLines(frame) as? [CTLine], !lines.isEmpty else { return }
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)

        for (line, origin) in zip(lines, origins) {
            guard let runs = CTLineGetGlyphRuns(line) as? [CTRun] else { continue }
            for run in runs {
                let attributes = CTRunGetAttributes(run) as NSDictionary
                let hidden = attributes[hiddenMarkKey] as? Bool == true
                let placeholder = hidden ? attributes[placeholderUnderlineKey] as? SceneColor : nil
                let caret = hidden ? attributes[caretKey] as? SceneColor : nil
                let wantsUnderline = !hidden && attributes[underlineMarkKey] as? Bool == true
                let wantsStrikethrough = !hidden && attributes[strikethroughMarkKey] as? Bool == true
                guard wantsUnderline || wantsStrikethrough || placeholder != nil || caret != nil else { continue }

                let stringRange = CTRunGetStringRange(run)
                let xStart = CTLineGetOffsetForStringIndex(line, stringRange.location, nil)
                let xEnd = CTLineGetOffsetForStringIndex(line, stringRange.location + stringRange.length, nil)
                guard xEnd > xStart else { continue }

                let fontKey = NSAttributedString.Key(kCTFontAttributeName as String)
                guard let fontValue = attributes[fontKey] else { continue }
                let font = fontValue as! CTFont
                let thickness = max(CTFontGetUnderlineThickness(font), 0.5)
                let baselineX = frameRect.minX + origin.x
                let baselineY = frameRect.minY + origin.y

                func paint(_ rect: CGRect) {
                    if let fill {

                        context.saveGState()
                        context.clip(to: rect)
                        drawInkFill(fill, over: frameRect, context: context)
                        context.restoreGState()
                    } else {
                        let colorKey = NSAttributedString.Key(kCTForegroundColorAttributeName as String)
                        if let colorValue = attributes[colorKey], CFGetTypeID(colorValue as CFTypeRef) == CGColor.typeID {
                            context.setFillColor(colorValue as! CGColor)
                        }
                        context.fill(rect)
                    }
                }

                if let caret, let color = LinearRaster.cgColor(caret) {

                    var ascent: CGFloat = 0
                    var descent: CGFloat = 0
                    CTRunGetTypographicBounds(run, CFRange(location: 0, length: 0), &ascent, &descent, nil)
                    let width = max(thickness * 1.5, 1.5)
                    context.setFillColor(color)
                    context.fill(CGRect(
                        x: baselineX + xStart, y: baselineY - descent,
                        width: width, height: ascent + descent
                    ))
                }
                if let placeholder, let color = LinearRaster.cgColor(placeholder) {

                    let position = CTFontGetUnderlinePosition(font)
                    context.setFillColor(color)
                    context.fill(CGRect(
                        x: baselineX + xStart,
                        y: baselineY + position - thickness / 2,
                        width: xEnd - xStart,
                        height: thickness
                    ))
                }
                if wantsUnderline {

                    let position = CTFontGetUnderlinePosition(font)
                    paint(CGRect(
                        x: baselineX + xStart,
                        y: baselineY + position - thickness / 2,
                        width: xEnd - xStart,
                        height: thickness
                    ))
                }
                if wantsStrikethrough {
                    let mid = CTFontGetXHeight(font) / 2
                    paint(CGRect(
                        x: baselineX + xStart,
                        y: baselineY + mid - thickness / 2,
                        width: xEnd - xStart,
                        height: thickness
                    ))
                }
            }
        }
    }

    struct FrameLayout {

        var text: StyledText
        var chorded: ChordedLayout?
        var attributed: CFAttributedString
        var frame: CTFrame

        var frameRect: CGRect
    }

    static func frameLayout(
        for text: StyledText, width: CGFloat, height: CGFloat,
        scale: CGFloat, fontScale: Double, colorSpace: CGColorSpace?
    ) -> FrameLayout {

        let insetLeft = CGFloat(text.insetLeft) * scale
        let insetRight = CGFloat(text.insetRight) * scale
        let insetTop = CGFloat(text.insetTop) * scale
        let insetBottom = CGFloat(text.insetBottom) * scale
        let availableWidth = max(width - insetLeft - insetRight, 1)
        let availableHeight = max(height - insetTop - insetBottom, 1)

        var text = text
        if text.balancedWrap {
            text.balancedLineInsets = balancedLineInsets(
                for: text, sceneWidth: availableWidth / scale, fontScale: fontScale
            )
        }

        let chorded = chordedLayout(
            for: text, sceneWidth: availableWidth / scale, fontScale: fontScale
        )
        let layoutText = chorded?.text ?? text

        let hasInkFill = text.fill != nil
        let attributed = attributedString(
            for: layoutText, fontScale: fontScale, pixelScale: scale, colorSpace: colorSpace,
            includeOutline: !hasInkFill
        )

        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let constraint = CGSize(width: availableWidth, height: .greatestFiniteMagnitude)
        let fitted = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter, CFRange(location: 0, length: 0), nil, constraint, nil
        )

        let layoutHeight = ceil(fitted.height)
        let frameY: CGFloat = switch text.verticalAlignment {
        case .top: height - insetTop - layoutHeight
        case .middle: insetBottom + (availableHeight - layoutHeight) / 2
        case .bottom: insetBottom
        }
        let frameRect = CGRect(x: insetLeft, y: frameY, width: availableWidth, height: layoutHeight)
        let path = CGPath(rect: frameRect, transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)

        return FrameLayout(
            text: text, chorded: chorded, attributed: attributed, frame: frame, frameRect: frameRect
        )
    }

    static func makeTexture(
        text: StyledText,
        pixelWidth: Int,
        pixelHeight: Int,
        scale: CGFloat,
        fontScale: Double,
        device: MTLDevice
    ) -> MTLTexture? {

        let rasterStart = CACurrentMediaTime()
        defer {
            RenderPulse.shared.textRasterized(
                ms: (CACurrentMediaTime() - rasterStart) * 1000)
        }
        guard let colorSpace = LinearRaster.colorSpace,
              let context = LinearRaster.makeContext(pixelWidth: pixelWidth, pixelHeight: pixelHeight)
        else { return nil }

        let layout = frameLayout(
            for: text, width: CGFloat(pixelWidth), height: CGFloat(pixelHeight),
            scale: scale, fontScale: fontScale, colorSpace: colorSpace
        )
        let text = layout.text
        let chorded = layout.chorded
        let frame = layout.frame
        let frameRect = layout.frameRect

        if let lineFill = text.lineFill {
            drawLineFillBands(
                lineFill, frame: frame, frameRect: frameRect,
                pixelWidth: pixelWidth, alignment: text.alignment,
                unitScale: fontScale * scale, context: context
            )
        }

        drawHighlightBands(frame: frame, frameRect: frameRect, context: context)

        let hasHiddenRuns = text.styleRuns.contains { $0.hidden == true }
        if let shadow = text.shadow {
            context.setShadow(

                offset: CGSize(width: shadow.offsetX * scale, height: -shadow.offsetY * scale),
                blur: shadow.blurRadius * scale,
                color: cgColor(shadow.color, in: colorSpace)
            )
        }

        if let fill = text.fill {

            let shadowed = text.shadow != nil
            if shadowed { context.beginTransparencyLayer(auxiliaryInfo: nil) }

            context.saveGState()
            context.setTextDrawingMode(.clip)
            drawFrameGlyphs(frame, frameRect: frameRect, skippingHidden: hasHiddenRuns, context: context)
            drawInkFill(fill, over: frameRect, context: context)
            context.restoreGState()

            if let outline = text.outline, outline.width > 0 {
                context.saveGState()
                context.setTextDrawingMode(.stroke)
                if let strokeColor = LinearRaster.cgColor(outline.color) {
                    context.setStrokeColor(strokeColor)
                }
                context.setLineWidth(outline.width * fontScale * scale)
                drawFrameGlyphs(frame, frameRect: frameRect, skippingHidden: hasHiddenRuns, context: context)
                context.restoreGState()
            }

            drawDecorations(frame: frame, frameRect: frameRect, fill: fill, context: context)
            if shadowed { context.endTransparencyLayer() }
        } else {
            drawFrameGlyphs(frame, frameRect: frameRect, skippingHidden: hasHiddenRuns, context: context)
            drawDecorations(frame: frame, frameRect: frameRect, fill: nil, context: context)
        }

        if let chorded {
            drawChords(
                chorded, frame: frame, frameRect: frameRect, text: text,
                fontScale: fontScale, pixelScale: scale,
                colorSpace: colorSpace, context: context
            )
        }

        return LinearRaster.makeTexture(from: context, device: device)
    }

    private static func drawLineFillBands(
        _ style: TextLineFillStyle,
        frame: CTFrame,
        frameRect: CGRect,
        pixelWidth: Int,
        alignment: SceneTextAlignment,
        unitScale: CGFloat,
        context: CGContext
    ) {
        guard let lines = CTFrameGetLines(frame) as? [CTLine], !lines.isEmpty else { return }
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)

        struct LineBox {
            var penX: CGFloat
            var baselineY: CGFloat
            var visibleWidth: CGFloat
            var ascent: CGFloat
            var descent: CGFloat
        }
        let boxes: [LineBox] = zip(lines, origins).compactMap { line, origin in
            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            var leading: CGFloat = 0
            let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
            let visible = width - CGFloat(CTLineGetTrailingWhitespaceWidth(line))

            guard visible > 0 else { return nil }
            return LineBox(
                penX: frameRect.minX + origin.x,
                baselineY: frameRect.minY + origin.y,
                visibleWidth: visible,
                ascent: ascent,
                descent: descent
            )
        }
        guard !boxes.isEmpty else { return }

        let verticalPadding = style.verticalPadding * unitScale
        let horizontalPadding = style.horizontalPadding * unitScale

        let offsetX = style.horizontalOffset * unitScale
        let offsetY = -style.verticalOffset * unitScale
        let maxVisible = boxes.map(\.visibleWidth).max() ?? 0

        let alignmentFactor: CGFloat = switch alignment {
        case .left: 0
        case .center: 0.5
        case .right: 1
        }

        context.saveGState()
        defer { context.restoreGState() }
        for box in boxes {
            let (x, width): (CGFloat, CGFloat) = switch style.widthMode {
            case .fullWidth:
                (-horizontalPadding, CGFloat(pixelWidth) + horizontalPadding * 2)
            case .lineWidth:
                (box.penX - horizontalPadding, box.visibleWidth + horizontalPadding * 2)
            case .maxLineWidth:
                (
                    box.penX - (maxVisible - box.visibleWidth) * alignmentFactor - horizontalPadding,
                    maxVisible + horizontalPadding * 2
                )
            }
            let band = CGRect(
                x: x + offsetX,
                y: box.baselineY - box.descent - verticalPadding + offsetY,
                width: width,
                height: box.ascent + box.descent + verticalPadding * 2
            )

            let radius = min(
                style.cornerRadius * unitScale, band.width / 2, band.height / 2
            )
            let bandPath = radius > 0
                ? CGPath(roundedRect: band, cornerWidth: radius, cornerHeight: radius, transform: nil)
                : CGPath(rect: band, transform: nil)
            switch style.fill {
            case .none, .media:

                continue
            case .solid(let color):
                guard let cgColor = LinearRaster.cgColor(color) else { continue }
                context.setFillColor(cgColor)
                context.addPath(bandPath)
                context.fillPath()
            case .linearGradient:
                context.saveGState()
                context.addPath(bandPath)
                context.clip()
                drawInkFill(style.fill, over: band, context: context)
                context.restoreGState()
            }
        }
    }

    static func drawInkFill(_ fill: SceneFill, over rect: CGRect, context: CGContext) {
        switch fill {
        case .none:
            return
        case .media:

            return
        case .solid(let color):
            guard let cgColor = LinearRaster.cgColor(color) else { return }
            context.setFillColor(cgColor)
            context.fill(rect)
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
            let direction = CGVector(dx: cos(radians), dy: -sin(radians))
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
            context.drawLinearGradient(gradient, start: start, end: end, options: [])
        }
    }
}
