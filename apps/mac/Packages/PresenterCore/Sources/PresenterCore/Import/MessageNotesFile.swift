import AppKit
import Foundation
import PDFKit

public enum MessageNotesFile {

    public struct Loaded: Equatable, Sendable {
        public var text: String
        public var hints: [String: MessageNotes.Hint]

        public init(text: String, hints: [String: MessageNotes.Hint] = [:]) {
            self.text = text
            self.hints = hints
        }
    }

    public static let extensions = ["docx", "doc", "pages", "pptx", "rtf", "odt", "txt", "text", "md", "pdf"]

    public static func load(_ data: Data, filename: String) -> Loaded? {
        let ext = (filename as NSString).pathExtension.lowercased()
        let loaded: Loaded?
        let documentTypes: [String: NSAttributedString.DocumentType] = [
            "docx": .officeOpenXML, "doc": .docFormat, "rtf": .rtf, "odt": .openDocument,
        ]
        if ext == "pages" || ext == "pptx" {
            loaded = nil
        } else if let type = documentTypes[ext] {
            loaded = (try? NSAttributedString(data: data, options: [.documentType: type], documentAttributes: nil))
                .map(read)
        } else if ext == "pdf" || data.starts(with: Array("%PDF".utf8)) {
            loaded = read(PDFGlyphReader.pages(of: data)) ?? PDFDocument(data: data)?.string.map { Loaded(text: $0) }
        } else {
            loaded = (String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252))
                .map { Loaded(text: $0) }
        }
        return loaded.flatMap { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
    }

    public static func loadPages(at url: URL) throws -> Loaded {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mxu-pages-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let pdfURL = directory.appendingPathComponent("export.pdf")
        let sourcePath = appleScriptString(url.path)
        let outputPath = appleScriptString(pdfURL.path)
        let script = """
        tell application id "com.apple.iWork.Pages"
            set importedDocument to open POSIX file \(sourcePath)
            try
                export importedDocument to POSIX file \(outputPath) as PDF
            on error errorMessage number errorNumber
                try
                    close importedDocument saving no
                end try
                error errorMessage number errorNumber
            end try
            close importedDocument saving no
        end tell
        """
        let appleScript = NSAppleScript(source: script)
        var errorInfo: NSDictionary?

        let accessing = url.startAccessingSecurityScopedResource()
        defer {
            if accessing { url.stopAccessingSecurityScopedResource() }
        }
        guard let appleScript else {
            throw NSError(
                domain: "MessageNotesFile.PagesImport", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Could not prepare the Pages document for import."])
        }
        _ = appleScript.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let detail = errorInfo["NSAppleScriptErrorMessage"] as? String
            let errorNumber = errorInfo["NSAppleScriptErrorNumber"] as? Int
            let message: String
            if errorNumber == -1743 {
                message = "Allow MxU Slides to control Pages in System Settings > Privacy & Security > Automation, then try again."
            } else {
                message = detail.flatMap { $0.isEmpty ? nil : $0 }
                    ?? "Pages couldn't export this document. Make sure Pages is installed and allow MxU Slides to control it."
            }
            throw NSError(
                domain: "MessageNotesFile.PagesImport", code: errorNumber ?? 1,
                userInfo: [NSLocalizedDescriptionKey: message])
        }

        let data = try Data(contentsOf: pdfURL)
        guard data.starts(with: Array("%PDF".utf8)),
              let loaded = load(data, filename: "pages-export.pdf")
        else {
            throw NSError(
                domain: "MessageNotesFile.PagesImport", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "The Pages document did not contain readable text."])
        }
        return loaded
    }

    private static func appleScriptString(_ value: String) -> String {
        let lines = value.components(separatedBy: .newlines).map { line in
            let escaped = line.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            return "\"" + escaped + "\""
        }
        return lines.joined(separator: " & return & ")
    }

    public static func read(_ rich: NSAttributedString) -> Loaded {
        let string = rich.string as NSString
        var lines: [String] = []
        var hints: [String: MessageNotes.Hint] = [:]
        string.enumerateSubstrings(
            in: NSRange(location: 0, length: string.length), options: [.byParagraphs, .substringNotRequired]
        ) { _, range, _, _ in
            var bold = 0
            var inked = 0
            var underlined: [NSRange] = []
            rich.enumerateAttributes(in: range) { attributes, run, _ in
                let ink = string.substring(with: run).count { !$0.isWhitespace }
                inked += ink
                let font = attributes[.font] as? NSFont
                if font?.fontDescriptor.symbolicTraits.contains(.bold) == true { bold += ink }
                if (attributes[.underlineStyle] as? Int ?? 0) != 0 {
                    if let last = underlined.last, NSMaxRange(last) == run.location {
                        underlined[underlined.count - 1].length += run.length
                    } else {
                        underlined.append(run)
                    }
                }
            }
            let line = tidy(string.substring(with: range))
            lines.append(line)
            if !line.isEmpty {
                let phrases = underlined.map { tidy(string.substring(with: $0)) }.filter { !$0.isEmpty }
                hints[line] = MessageNotes.Hint(
                    bold: bold * 2 > inked,
                    underlined: phrases.count == 1 && phrases[0] == line ? [] : phrases)
            }
        }
        return Loaded(text: lines.joined(separator: "\n"), hints: hints)
    }

    public static func read(_ pages: [PDFPageText]) -> Loaded? {
        struct Line {
            var text: String
            var bold: Bool
            var page: Int
            var baseline: CGFloat
            var size: CGFloat
            var maxX: CGFloat
            var firstWord: CGFloat
        }
        var lines: [Line] = []
        for (index, page) in pages.enumerated() {
            var rows: [(baseline: CGFloat, glyphs: [PDFGlyph])] = []
            for glyph in page.glyphs.sorted(by: { $0.y > $1.y }) where !glyph.light {
                if let last = rows.indices.last, abs(rows[last].baseline - glyph.y) < max(1.5, glyph.size * 0.25) {
                    rows[last].glyphs.append(glyph)
                } else {
                    rows.append((glyph.y, [glyph]))
                }
            }
            for row in rows {
                let glyphs = row.glyphs.sorted { $0.x < $1.x }
                let inked = glyphs.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
                let text = tidy(ChordChartPDF.text(of: glyphs).text)
                guard let first = inked.first, let last = inked.last, !text.isEmpty else { continue }

                if text.allSatisfy(\.isNumber), rows.count > 1 { continue }
                let wordEnd = glyphs.drop { $0.x < first.x }
                    .first { $0.text.trimmingCharacters(in: .whitespaces).isEmpty }?.x ?? last.maxX
                lines.append(Line(
                    text: text, bold: inked.count { $0.bold } * 2 > inked.count, page: index,
                    baseline: row.baseline, size: inked.map(\.size).max() ?? first.size,
                    maxX: last.maxX, firstWord: wordEnd - first.x))
            }
        }
        guard let margin = lines.map(\.maxX).max() else { return nil }
        let pitches = zip(lines, lines.dropFirst()).compactMap { above, below -> CGFloat? in
            let gap = above.baseline - below.baseline
            return above.page == below.page && gap > above.size * 0.8 ? gap : nil
        }
        let pitch = pitches.min() ?? 0

        var paragraphs: [(text: String, bold: Int, lines: Int)] = []
        var output: [String] = []
        var hints: [String: MessageNotes.Hint] = [:]
        func close() {
            guard let paragraph = paragraphs.popLast() else { return }
            output.append(paragraph.text)
            hints[paragraph.text] = MessageNotes.Hint(bold: paragraph.bold * 2 > paragraph.lines)
        }
        for (index, line) in lines.enumerated() {
            var wraps = false
            var apart = false
            if index > 0 {
                let above = lines[index - 1]
                let gap = above.baseline - line.baseline
                let samePage = above.page == line.page
                let full = above.maxX + line.firstWord + above.size * 0.1 >= margin
                wraps = full && (!samePage || gap <= pitch * 1.3)
                apart = samePage && gap > pitch * 1.5
            }
            if wraps, !paragraphs.isEmpty {
                paragraphs[paragraphs.count - 1].text += " " + line.text
                paragraphs[paragraphs.count - 1].bold += line.bold ? 1 : 0
                paragraphs[paragraphs.count - 1].lines += 1
            } else {
                close()
                if apart { output.append("") }
                paragraphs.append((line.text, line.bold ? 1 : 0, 1))
            }
        }
        close()
        return Loaded(text: output.joined(separator: "\n"), hints: hints)
    }

    private static func tidy(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{2028}", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }
}
