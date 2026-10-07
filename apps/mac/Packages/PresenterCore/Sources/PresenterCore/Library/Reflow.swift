import Foundation

public enum Reflow {
    public struct ParsedSection: Equatable {
        public var name: String

        public var slides: [String]

        public init(name: String, slides: [String]) {
            self.name = name
            self.slides = slides
        }
    }

    public struct ParseResult: Equatable {
        public var sections: [ParsedSection]

        public var order: [Int]

        public init(sections: [ParsedSection] = [], order: [Int] = []) {
            self.sections = sections
            self.order = order
        }

        public func openingOnBlank() -> ParseResult {
            guard !sections.isEmpty else { return self }
            var result = self
            if result.sections[0].slides.isEmpty, Reflow.isIntro(result.sections[0].name) {
                result.sections[0].slides = [""]
                return result
            }
            let name = result.sections.contains { Reflow.isIntro($0.name) } ? "Blank" : "Intro"
            result.sections.insert(ParsedSection(name: name, slides: [""]), at: 0)
            result.order = [0] + result.order.map { $0 + 1 }
            return result
        }
    }

    static func isIntro(_ name: String) -> Bool {
        let lowered = name.trimmingCharacters(in: .whitespaces).lowercased()
        return lowered == "intro" || lowered.hasPrefix("intro ")
    }

    private static let labelPattern: NSRegularExpression = {
        let names = [
            "verse", "chorus", "pre[- ]?chorus", "bridge", "tag", "intro",
            "outro", "ending", "refrain", "interlude", "vamp", "breakdown",
            "point", "reading",

            "misc", "instrumental", "rap", "descant",

            "half[- ]?chorus", "post[- ]?chorus", "turnaround", "hook", "channel", "coda",
        ].joined(separator: "|")

        return try! NSRegularExpression(
            pattern: #"^\[?\s*(?:repeat\s+)?(\#(names))\s*(\d+)?\s*\]?\s*:?\s*$"#,
            options: [.caseInsensitive]
        )
    }()

    public static let stanzaOnly = 10_000

    public static func materialize(_ text: String, linesPerSlide: Int, mergeStanzas: Bool = false, extraLabels: [String] = []) -> String {
        let perSlide = max(1, linesPerSlide)
        var blocks: [String] = []
        var stanzas: [[String]] = []
        var pending: [String] = []

        func flushStanza() {
            if !pending.isEmpty { stanzas.append(pending) }
            pending = []
        }
        func flushSection() {
            flushStanza()
            let groups = mergeStanzas ? [stanzas.flatMap { $0 }].filter { !$0.isEmpty } : stanzas
            for group in groups {
                for start in stride(from: 0, to: group.count, by: perSlide) {
                    blocks.append(group[start..<min(start + perSlide, group.count)].joined(separator: "\n"))
                }
            }
            stanzas = []
        }

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if labelName(of: line, extraLabels: extraLabels) != nil {
                flushSection()
                blocks.append(line)
            } else if line.isEmpty {
                flushStanza()
            } else {
                pending.append(line)
            }
        }
        flushSection()

        var out = ""
        var previousWasLabel = false
        for block in blocks {
            let isLabel = labelName(of: block, extraLabels: extraLabels) != nil && !block.contains("\n")
            if !out.isEmpty { out += previousWasLabel && !isLabel ? "\n" : "\n\n" }
            out += block
            previousWasLabel = isLabel
        }
        return out
    }

    public static func labelName(of line: String, extraLabels: [String] = []) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        guard let match = labelPattern.firstMatch(in: trimmed, range: range),
              let nameRange = Range(match.range(at: 1), in: trimmed)
        else {
            guard !extraLabels.isEmpty else { return nil }
            let bare = trimmed
                .trimmingCharacters(in: CharacterSet(charactersIn: "[]:"))
                .trimmingCharacters(in: .whitespaces)
            guard !bare.isEmpty else { return nil }
            return extraLabels.first { $0.caseInsensitiveCompare(bare) == .orderedSame }
        }
        let name = trimmed[nameRange].lowercased()
            .replacingOccurrences(of: "pre chorus", with: "pre-chorus")
            .replacingOccurrences(of: "half chorus", with: "half-chorus")
            .replacingOccurrences(of: "post chorus", with: "post-chorus")
            .capitalized
        guard let numberRange = Range(match.range(at: 2), in: trimmed) else { return name }
        return "\(name) \(trimmed[numberRange])"
    }

    public static func parse(_ text: String, linesPerSlide: Int, extraLabels: [String] = []) -> ParseResult {
        let perSlide = max(1, linesPerSlide)

        var result = ParseResult()
        let hasAnyLabel = text
            .components(separatedBy: .newlines)
            .contains { labelName(of: $0, extraLabels: extraLabels) != nil }
        var verseCounter = 0

        var currentName: String?
        var currentStanzas: [[String]] = []
        var pendingStanza: [String] = []

        func flushStanza() {
            if !pendingStanza.isEmpty { currentStanzas.append(pendingStanza) }
            pendingStanza = []
        }

        func closeSection() {
            flushStanza()
            guard let name = currentName else {
                currentStanzas = []
                return
            }
            let slides = chunk(stanzas: currentStanzas, perSlide: perSlide)
            defer {
                currentName = nil
                currentStanzas = []
            }

            if let existing = result.sections.firstIndex(where: {
                $0.name.caseInsensitiveCompare(name) == .orderedSame
                    && (slides.isEmpty || $0.slides == slides)
            }) {
                result.order.append(existing)
                return
            }
            guard !slides.isEmpty else {

                result.sections.append(ParsedSection(name: name, slides: []))
                result.order.append(result.sections.count - 1)
                return
            }
            result.sections.append(ParsedSection(name: name, slides: slides))
            result.order.append(result.sections.count - 1)
        }

        func nextVerseName() -> String {
            verseCounter += 1
            return "Verse \(verseCounter)"
        }

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if let label = labelName(of: line, extraLabels: extraLabels) {
                closeSection()
                currentName = label
            } else if line.isEmpty {

                if hasAnyLabel {
                    flushStanza()
                } else {
                    closeSection()
                }
            } else {
                if currentName == nil { currentName = nextVerseName() }
                pendingStanza.append(line)
            }
        }
        closeSection()
        return result
    }

    private static func chunk(stanzas: [[String]], perSlide: Int) -> [String] {
        stanzas.flatMap { stanza in
            stride(from: 0, to: stanza.count, by: perSlide).map { start in
                stanza[start..<min(start + perSlide, stanza.count)].joined(separator: "\n")
            }
        }
    }

    public struct Built {
        public var sections: [PresentationSection]
        public var slides: [Slide]

        public var arrangement: Arrangement?
    }

    public static func build(
        from text: String,
        linesPerSlide: Int,
        themeSlideName: String = "Lyrics",
        extraLabels: [String] = []
    ) -> Built {
        build(
            parse(text, linesPerSlide: linesPerSlide, extraLabels: extraLabels),
            themeSlideName: themeSlideName
        )
    }

    public static func build(_ parsed: ParseResult, themeSlideName: String = "Lyrics") -> Built {
        var sections: [PresentationSection] = []
        var slides: [Slide] = []
        for section in parsed.sections {
            let sectionId = UUID().uuidString
            sections.append(PresentationSection(id: sectionId, name: section.name))
            for content in section.slides {

                var slide = Slide(id: UUID().uuidString, name: "", objects: [])
                if !content.isEmpty {
                    let extracted = ChordMath.extract(content)
                    var lyrics = SlideObject(
                        id: UUID().uuidString, objectKind: .text,
                        name: "Lyrics", text: extracted.text
                    )
                    if !extracted.chords.isEmpty { lyrics.chords = extracted.chords }
                    slide.objects = [lyrics]
                }
                slide.sectionId = sectionId
                slide.themeSlideName = themeSlideName
                slides.append(slide)
            }
        }
        let hasRepeats = parsed.order.count != Set(parsed.order).count
        let arrangement = hasRepeats
            ? Arrangement(
                id: UUID().uuidString, name: "As Pasted",
                sectionIds: parsed.order.map { sections[$0].id }
            )
            : nil
        return Built(sections: sections, slides: slides, arrangement: arrangement)
    }
}
