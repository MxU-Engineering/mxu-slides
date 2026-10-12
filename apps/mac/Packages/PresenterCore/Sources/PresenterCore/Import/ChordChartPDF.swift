import CoreGraphics
import Foundation

public enum ChordChartPDF {
    public static func chordPro(fromPDF data: Data) -> String? {
        chordPro(from: PDFGlyphReader.pages(of: data))
    }

    public static func importText(from data: Data, filename: String) -> String? {
        let isPDF = filename.lowercased().hasSuffix(".pdf") || data.starts(with: Array("%PDF".utf8))
        if isPDF {
            return chordPro(fromPDF: data)
        } else {
            let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252)
            return text.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        }
    }

    public static func chordPro(from pages: [PDFPageText]) -> String? {
        let body = bodySize(of: pages)
        guard body > 0 else { return nil }
        var metadata = Metadata()
        metadata.title = title(of: pages.first, body: body)

        var rows: [Row] = []
        for (pageIndex, page) in pages.enumerated() {
            let printed = Self.printedLines(of: page)
            printed.forEach { metadata.read($0.text) }
            let footerTop = printed.first { ccliSongNumber($0.text) != nil }?.baseline
            for row in Self.rows(of: page, index: pageIndex, body: body) {
                let isFooter = footerTop.map { row.baseline <= $0 + 0.5 } ?? false

                let isTitle = metadata.title.map { normalized(row.text) == normalized($0) } ?? false
                    && row.glyphs.allSatisfy { $0.bold || $0.text == " " }
                if !isFooter, !isTitle, !row.isOversized(body: body) {
                    rows.append(row)
                }
            }
        }

        var sections: [Section] = []
        var leading: [String] = []
        var index = 0
        while index < rows.count {
            let row = rows[index]
            if let label = label(of: row, body: body) {
                sections.append(Section(name: label))
            } else {
                var line: String
                if let chords = chords(of: row, body: body) {
                    let next = index + 1 < rows.count ? rows[index + 1] : nil
                    if let next, next.column == row.column, next.page == row.page,
                       row.baseline - next.baseline < body * 1.35,
                       label(of: next, body: body) == nil, self.chords(of: next, body: body) == nil {
                        line = inline(chords, into: next)
                        index += 1
                    } else {
                        line = chords.map { "[\($0.symbol)]" }.joined()
                    }
                } else {
                    line = row.text
                }
                if sections.isEmpty { leading.append(line) } else { sections[sections.count - 1].lines.append(line) }
            }
            index += 1
        }

        let lines = written(sections: sections, leading: sections.isEmpty ? leading : [])
        guard lines.contains(where: { !$0.isEmpty && Reflow.labelName(of: $0) == nil && !$0.hasPrefix("{") }) else {
            return nil
        }
        return (metadata.directives + [""] + lines).joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    struct Row {
        var page: Int
        var column: Int
        var baseline: CGFloat

        var glyphs: [PDFGlyph]

        var small: [PDFGlyph] = []

        var text: String { ChordChartPDF.text(of: glyphs).text }
        func isOversized(body: CGFloat) -> Bool { (glyphs.map(\.size).max() ?? 0) >= body * 1.25 }
    }

    static func bodySize(of pages: [PDFPageText]) -> CGFloat {
        var counts: [Int: Int] = [:]
        for glyph in pages.flatMap(\.glyphs) where !glyph.light && !glyph.text.trimmingCharacters(in: .whitespaces).isEmpty {
            counts[Int((glyph.size * 2).rounded()), default: 0] += 1
        }
        return CGFloat(counts.max { $0.value < $1.value }?.key ?? 0) / 2
    }

    static func title(of page: PDFPageText?, body: CGFloat) -> String? {
        guard let page, let largest = page.glyphs.filter({ !$0.light }).map(\.size).max(), largest >= body * 1.25 else { return nil }
        let glyphs = page.glyphs.filter { !$0.light && $0.size >= largest * 0.95 }
        let baseline = glyphs.map(\.y).max() ?? 0
        let text = Self.text(of: glyphs.filter { abs($0.y - baseline) < largest * 0.3 }.sorted { $0.x < $1.x }).text
        return text.isEmpty ? nil : text
    }

    static func printedLines(of page: PDFPageText) -> [(baseline: CGFloat, text: String)] {
        var lines: [(baseline: CGFloat, glyphs: [PDFGlyph])] = []
        for glyph in page.glyphs.sorted(by: { $0.y > $1.y }) {
            if let last = lines.indices.last, abs(lines[last].baseline - glyph.y) < 1.5 {
                lines[last].glyphs.append(glyph)
            } else {
                lines.append((glyph.y, [glyph]))
            }
        }
        return lines.map { ($0.baseline, text(of: $0.glyphs.sorted { $0.x < $1.x }).text) }
    }

    static func rows(of page: PDFPageText, index pageIndex: Int, body: CGFloat) -> [Row] {

        let printable = page.glyphs.filter { !$0.light && (!$0.text.trimmingCharacters(in: .whitespaces).isEmpty || $0.text == " ") }
        let main = printable.filter { $0.size >= body * 0.85 }
        let small = printable.filter { $0.size < body * 0.85 } + page.marks.compactMap { mark in
            mark.accidental.map {
                PDFGlyph(text: $0, x: mark.bounds.minX, y: mark.bounds.minY, width: mark.bounds.width,
                         size: body * 0.7, bold: true)
            }
        }
        let split = gutter(of: main.filter { $0.text != " " }, in: page.bounds)
        func column(_ glyph: PDFGlyph) -> Int { split.map { glyph.x + glyph.width / 2 < $0 ? 0 : 1 } ?? 0 }

        var rows: [Row] = []
        for columnIndex in 0...(split == nil ? 0 : 1) {

            let glyphs = main.filter { column($0) == columnIndex }.sorted { $0.y > $1.y }
            var columnRows: [Row] = []
            for glyph in glyphs {
                if let last = columnRows.indices.last, abs(columnRows[last].baseline - glyph.y) < body * 0.2 {
                    columnRows[last].glyphs.append(glyph)
                } else {
                    columnRows.append(Row(page: pageIndex, column: columnIndex, baseline: glyph.y, glyphs: [glyph]))
                }
            }

            for glyph in small where column(glyph) == columnIndex {
                let candidates = columnRows.indices.filter {
                    let rise = glyph.y - columnRows[$0].baseline
                    return rise > -body * 0.15 && rise < body * 0.6
                }
                if let nearest = candidates.min(by: { abs(glyph.y - columnRows[$0].baseline) < abs(glyph.y - columnRows[$1].baseline) }) {
                    columnRows[nearest].small.append(glyph)
                }
            }
            for index in columnRows.indices {
                columnRows[index].glyphs.sort { $0.x < $1.x }
                columnRows[index].small.sort { $0.x < $1.x }
            }
            rows += columnRows.filter { $0.glyphs.contains { $0.text != " " } }
        }
        return rows
    }

    static func gutter(of glyphs: [PDFGlyph], in bounds: CGRect) -> CGFloat? {
        guard glyphs.count > 20, bounds.width > 0 else { return nil }
        let low = bounds.minX + bounds.width * 0.3
        let high = bounds.minX + bounds.width * 0.7
        let spans = glyphs.filter { $0.maxX > low && $0.x < high }.map { ($0.x, $0.maxX) }.sorted { $0.0 < $1.0 }
        var widest: (start: CGFloat, end: CGFloat)?
        var cursor = low
        for span in spans {
            if span.0 > cursor, span.0 - cursor > (widest.map { $0.end - $0.start } ?? 0) {
                widest = (cursor, span.0)
            }
            cursor = max(cursor, span.1)
        }
        if high > cursor, high - cursor > (widest.map { $0.end - $0.start } ?? 0) {
            widest = (cursor, high)
        }
        let body = glyphs.map(\.size).sorted()[glyphs.count / 2]
        guard let widest, widest.end - widest.start >= body else { return nil }
        let split = (widest.start + widest.end) / 2
        let left = glyphs.filter { $0.maxX <= split }.count
        return min(left, glyphs.count - left) >= glyphs.count / 10 ? split : nil
    }

    static func text(of glyphs: [PDFGlyph]) -> (text: String, ends: [CGFloat]) {
        var text = ""
        var ends: [CGFloat] = []
        var lastEnd: CGFloat?
        for glyph in glyphs {
            if glyph.text == " " || glyph.text.trimmingCharacters(in: .whitespaces).isEmpty {
                if !text.isEmpty, text.last != " " { text.append(" "); ends.append(glyph.maxX) }
                lastEnd = glyph.maxX
                continue
            }
            if let lastEnd, glyph.x - lastEnd > glyph.size * 0.2, !text.isEmpty, text.last != " " {
                text.append(" ")
                ends.append(glyph.x)
            }
            for character in glyph.text {
                text.append(character)
                ends.append(glyph.maxX)
            }
            lastEnd = glyph.maxX
        }
        while text.last == " " { text.removeLast(); ends.removeLast() }
        return (text, ends)
    }

    static func label(of row: Row, body: CGFloat) -> String? {
        let text = row.text
        if let name = Reflow.labelName(of: text) {
            return name
        }
        let letters = text.filter(\.isLetter)
        let isHeading = !letters.isEmpty && letters == letters.uppercased()
            && row.glyphs.allSatisfy { $0.bold || $0.text == " " }
            && (row.glyphs.map(\.size).min() ?? 0) >= body * 1.03
            && text.count <= 24 && chords(of: row, body: body) == nil
        return isHeading ? text.capitalized : nil
    }

    static func chords(of row: Row, body: CGFloat) -> [(x: CGFloat, symbol: String)]? {
        var chords: [(x: CGFloat, symbol: String)] = []
        var allChart = true
        var token = ""
        var start: CGFloat = 0
        var end: CGFloat?
        func close() {
            if !token.isEmpty {
                let symbol = token
                    .replacingOccurrences(of: "♯", with: "#").replacingOccurrences(of: "♭", with: "b")
                    .replacingOccurrences(of: "Δ", with: "maj").replacingOccurrences(of: "∆", with: "maj")
                let core = symbol.trimmingCharacters(in: CharacterSet(charactersIn: "|()[]"))
                if ChordMath.isChordToken(core) {
                    chords.append((start, core))
                } else if !chartPunctuation.wholeMatch(symbol) {
                    allChart = false
                }
                token = ""
            }
        }

        for glyph in (row.glyphs + row.small).sorted(by: { $0.x < $1.x }) {
            if glyph.text.trimmingCharacters(in: .whitespaces).isEmpty {
                close()
                end = nil
                continue
            }
            let isSmall = glyph.size < body * 0.85
            if let end, glyph.x - end > (isSmall ? body * 0.3 : body * 0.12) { close() }
            if token.isEmpty { start = glyph.x }
            token += glyph.text
            end = max(end ?? glyph.maxX, glyph.maxX)
        }
        close()
        return allChart && !chords.isEmpty ? chords : nil
    }

    static func inline(_ chords: [(x: CGFloat, symbol: String)], into row: Row) -> String {
        let built = text(of: row.glyphs)
        var characters = Array(built.text)
        var inserts: [(index: Int, symbol: String)] = []
        for chord in chords {
            var index = built.ends.firstIndex { $0 > chord.x + 0.5 } ?? characters.count
            while index < characters.count, characters[index] == " " { index += 1 }
            var wordStart = index
            while wordStart > 0, characters[wordStart - 1] != " " { wordStart -= 1 }

            while index > wordStart, index < characters.count,
                  "aeiouAEIOU".contains(characters[index]), "aeiouAEIOU".contains(characters[index - 1]) {
                index -= 1
            }
            if index < characters.count,
               index - wordStart <= 1 || !characters[wordStart..<index].contains(where: { "aeiouAEIOU".contains($0) }) {
                index = wordStart
            }
            inserts.append((index, chord.symbol))
        }
        for insert in inserts.enumerated().sorted(by: { ($0.element.index, $0.offset) > ($1.element.index, $1.offset) }) {
            characters.insert(contentsOf: "[\(insert.element.symbol)]", at: insert.element.index)
        }
        return withoutLoneDashes(String(characters))
    }

    static func withoutLoneDashes(_ line: String) -> String {
        line.split(separator: " ", omittingEmptySubsequences: true)
            .map { word in
                let bare = ChordMath.extractLine(String(word)).text
                return bare.allSatisfy({ "-–—_".contains($0) }) && !bare.isEmpty
                    ? word.replacingOccurrences(of: bare, with: "") : String(word)
            }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    struct Section {
        var name: String
        var lines: [String] = []
    }

    static func written(sections: [Section], leading: [String]) -> [String] {
        var out = leading
        var seen: [(name: String, words: String)] = []
        for section in sections {
            let words = section.lines.map { ChordMath.extractLine($0).text.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }.joined(separator: "\n")
            if !out.isEmpty { out.append("") }
            out.append(Reflow.labelName(of: section.name) != nil ? section.name : "{start_of_part: \(section.name)}")
            let repeated = seen.contains { $0.name.caseInsensitiveCompare(section.name) == .orderedSame && $0.words == words }
            if !repeated {
                out += section.lines
                seen.append((section.name, words))
            }
        }
        return out
    }

    struct Metadata {
        var title: String?
        var key: String?
        var writers: String?
        var ccli: Int?
        var copyright: String?

        mutating func read(_ text: String) {
            if key == nil, let match = keyRegex.firstMatch(in: text) {
                let spelled = match.replacingOccurrences(of: "♯", with: "#").replacingOccurrences(of: "♭", with: "b")
                key = ChordMath.parseKey(spelled) != nil ? spelled : nil
            }
            if writers == nil, let match = writersRegex.firstMatch(in: text) {
                writers = match.trimmingCharacters(in: .whitespaces)
            }
            if ccli == nil, let number = ccliSongNumber(text) {
                ccli = number
            }
            if copyright == nil, text.hasPrefix("©") {
                copyright = text
            }
        }

        var directives: [String] {
            [
                title.map { "{title: \($0)}" },
                writers.map { "{artist: \($0)}" },
                key.map { "{key: \($0)}" },
                ccli.map { "{ccli: \($0)}" },
                copyright.map { "{copyright: \($0)}" },
            ].compactMap { $0 }
        }
    }

    static func ccliSongNumber(_ text: String) -> Int? {
        ccliRegex.firstMatch(in: text).flatMap { Int($0) }
    }

    static func normalized(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private static let keyRegex = SimpleRegex(#"\bKey\s*(?::|-|–)?\s*([A-G][#b♯♭]?m?)(?![a-z])"#)
    private static let writersRegex = SimpleRegex(#"^(?:Writers?|Words and Music by|Words & Music by)\s*:?\s*(.+)$"#, caseInsensitive: true)
    private static let ccliRegex = SimpleRegex(#"CCLI Song\s*#?\s*(\d+)"#, caseInsensitive: true)
    private static let chartPunctuation = SimpleRegex(
        #"[|/\\.%:\-–~*]+|\(?[xX]\d+\)?|\(?\d+[xX]\)?|N\.?C\.?|\(|\)"#, caseInsensitive: true)
}
