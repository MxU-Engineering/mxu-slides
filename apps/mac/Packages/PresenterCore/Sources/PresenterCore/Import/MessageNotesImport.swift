import Foundation

public enum MessageNotes {

    public enum Kind: String, Sendable, Equatable, CaseIterable {
        case title
        case point
        case scripture
        case quote
        case skip
    }

    public struct Hint: Equatable, Sendable {
        public var bold: Bool

        public var underlined: [String]

        public init(bold: Bool, underlined: [String] = []) {
            self.bold = bold
            self.underlined = underlined
        }
    }

    public struct Block: Equatable, Sendable {

        public var source: String
        public var kind: Kind

        public var text: String

        public var detail: String?

        public var cues: [String] = []
        public var underlined: [String] = []
    }

    public struct Parsed: Equatable, Sendable {
        public var title: String?
        public var blocks: [Block]

        public func count(of kind: Kind) -> Int {
            blocks.count { $0.kind == kind }
        }
    }

    static let longestPoint = 180

    public static func parse(
        _ text: String, hints: [String: Hint] = [:], overrides: [String: Kind] = [:], boldOnly: Bool = false
    ) -> Parsed {
        struct Line {
            var text: String
            var adjacent: Bool
        }
        var lines: [Line] = []
        var gap = true
        for raw in LyricTextImporter.unified(text).components(separatedBy: "\n") {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                gap = true
            } else {
                lines.append(Line(text: trimmed, adjacent: !gap))
                gap = false
            }
        }
        let boldMatters = boldOnly && lines.contains { hints[$0.text]?.bold == true }

        let spaced = lines.dropFirst().count { !$0.adjacent } * 2 >= lines.count - 1
        func read(_ line: Line) -> Reading {
            reading(line.text, hint: hints[line.text], boldMatters: boldMatters, forced: overrides[line.text])
        }

        var blocks: [Block] = []
        var ordinary: [Bool] = []
        var index = 0
        while index < lines.count {
            var current = read(lines[index])
            let first = lines[index]
            var held = 1
            while spaced, !blocks.isEmpty, held < 4, current.block.kind == .point, current.ordinary,
                  overrides[first.text] == nil, index + 1 < lines.count, lines[index + 1].adjacent,
                  overrides[lines[index + 1].text] == nil,
                  hints[first.text]?.bold == hints[lines[index + 1].text]?.bold {
                let next = read(lines[index + 1])
                guard next.block.kind == .point, next.ordinary,
                      current.block.text.count + next.block.text.count < longestPoint
                else { break }
                current.block.text += "\n" + next.block.text
                current.block.cues += next.block.cues
                current.block.underlined += next.block.underlined
                held += 1
                index += 1
            }
            if held == 1, index + 1 < lines.count, lines[index + 1].adjacent, overrides[lines[index + 1].text] == nil {
                let next = read(lines[index + 1])

                if current.block.kind == .scripture, current.block.text.isEmpty, next.ordinary, !blocks.isEmpty {
                    current.block.text = next.body
                    current.block.cues += next.block.cues
                    index += 1
                } else if current.ordinary, overrides[lines[index].text] == nil,
                          let reference = trailingReferenceLine(lines[index + 1].text) {
                    current.block.kind = .scripture
                    current.block.text = current.body
                    current.block.detail = reference
                    current.ordinary = false
                    index += 1
                }
            }
            if current.block.kind == .scripture, !current.block.text.isEmpty,
               let range = current.block.detail.flatMap(verseRange.groups(in:)),
               let low = Int(range[1]), let high = Int(range[2]) {
                while index + 1 < lines.count, lines[index + 1].adjacent, overrides[lines[index + 1].text] == nil,
                      let number = leadingNumber.groups(in: lines[index + 1].text).flatMap({ Int($0[0]) }),
                      number > low, number <= high {
                    current.block.text += " " + lines[index + 1].text
                    index += 1
                }
            }
            if current.block.kind == .scripture {
                current.block.text = current.block.text
                    .replacingOccurrences(of: #"\s*\[[a-z]\]"#, with: "", options: .regularExpression)
            }
            if current.block.kind == .scripture, let reference = current.block.detail,
               let verse = singleVerse.groups(in: reference)?[0],
               let number = Int(verse), let numbered = numberedVerses(in: current.block.text, first: number, last: number),
               numbered.count == 1 {
                current.block.text = numbered[0]
            }
            blocks.append(current.block)
            ordinary.append(current.ordinary)
            index += 1
        }

        var title: String?
        if !blocks.contains(where: { $0.kind == .title }),
           let first = blocks.first, ordinary[0], overrides[first.source] == nil, first.text.count <= 120 {
            blocks[0].kind = .title
            let headed = heading(first.text)
            blocks[0].text = headed.title
            blocks[0].detail = headed.detail
        }
        if let index = blocks.firstIndex(where: { $0.kind == .title }) {
            title = blocks[index].text
            if blocks[index].detail == nil, index + 1 < blocks.count, blocks[index + 1].kind == .scripture,
               blocks[index + 1].text.isEmpty, overrides[blocks[index + 1].source] == nil {
                blocks[index].detail = blocks[index + 1].detail
                blocks.remove(at: index + 1)
            }
        }
        return Parsed(title: title, blocks: blocks)
    }

    static func heading(_ line: String) -> (title: String, detail: String?) {
        let segments = line.replacingOccurrences(of: #"\s{3,}"#, with: "|", options: .regularExpression)
            .split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && dated.groups(in: $0) == nil }
        let names = segments.filter { !ScriptureReference.isReferenceLine($0) }
        guard line.contains("|") || segments.count > 1, let main = names.first(where: { $0.first.map(openingQuotes.contains) ?? false }) ?? names.last
        else { return (line, nil) }
        let rest = segments.filter { $0 != main }
        return (
            main.trimmingCharacters(in: CharacterSet(charactersIn: "“”\"‘’«»")),
            rest.isEmpty ? nil : rest.joined(separator: " · "))
    }

    struct Reading {
        var block: Block

        var ordinary: Bool

        var body: String
    }

    static func reading(_ line: String, hint: Hint?, boldMatters: Bool, forced: Kind?) -> Reading {
        var rest = strippingBullet(line)
        var cues: [String] = []
        while let lead = leadingAside.groups(in: rest), !ScriptureReference.isReferenceLine(lead[0]) {
            cues.append(lead[0].trimmingCharacters(in: .whitespaces))
            rest = lead[1].trimmingCharacters(in: .whitespaces)
        }
        let underlined = hint?.underlined ?? []
        func made(_ kind: Kind, _ text: String, detail: String? = nil, ordinary: Bool = false) -> Reading {
            Reading(
                block: Block(
                    source: line, kind: kind, text: text, detail: detail,
                    cues: kind == .skip ? [] : cues,
                    underlined: kind == .point || kind == .title ? underlined.filter { $0.count > 1 } : []),
                ordinary: ordinary, body: rest)
        }
        if rest.isEmpty {
            return made(.skip, cues.joined(separator: " · "))
        }

        var body = rest
        if let aside = trailingDashedAside.groups(in: body) {
            body = aside[0]
            cues.append(aside[1].trimmingCharacters(in: .whitespaces))
        }

        var label: String?
        if forced == nil, let labelled = labelled.groups(in: rest) {
            let name = labelled[0].trimmingCharacters(in: .whitespaces)
            let value = labelled[1].trimmingCharacters(in: .whitespaces)
            let word = name.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "#0123456789 "))
            if ["title", "message", "sermon", "message title", "sermon title"].contains(word) {
                return made(.title, value)
            } else if ["series", "date", "speaker", "pastor"].contains(word) {
                return made(.skip, line)
            } else if ["quote", "quotation"].contains(word) {
                let quote = quotation(in: value) ?? (text: value, source: nil)
                return made(.quote, quote.text, detail: quote.source)
            } else if ["text", "scripture", "passage", "key verse", "main text", "key text", "reading", "read"].contains(word) {
                rest = value
                body = value
            } else {
                label = name
                rest = value
                body = value
            }
        }

        if let forced {
            switch forced {
            case .skip:
                return made(.skip, line)
            case .title, .point:
                return made(forced, body)
            case .scripture:
                var passage = scripture(in: rest) ?? (reference: nil, verse: rest)
                takeTrailingAside(from: &passage.verse, reference: &passage.reference, cues: &cues)
                return made(.scripture, passage.verse, detail: passage.reference)
            case .quote:
                var text = rest
                var none: String?
                takeTrailingAside(from: &text, reference: &none, cues: &cues)
                let quote = quotation(in: text) ?? (text: text, source: nil)
                return made(.quote, quote.text, detail: quote.source)
            }
        }

        if var passage = scripture(in: rest) {
            takeTrailingAside(from: &passage.verse, reference: &passage.reference, cues: &cues)
            return made(.scripture, passage.verse, detail: passage.reference)
        }
        if let first = rest.first, openingQuotes.contains(first) {
            var text = rest
            var none: String?
            takeTrailingAside(from: &text, reference: &none, cues: &cues)
            if let quote = quotation(in: text) {
                return made(.quote, quote.text, detail: quote.source)
            }
        }
        if serviceLine.groups(in: rest) != nil || mediaCue.groups(in: rest) != nil || rest.contains(" ~ ") {
            return made(.skip, line)
        }
        if let label {
            return made(.point, body, detail: label)
        }
        if boldMatters, hint?.bold == false {
            return made(.skip, line, ordinary: true)
        }
        if body.count > longestPoint {
            return made(.skip, line, ordinary: true)
        }
        return made(.point, body, ordinary: true)
    }

    static func scripture(in line: String) -> (reference: String?, verse: String)? {
        let bare = line.trimmingCharacters(in: CharacterSet(charactersIn: "()[]–—- "))
        if ScriptureReference.isReferenceLine(bare) {
            return (bare, "")
        }
        let found = ScriptureReference.matches(in: line)
        if line.hasPrefix("("), let lead = found.first, line.index(after: line.startIndex) == lead.range.lowerBound {
            let tail = line[lead.range.upperBound...]
            let verse = tail.dropFirst().trimmingCharacters(in: CharacterSet(charactersIn: "–—-: "))
            if tail.hasPrefix(")"), !verse.isEmpty { return (lead.text, verse) }
        }
        if let lead = found.first, lead.range.lowerBound == line.startIndex {
            let tail = line[lead.range.upperBound...].trimmingCharacters(in: .whitespaces)
            if let first = tail.first, separators.contains(first) {
                let verse = String(tail.drop { separators.contains($0) || $0 == " " })
                if !verse.isEmpty { return (lead.text, verse) }
            } else if lead.hasVerse, let first = tail.first,
                      first.isUppercase || openingQuotes.contains(first),
                      tail.split(separator: " ").count >= 4 {
                return (lead.text, tail)
            }
        }
        if let last = found.last {
            let after = line[last.range.upperBound...].trimmingCharacters(in: .whitespaces)
            var before = line[..<last.range.lowerBound].trimmingCharacters(in: .whitespaces)
            if after.isEmpty || after == ")", let end = before.last {
                if end == "(" || separators.contains(end) {
                    before.removeLast()
                    let verse = before.trimmingCharacters(in: CharacterSet(charactersIn: "–—- "))
                    if !verse.isEmpty { return (last.text, verse) }
                } else if last.hasVerse, ".!?”\"’".contains(end), before.split(separator: " ").count >= 3 {
                    return (last.text, before)
                }
            }
        }
        return nil
    }

    static func trailingReferenceLine(_ line: String) -> String? {
        guard let first = line.first, first == "(" || separators.contains(first) else { return nil }
        let bare = line.trimmingCharacters(in: CharacterSet(charactersIn: "()[]–—- "))
        return ScriptureReference.isReferenceLine(bare) ? bare : nil
    }

    static func quotation(in line: String) -> (text: String, source: String?)? {
        guard let parts = quoted.groups(in: line) else { return nil }
        let text = parts[0].trimmingCharacters(in: .whitespaces)
        let source = parts[1].trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : (text, source.isEmpty ? nil : source)
    }

    private static func takeTrailingAside(from text: inout String, reference: inout String?, cues: inout [String]) {
        guard let aside = trailingAside.groups(in: text) else { return }
        let inner = aside[1].trimmingCharacters(in: .whitespaces)
        if translations.contains(inner.uppercased()) {
            if let held = reference, !held.uppercased().contains(inner.uppercased()) {
                reference = "\(held) (\(inner.uppercased()))"
                text = aside[0]
            }
        } else if !inner.isEmpty {
            cues.append(inner)
            text = aside[0]
        }
    }

    private static func strippingBullet(_ line: String) -> String {
        bullet.groups(in: line)?[0] ?? line
    }

    private static let separators: Set<Character> = ["–", "—", "-", ":"]
    private static let openingQuotes: Set<Character> = ["“", "\"", "‘", "«"]
    private static let translations = Set(ScriptureReference.translations.split(separator: "|").map(String.init))

    private static let bullet = GroupRegex(#"^(?:[•◦▪■●○‣·*]\s*|-\s+|#+\s+)(.+)$"#)
    private static let leadingAside = GroupRegex(#"^\(([^()]*)\)\s*(.*)$"#)
    private static let trailingAside = GroupRegex(#"^(.*\S)\s*\(([^()]*)\)[\s.]*$"#)
    private static let trailingDashedAside = GroupRegex(#"^(.*?\S)\s*[–—-]\s*\(([^()]*)\)\s*$"#)
    private static let quoted = GroupRegex(#"^[“"«‘](.+)[”"»’][\s.,]*(?:[–—-]+\s*(.+))?$"#)
    private static let labelled = GroupRegex(
        #"^(?:the\s+)?((?:title|message(?: title)?|sermon(?: title)?|series|date|speaker|pastor|quote|quotation|text|scripture|passage|key verse|main text|key text|reading|read|big idea|main idea|main point|bottom line|key thought|key truth|takeaway|application|point|truth|principle|step|key|lesson)(?:\s*#?\d+)?)\s*[:–—-]\s*(\S.*)$"#,
        caseInsensitive: true)
    private static let mediaCue = GroupRegex(
        #"^(?:pictures?|pics?|photos?|images?|videos?|clips?|graphics?|slides?)\s*(?:of|from|[:–—-])\s"#, caseInsensitive: true)
    private static let dated = GroupRegex(#"(\b\d{1,2}[-/.]\d{1,2}[-/.]\d{2,4}\b)"#)
    private static let leadingNumber = GroupRegex(#"^[\[(]?(\d{1,3})[\])]?\.?\s*[\p{L}“"‘]"#)
    static let singleVerse = GroupRegex(#"\d\s*[:.]\s*(\d+)[a-c]?(?:\s*\(?[A-Za-z]+\)?)?$"#)
    private static let serviceLine = GroupRegex(
        #"^(?:introduction|intro|conclusion|illustration|story|transition|next steps?|offering(?: moment)?|giving|tithes?(?: (?:and|&) offerings?)?|campus connect|announcements?|welcome|worship(?: set)?|response(?: song)?|communion|baptisms?|closing(?: prayer| song)?|opening prayer|prayer|dismissal|dismiss|benediction|invitation|altar call|video|bumper)\s*(?:$|[–—:/~-])"#,
        caseInsensitive: true)
}

public extension MessageNotes {

    static func styles(in theme: Theme?) -> [String] {
        var styles: [String] = []
        for design in theme?.slides ?? [] where score(design, .point) > 0 || score(design, .scripture) > 0 {
            let folder = design.folder ?? ""
            if !styles.contains(folder) { styles.append(folder) }
        }
        return styles
    }

    static func design(for kind: Kind, in theme: Theme?, style: String?) -> Slide? {
        let designs = theme?.slides ?? []
        let folder = style ?? styles(in: theme).first ?? ""
        let inStyle = designs.filter { ($0.folder ?? "") == folder }
        func best(_ kind: Kind, among designs: [Slide]) -> Slide? {
            var winner: (design: Slide, score: Int)?
            for design in designs {
                let score = score(design, kind)
                if score > (winner?.score ?? 0) { winner = (design, score) }
            }
            return winner?.design
        }
        return best(kind, among: inStyle)
            ?? (kind == .point ? nil : best(.point, among: inStyle))
            ?? best(kind, among: designs)
            ?? best(.point, among: designs)
    }

    internal static func score(_ design: Slide, _ kind: Kind) -> Int {
        let name = design.name.lowercased()
        let boxes = design.objects.filter { $0.objectKind == .text }.map { $0.name.lowercased() }
        switch kind {
        case .scripture:
            let named = ["verse", "scripture", "bible", "passage"].contains { name.contains($0) }
            return (named ? 3 : 0) + (named && boxes.contains("reference") ? 1 : 0)
        case .point:
            if name == "point" {
                return 5
            } else if name.hasPrefix("point"), !name.hasPrefix("points") {
                return 4
            } else if name.contains("point") {
                return 2
            } else {
                return 0
            }
        case .quote:
            return name.contains("quote") ? 3 : 0
        case .title:
            if name == "title" {
                return 5
            } else if ["section title", "sermon title", "message title"].contains(where: name.contains) {
                return 4
            } else if name.contains("title"), !name.contains("name") {
                return 2
            } else {
                return 0
            }
        case .skip:
            return 0
        }
    }

    static func makePresentation(
        _ parsed: Parsed,
        fallbackTitle: String? = nil,
        id: String = UUID().uuidString,
        themeId: String = "",
        theme: Theme? = nil,
        style: String? = nil,
        kindThemes: [Kind: Theme] = [:],
        newID: () -> String = { UUID().uuidString }
    ) -> Presentation {
        var slides: [Slide] = []
        var waiting: [String] = []
        for block in parsed.blocks {
            if block.kind == .skip {
                if slides.isEmpty {
                    waiting.append(block.text)
                } else {
                    slides[slides.count - 1].notes = joined(slides[slides.count - 1].notes, block.text)
                }
            } else {
                let own = kindThemes[block.kind].flatMap { $0.id == themeId ? nil : $0 }
                let ownStyle = own.map { styles(in: $0).contains(style ?? "") ? style : nil } ?? style
                var slide = slide(
                    for: block, design: design(for: block.kind, in: own ?? theme, style: ownStyle), newID: newID)
                slide.themeId = own?.id
                for note in waiting.reversed() { slide.notes = joined(note, slide.notes) }
                waiting = []
                slides.append(slide)
            }
        }
        if slides.isEmpty {
            slides = [Slide(id: newID(), name: "", objects: [])]
        }
        return Presentation(
            id: id,
            name: parsed.title ?? fallbackTitle ?? "Message Notes",
            presentationKind: .deck,
            themeId: themeId,
            slides: slides
        )
    }

    private static func joined(_ first: String?, _ second: String?) -> String? {
        let parts = [first, second].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

    internal static func slide(for block: Block, design: Slide?, newID: () -> String) -> Slide {
        let roles: (name: String, primary: [String], secondary: [String])
        switch block.kind {
        case .scripture:
            roles = ("Verse", ["verse", "scripture", "passage", "text", "body"], ["reference", "ref", "citation", "source"])
        case .quote:
            roles = ("Quote", ["quote", "body", "text"], ["source", "attribution", "author", "reference", "name"])
        case .title:
            roles = ("Title", ["title", "headline", "text", "point"], ["kicker", "subtitle", "subhead", "reference"])
        case .point, .skip:
            roles = ("Point", ["point", "text", "body", "title", "headline"], ["kicker", "label", "subtitle"])
        }
        var text = block.text
        var detail = block.detail ?? ""
        if block.kind == .scripture, text.isEmpty {
            text = detail
            detail = ""
        }

        let placeholders = (design?.objects ?? []).filter { $0.objectKind == .text }
        let fillable = placeholders.filter { !isDecoration($0) }
        func pick(_ names: [String], from boxes: [SlideObject]) -> SlideObject? {
            for name in names {
                if let exact = boxes.first(where: { $0.name.lowercased() == name }) { return exact }
            }
            for name in names {
                if let partial = boxes.first(where: { $0.name.lowercased().contains(name) }) { return partial }
            }
            return nil
        }
        let primary = pick(roles.primary, from: fillable)
            ?? fillable.max { ($0.textStyle?.fontSize ?? 0) < ($1.textStyle?.fontSize ?? 0) }
        let secondary = detail.isEmpty ? nil : pick(roles.secondary, from: fillable.filter { $0.id != primary?.id })

        if block.kind == .quote, !placeholders.contains(where: isDecoration) {
            text = "“\(text)”"
        }
        if secondary == nil, !detail.isEmpty, block.kind != .point {
            text += "\n" + (block.kind == .quote ? "– " : "") + detail
        }

        var objects: [SlideObject] = []
        if let primary {
            for placeholder in placeholders {
                var box = SlideObject(id: newID(), objectKind: .text, name: placeholder.name, text: "")
                if placeholder.id == primary.id {
                    box.text = text
                    box.styleRuns = underlines(block.underlined, in: text)
                } else if placeholder.id == secondary?.id {
                    box.text = detail
                } else if isDecoration(placeholder) {
                    box.text = placeholder.text
                }
                objects.append(box)
            }
        } else {
            var box = SlideObject(id: newID(), objectKind: .text, name: roles.name, text: text)
            box.styleRuns = underlines(block.underlined, in: text)
            objects = [box]
        }

        var slide = Slide(id: newID(), name: "", objects: objects, themeSlideName: design?.name)
        slide.adoptActions(of: design)
        slide.notes = block.cues.isEmpty ? nil : block.cues.joined(separator: "\n")
        return slide
    }

    private static func isDecoration(_ placeholder: SlideObject) -> Bool {
        let sample = placeholder.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return !sample.isEmpty && !sample.contains { $0.isLetter || $0.isNumber }
    }

    internal static func underlines(_ phrases: [String], in text: String) -> [TextStyleRun]? {
        var runs: [TextStyleRun] = []
        var cursor = text.startIndex
        for phrase in phrases where !phrase.isEmpty {
            guard let found = text.range(of: phrase, range: cursor..<text.endIndex) else { continue }
            let before = text[..<found.lowerBound]
            let lineStart = before.lastIndex(of: "\n").map { text.index(after: $0) } ?? text.startIndex
            runs.append(TextStyleRun(
                line: before.count { $0 == "\n" },
                column: text.distance(from: lineStart, to: found.lowerBound),
                length: phrase.count, underline: true))
            cursor = found.upperBound
        }
        return runs.isEmpty ? nil : runs
    }
}

public extension MessageNotes.Parsed {

    func splittingVerses() -> MessageNotes.Parsed {
        var result = self
        result.blocks = blocks.flatMap(MessageNotes.verses(of:))
        return result
    }
}

extension MessageNotes {

    static func verses(of block: Block) -> [Block] {
        guard block.kind == .scripture, !block.text.isEmpty, let reference = block.detail,
              let parts = verseRange.groups(in: reference),
              let first = Int(parts[1]), let last = Int(parts[2]), last > first, last - first <= 40
        else { return [block] }
        let pieces: [(text: String, reference: String)]
        if let numbered = numberedVerses(in: block.text, first: first, last: last) {
            pieces = numbered.enumerated().map { ($1, parts[0] + String(first + $0) + parts[3]) }
        } else {
            pieces = sentenceGroups(in: block.text, count: last - first + 1).map { ($0, reference) }
        }
        guard pieces.count > 1 else { return [block] }
        return pieces.enumerated().map { index, piece in
            var part = block
            part.text = piece.text
            part.detail = piece.reference
            part.cues = index == 0 ? block.cues : []
            return part
        }
    }

    static func numberedVerses(in text: String, first: Int, last: Int) -> [String]? {
        var text = text
        for (mark, digit) in zip("⁰¹²³⁴⁵⁶⁷⁸⁹", "0123456789") {
            text = text.replacingOccurrences(of: String(mark), with: String(digit))
        }
        func marker(_ verse: Int) -> NSRegularExpression {
            try! NSRegularExpression(pattern: #"(?<![\d:,.])[\[(]?\b"# + String(verse) + #"[\])]?\.?(?=\s*[\p{L}“"‘])\s*"#)
        }
        var pieces: [String] = []
        var cursor = text.startIndex
        let opening = marker(first)
        if let lead = opening.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), lead.range.location == 0,
           let range = Range(lead.range, in: text) {
            cursor = range.upperBound
        }
        for verse in stride(from: first + 1, through: last, by: 1) {
            guard let found = marker(verse).firstMatch(in: text, range: NSRange(cursor..., in: text)),
                  let range = Range(found.range, in: text)
            else { return nil }
            pieces.append(String(text[cursor..<range.lowerBound]))
            cursor = range.upperBound
        }
        pieces.append(String(text[cursor...]))
        let trimmed = pieces.map { $0.trimmingCharacters(in: .whitespaces) }
        return trimmed.contains(where: \.isEmpty) ? nil : trimmed
    }

    static func sentenceGroups(in text: String, count: Int) -> [String] {
        let whole = NSRange(text.startIndex..., in: text)
        let ends = sentenceEnd.matches(in: text, range: whole).compactMap { Range($0.range, in: text)?.upperBound }
        guard !ends.isEmpty, count > 1 else { return [text] }
        var cuts: [String.Index] = []
        let parts = min(count, ends.count + 1)
        for part in 1..<parts {
            let target = text.count * part / parts
            let open = ends.filter { end in cuts.last.map { end > $0 } ?? true }
            guard let cut = open.min(by: {
                abs(text.distance(from: text.startIndex, to: $0) - target) < abs(text.distance(from: text.startIndex, to: $1) - target)
            }) else { break }
            cuts.append(cut)
        }
        var groups: [String] = []
        var start = text.startIndex
        for cut in cuts + [text.endIndex] where cut > start {
            groups.append(text[start..<cut].trimmingCharacters(in: .whitespaces))
            start = cut
        }
        return groups.filter { !$0.isEmpty }
    }

    static let verseRange = GroupRegex(#"^(.*?\d+\s*[:.]\s*)(\d+)\s*[-–—]\s*(\d+)(\s*\(?[A-Za-z]+\)?)?$"#)
    private static let sentenceEnd = try! NSRegularExpression(pattern: #"[.!?][”"’']*\s+(?=[\p{Lu}“"‘])"#)
}

struct GroupRegex {
    private let regex: NSRegularExpression

    init(_ pattern: String, caseInsensitive: Bool = false) {
        regex = try! NSRegularExpression(pattern: pattern, options: caseInsensitive ? [.caseInsensitive] : [])
    }

    func groups(in text: String) -> [String]? {
        let whole = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: whole) else { return nil }
        return (1..<match.numberOfRanges).map { index in
            Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
        }
    }
}
