import Foundation

enum ChordChartText {
    struct Inlined: Equatable {

        var text: String

        var chordCount: Int
        var musicKey: String?
    }

    static func inlined(_ text: String) -> Inlined {
        let lines = text.components(separatedBy: "\n").map(expandingTabs)
        var out: [String] = []
        var chordCount = 0
        var musicKey: String?
        var index = 0
        while index < lines.count {
            let line = lines[index]
            if let key = keyLine(line) {
                musicKey = musicKey ?? key
            } else if let (label, chords) = labeledChordLine(line) {
                chordCount += chords.count
                out.append(label)
                out.append(chordOnly(chords))
            } else if let chords = chordTokens(in: line) {
                chordCount += chords.count
                if index + 1 < lines.count, isLyric(lines[index + 1]) {
                    out.append(merging(chords, into: lines[index + 1]))
                    index += 1
                } else {
                    out.append(chordOnly(chords))
                }
            } else {
                out.append(line)
            }
            index += 1
        }
        if chordCount > 0 {
            return Inlined(text: out.joined(separator: "\n"), chordCount: chordCount, musicKey: musicKey)
        } else {
            return Inlined(text: text, chordCount: 0, musicKey: nil)
        }
    }

    static func titled(_ text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        if let first = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
           first + 1 == lines.count || lines[first + 1].trimmingCharacters(in: .whitespaces).isEmpty,
           !lines[first].contains("["), !lines[first].contains("{"),
           Reflow.labelName(of: lines[first]) == nil {
            lines[first] = "{title: \(lines[first].trimmingCharacters(in: .whitespaces))}"
            return lines.joined(separator: "\n")
        } else {
            return text
        }
    }

    static func chordTokens(in line: String) -> [(column: Int, symbol: String)]? {
        var chords: [(column: Int, symbol: String)] = []
        var allChart = true
        var column = 0
        var token = ""
        var tokenStart = 0
        func close() {
            if !token.isEmpty {

                let leading = token.prefix { "|([".contains($0) }.count
                let core = String(token.dropFirst(leading)).trimmingCharacters(in: CharacterSet(charactersIn: "|)]"))
                if ChordMath.isChordToken(core) {
                    chords.append((tokenStart + leading, core))
                } else if !chartPunctuation.wholeMatch(token) {
                    allChart = false
                }
                token = ""
            }
        }
        for character in line {
            if character == " " {
                close()
            } else {
                if token.isEmpty { tokenStart = column }
                token.append(character)
            }
            column += 1
        }
        close()
        return allChart && !chords.isEmpty ? chords : nil
    }

    private static func labeledChordLine(_ line: String) -> (label: String, chords: [(column: Int, symbol: String)])? {
        let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
        if parts.count == 2, let label = Reflow.labelName(of: parts[0]),
           let chords = chordTokens(in: parts[1]) {
            return (label, chords)
        } else {
            return nil
        }
    }

    private static func keyLine(_ line: String) -> String? {
        keyLineRegex.firstMatch(in: line.trimmingCharacters(in: .whitespaces))
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .flatMap { ChordMath.parseKey($0) != nil ? $0 : nil }
    }

    private static func isLyric(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty
            && chordTokens(in: line) == nil
            && labeledChordLine(line) == nil
            && keyLine(line) == nil
            && Reflow.labelName(of: trimmed) == nil
            && !(trimmed.hasPrefix("{") && trimmed.hasSuffix("}"))
    }

    static func merging(_ chords: [(column: Int, symbol: String)], into lyric: String) -> String {
        var characters = Array(lyric)
        let end = characters.count
        for chord in chords.sorted(by: { $0.column > $1.column }) {
            characters.insert(contentsOf: "[\(chord.symbol)]", at: min(chord.column, end))
        }
        return String(characters)
    }

    private static func chordOnly(_ chords: [(column: Int, symbol: String)]) -> String {
        chords.map { "[\($0.symbol)]" }.joined()
    }

    private static func expandingTabs(_ line: String) -> String {
        if line.contains("\t") {
            var expanded = ""
            for character in line {
                if character == "\t" {
                    expanded += String(repeating: " ", count: 4 - expanded.count % 4)
                } else {
                    expanded.append(character)
                }
            }
            return expanded
        } else {
            return line
        }
    }

    private static let chartPunctuation = SimpleRegex(
        #"[|/\\.%:\-–~*]+|\(?[xX]\d+\)?|\(?\d+[xX]\)?|N\.?C\.?|\(|\)"#, caseInsensitive: true)
    private static let keyLineRegex = SimpleRegex(
        #"^key\s*(?::|-|–|of|=)?\s*([A-G][#b♯♭]?(?:m|min|minor)?)$"#, caseInsensitive: true)
}
