import Foundation

public enum LyricPhrasing {

    public static let maxJoinedLength = 45

    public struct Casing: Equatable {

        var capitalized: Set<String>

        public init(_ text: String) {
            var capitalized: Set<String> = []
            for line in text.components(separatedBy: .newlines) {
                for word in LyricPhrasing.words(of: line).dropFirst() where word.first?.isUppercase == true {
                    capitalized.insert(word.trimmingCharacters(in: .punctuationCharacters))
                }
            }
            self.capitalized = capitalized
        }

        func midLine(_ word: String, before next: String?) -> String {
            let keeps = word == "I" || word.hasPrefix("I’") || word.hasPrefix("I'")
                || capitalized.contains(word.trimmingCharacters(in: .punctuationCharacters))
                || Self.alwaysCapitalized.contains(word.trimmingCharacters(in: .punctuationCharacters))

                || (next?.first?.isUppercase == true
                    && !Self.alwaysCapitalized.contains(next?.trimmingCharacters(in: .punctuationCharacters) ?? ""))
            return keeps ? word : word.prefix(1).lowercased() + word.dropFirst()
        }

        static let alwaysCapitalized: Set<String> = [
            "God", "Jesus", "Lord", "Christ", "Spirit", "Father", "King", "Savior", "Saviour",
            "You", "Your", "Yours", "He", "Him", "His",
        ]
    }

    public static func applies(to origin: PresentationOrigin?, text: String) -> Bool {
        switch origin?.source {
        case .planningCenterChart, .planningCenterLyrics, .songSelect, .chartFile: true
        case .pastedLyrics, .lyricsFile: LyricTextImporter.detectFormat(text) != .plainText
        default: false
        }
    }

    public static func rejoined(_ lines: [String], casing: Casing) -> [String] {
        var out: [String] = []
        for (index, line) in lines.enumerated() {
            let next = index + 1 < lines.count ? lines[index + 1] : nil
            if let previous = out.last, continues(line, after: previous, before: next) {
                out[out.count - 1] = joining(previous, line, casing: casing)
            } else {
                out.append(line)
            }
        }
        return out
    }

    static func continues(_ line: String, after previous: String, before next: String?) -> Bool {
        let words = Self.words(of: line)
        let previousWords = Self.words(of: previous)
        let bare = words.joined(separator: " ")
        let previousBare = previousWords.joined(separator: " ")
        let fits = !words.isEmpty && !previousWords.isEmpty
            && previousBare.count + 1 + bare.count <= maxJoinedLength
            && !previousBare.hasSuffix(".") && !previousBare.hasSuffix("!")
            && !previousBare.hasSuffix("?") && !previousBare.hasSuffix(";")

            && bare.lowercased() != previousBare.lowercased()
            && next.map { Self.words(of: $0).joined(separator: " ").lowercased() != bare.lowercased() } ?? true
        let first = key(words.first)
        let cue = runsOn.contains(key(previousWords.last))
            || continuations.contains(first)
            || (words.count <= 2 && !interjections.contains(first)
                && next.map { Self.words(of: $0).count > 3 } ?? true)
        return fits && cue
    }

    static func joining(_ previous: String, _ line: String, casing: Casing) -> String {
        var characters = Array(line)
        var index = 0
        var inChord = false

        while index < characters.count, inChord || characters[index] == "[" || !characters[index].isLetter {
            if characters[index] == "[" { inChord = true } else if characters[index] == "]" { inChord = false }
            index += 1
        }
        let words = Self.words(of: line)
        if let first = words.first, index < characters.count {
            let cased = casing.midLine(first, before: words.dropFirst().first)
            if cased != first, let letter = cased.first(where: \.isLetter) {
                characters[index] = letter
            }
        }
        return previous + " " + String(characters)
    }

    public static func slides(_ lines: [String], perSlide: Int) -> [[String]] {
        let limit = max(1, perSlide)
        let count = lines.count
        if count <= limit {
            return count == 0 ? [] : [lines]
        } else {
            let bare = lines.map { words(of: $0).joined(separator: " ").lowercased() }
            let ends = (0..<count).map { endsPhrase($0, bare) }

            var best = [Double](repeating: .infinity, count: count + 1)
            var from = [Int](repeating: 0, count: count + 1)
            best[0] = 0
            for start in 0..<count {
                for size in 1...min(limit, count - start) {
                    let end = start + size
                    var cost = best[start] + 1
                    if size < limit { cost += end == count || ends[end - 1] ? 0.7 : 0.9 }
                    if slideEndsBadly.contains(key(words(of: lines[end - 1]).last)) { cost += 5 }
                    cost += Double((start..<(end - 1)).filter { ends[$0] }.count) * 3
                    if cost < best[end] {
                        best[end] = cost
                        from[end] = start
                    }
                }
            }
            var slides: [[String]] = []
            var end = count
            while end > 0 {
                slides.insert(Array(lines[from[end]..<end]), at: 0)
                end = from[end]
            }
            return slides
        }
    }

    static func endsPhrase(_ index: Int, _ bare: [String]) -> Bool {
        let line = bare[index]
        let after = index + 1 < bare.count ? bare[index + 1] : nil
        let besideItself = (index > 0 && bare[index - 1] == line) || after == line
        return !line.isEmpty && !besideItself && bare.indices.contains { other in
            abs(other - index) > 1 && bare[other] == line
                && (other + 1 < bare.count ? bare[other + 1] : nil) != after
        }
    }

    public static func joinEdit(at caret: Int, in text: String, extraLabels: [String] = []) -> (location: Int, length: Int, replacement: String)? {
        let lines = text.components(separatedBy: "\n")

        var starts: [Int] = []
        var offset = 0
        for line in lines {
            starts.append(offset)
            offset += line.utf16.count + 1
        }
        let here = starts.lastIndex { $0 <= max(0, caret) } ?? 0
        let next = lines.indices.first { $0 > here && !lines[$0].trimmingCharacters(in: .whitespaces).isEmpty }
        let isWords: (String) -> Bool = { line in
            !words(of: line).isEmpty && Reflow.labelName(of: line, extraLabels: extraLabels) == nil
        }
        if let next, isWords(lines[here]), isWords(lines[next]) {
            let left = lines[here].replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression)
            let joined = joining(left, lines[next].trimmingCharacters(in: .whitespaces), casing: Casing(text))
            return (starts[here], starts[next] + lines[next].utf16.count - starts[here], joined)
        } else {
            return nil
        }
    }

    static func words(of line: String) -> [String] {
        ChordMath.extractLine(line).text.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    static func key(_ word: String?) -> String {
        (word ?? "").lowercased().trimmingCharacters(in: CharacterSet.letters.inverted)
    }

    static let runsOn: Set<String> = [
        "the", "a", "an", "of", "to", "for", "and", "or", "but", "with", "in", "on", "at", "by",
        "from", "into", "about", "than", "that", "my", "your", "our", "his", "her", "their", "its",
        "be", "been", "is", "when", "who", "as", "if", "like",
    ]

    static let continuations: Set<String> = ["of", "than", "about"]

    static let slideEndsBadly: Set<String> = [
        "the", "a", "an", "of", "to", "for", "and", "or", "but", "with", "in", "on", "at", "by",
        "from", "into", "about", "than", "that", "my", "your", "our", "his", "her", "their", "its",
    ]

    static let interjections: Set<String> = ["oh", "o", "hallelujah", "alleluia", "amen", "hosanna", "whoa", "yeah"]
}
