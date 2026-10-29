import Foundation

public struct BibleVerse: Codable, Sendable, Equatable, Identifiable {
    public let book: String
    public let chapter: Int
    public let verse: Int
    public let text: String
    // Online editions can publish a single text unit covering several verses
    // (MSG), or a partial verse. Keep its label and request ID without inventing
    // separate verse texts. Optional fields keep older offline JSON compatible.
    public let verseLabel: String?
    public let apiVerseID: String?
    public var displayNumber: String { verseLabel ?? String(verse) }
    public var endNumber: String { displayNumber.components(separatedBy: "–").last ?? displayNumber }
    public var lastVerse: Int { Int(endNumber.prefix(while: { $0.isNumber })) ?? verse }
    public var id: String { apiVerseID ?? "\(book).\(chapter).\(verse)" }
    public var reference: String { "\(BibleBook.name(book)) \(chapter):\(displayNumber)" }

    public init(book: String, chapter: Int, verse: Int, text: String, verseLabel: String? = nil, apiVerseID: String? = nil) {
        self.verseLabel = verseLabel; self.apiVerseID = apiVerseID
        self.book = book; self.chapter = chapter; self.verse = verse; self.text = text
    }
}

public enum BibleBook {
    // USFM identifiers are stable across translations. Numbered books stay distinct.
    public static let all: [(id: String, name: String)] = [
        ("GEN", "Genesis"), ("EXO", "Exodus"), ("LEV", "Leviticus"), ("NUM", "Numbers"), ("DEU", "Deuteronomy"),
        ("JOS", "Joshua"), ("JDG", "Judges"), ("RUT", "Ruth"), ("1SA", "1 Samuel"), ("2SA", "2 Samuel"),
        ("1KI", "1 Kings"), ("2KI", "2 Kings"), ("1CH", "1 Chronicles"), ("2CH", "2 Chronicles"), ("EZR", "Ezra"),
        ("NEH", "Nehemiah"), ("EST", "Esther"), ("JOB", "Job"), ("PSA", "Psalms"), ("PRO", "Proverbs"),
        ("ECC", "Ecclesiastes"), ("SNG", "Song of Songs"), ("ISA", "Isaiah"), ("JER", "Jeremiah"), ("LAM", "Lamentations"),
        ("EZK", "Ezekiel"), ("DAN", "Daniel"), ("HOS", "Hosea"), ("JOL", "Joel"), ("AMO", "Amos"),
        ("OBA", "Obadiah"), ("JON", "Jonah"), ("MIC", "Micah"), ("NAM", "Nahum"), ("HAB", "Habakkuk"),
        ("ZEP", "Zephaniah"), ("HAG", "Haggai"), ("ZEC", "Zechariah"), ("MAL", "Malachi"),
        ("MAT", "Matthew"), ("MRK", "Mark"), ("LUK", "Luke"), ("JHN", "John"), ("ACT", "Acts"), ("ROM", "Romans"),
        ("1CO", "1 Corinthians"), ("2CO", "2 Corinthians"), ("GAL", "Galatians"), ("EPH", "Ephesians"), ("PHP", "Philippians"),
        ("COL", "Colossians"), ("1TH", "1 Thessalonians"), ("2TH", "2 Thessalonians"), ("1TI", "1 Timothy"), ("2TI", "2 Timothy"),
        ("TIT", "Titus"), ("PHM", "Philemon"), ("HEB", "Hebrews"), ("JAS", "James"), ("1PE", "1 Peter"),
        ("2PE", "2 Peter"), ("1JN", "1 John"), ("2JN", "2 John"), ("3JN", "3 John"), ("JUD", "Jude"), ("REV", "Revelation"),
    ]
    public static func name(_ id: String) -> String { all.first { $0.id == id }?.name ?? id }
    public static func resolve(_ text: String) -> String? {
        let key = normalized(text)
        let aliases = ["ps": "PSA", "psalm": "PSA", "songofsolomon": "SNG", "sos": "SNG", "jn": "JHN", "joh": "JHN", "mt": "MAT", "mk": "MRK", "lk": "LUK", "phil": "PHP", "phlm": "PHM", "james": "JAS", "judg": "JDG", "ezek": "EZK"]
        if let id = aliases[key] { return id }
        if let exact = all.first(where: { normalized($0.name) == key || normalized($0.id) == key }) { return exact.id }
        guard key.count >= 3 else { return nil }
        let matches = all.filter { normalized($0.name).hasPrefix(key) }
        return matches.count == 1 ? matches[0].id : nil
    }
    private static func normalized(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}

public struct BibleTranslation: Codable, Sendable, Equatable, Identifiable {
    public let formatVersion: Int
    public let id: String
    public let name: String
    public let language: String
    public let copyright: String
    public let source: String?
    public let verses: [BibleVerse]

    public init(id: String, name: String, language: String = "en", copyright: String, source: String? = nil, verses: [BibleVerse]) {
        self.formatVersion = 1; self.id = id; self.name = name; self.language = language
        self.copyright = copyright; self.source = source; self.verses = verses
    }
    public static func bundledWEB() throws -> BibleTranslation {
        guard let url = Bundle.module.url(forResource: "WEB", withExtension: "json") else {
            throw BibleError.message("The bundled WEB Bible is missing. Reinstall the app.")
        }
        return try read(url)
    }
    public static func read(_ url: URL) throws -> BibleTranslation {
        if let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 64 * 1024 * 1024 {
            throw BibleError.message("Bible files must be smaller than 64 MB.")
        }
        let data = try Data(contentsOf: url)
        guard data.count <= 64 * 1024 * 1024 else { throw BibleError.message("Bible file is too large.") }
        let translation: BibleTranslation
        do { translation = try JSONDecoder().decode(Self.self, from: data) }
        catch { throw BibleError.message("This file is not a supported Bible JSON file. Use the format shown by Export Import Example.") }
        _ = try BibleCorpus(translation)
        return translation
    }
}

public enum BibleError: LocalizedError {
    case message(String)
    public var errorDescription: String? { if case .message(let text) = self { text } else { "Bible error" } }
}

public struct BibleCorpus: Sendable {
    public let translation: BibleTranslation
    public let verses: [BibleVerse]
    private let positions: [String: Int]
    private let searchable: [String]
    public var books: [(id: String, name: String)] { BibleBook.all.filter { id, _ in verses.contains { $0.book == id } } }

    public init(_ translation: BibleTranslation) throws {
        guard translation.formatVersion == 1, !translation.id.isEmpty, translation.id.count <= 40,
              translation.id.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || "-_".unicodeScalars.contains($0) }),
              !translation.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !translation.copyright.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !translation.verses.isEmpty, translation.verses.count <= 100_000 else {
            throw BibleError.message("The Bible needs formatVersion 1, an ID (letters, numbers, - or _), a name, copyright information, and 1–100,000 verses.")
        }
        let order = Dictionary(uniqueKeysWithValues: BibleBook.all.enumerated().map { ($0.element.id, $0.offset) })
        var seen = Set<String>()
        for verse in translation.verses {
            guard verse.verseLabel == nil, verse.apiVerseID == nil, order[verse.book] != nil, (1...200).contains(verse.chapter), (1...999).contains(verse.verse),
                  !verse.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, verse.text.count <= 20_000,
                  seen.insert(verse.id).inserted else {
                throw BibleError.message("Invalid or duplicate verse: \(verse.id). Use USFM book IDs (GEN, JHN, 1JN…), positive chapter/verse numbers, and nonempty text.")
            }
        }
        self.translation = translation
        verses = translation.verses.sorted {
            (order[$0.book]!, $0.chapter, $0.verse) < (order[$1.book]!, $1.chapter, $1.verse)
        }
        positions = Dictionary(uniqueKeysWithValues: verses.enumerated().map { ($0.element.id, $0.offset) })
        searchable = verses.map { Self.fold($0.text) }
    }

    public func chapters(in book: String) -> [Int] { Array(Set(verses.filter { $0.book == book }.map(\.chapter))).sorted() }

    public func passage(_ reference: String) throws -> [BibleVerse] {
        let pattern = #"^\s*(.+?)\s*(\d+)\s*(?::\s*(\d+)\s*(?:[-–—]\s*(?:(\d+)\s*:\s*)?(\d+)\s*)?)?$"#
        let regex = try NSRegularExpression(pattern: pattern)
        let input = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let match = regex.firstMatch(in: input, range: NSRange(input.startIndex..., in: input)) else {
            throw BibleError.message("Enter a reference such as John 3, John 3:16–18, or John 3:16–4:2.")
        }
        func part(_ i: Int) -> String? { Range(match.range(at: i), in: input).map { String(input[$0]) } }
        guard let book = part(1).flatMap(BibleBook.resolve), let chapter = part(2).flatMap(Int.init) else {
            throw BibleError.message("Book not recognized. Try the full name, such as 1 John 3:1.")
        }
        guard let startVerse = part(3).flatMap(Int.init) else {
            let found = verses.filter { $0.book == book && $0.chapter == chapter }
            guard !found.isEmpty else { throw BibleError.message("That chapter is not in \(translation.id).") }
            return found
        }
        let endChapter = part(4).flatMap(Int.init) ?? chapter
        let endVerse = part(5).flatMap(Int.init) ?? startVerse
        guard let start = positions["\(book).\(chapter).\(startVerse)"],
              let end = positions["\(book).\(endChapter).\(endVerse)"], end >= start else {
            throw BibleError.message("That verse range is not in \(translation.id). Check the chapter, verse numbers, and range order.")
        }
        return Array(verses[start...end])
    }

    public func search(_ query: String, limit: Int = 200) -> [BibleVerse] {
        let words = Self.fold(query).split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty, limit > 0 else { return [] }
        var found: [BibleVerse] = []
        for (index, text) in searchable.enumerated() where words.allSatisfy({ text.contains($0) }) {
            found.append(verses[index])
            if found.count == limit { break }
        }
        return found
    }
    public func adjacent(to verse: BibleVerse, offset: Int) -> BibleVerse? {
        guard let index = positions[verse.id], verses.indices.contains(index + offset) else { return nil }
        return verses[index + offset]
    }
    public static func reference(for verses: [BibleVerse]) -> String {
        guard let first = verses.first, let last = verses.last else { return "" }
        if first.id == last.id { return first.reference }
        if first.book != last.book { return "\(first.reference)–\(last.reference)" }
        return first.chapter == last.chapter ? "\(BibleBook.name(first.book)) \(first.chapter):\(first.displayNumber.components(separatedBy: "–")[0])–\(last.endNumber)" : "\(first.reference)–\(last.chapter):\(last.endNumber)"
    }
    private static func fold(_ text: String) -> String { text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX")) }
}
