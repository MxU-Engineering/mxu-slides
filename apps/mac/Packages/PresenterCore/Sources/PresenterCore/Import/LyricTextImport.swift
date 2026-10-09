import Foundation

public enum LyricTextFormat: String, Sendable, Equatable {
    case songSelect
    case chordPro

    case chordChart
    case plainText
}

public enum LyricTextImporter {

    public struct Normalized: Equatable {
        public var format: LyricTextFormat
        public var title: String?
        public var ccli: CCLIInfo?
        public var chordProSource: String?

        public var musicKey: String?

        public var body: String
    }

    public static func detectFormat(_ text: String) -> LyricTextFormat {
        if ccliSongNumberRegex.firstMatch(in: text) != nil { return .songSelect }
        var directiveHits = 0
        var chordLineHits = 0
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if chordProDirectiveRegex.wholeMatch(trimmed) { directiveHits += 1 }
            if inlineChordRegex.firstMatch(in: trimmed) != nil { chordLineHits += 1 }
        }
        if directiveHits >= 1 {
            return .chordPro
        } else if ChordChartText.inlined(text).chordCount >= 2 {
            return .chordChart
        } else if chordLineHits >= 2 {
            return .chordPro
        } else {
            return .plainText
        }
    }

    public static func makePresentation(
        _ text: String,
        fallbackTitle: String? = nil,
        id: String = UUID().uuidString,
        folder: String? = nil,
        themeId: String = "",
        themeSlideName: String = "Lyrics",
        linesPerSlide: Int = 2
    ) -> Presentation {
        let normalized = normalize(text)
        let built = Reflow.build(
            Reflow.parse(normalized.body, linesPerSlide: linesPerSlide).openingOnBlank(),
            themeSlideName: themeSlideName
        )
        var slides = built.slides
        if slides.isEmpty {
            slides = [Slide(id: UUID().uuidString, name: "", objects: [])]
        }
        return Presentation(
            id: id,
            name: normalized.title ?? fallbackTitle ?? "Imported Lyrics",
            presentationKind: .deck,
            themeId: themeId,
            folder: folder,
            slides: slides,
            sections: built.sections.isEmpty ? nil : built.sections,
            arrangements: built.arrangement.map { [$0] },
            defaultArrangementId: built.arrangement?.id,
            reflowSource: normalized.body.isEmpty ? nil : normalized.body,
            ccli: normalized.ccli,
            chordProSource: normalized.chordProSource,
            musicKey: normalized.musicKey
        )
    }

    public static func normalize(_ text: String) -> Normalized {
        let unified = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        let chart = ChordChartText.inlined(unified)
        switch detectFormat(unified) {
        case .songSelect:
            var normalized = normalizeSongSelect(chart.text)
            normalized.musicKey = chart.musicKey
            return normalized
        case .chordPro: return normalizeChordPro(unified)
        case .chordChart:
            var normalized = normalizeChordPro(ChordChartText.titled(chart.text))
            normalized.format = .chordChart
            normalized.musicKey = normalized.musicKey ?? chart.musicKey
            return normalized
        case .plainText:
            return Normalized(format: .plainText, body: unified.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private static func normalizeSongSelect(_ text: String) -> Normalized {
        var lines = text.components(separatedBy: "\n")

        var ccli = CCLIInfo()
        if let footerStart = lines.firstIndex(where: { ccliSongNumberRegex.firstMatch(in: $0) != nil }) {
            let footer = lines[footerStart...].map { $0.trimmingCharacters(in: .whitespaces) }
            lines = Array(lines[..<footerStart])
            for (offset, line) in footer.enumerated() {
                if let number = ccliSongNumberRegex.firstMatch(in: line) {
                    ccli.songNumber = Int(number)

                    let next = footer.dropFirst(offset + 1).first(where: { !$0.isEmpty })
                    if let authors = next, !authors.hasPrefix("©"), !isCCLIBoilerplate(authors) {
                        ccli.author = authors
                    }
                } else if line.hasPrefix("©") {
                    ccli.copyright = (ccli.copyright.map { $0 + "\n" } ?? "") + line
                    if ccli.copyrightYear == nil {
                        ccli.copyrightYear = copyrightYearRegex.firstMatch(in: line).flatMap { Int($0) }
                    }
                }
            }
        }

        var title: String?
        var body: [String] = []
        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if title == nil {
                if !line.isEmpty { title = line }
                continue
            }
            body.append(line)
        }
        ccli.songTitle = title

        return Normalized(
            format: .songSelect,
            title: title,
            ccli: ccli == CCLIInfo(songTitle: title) && title == nil ? nil : ccli,
            body: body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private static func normalizeChordPro(_ text: String) -> Normalized {
        var title: String?
        var ccli = CCLIInfo()
        var hasCCLI = false
        var musicKey: String?
        var body: [String] = []

        func appendLabel(_ label: String) {
            if body.last?.isEmpty == false { body.append("") }
            body.append(label)
        }

        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if let directive = chordProDirective(from: line) {
                switch directive.key {
                case "title", "t":
                    title = directive.value
                case "subtitle", "st", "artist", "author":
                    if ccli.author == nil, let value = directive.value {
                        ccli.author = value
                        hasCCLI = true
                    }
                case "copyright":
                    if let value = directive.value {
                        ccli.copyright = value
                        ccli.copyrightYear = copyrightYearRegex.firstMatch(in: value).flatMap { Int($0) }
                        hasCCLI = true
                    }
                case "ccli":
                    if let value = directive.value, let number = Int(value.filter(\.isNumber)), number > 0 {
                        ccli.songNumber = number
                        hasCCLI = true
                    }
                case "comment", "c":

                    if let value = directive.value, let label = Reflow.labelName(of: value) {
                        appendLabel(label)
                    }
                case "start_of_chorus", "soc":
                    appendLabel(directive.value ?? "Chorus")
                case "start_of_verse", "sov":
                    appendLabel(directive.value ?? "Verse")
                case "start_of_bridge", "sob":
                    appendLabel(directive.value ?? "Bridge")
                case "key":

                    if let value = directive.value, ChordMath.parseKey(value) != nil {
                        musicKey = value
                    }
                default:
                    break  
                }
                continue
            }
            if line.isEmpty {
                if body.last?.isEmpty == false { body.append("") }
                continue
            }
            if Reflow.labelName(of: line) != nil {
                body.append(line)
                continue
            }

            body.append(line)
        }

        return Normalized(
            format: .chordPro,
            title: title,
            ccli: hasCCLI ? ccli : nil,
            chordProSource: text,
            musicKey: musicKey,
            body: body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private static func chordProDirective(from line: String) -> (key: String, value: String?)? {
        guard line.hasPrefix("{"), line.hasSuffix("}") else { return nil }
        let body = String(line.dropFirst().dropLast())
        let parts = body.split(separator: ":", maxSplits: 1)
        guard let key = parts.first else { return nil }
        let value = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : nil
        return (key.trimmingCharacters(in: .whitespaces).lowercased(), value?.isEmpty == true ? nil : value)
    }

    private static func isCCLIBoilerplate(_ line: String) -> Bool {
        line.localizedCaseInsensitiveContains("songselect")
            || line.localizedCaseInsensitiveContains("ccli licen")
            || line.localizedCaseInsensitiveContains("all rights reserved")
            || line.localizedCaseInsensitiveContains("www.ccli.com")
    }

    private static let ccliSongNumberRegex = SimpleRegex(#"CCLI Song #\s*(\d+)"#, caseInsensitive: true)
    private static let copyrightYearRegex = SimpleRegex(#"(\b(?:19|20)\d{2}\b)"#)
    private static let chordProDirectiveRegex = SimpleRegex(#"^\{[a-zA-Z_]+(:.*)?\}$"#)
    private static let inlineChordRegex = SimpleRegex(#"\[[A-G][#b]?(?:m|maj|min|dim|aug|sus|add)?\d*(?:/[A-G][#b]?)?\]"#)
}

struct SimpleRegex {
    private let regex: NSRegularExpression

    init(_ pattern: String, caseInsensitive: Bool = false) {
        regex = try! NSRegularExpression(pattern: pattern, options: caseInsensitive ? [.caseInsensitive] : [])
    }

    func firstMatch(in text: String) -> String? {
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range) else { return nil }
        let groupRange = match.numberOfRanges > 1 ? match.range(at: 1) : match.range
        guard let swiftRange = Range(groupRange.location == NSNotFound ? match.range : groupRange, in: text) else { return nil }
        return String(text[swiftRange])
    }

    func wholeMatch(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range) else { return false }
        return match.range == range
    }
}
