import CoreText
import Foundation

public enum SlideKind: String, CaseIterable, Sendable {
    case scripture, points, quote, title, lyrics, body, media, blank, picture, video
}

public struct MarkedGroup: Equatable, Sendable {
    public var id: String

    public var type: String?
    public var shape: NoteSlideMarks.Shape
    public var text: String

    public var underlines: [String]

    public var media: [String]

    public var links: [String]

    public init(
        id: String, type: String? = nil, shape: NoteSlideMarks.Shape = .paragraph, text: String, underlines: [String] = [],
        media: [String] = [], links: [String] = []
    ) {
        self.id = id
        self.type = type
        self.shape = shape
        self.text = text
        self.underlines = underlines
        self.media = media
        self.links = links
    }
}

public struct SlideBox: Equatable, Sendable {
    public var name: String
    public var text: String

    public var styleRuns: [TextStyleRun]?

    public var revealLines: [Int]?

    public init(name: String, text: String, styleRuns: [TextStyleRun]? = nil, revealLines: [Int]? = nil) {
        self.name = name
        self.text = text
        self.styleRuns = styleRuns
        self.revealLines = revealLines
    }
}

public struct SlideRow: Equatable {
    public var groupId: String
    public var kind: SlideKind

    public var themeSlideName: String?
    public var linesPerSlide: Int

    public var parts: [[SlideBox]]
    public var lyrics: Reflow.ParseResult?

    public var notes: String?

    public var warning: String?

    public var ownType: String?

    public var media: [String] = []

    public var scale: MediaScaleMode?

    public var videoEnd: SlideOptions.VideoEnd?

    public var photosPerSlide = 1

    public var pictureShapes: [String: PictureShape] = [:]

    public var scaleChosen = false

    public func spotScale(for key: String) -> MediaScaleMode? {
        if pictureShapes[key] != nil { return .scaleAndBlur }
        return scaleChosen ? scale : scale?.inPhotoSpot
    }

    public var shownScale: MediaScaleMode {
        guard themeSlideName != nil else { return scale ?? .fill }
        return media.first.flatMap(spotScale(for:)) ?? .fill
    }

    public var typeKey: String { ownType ?? kind.rawValue }

    public var holdsMedia: Bool { kind == .picture || kind == .video || kind == .media }
}

public struct SlidePlan: Equatable {
    public var rows: [SlideRow]

    public init(rows: [SlideRow]) { self.rows = rows }
}

public struct SlideRowOverride: Equatable, Sendable {
    public var kind: SlideKind?
    public var themeSlideName: String?
    public var linesPerSlide: Int?

    public init(kind: SlideKind? = nil, themeSlideName: String? = nil, linesPerSlide: Int? = nil) {
        self.kind = kind
        self.themeSlideName = themeSlideName
        self.linesPerSlide = linesPerSlide
    }
}

public protocol SlidePlanner {
    func plan(_ groups: [MarkedGroup], theme: Theme?, overrides: [String: SlideRowOverride]) -> SlidePlan
}

public struct DeterministicSlidePlanner: SlidePlanner, Sendable {
    public var options: SlideOptions

    public var pictureAspects: [String: Double]

    public var pictureScaleChosen: Bool

    public init(options: SlideOptions = SlideOptions(), pictureAspects: [String: Double] = [:], pictureScaleChosen: Bool = false) {
        self.options = options
        self.pictureAspects = pictureAspects
        self.pictureScaleChosen = pictureScaleChosen
    }

    public func plan(_ groups: [MarkedGroup], theme: Theme?, overrides: [String: SlideRowOverride]) -> SlidePlan {
        SlidePlan(rows: groups.map { row(for: $0, theme: theme, override: overrides[$0.id] ?? SlideRowOverride()) })
    }

    private func row(for group: MarkedGroup, theme: Theme?, override: SlideRowOverride) -> SlideRow {
        var text = group.text
        var kind = override.kind ?? group.type.flatMap(SlideKind.init(rawValue:))
        var design: String? = override.themeSlideName
        var notes: String?

        var own: SlideOptions.OwnType?
        if override.kind == nil {
            own = options.ownType(named: group.type)
            if own == nil, group.type == nil, let label = Self.leadingLabel(of: text) { own = options.ownType(named: label.name) }
            if let own, let label = Self.leadingLabel(of: text), label.name.caseInsensitiveCompare(own.name) == .orderedSame {
                var lines = text.components(separatedBy: .newlines)
                lines[0] = lines[0].drop { $0 != ":" }.dropFirst().trimmingCharacters(in: .whitespaces)
                if lines[0].isEmpty { lines.removeFirst() }
                text = lines.joined(separator: "\n")
            }
            if own != nil { kind = .body }
        }
        if kind == nil, let label = Self.leadingLabel(of: text) {
            if let named = SlideKind(rawValue: label.name.lowercased()) ?? Self.kind(ofDesignNamed: label.name) {
                kind = named
                text = label.rest
                if design == nil, Self.design(named: label.name, in: theme) != nil { design = Self.design(named: label.name, in: theme) }
            } else if let match = Self.design(named: label.name, in: theme) {
                kind = Self.kind(ofDesignNamed: match) ?? .body
                design = design ?? match
                text = label.rest
            }
        }

        if kind == nil, !group.media.isEmpty { kind = group.type == SlideKind.video.rawValue ? .video : .picture }

        if kind == nil, group.media.isEmpty, !group.links.isEmpty, Self.isVideoFileName(text) { kind = .video }
        if kind == .picture || kind == .video {
            let picture = kind == .picture
            let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
            var row = SlideRow(
                groupId: group.id, kind: kind!, themeSlideName: nil, linesPerSlide: 1, parts: [], lyrics: nil,
                notes: group.media.isEmpty ? (Self.firstLink(in: text) ?? group.links.first ?? text) : (words.isEmpty ? nil : words),
                warning: group.media.isEmpty ? "Needs media: the link is in the slide's notes" : nil)
            row.media = group.media
            if picture { row.scale = options.pictureScale } else { row.videoEnd = options.videoEnd }

            let together = options.picturesTogether && group.media.count > 1
            if picture, !group.media.isEmpty, let pick = Self.photoDesign(chosen: design, together: together, count: group.media.count, in: theme) {
                row.themeSlideName = pick.name
                row.photosPerSlide = together ? pick.photoSpots.count : 1

                row.scaleChosen = pictureScaleChosen
                if !pictureScaleChosen, row.scale?.inPhotoSpot == .fill {
                    let spots = pick.photoSpots
                    for (index, key) in group.media.enumerated() {
                        let spot = spots[index % max(1, row.photosPerSlide)]
                        if let shape = PictureShape(picture: pictureAspects[key], spot: (spot.width ?? 1920) / max(1, spot.height ?? 1080)) {
                            row.pictureShapes[key] = shape
                        }
                    }
                }
                let boxes = pick.objects.filter { $0.objectKind == .text && !Self.isDecoration($0) }
                if !words.isEmpty, let main = Self.mainPlaceholder(in: boxes, short: false) {
                    row.parts = [[SlideBox(name: main.name, text: words)]]
                    row.notes = nil
                }
            }
            return row
        }

        if kind == nil, let link = Self.loneLink(in: text) {
            return SlideRow(
                groupId: group.id, kind: .media, themeSlideName: nil, linesPerSlide: 1, parts: [], lyrics: nil,
                notes: link, warning: "Needs media: the link is in the slide's notes")
        }
        if kind == nil, Self.looksLikeLyrics(text, theme: theme) { kind = .lyrics }
        if kind == nil, ScriptureReference.split(Self.strippingInstruction(text).text) != nil { kind = .scripture }

        if kind == nil, Self.readsAsPoints(text) { kind = .points }

        if kind == nil, Self.labelledPoint(text) != nil { kind = .points }
        let resolvedKind = kind ?? Self.kind(ofShape: group.shape)

        var asides: [String] = []
        if options.parenthesesToNotes, resolvedKind != .lyrics, resolvedKind != .media {
            (text, asides) = Self.strippingParentheticals(text)
        }

        let textLines = text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let listItems = group.shape == .list ? textLines.count : 0

        let underHeading = Self.pointsHeading(textLines) != nil ? textLines.count - 1 : 0
        let pointCount = resolvedKind == .points ? max(1, Self.pointLines(in: text).count, listItems, underHeading) : 0
        let designName = design ?? own.flatMap { Self.design(named: $0.name, in: theme) }
            ?? NoteSlideBuilder.designName(for: resolvedKind, in: theme, pointCount: pointCount)
        let template = Self.template(named: designName, in: theme)

        let placeholders = template?.objects.filter { $0.objectKind == .text && !Self.isDecoration($0) } ?? []

        if resolvedKind == .lyrics {
            let main = Self.mainPlaceholder(in: placeholders, short: false)
            let fit = NoteSlideBuilder.fit(of: main, theme: theme)
            let lines = override.linesPerSlide ?? fit.lines
            return SlideRow(
                groupId: group.id, kind: .lyrics, themeSlideName: designName, linesPerSlide: lines,
                parts: [], lyrics: Reflow.parse(text, linesPerSlide: lines), notes: nil, warning: nil)
        }
        if resolvedKind == .media {
            return SlideRow(
                groupId: group.id, kind: .media, themeSlideName: nil, linesPerSlide: 1, parts: [], lyrics: nil,
                notes: text, warning: "Needs media: the passage is in the slide's notes")
        }

        var named: [SlideBox] = []
        var mainLines: [String] = []
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { mainLines.append(""); continue }
            if let label = Self.leadingLabel(of: trimmed),
               let placeholder = placeholders.first(where: { $0.name.caseInsensitiveCompare(label.name) == .orderedSame }) {
                if let index = named.firstIndex(where: { $0.name == placeholder.name }) {
                    named[index].text += "\n" + label.rest
                } else {
                    named.append(SlideBox(name: placeholder.name, text: label.rest))
                }
            } else {
                mainLines.append(trimmed)
            }
        }
        var short: (text: String, synonyms: [String])?
        var title: String?

        var verseParts: [(text: String, reference: String)]?
        switch resolvedKind {
        case .scripture:
            let stripped = Self.strippingInstruction(mainLines.filter { !$0.isEmpty }.joined(separator: "\n"))
            notes = stripped.instruction
            if let split = ScriptureReference.split(stripped.text) {
                mainLines = split.verse.components(separatedBy: "\n")
                short = (split.reference, Self.referenceNames)
                if let numbered = ScriptureReference.verses(of: split.reference) {
                    let verses = ScriptureReference.verses(in: split.verse, numbered: numbered.verses)
                    if !options.verseNumbers {
                        mainLines = ScriptureReference.removingVerseNumbers(from: split.verse, numbered: numbered.verses)
                            .components(separatedBy: "\n")
                    }

                    if options.scriptureSplit == .oneVerse, verses.count >= 2 {
                        verseParts = verses.enumerated().map { index, verse in
                            let number = verse.number ?? numbered.verses.lowerBound
                            return (options.verseNumbers ? verse.numbered : verse.text,
                                    index == verses.count - 1 ? split.reference : "\(numbered.chapter):\(number)")
                        }
                    }
                }
            }
        case .quote:
            let content = mainLines.filter { !$0.isEmpty }
            if let attribution = Self.attribution(in: content) {
                mainLines = Array(content.dropLast())
                short = (attribution, Self.attributionNames)
            } else if let last = content.last, let inline = Self.inlineAttribution(last) {
                mainLines = content.dropLast() + [inline.quote]
                short = (inline.name, Self.attributionNames)
            }

            if template?.objects.contains(where: { $0.objectKind == .text && Self.isDecoration($0) && Self.unquoted($0.text) != $0.text }) == true {
                let words = Self.unquoted(mainLines.filter { !$0.isEmpty }.joined(separator: "\n"))
                mainLines = words.components(separatedBy: "\n")
            }
        case .title:

            let content = mainLines.filter { !$0.isEmpty }
            if content.count >= 2 {
                mainLines = [content[0]]
                short = (content.dropFirst().joined(separator: "\n"), Self.subtitleNames)
            }
        case .points:

            let content = mainLines.filter { !$0.isEmpty }
            if content.count == 1, let label = Self.labelledPoint(content[0]) {
                title = label.name
                mainLines = [label.rest]
            } else if let first = content.first, let heading = Self.pointsHeading(content) {
                title = heading
                mainLines = Array(mainLines.drop { $0.isEmpty || $0 == first })
            }
        default:
            break
        }

        var stanzas: [[String]] = [[]]
        for line in mainLines {
            if line.isEmpty { if !(stanzas.last?.isEmpty ?? true) { stanzas.append([]) }; continue }
            if line.hasSuffix(":"), !(stanzas.last?.isEmpty ?? true) { stanzas.append([]) }
            stanzas[stanzas.count - 1].append(line)
        }
        stanzas.removeAll(where: \.isEmpty)
        var main = stanzas.map { $0.joined(separator: "\n") }.joined(separator: "\n")
        let points = main.components(separatedBy: "\n").filter { !$0.isEmpty }

        let claimed = Set(named.map(\.name))
        var free = placeholders.filter { !claimed.contains($0.name) }
        var titleBox: SlideBox?
        if let title {
            if let byName = free.first(where: { Self.matches($0.name, any: Self.titleNames) })
                ?? free.first(where: { Self.matches($0.name, any: Self.subtitleNames) }) {
                titleBox = SlideBox(name: byName.name, text: title)
                free.removeAll { $0.name == byName.name }
            } else {
                main = main.isEmpty ? title : title + "\n" + main
                stanzas.insert([title], at: 0)
            }
        }
        let mainPlaceholder = Self.mainPlaceholder(in: free, short: short != nil)
        let mainName = mainPlaceholder?.name ?? placeholders.first?.name ?? "Text"
        var shortBox: SlideBox?
        var tail: String?
        if let short {
            let candidates = free.filter { $0.name != mainName }
            if let byName = candidates.first(where: { Self.matches($0.name, any: short.synonyms) }) {
                shortBox = SlideBox(name: byName.name, text: short.text)
            } else if let smallest = candidates.min(by: { Self.area($0) < Self.area($1) }) {
                shortBox = SlideBox(name: smallest.name, text: short.text)
            } else if main.isEmpty {
                main = short.text
                stanzas = [[short.text]]
            } else {
                main += "\n" + short.text
                tail = short.text
            }
        }

        let fit = NoteSlideBuilder.fit(of: mainPlaceholder, theme: theme)
        let lines = override.linesPerSlide ?? fit.lines

        func parts(_ stanzas: [[String]], tail: String?) -> [String] {
            func ending(_ parts: [String]) -> [String] {
                guard let tail, let last = parts.last else { return parts + (tail.map { [$0] } ?? []) }
                return parts.dropLast() + [last + "\n" + tail]
            }
            var parts = Self.chunk(stanzas: stanzas, linesPerSlide: lines, charsPerLine: fit.charsPerLine)
            if let tail, let last = parts.last,
               Self.cost(of: last.components(separatedBy: "\n") + [tail], charsPerLine: fit.charsPerLine) > lines {
                let room = max(1, lines - Self.cost(of: [tail], charsPerLine: fit.charsPerLine))
                parts = Self.chunk(stanzas: stanzas, linesPerSlide: room, charsPerLine: fit.charsPerLine)
            }
            guard override.linesPerSlide == nil else { return ending(parts) }
            let split = parts.enumerated().flatMap { index, part -> [String] in
                let partLines = part.components(separatedBy: "\n")
                let end = index == parts.count - 1 ? tail : nil
                func with(_ pieces: [String]) -> [String] { end == nil ? pieces : ending(pieces) }
                var perSlide = Self.cost(of: partLines, charsPerLine: fit.charsPerLine)
                var pieces = with([part])
                while perSlide > 1, pieces.contains(where: { !NoteSlideBuilder.fits($0, in: mainPlaceholder, theme: theme) }) {
                    perSlide -= 1
                    pieces = with(Self.chunk(partLines, linesPerSlide: perSlide, charsPerLine: fit.charsPerLine))
                }
                return pieces
            }
            return split.reduce(into: []) { joined, piece in
                if let last = joined.last, NoteSlideBuilder.fits(last + "\n" + piece, in: mainPlaceholder, theme: theme) {
                    joined[joined.count - 1] = last + "\n" + piece
                } else {
                    joined.append(piece)
                }
            }
        }

        let chunks: [(text: String, short: String?)]
        if let verseParts {
            chunks = verseParts.flatMap { verse in
                parts([[verse.text]], tail: shortBox == nil ? verse.reference : nil).map { ($0, verse.reference) }
            }
        } else if let own, own.split != .fitToBox {
            let all = stanzas + (tail.map { [[$0]] } ?? [])
            chunks = (own.split == .paragraph ? all.map { $0.joined(separator: "\n") } : all.flatMap { $0 }).map { ($0, nil) }
        } else {
            chunks = (resolvedKind == .title || main.isEmpty
                ? (main.isEmpty ? [] : [main])
                : parts(stanzas, tail: tail)).map { ($0, nil) }
        }

        let textBoxes = template?.objects.filter { $0.objectKind == .text } ?? []
        func ordered(_ boxes: [SlideBox]) -> [SlideBox] {
            boxes.sorted { a, b in
                let ia = textBoxes.firstIndex { $0.name == a.name } ?? textBoxes.count
                let ib = textBoxes.firstIndex { $0.name == b.name } ?? textBoxes.count
                return ia < ib
            }
        }

        let decorations = (template?.objects ?? []).filter { $0.objectKind == .text && Self.isDecoration($0) }
            .map { SlideBox(name: $0.name, text: $0.text) }
        func extras(short: String? = nil) -> [SlideBox] {
            named + (titleBox.map { [$0] } ?? []) + (shortBox.map { [SlideBox(name: $0.name, text: short ?? $0.text)] } ?? [])
                + decorations
        }
        var parts: [[SlideBox]]
        if resolvedKind == .points, pointCount >= 1,
           let numberBox = free.first(where: { Self.matches($0.name, any: Self.numberNames) && $0.name != mainName }) {
            let lead = titleBox == nil ? title : nil
            let numbered = points.filter(Self.isPointLine)
            parts = (numbered.isEmpty ? points : numbered).enumerated().map { index, line in
                let split = Self.splitPointNumber(line)
                let text = lead.map { "\($0)\n\(split.text)" } ?? split.text
                var boxes = [SlideBox(name: mainName, text: text)] + extras()
                if let number = split.number ?? (numbered.isEmpty && points.count >= 2 ? "\(index + 1)." : nil) {
                    boxes.append(SlideBox(name: numberBox.name, text: number))
                }
                return ordered(boxes)
            }
        } else {
            let leadingTitle = titleBox == nil ? title : nil
            parts = chunks.enumerated().map { index, chunk in
                var main = SlideBox(name: mainName, text: chunk.text)
                if own?.reveal ?? (options.revealPoints && resolvedKind == .points) {
                    let reveal = chunk.text.components(separatedBy: "\n").indices.filter { line in
                        !(index == 0 && line == 0 && leadingTitle != nil)
                    }
                    if reveal.count >= 2 { main.revealLines = reveal }
                }
                return ordered([main] + extras(short: chunk.short))
            }
        }
        if parts.isEmpty { parts = [ordered(extras())].filter { !$0.isEmpty } }
        if options.keepUnderlines, !group.underlines.isEmpty {
            Self.underlining(group.underlines, in: &parts, mainName: mainName)
        }
        let allNotes = ([notes].compactMap { $0 } + asides).joined(separator: "\n")
        return SlideRow(
            groupId: group.id, kind: resolvedKind, themeSlideName: designName, linesPerSlide: lines,
            parts: parts, lyrics: nil, notes: allNotes.isEmpty ? nil : allNotes, warning: nil, ownType: own?.name)
    }

    static let referenceNames = ["reference", "ref", "citation", "address", "verse reference", "scripture reference"]
    static let attributionNames = ["attribution", "author", "source", "credit", "speaker"]
    static let titleNames = ["title", "heading", "header", "headline"]
    static let subtitleNames = ["subtitle", "kicker", "subheading", "tagline", "series", "caption"]
    static let mainNames = ["verse", "scripture", "text", "body", "quote", "lyrics", "points", "point", "main", "content", "passage", "note", "default"]
    static let numberNames = ["number", "no", "index", "numeral", "digit"]

    static func leadingLabel(of text: String) -> (name: String, rest: String)? {
        let first = text.components(separatedBy: .newlines).first ?? text
        guard let colon = first.firstIndex(of: ":") else { return nil }
        let name = first[..<colon].trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name.count <= 24, name.allSatisfy({ $0.isLetter || $0 == " " }) else { return nil }
        let restOfFirst = first[first.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        let remaining = text.components(separatedBy: .newlines).dropFirst()
        let rest = ([restOfFirst] + remaining).filter { !$0.isEmpty }.joined(separator: "\n")
        return (name, rest)
    }

    static func kind(ofShape shape: NoteSlideMarks.Shape) -> SlideKind {
        switch shape {
        case .heading: .title
        case .list: .points
        case .quote: .quote
        case .paragraph: .body
        }
    }

    static func photoDesign(chosen: String?, together: Bool, count: Int, in theme: Theme?) -> Slide? {
        let picked = template(named: chosen, in: theme).flatMap { $0.photoSpots.isEmpty ? nil : $0 }
        guard together else { return picked }
        if let picked, picked.photoSpots.count >= 2 { return picked }
        let designs = (theme?.slides ?? []).filter { $0.photoSpots.count >= 2 }
        guard let most = designs.map(\.photoSpots.count).max() else { return picked }
        let want = min(count, most)
        let fits = designs.filter { $0.photoSpots.count == want }
        return fits.first { $0.folder == picked?.folder } ?? fits.first ?? picked
    }

    static func firstLink(in text: String) -> String? {
        text.split(whereSeparator: \.isWhitespace).map(String.init).first { word in
            let lower = word.lowercased()
            return lower.hasPrefix("http://") || lower.hasPrefix("https://")
        }
    }

    static func loneLink(in text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace),
              trimmed.lowercased().hasPrefix("http://") || trimmed.lowercased().hasPrefix("https://") else { return nil }
        return trimmed
    }

    static func strippingInstruction(_ text: String) -> (text: String, instruction: String?) {
        var lines = text.components(separatedBy: "\n")
        for index in lines.indices {
            let line = lines[index].trimmingCharacters(in: .whitespaces)
            guard line.hasSuffix(")"), let open = line.lastIndex(of: "(") else { continue }
            let before = line[..<open].trimmingCharacters(in: .whitespaces)
            let inside = line[line.index(after: open)...].dropLast().trimmingCharacters(in: .whitespaces)
            guard !before.isEmpty, !inside.isEmpty, !Self.isTranslation(inside), ScriptureReference.isReferenceLine(before),
                  ScriptureReference.matches(in: inside).isEmpty else { continue }
            lines[index] = before
            return (lines.joined(separator: "\n"), inside)
        }
        return (text, nil)
    }

    static func strippingParentheticals(_ text: String) -> (text: String, asides: [String]) {
        var asides: [String] = []
        let lines = text.components(separatedBy: "\n").compactMap { line -> String? in
            var kept = ""
            var rest = Substring(line)
            let found = asides.count
            while let open = rest.firstIndex(of: "("), let close = rest[open...].firstIndex(of: ")") {
                let inside = rest[rest.index(after: open) ..< close].trimmingCharacters(in: .whitespaces)
                if !movesToNotes(inside) {
                    kept += rest[...close]
                } else {
                    kept += rest[..<open]
                    asides.append(inside)
                }
                rest = rest[rest.index(after: close)...]
            }
            kept += rest
            guard asides.count > found else { return line }
            let cleaned = kept.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
                .replacingOccurrences(of: #"\s+([.,;:!?])"#, with: "$1", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            return cleaned.isEmpty && !line.trimmingCharacters(in: .whitespaces).isEmpty ? nil : cleaned
        }
        return (lines.joined(separator: "\n"), asides)
    }

    static func movesToNotes(_ inside: String) -> Bool {
        !inside.isEmpty && !isTranslation(inside) && ScriptureReference.matches(in: inside).isEmpty
    }

    public static func asideRanges(in text: String) -> [Range<String.Index>] {
        var found: [Range<String.Index>] = []
        var rest = text[...]
        while let open = rest.firstIndex(of: "(") {
            guard let close = rest[open...].firstIndex(where: { $0 == ")" || $0 == "\n" }) else { break }
            if text[close] == ")", movesToNotes(text[text.index(after: open) ..< close].trimmingCharacters(in: .whitespaces)) {
                found.append(open ..< text.index(after: close))
            }
            rest = text[text.index(after: close)...]
        }
        return found
    }

    static func isTranslation(_ text: String) -> Bool {
        (2 ... 6).contains(text.count) && text.allSatisfy { $0.isUppercase }
    }

    static func labelledPoint(_ text: String) -> (name: String, rest: String)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains("\n"), let label = leadingLabel(of: trimmed), !label.rest.isEmpty,
              Reflow.labelName(of: label.name) == nil,
              label.name.split(separator: " ").count <= 3,
              SlideKind(rawValue: label.name.lowercased()) == nil, kind(ofDesignNamed: label.name) == nil
        else { return nil }
        return label
    }

    static func inlineAttribution(_ line: String) -> (quote: String, name: String)? {
        guard let match = line.firstMatch(of: /^(.*["”’])\s*[-–—~]\s*(\S.*)$/) else { return nil }
        return (String(match.1).trimmingCharacters(in: .whitespaces), String(match.2).trimmingCharacters(in: .whitespaces))
    }

    static func readsAsQuote(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first, "“\"".contains(first) else { return false }
        let lines = trimmed.components(separatedBy: "\n")
        if attribution(in: lines) != nil || lines.last.flatMap(inlineAttribution) != nil { return true }
        return trimmed.count > 1 && trimmed.last.map { "”\"".contains($0) } == true
    }

    static func underlining(_ phrases: [String], in parts: inout [[SlideBox]], mainName: String) {
        var part = 0
        var from = 0
        for phrase in phrases.map({ $0.trimmingCharacters(in: .whitespaces) }) where !phrase.isEmpty {
            for candidate in part ..< parts.count {
                guard let box = parts[candidate].firstIndex(where: { $0.name == mainName }) else { continue }
                let text = parts[candidate][box].text
                let start = text.index(text.startIndex, offsetBy: candidate == part ? min(from, text.count) : 0)
                guard let found = text.range(of: phrase, range: start ..< text.endIndex) else { continue }
                let before = text[..<found.lowerBound]
                let line = before.filter { $0 == "\n" }.count
                let column = before.count - (before.lastIndex(of: "\n").map { before.distance(from: before.startIndex, to: $0) + 1 } ?? 0)
                parts[candidate][box].styleRuns = (parts[candidate][box].styleRuns ?? [])
                    + [TextStyleRun(line: line, column: column, length: phrase.count, underline: true)]
                part = candidate
                from = text.distance(from: text.startIndex, to: found.upperBound)
                break
            }
        }
    }

    static func isPointLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if let first = trimmed.first, "-•*–".contains(first), trimmed.dropFirst().first == " " { return true }
        var digits = trimmed.prefix { $0.isNumber }
        guard !digits.isEmpty, digits.count <= 2 else { return false }
        digits = trimmed.prefix(digits.count)
        let rest = trimmed.dropFirst(digits.count)
        return (rest.hasPrefix(". ") || rest.hasPrefix(") ")) && rest.count > 2
    }

    static func readsAsPoints(_ text: String) -> Bool {
        let lines = text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let points = lines.filter(isPointLine).count
        if points >= 2 { return true }
        guard points == 1, let first = lines.first, lines.count == 2 else { return false }
        return !isPointLine(first) && first.count <= 80
    }

    static func pointsHeading(_ lines: [String]) -> String? {
        guard let first = lines.first, !isPointLine(first), first.count <= 80 else { return nil }
        if first.hasSuffix(":"), lines.count >= 2 { return first.dropLast().trimmingCharacters(in: .whitespaces) }
        return lines.dropFirst().allSatisfy(isPointLine) ? first : nil
    }

    static func isVideoFileName(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.contains("\n")
            && trimmed.range(of: NoteSlideMarks.videoFilePattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    static func unquoted(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let marks: Set<Character> = ["\"", "“", "”", "„", "«", "»", "'", "‘", "’"]
        if trimmed.count == 1, let only = trimmed.first, marks.contains(only) { return "" }
        guard trimmed.count >= 2, let first = trimmed.first, let last = trimmed.last,
              marks.contains(first), marks.contains(last) else { return text }
        let inner = trimmed.dropFirst().dropLast()

        guard !inner.contains(where: { "“”\"".contains($0) }) else { return text }
        return String(inner)
    }

    static func pointLines(in text: String) -> [String] {
        text.components(separatedBy: "\n").filter(isPointLine)
    }

    static func splitPointNumber(_ line: String) -> (number: String?, text: String) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard isPointLine(trimmed) else { return (nil, trimmed) }
        if let first = trimmed.first, "-•*–".contains(first) {
            return (nil, trimmed.dropFirst().trimmingCharacters(in: .whitespaces))
        }
        let digits = trimmed.prefix { $0.isNumber }
        let marker = trimmed.prefix(digits.count + 1)
        return (String(marker), trimmed.dropFirst(marker.count).trimmingCharacters(in: .whitespaces))
    }

    static func looksLikeLyrics(_ text: String, theme: Theme?) -> Bool {
        let labels = text.components(separatedBy: .newlines).filter { Reflow.labelName(of: $0) != nil }.count
        if labels >= 2 { return true }
        if let slides = theme?.slides, slides.count == 1, kind(ofDesignNamed: slides[0].name) == .lyrics { return true }
        return false
    }

    static func attribution(in lines: [String]) -> String? {
        guard lines.count >= 2, let last = lines.last else { return nil }
        let previous = lines[lines.count - 2]
        if let lead = last.first, "-–—~".contains(lead) {
            return last.dropFirst().trimmingCharacters(in: .whitespaces)
        }
        if last.count <= 60, previous.last.map({ "\"”’'".contains($0) }) == true { return last }
        return nil
    }

    static func matches(_ name: String, any synonyms: [String]) -> Bool {
        let lowered = name.lowercased()
        let words = Set(lowered.split(whereSeparator: { !$0.isLetter }).map(String.init))
        return synonyms.contains { lowered == $0 || words.contains($0) }
    }

    static func design(named name: String, in theme: Theme?) -> String? {
        theme?.slides?.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.name
    }

    static func template(named name: String?, in theme: Theme?) -> Slide? {
        theme?.design(named: name)
    }

    static func kind(ofDesignNamed name: String) -> SlideKind? {
        SlideKind.allCases.first { matches(name, any: NoteSlideBuilder.designSynonyms[$0] ?? []) }
    }

    static func area(_ object: SlideObject) -> Double {
        (object.width ?? 1920) * (object.height ?? 1080)
    }

    static func isDecoration(_ box: SlideObject) -> Bool {
        let sample = box.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return !sample.isEmpty && !sample.contains { $0.isLetter || $0.isNumber }
    }

    static func mainPlaceholder(in placeholders: [SlideObject], short: Bool) -> SlideObject? {
        if let named = placeholders.first(where: { matches($0.name, any: mainNames) }) { return named }

        if placeholders.count >= 2 { return placeholders.max { area($0) < area($1) } }
        return placeholders.first
    }

    static func chunk(stanzas: [[String]], linesPerSlide: Int, charsPerLine: Int) -> [String] {
        let perSlide = max(1, linesPerSlide)
        func cost(_ line: String) -> Int { Self.cost(of: [line], charsPerLine: charsPerLine) }
        var parts: [String] = []
        var current: [String] = []
        var used = 0
        func flush() {
            if !current.isEmpty { parts.append(current.joined(separator: "\n")) }
            current = []
            used = 0
        }
        for stanza in stanzas {
            let stanzaCost = stanza.reduce(0) { $0 + cost($1) }
            if stanzaCost <= perSlide {
                if used > 0, used + stanzaCost > perSlide { flush() }
                current += stanza
                used += stanzaCost
                continue
            }
            flush()
            for line in stanza {
                let units = cost(line) > perSlide ? pieces(of: line) : [line]
                for unit in units {
                    let unitCost = cost(unit)
                    if used > 0, used + unitCost > perSlide { flush() }
                    current.append(unit)
                    used += unitCost
                }
            }
            flush()
        }
        flush()
        return parts
    }

    static func cost(of lines: [String], charsPerLine: Int) -> Int {
        lines.reduce(0) { $0 + max(1, Int(ceil(Double($1.count) / Double(max(1, charsPerLine))))) }
    }

    static func pieces(of line: String) -> [String] {
        let pattern = try! NSRegularExpression(pattern: #"(?<=[.!?;:])\s+|\s+(?=\d{1,3}\s+[A-Za-z“"‘'])"#)
        let whole = NSRange(line.startIndex..., in: line)
        var pieces: [String] = []
        var start = line.startIndex
        for match in pattern.matches(in: line, range: whole) {
            guard let range = Range(match.range, in: line) else { continue }
            let piece = line[start ..< range.lowerBound].trimmingCharacters(in: .whitespaces)
            if !piece.isEmpty { pieces.append(piece) }
            start = range.upperBound
        }
        let tail = line[start...].trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty { pieces.append(tail) }
        return pieces.isEmpty ? [line] : pieces
    }

    static func chunk(_ lines: [String], linesPerSlide: Int, charsPerLine: Int) -> [String] {
        chunk(stanzas: [lines.filter { !$0.isEmpty }], linesPerSlide: linesPerSlide, charsPerLine: charsPerLine)
    }
}

public enum NoteSlideBuilder {
    public static let designSynonyms: [SlideKind: [String]] = [
        .scripture: ["scripture", "verse", "bible", "passage"],
        .points: ["points", "point", "bullets", "list"],
        .quote: ["quote", "quotation"],
        .title: ["title", "section", "heading"],
        .lyrics: ["lyrics", "song"],
        .body: ["body", "text", "default", "main", "content", "note", "notes", "statement"],
        .media: ["media"],
        .picture: ["picture"],
        .video: ["video"],
        .blank: ["blank", "empty", "logo"],
    ]

    public static func groups(in body: NoteBody) -> [MarkedGroup] {
        NoteSlideMarks.groups(in: body).map(marked)
    }

    public static func marked(_ group: NoteSlideMarks.Group) -> MarkedGroup {
        MarkedGroup(
            id: group.id, type: group.type, shape: group.shape, text: group.text, underlines: group.underlines,
            media: group.media, links: group.links)
    }

    public static func designName(for kind: SlideKind, in theme: Theme?, pointCount: Int = 0) -> String? {
        guard let slides = theme?.slides?.filter({ kind == .picture || $0.photoSpots.isEmpty }), !slides.isEmpty else { return nil }

        if kind == .points {
            let many = ["points", "list", "bullets"], one = ["point"]
            let order = pointCount >= 2 ? [many, one] : [one, many]
            for names in order {
                if let match = slides.first(where: { DeterministicSlidePlanner.matches($0.name, any: names) }) { return match.name }
            }
        }
        if let match = slides.first(where: { DeterministicSlidePlanner.matches($0.name, any: designSynonyms[kind] ?? []) }) {
            return match.name
        }
        if kind == .scripture || kind == .quote,
           let twoBox = slides.first(where: { $0.objects.filter { $0.objectKind == .text }.count >= 2 }) {
            return twoBox.name
        }
        return nil
    }

    public static func lookDesigns(for kind: SlideKind, looks: [Theme], chosen: [String: String]) -> [String: String] {
        var result: [String: String] = [:]
        for look in looks {
            if let design = chosen[look.id] ?? designName(for: kind, in: look) { result[look.id] = design }
        }
        return result
    }

    public struct Fit: Equatable, Sendable {
        public var lines: Int
        public var charsPerLine: Int
    }

    public static func fit(of placeholder: SlideObject?, theme: Theme?) -> Fit {
        let style = placeholder?.textStyle
        let fontSize = style?.fontSize ?? theme?.fontSize ?? defaultFontSize
        let lineHeight = fontSize * (style?.lineHeightMultiple ?? 1) * 1.2
        let box = textBox(of: placeholder)
        let lines = min(12, max(1, Int(box.height / max(1, lineHeight))))
        let chars = max(8, Int(box.width / max(1, fontSize * 0.5)))
        return Fit(lines: lines, charsPerLine: chars)
    }

    static let defaultFontName = "HelveticaNeue-Bold"
    static let defaultFontSize = 96.0

    static func textBox(of placeholder: SlideObject?) -> CGSize {
        let style = placeholder?.textStyle
        return CGSize(
            width: max(1, (placeholder?.width ?? 1920 * 0.8) - (style?.insetLeft ?? 0) - (style?.insetRight ?? 0)),
            height: max(1, (placeholder?.height ?? 1080 * 0.8) - (style?.insetTop ?? 0) - (style?.insetBottom ?? 0)))
    }

    public static func fits(_ text: String, in placeholder: SlideObject?, theme: Theme?) -> Bool {
        guard !text.isEmpty else { return true }
        let style = placeholder?.textStyle
        let box = textBox(of: placeholder)
        let fullSize = style?.fontSize ?? theme?.fontSize ?? defaultFontSize
        let floor = style?.autoShrink == true ? min(fullSize, style?.minFontSize ?? fullSize) : fullSize
        let specs: [CTParagraphStyleSpecifier] = [.lineHeightMultiple, .paragraphSpacing, .headIndent, .firstLineHeadIndent, .tailIndent]
        let values: [CGFloat] = [
            CGFloat(style?.lineHeightMultiple ?? 1), CGFloat(style?.paragraphSpacing ?? 0), CGFloat(style?.leftIndent ?? 0),
            CGFloat((style?.leftIndent ?? 0) + (style?.firstLineIndent ?? 0)), CGFloat(-(style?.rightIndent ?? 0)),
        ]
        let paragraph = values.withUnsafeBufferPointer { values in
            var settings = specs.indices.map { index in
                CTParagraphStyleSetting(spec: specs[index], valueSize: MemoryLayout<CGFloat>.size, value: values.baseAddress! + index)
            }
            return CTParagraphStyleCreate(&settings, settings.count)
        }

        func framesetter(_ string: String, at size: Double) -> CTFramesetter {
            let font = CTFontCreateWithName((style?.fontName ?? theme?.fontFamily ?? defaultFontName) as CFString, CGFloat(size), nil)
            let shown = style?.textTransform == .uppercase ? string.uppercased() : string
            return CTFramesetterCreateWithAttributedString(NSAttributedString(string: shown, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTParagraphStyleAttributeName as String): paragraph,
                NSAttributedString.Key(kCTKernAttributeName as String): ((style?.tracking ?? 0) * size / max(1, fullSize)) as NSNumber,
            ]))
        }
        func lineCount(_ point: String, at size: Double) -> Int {
            let path = CGPath(rect: CGRect(x: 0, y: 0, width: box.width, height: 100_000), transform: nil)
            return CFArrayGetCount(CTFrameGetLines(CTFramesetterCreateFrame(framesetter(point, at: size), CFRange(location: 0, length: 0), path, nil)))
        }
        let short = floor < fullSize && text.components(separatedBy: "\n").allSatisfy { lineCount($0, at: floor) <= 2 }
        let size = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter(text, at: short ? floor : fullSize), CFRange(location: 0, length: 0), nil,
            CGSize(width: box.width, height: .greatestFiniteMagnitude), nil)
        return size.height <= box.height
    }

    public struct Built: Equatable {
        public var slides: [Slide]
        public var sections: [PresentationSection]
        public var arrangement: Arrangement?

        public var groupBySlideId: [String: String]

        public var blankFollows: [String: String] = [:]

        public var pictureShapes: [String: PictureShape] = [:]

        public func group(of slideId: String) -> String? {
            groupBySlideId[slideId] ?? blankFollows[slideId]
        }
    }

    public enum SwitchOverride: Equatable, Sendable {
        case typeDefault
        case none
        case chosen(SlidePresetChoice)
    }

    public static func presetChoice(for kind: SlideKind, override: SwitchOverride, settings: SlideDesignMap) -> SlidePresetChoice? {
        presetChoice(forType: kind.rawValue, override: override, settings: settings)
    }

    public static func presetChoice(forType type: String, override: SwitchOverride, settings: SlideDesignMap) -> SlidePresetChoice? {
        switch override {
        case .typeDefault: settings.preset(forType: type)
        case .none: nil
        case .chosen(let choice): choice
        }
    }

    public struct BlankStyle: Equatable, Sendable {
        public var themeId: String?
        public var themeSlideName: String?
        public var actions: [SlideAction]

        public init(themeId: String? = nil, themeSlideName: String? = nil, actions: [SlideAction] = []) {
            self.themeId = themeId
            self.themeSlideName = themeSlideName
            self.actions = actions
        }
    }

    public static func blankSlide(after slide: Slide?, style: BlankStyle) -> Slide {
        var blank = Slide(id: UUID().uuidString, name: "", objects: [])
        blank.sectionId = slide?.sectionId
        blank.themeSlideName = style.themeSlideName
        blank.themeId = style.themeId
        blank.actions = style.actions.isEmpty ? nil : style.actions.map { action in
            var copy = action
            copy.id = UUID().uuidString
            return copy
        }
        return blank
    }

    public static func build(_ plan: SlidePlan) -> Built {
        build(plan, blanks: [:], blank: BlankStyle())
    }

    public static func build(
        _ plan: SlidePlan, blanks: [String: BlankPlacement], blank style: BlankStyle, options: SlideOptions = SlideOptions(),
        media: (String) -> String? = { _ in nil }
    ) -> Built {
        var built = Built(slides: [], sections: [], arrangement: nil, groupBySlideId: [:])
        for row in plan.rows {
            let start = built.slides.count
            if let lyrics = row.lyrics {
                let reflowed = Reflow.build(lyrics, themeSlideName: row.themeSlideName ?? "Lyrics")
                built.sections += reflowed.sections
                built.slides += reflowed.slides
                if built.arrangement == nil { built.arrangement = reflowed.arrangement }
                for slide in reflowed.slides { built.groupBySlideId[slide.id] = row.groupId }
            } else if row.kind == .picture, row.themeSlideName != nil, !row.media.isEmpty {
                let per = max(1, row.photosPerSlide)
                for start in stride(from: 0, to: row.media.count, by: per) {
                    let keys = row.media[start ..< min(start + per, row.media.count)]
                    let photos = keys.map { key in
                        SlideObject.photo(
                            mediaId: media(key) ?? NoteMedia.pendingId(for: key),
                            scale: row.spotScale(for: key))
                    }
                    var slide = Slide(id: UUID().uuidString, name: "", objects: photos + (row.parts.first ?? []).map(textObject))
                    slide.themeSlideName = row.themeSlideName
                    slide.notes = row.notes
                    if let shape = keys.lazy.compactMap({ row.pictureShapes[$0] }).first { built.pictureShapes[slide.id] = shape }
                    built.slides.append(slide)
                    built.groupBySlideId[slide.id] = row.groupId
                }
            } else if row.kind == .picture || row.kind == .video, !row.media.isEmpty {
                for key in row.media {
                    let slide = mediaSlide(row, mediaId: media(key) ?? NoteMedia.pendingId(for: key))
                    built.slides.append(slide)
                    built.groupBySlideId[slide.id] = row.groupId
                }
            } else if row.kind == .media || row.kind == .picture || row.kind == .video {
                var slide = Slide(id: UUID().uuidString, name: "", objects: [])
                slide.notes = row.notes
                built.slides.append(slide)
                built.groupBySlideId[slide.id] = row.groupId
            } else {
                for part in row.parts {
                    var slide = Slide(id: UUID().uuidString, name: "", objects: part.map(textObject))
                    slide.themeSlideName = row.themeSlideName
                    slide.notes = row.notes
                    built.slides.append(slide)
                    built.groupBySlideId[slide.id] = row.groupId
                }
            }
            let made = built.slides.count - start
            guard made > 0, var placement = blanks[row.groupId], placement != .none else { continue }
            if placement == .afterSlide, row.kind == .scripture, !options.blanksBetweenVerses { placement = .afterPassage }
            func blank(after index: Int) -> Slide {
                let slide = blankSlide(after: built.slides[index], style: style)
                built.blankFollows[slide.id] = row.groupId
                return slide
            }
            switch placement {
            case .afterPassage:
                built.slides.append(blank(after: built.slides.count - 1))
            case .afterSlide:
                var withBlanks: [Slide] = []
                for index in start ..< built.slides.count {
                    withBlanks.append(built.slides[index])
                    withBlanks.append(blank(after: index))
                }
                built.slides.replaceSubrange(start..., with: withBlanks)
            case .none:
                break
            }
        }
        return built
    }

    static func mediaSlide(_ row: SlideRow, mediaId: String) -> Slide {
        var slide = Slide(id: UUID().uuidString, name: "", objects: [])
        slide.showMedia(mediaId, kind: row.kind == .video ? .video : .image, scale: row.scale, videoEnd: row.videoEnd ?? .next)
        return slide
    }

    static func textObject(_ box: SlideBox) -> SlideObject {
        var object = SlideObject(id: UUID().uuidString, objectKind: .text, name: box.name, text: box.text, styleRuns: box.styleRuns)
        if let reveal = box.revealLines {
            let lines = box.text.components(separatedBy: "\n")
            object.animationSteps = reveal.filter { lines.indices.contains($0) }.map { line in
                AnimationStep(
                    id: UUID().uuidString, kind: .in, animation: .fade, trigger: .onClick, durationSeconds: 0.5,
                    ranges: [AnimationRange(line: line, column: 0, length: lines[line].count)])
            }
        }
        return object
    }

    public static func attachingSwitches(
        to built: inout Built, rows: [SlideRow], settings: SlideDesignMap, overrides: [String: SwitchOverride]
    ) {
        let rowsByGroup = Dictionary(rows.map { ($0.groupId, $0) }, uniquingKeysWith: { first, _ in first })
        for index in built.slides.indices {
            guard let group = built.groupBySlideId[built.slides[index].id], let row = rowsByGroup[group],
                  let choice = presetChoice(forType: row.typeKey, override: overrides[group] ?? .typeDefault, settings: settings)
            else { continue }
            built.slides[index].actions = (built.slides[index].actions ?? []) + [choice.action()]
        }
    }

    public static func attachingDesignActions(to built: inout Built, deckThemeId: String, theme: (String) -> Theme?) {
        for index in built.slides.indices {
            let slide = built.slides[index]
            if let name = slide.themeSlideName, !name.isEmpty {
                let own = slide.themeId ?? ""
                let themeId = own.isEmpty ? deckThemeId : own
                built.slides[index].adoptActions(of: theme(themeId)?.design(named: name))
            }
        }
    }
}

extension Slide {
    public mutating func showMedia(_ mediaId: String, kind: MediaKind, scale: MediaScaleMode?, videoEnd: SlideOptions.VideoEnd) {
        var cue = CueMedia.droppedAsNewSlide(mediaId: mediaId, kind: kind)
        if kind == .image { cue.scaleMode = scale == .fill ? nil : scale }
        autoAdvance = nil
        if kind == .video {
            switch videoEnd {
            case .next: autoAdvance = AutoAdvance(delaySeconds: 0, afterPlayback: true)
            case .stop: break
            case .loop: cue.loops = true
            case .fadeToBlack: cue.endFade = .black
            case .fadeToClear: cue.endFade = .clear
            }
        }
        background = cue
    }

    public var waitsForMedia: Bool {
        guard objects.isEmpty, background == nil, let notes else { return false }
        return notes.hasPrefix("http://") || notes.hasPrefix("https://") || notes.hasPrefix(Self.needsMediaNote)
    }

    public static let needsMediaNote = "Needs media:"

    public mutating func fillPlaceholder(with item: MediaItem, options: SlideOptions) {
        showMedia(item.id, kind: item.mediaKind, scale: options.pictureScale, videoEnd: options.videoEnd)
        if notes?.hasPrefix(Self.needsMediaNote) == true { notes = nil }
    }
}
