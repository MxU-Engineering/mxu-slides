import Foundation

public enum ScriptureReference {

    public struct Match: Equatable, Sendable {
        public var range: Range<String.Index>
        public var text: String

        public var hasVerse: Bool
    }

    public struct Split: Equatable, Sendable {
        public var verse: String
        public var reference: String
    }

    static let books: [String] = [
        "Genesis|Gen", "Exodus|Exod|Ex", "Leviticus|Lev", "Numbers|Num", "Deuteronomy|Deut|Dt",
        "Joshua|Josh", "Judges|Judg", "Ruth", "Samuel|Sam", "Kings|Kgs", "Chronicles|Chron|Chr",
        "Ezra", "Nehemiah|Neh", "Esther|Esth", "Job", "Psalms|Psalm|Ps|Pss", "Proverbs|Prov",
        "Ecclesiastes|Eccl|Eccles", "Song of Songs|Song of Solomon|Song", "Isaiah|Isa", "Jeremiah|Jer",
        "Lamentations|Lam", "Ezekiel|Ezek", "Daniel|Dan", "Hosea|Hos", "Joel", "Amos", "Obadiah|Obad",
        "Jonah|Jon", "Micah|Mic", "Nahum|Nah", "Habakkuk|Hab", "Zephaniah|Zeph", "Haggai|Hag",
        "Zechariah|Zech", "Malachi|Mal",
        "Matthew|Matt|Mt", "Mark|Mk", "Luke|Lk|Lu", "John|Jn", "Acts", "Romans|Rom", "Corinthians|Cor",
        "Galatians|Gal", "Ephesians|Eph", "Philippians|Phil", "Colossians|Col", "Thessalonians|Thess",
        "Timothy|Tim", "Titus", "Philemon|Phlm", "Hebrews|Heb", "James|Jas", "Peter|Pet", "Jude",
        "Revelation|Rev",
    ]

    static let translations = "NIV|ESV|KJV|NKJV|NLT|NASB|CSB|HCSB|MSG|AMP|NRSV|NET|TPT|CEV|NCV|WEB|ASV|RSV|BSB|LSB|NIRV|GNT|NABRE"

    private static let pattern: NSRegularExpression = {
        let names = books.flatMap { $0.split(separator: "|").map(String.init) }
            .sorted { $0.count > $1.count }
            .map(NSRegularExpression.escapedPattern(for:))
            .joined(separator: "|")
        let ordinal = #"(?:(?:[123]|I{1,3}|First|Second|Third)\s+)?"#
        let verse = #"(?:\s*(?::|\.|\s+v\.?|\s+vs\.?|\s+verses?)\s*\d+[a-c]?)"#
        let range = #"(?:\s*[-–—]\s*\d+(?::\d+)?[a-c]?)?(?:\s*,\s*\d+(?:\s*[-–—]\s*\d+)?)*"#
        let translation = #"(?:\s*\(?(?:\#(translations))\)?)?"#
        return try! NSRegularExpression(
            pattern: #"\b\#(ordinal)(?:\#(names))\.?\s+(\d+)(\#(verse))?\#(range)\#(translation)"#,
            options: [.caseInsensitive])
    }()

    public static func matches(in line: String) -> [Match] {
        let whole = NSRange(line.startIndex..., in: line)
        return pattern.matches(in: line, range: whole).compactMap { result in
            guard let range = Range(result.range, in: line) else { return nil }
            let hasVerse = result.range(at: 2).location != NSNotFound
            return Match(range: range, text: String(line[range]), hasVerse: hasVerse)
        }
    }

    public static func isReferenceLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        var rest = trimmed
        let found = matches(in: trimmed)
        guard !found.isEmpty else { return false }
        for match in found.reversed() { rest.removeSubrange(match.range) }
        let leftovers = rest.filter { !$0.isWhitespace && !";,()[]".contains($0) }
        return leftovers.isEmpty
    }

    public static func split(_ text: String) -> Split? {
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard let first = lines.first, let last = lines.last else { return nil }
        if lines.count == 1 {
            if isReferenceLine(first) { return Split(verse: "", reference: first) }
            return splitInline(first)
        }
        if isReferenceLine(last) {
            return Split(verse: lines.dropLast().joined(separator: "\n"), reference: last)
        }
        if isReferenceLine(first) {
            return Split(verse: lines.dropFirst().joined(separator: "\n"), reference: first)
        }
        if let inline = splitInline(last) {
            return Split(verse: (lines.dropLast() + [inline.verse]).filter { !$0.isEmpty }.joined(separator: "\n"), reference: inline.reference)
        }
        return nil
    }

    private static func splitInline(_ line: String) -> Split? {
        let found = matches(in: line)
        guard let match = found.last else { return nil }
        let before = String(line[..<match.range.lowerBound]).trimmingCharacters(in: .whitespaces)
        let after = String(line[match.range.upperBound...]).trimmingCharacters(in: .whitespaces)
        let trailing = after.isEmpty || after == ")"
        let opensParen = before.hasSuffix("(")
        let afterDash = before.last.map { "-–—".contains($0) } ?? false
        if trailing, opensParen || afterDash {
            var verse = before
            verse.removeLast()
            return Split(verse: verse.trimmingCharacters(in: .whitespaces), reference: match.text)
        }
        if trailing, match.hasVerse, !before.isEmpty {
            return Split(verse: before, reference: match.text)
        }
        if let lead = found.first, lead.range.lowerBound == line.startIndex {
            let rest = String(line[lead.range.upperBound...]).trimmingCharacters(in: .whitespaces)
            let separator = rest.first.map { ":-–—".contains($0) } ?? false
            if separator {
                let verse = String(rest.dropFirst()).trimmingCharacters(in: .whitespaces)
                if !verse.isEmpty { return Split(verse: verse, reference: lead.text) }
            }
        }
        return nil
    }

    public static func verses(of reference: String) -> (chapter: String, verses: ClosedRange<Int>)? {
        let range = NSRange(reference.startIndex..., in: reference)
        guard let match = versePattern.firstMatch(in: reference, range: range),
              let chapter = Range(match.range(at: 1), in: reference),
              let first = Range(match.range(at: 2), in: reference).flatMap({ Int(reference[$0]) }) else { return nil }
        let last = Range(match.range(at: 3), in: reference).flatMap { Int(reference[$0]) } ?? first
        guard last >= first else { return nil }
        return (String(reference[chapter]), first ... last)
    }

    private static let versePattern = try! NSRegularExpression(
        pattern: #"^\s*([^:]*?\d+)\s*:\s*(\d+)[a-c]?(?:\s*[-–—]\s*(\d+)[a-c]?)?\s*(?:\(?[A-Z]{2,6}\)?)?\s*$"#)

    public struct Verse: Equatable, Sendable {
        public var number: Int?
        public var text: String

        public var numbered: String { number.map { "\($0) \(text)" } ?? text }
    }

    public static func verses(in text: String, numbered verses: ClosedRange<Int>) -> [Verse] {
        let cuts = verseNumbers(in: text, numbered: verses)
        guard !cuts.isEmpty else { return [Verse(number: nil, text: text.trimmingCharacters(in: .whitespacesAndNewlines))] }
        var result: [Verse] = []
        let head = text[..<cuts[0].marker.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        if !head.isEmpty { result.append(Verse(number: nil, text: head)) }
        for (index, cut) in cuts.enumerated() {
            let end = index + 1 < cuts.count ? cuts[index + 1].marker.lowerBound : text.endIndex
            let words = text[cut.marker.upperBound ..< end].trimmingCharacters(in: .whitespacesAndNewlines)
            result.append(Verse(number: cut.number, text: words))
        }
        return result
    }

    public static func removingVerseNumbers(from text: String, numbered verses: ClosedRange<Int>) -> String {
        var text = text
        for cut in verseNumbers(in: text, numbered: verses).reversed() { text.removeSubrange(cut.marker) }
        return text
    }

    private static func verseNumbers(in text: String, numbered verses: ClosedRange<Int>) -> [(number: Int, marker: Range<String.Index>)] {
        let whole = NSRange(text.startIndex..., in: text)
        var cuts: [(number: Int, marker: Range<String.Index>)] = []
        var expected = verses.lowerBound
        for match in numberPattern.matches(in: text, range: whole) {
            guard expected <= verses.upperBound, let range = Range(match.range, in: text),
                  let digits = Range(match.range(at: 1), in: text), let number = Int(text[digits]) else { continue }
            let leading = !text[..<range.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if number == expected || (cuts.isEmpty && leading && number == expected + 1 && number <= verses.upperBound) {
                cuts.append((number, range))
                expected = number + 1
            }
        }
        return cuts
    }

    private static let numberPattern = try! NSRegularExpression(
        pattern: #"(?:^|(?<=\s))(\d{1,3})\s+(?=[^\d\s])"#, options: [.anchorsMatchLines])
}
