import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum NoteFileReader {
    public typealias SaveMedia = @Sendable (_ data: Data, _ fileName: String) -> String?

    public struct Media: Sendable, Equatable {
        public var url: String
        public var fileName: String
        public var video: Bool

        public init(url: String, fileName: String, video: Bool) {
            self.url = url
            self.fileName = fileName
            self.video = video
        }

        public static func isVideo(fileName name: String) -> Bool? {
            guard let type = UTType(filenameExtension: (name as NSString).pathExtension) else { return nil }
            if type.conforms(to: .image) { return false }
            if type.conforms(to: .movie) || type.conforms(to: .video) { return true }
            return nil
        }

        static func saving(_ data: Data, fileName: String, with save: SaveMedia?) -> Media? {
            guard let save, let video = isVideo(fileName: fileName), video || !isIcon(data, fileName: fileName) else { return nil }
            return save(data, fileName).map { Media(url: $0, fileName: fileName, video: video) }
        }

        static func isIcon(_ data: Data, fileName: String) -> Bool {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int else { return false }
            return min(width, height) < 48 || fileName == "Attachment.png" && max(width, height) <= 48
        }

        var block: NoteBlock {
            video ? NoteBlock(type: .attachment, url: url, attachmentKind: "video", filename: fileName) : NoteBlock(type: .image, url: url)
        }
    }

    public struct Line: Sendable, Equatable {
        public var runs: [NoteRun]

        public var size: Double

        public var heading: Int?

        public var list: Bool?

        public var media: Media?

        public var gap = false

        public init(runs: [NoteRun], size: Double = 0, heading: Int? = nil, list: Bool? = nil, media: Media? = nil, gap: Bool = false) {
            self.runs = runs
            self.size = size
            self.heading = heading
            self.list = list
            self.media = media
            self.gap = gap
        }
    }

    public static let fileExtensions = ["docx", "doc", "rtf", "rtfd", "odt", "pdf", "txt", "text", "md", "pptx"]

    public static func mediaBlock(file url: URL, save: SaveMedia?) -> NoteBlock? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return Media.saving(data, fileName: url.lastPathComponent, with: save)?.block
    }

    public static func body(ofFile url: URL, save: SaveMedia? = nil) -> NoteBody? {
        let body: NoteBody?
        switch url.pathExtension.lowercased() {
        case "pdf":
            body = (try? Data(contentsOf: url)).map { Self.body(pdf: $0, save: save) }
        case "txt", "text", "md":
            body = (try? String(contentsOf: url, encoding: .utf8)).map(Self.body(text:))
        case "docx", "doc", "rtf", "rtfd", "odt":
            body = (try? NSAttributedString(url: url, options: [:], documentAttributes: nil)).map { text in
                var read = Self.lines(attributed: text, save: save)

                if url.pathExtension.lowercased() == "docx", save != nil, !read.contains(where: { $0.media != nil }) {
                    read = Self.placing(DocxMedia.pictures(of: url, save: save), into: read)
                }
                return Self.body(lines: read)
            }
        default:
            body = nil
        }
        guard let body, !body.blocks.isEmpty else { return nil }
        return body
    }

    public static func body(text: String) -> NoteBody {
        body(lines: text.components(separatedBy: .newlines).map {
            Line(runs: [NoteRun(text: $0)], gap: $0.trimmingCharacters(in: .whitespaces).isEmpty)
        })
    }

    public static func body(attributed text: NSAttributedString, save: SaveMedia? = nil) -> NoteBody {
        body(lines: lines(attributed: text, save: save))
    }

    static func lines(attributed text: NSAttributedString, save: SaveMedia? = nil) -> [Line] {
        let string = text.string as NSString
        var lines: [Line] = []
        string.enumerateSubstrings(in: NSRange(location: 0, length: string.length), options: [.byParagraphs, .substringNotRequired]) { _, range, _, _ in
            guard range.length > 0, !string.substring(with: range).trimmingCharacters(in: .whitespaces).isEmpty else {
                lines.append(Line(runs: [], gap: true))
                return
            }
            var runs: [NoteRun] = []
            var sizes: [Double: Int] = [:]
            var media: [Media] = []
            text.enumerateAttributes(in: range) { attributes, subrange, _ in
                if let attachment = attributes[.attachment] as? NSTextAttachment {
                    if let (data, name) = Self.file(of: attachment), let kept = Media.saving(data, fileName: name, with: save) {
                        media.append(kept)
                    }
                    return
                }
                var run = NoteRun(text: string.substring(with: subrange))
                if let font = attributes[.font] as? NSFont {
                    let traits = font.fontDescriptor.symbolicTraits
                    if traits.contains(.bold) { run.bold = true }
                    if traits.contains(.italic) { run.italic = true }
                    sizes[Double(font.pointSize), default: 0] += run.text.filter { !$0.isWhitespace }.count
                }
                if (attributes[.underlineStyle] as? Int ?? 0) != 0 { run.underline = true }
                if (attributes[.strikethroughStyle] as? Int ?? 0) != 0 { run.strike = true }

                if let link = attributes[.link] { run.href = (link as? URL)?.absoluteString ?? link as? String }
                runs.append(run)
            }
            var line = Line(runs: runs, size: sizes.max { $0.value < $1.value }?.key ?? 0)

            if let list = (text.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle)?.textLists.last {
                let marker = list.markerFormat.rawValue
                line.list = ["decimal", "alpha", "roman"].contains { marker.contains($0) }
                let head = NoteReading.text(of: line.runs)
                if let match = head.range(of: #"^\s*\S*\t"#, options: .regularExpression) {
                    line.runs = dropping(head.distance(from: head.startIndex, to: match.upperBound), from: line.runs)
                }
            } else {
                let head = NoteReading.text(of: line.runs)
                if let match = head.range(of: #"^\t(\d{1,3}[.)]?|[•◦▪▫‣⁃●○■□\x{F0B7}\x{F0A7}*-])\t"#, options: .regularExpression) {
                    line.list = head.dropFirst().first?.isNumber == true
                    line.runs = dropping(head.distance(from: head.startIndex, to: match.upperBound), from: line.runs)
                }
            }
            lines.append(line)
            lines += media.map { Line(runs: [], media: $0) }
        }
        return lines
    }

    static func file(of attachment: NSTextAttachment) -> (Data, String)? {
        let ext = attachment.fileType.flatMap { UTType($0)?.preferredFilenameExtension }
        if let wrapper = attachment.fileWrapper, wrapper.isRegularFile, let data = wrapper.regularFileContents {
            let name = wrapper.preferredFilename ?? wrapper.filename ?? "attachment.\(ext ?? "dat")"
            return (data, (name as NSString).pathExtension.isEmpty ? "\(name).\(ext ?? "dat")" : name)
        }
        if let data = attachment.contents { return (data, "attachment.\(ext ?? "dat")") }
        if let image = attachment.image, let tiff = image.tiffRepresentation,
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            return (png, "picture.png")
        }
        return nil
    }

    static func placing(_ media: [(afterWordLines: Int, media: Media)], into lines: [Line]) -> [Line] {
        guard !media.isEmpty else { return lines }
        var result: [Line] = []
        var words = 0
        var pending = media[...]
        func flush() {
            while let next = pending.first, next.afterWordLines <= words {
                result.append(Line(runs: [], media: next.media))
                pending = pending.dropFirst()
            }
        }
        flush()
        for line in lines {
            result.append(line)
            if !NoteReading.text(of: line.runs).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { words += 1 }
            flush()
        }
        return result + pending.map { Line(runs: [], media: $0.media) }
    }

    public static func body(pdf data: Data, save: SaveMedia? = nil) -> NoteBody {
        guard let provider = CGDataProvider(data: data as CFData), let document = CGPDFDocument(provider) else {
            return body(pdfPages: [])
        }
        let pages = PDFGlyphReader.pages(of: document)
        return body(pdfPages: pages, pictures: save == nil ? [] : pdfPictures(pages, in: document, save: save))
    }

    static func pdfPictures(_ pages: [PDFPageText], in document: CGPDFDocument, save: SaveMedia?) -> [PDFPicture] {
        pages.enumerated().flatMap { index, text -> [PDFPicture] in
            guard let page = document.page(at: index + 1) else { return [] }
            return text.images.filter { $0.width >= 72 && $0.height >= 72 }.enumerated().compactMap { number, rect in
                guard let png = render(page, rect), let media = Media.saving(png, fileName: "pdf-page\(index + 1)-\(number + 1).png", with: save)
                else { return nil }
                return PDFPicture(page: index, y: rect.maxY, media: media)
            }
        }
    }

    static func render(_ page: CGPDFPage, _ rect: CGRect) -> Data? {
        let scale = min(2, 2400 / max(rect.width, rect.height))
        let width = Int(rect.width * scale), height = Int(rect.height * scale)
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.setFillColor(.white)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -rect.minX, y: -rect.minY)
        context.drawPDFPage(page)
        guard let image = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    struct PDFPicture: Equatable {
        var page: Int
        var y: CGFloat
        var media: Media
    }

    struct PrintedLine {
        var runs: [NoteRun]
        var size: Double
        var page: Int
        var y: CGFloat
        var maxX: CGFloat

        var firstWord: CGFloat
    }

    static func body(pdfPages pages: [PDFPageText], pictures: [PDFPicture] = []) -> NoteBody {
        let printed = pages.enumerated().flatMap { printedLines(of: $1, page: $0) }
        let right = printed.map(\.maxX).max() ?? 0
        var lines: [Line] = []
        var previous: PrintedLine?
        var pending = pictures.sorted { ($0.page, -$0.y) < ($1.page, -$1.y) }[...]
        for line in printed {
            while let picture = pending.first, (picture.page, -picture.y) < (line.page, -line.y) {
                lines.append(Line(runs: [], media: picture.media))
                pending = pending.dropFirst()
                previous = nil
            }

            if let before = previous, var last = lines.last, abs(before.size - line.size) < 0.6,
               before.page != line.page || before.y - line.y <= line.size * 1.45,
               before.maxX + line.size * 0.6 + line.firstWord > right,
               marker(NoteReading.text(of: line.runs)) == nil {
                last.runs += [NoteRun(text: " ")] + line.runs
                lines[lines.count - 1] = last
            } else {
                lines.append(Line(runs: line.runs, size: line.size))
            }
            previous = line
        }
        lines += pending.map { Line(runs: [], media: $0.media) }
        return body(lines: lines)
    }

    static func printedLines(of page: PDFPageText, page index: Int) -> [PrintedLine] {
        let glyphs = page.glyphs.filter { !$0.text.isEmpty }.sorted { $0.y > $1.y }
        var rows: [[PDFGlyph]] = []
        for glyph in glyphs {
            if let anchor = rows.last?.max(by: { $0.size < $1.size }), anchor.y - glyph.y <= max(anchor.size, glyph.size) * 0.5 {
                rows[rows.count - 1].append(glyph)
            } else {
                rows.append([glyph])
            }
        }
        return rows.compactMap { row in
            let row = row.sorted { $0.x < $1.x }
            var sizes: [CGFloat: Int] = [:]
            for glyph in row where glyph.text != " " { sizes[(glyph.size * 2).rounded() / 2, default: 0] += 1 }
            let size = sizes.max { $0.value < $1.value }?.key ?? 0
            var runs: [NoteRun] = []
            var last: PDFGlyph?
            for glyph in row {
                if let last, glyph.x - last.maxX > size * 0.18, last.text != " ", glyph.text != " " {
                    var space = runs[runs.count - 1]
                    space.text = " "
                    runs.append(space)
                }
                var run = NoteRun(text: glyph.text)
                let font = glyph.font.lowercased()
                if glyph.bold { run.bold = true }
                if font.contains("italic") || font.contains("oblique") { run.italic = true }
                let middle = glyph.x + glyph.width / 2
                if page.rules.contains(where: { $0.minX <= middle && middle <= $0.maxX && $0.midY < glyph.y + size * 0.05 && $0.midY > glyph.y - size * 0.4 }) {
                    run.underline = true
                }
                runs.append(run)
                last = glyph
            }
            let text = NoteReading.text(of: runs).trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty, !text.allSatisfy(\.isNumber) else { return nil }
            let firstSpace = row.firstIndex { $0.text == " " } ?? row.endIndex
            let start = row.first?.x ?? 0
            let firstWord = row[..<firstSpace].last.map { $0.maxX - start } ?? 0
            return PrintedLine(runs: runs, size: Double(size), page: index, y: row.max { $0.size < $1.size }?.y ?? 0,
                               maxX: row.last?.maxX ?? 0, firstWord: firstWord)
        }
    }

    public static func body(lines: [Line]) -> NoteBody {
        let markers = lines.contains { NoteSlides.startsSlide(NoteBlock(type: .paragraph, runs: tidied($0.runs))) }
        var kept: [Line] = []
        for var line in lines {
            line.runs = tidied(line.runs)
            if line.gap || (line.runs.isEmpty && line.media == nil) {
                if line.gap, markers, let last = kept.last, !last.gap { kept.append(Line(runs: [], gap: true)) }
                continue
            }
            kept.append(line)
        }
        if kept.last?.gap == true { kept.removeLast() }
        let lines = kept
        var counts: [Double: Int] = [:]
        for line in lines where line.size > 0 { counts[line.size, default: 0] += NoteReading.text(of: line.runs).count }
        let bodySize = counts.max { $0.value < $1.value }?.key ?? 0
        let headingSizes = Set(lines.map(\.size).filter { bodySize > 0 && $0 >= bodySize * 1.2 }).sorted(by: >)

        var blocks: [NoteBlock] = []
        for line in lines {
            if line.gap {
                blocks.append(NoteBlock(type: .paragraph, runs: []))
                continue
            }
            if let media = line.media {
                blocks.append(media.block)
                continue
            }
            var runs = line.runs
            var ordered = line.list
            if ordered == nil, let found = marker(NoteReading.text(of: runs)) {
                ordered = found.ordered
                runs = dropping(found.length, from: runs)
            }
            if let ordered {
                let item = NoteListItem(runs: runs)
                if let last = blocks.last, last.type == .list, last.ordered == ordered {
                    blocks[blocks.count - 1].items?.append(item)
                } else {
                    blocks.append(NoteBlock(type: .list, ordered: ordered, items: [item]))
                }
            } else if let level = line.heading ?? headingSizes.firstIndex(of: line.size).map({ min($0 + 1, 3) }) {
                blocks.append(NoteBlock(type: .heading, level: level, runs: runs))
            } else {
                blocks.append(NoteBlock(type: .paragraph, runs: runs))
            }
        }
        return NoteBody(blocks: blocks, plainText: blocks.map(NoteReading.text(of:)).joined(separator: "\n"))
    }

    static func marker(_ text: String) -> (ordered: Bool, length: Int)? {
        if let match = text.range(of: #"^[•◦▪▫‣⁃●○■□\x{F0B7}\x{F0A7}*-]\s+"#, options: .regularExpression) {
            return (false, text.distance(from: text.startIndex, to: match.upperBound))
        }
        if let match = text.range(of: #"^\d{1,3}[.)]\s+"#, options: .regularExpression) {
            return (true, text.distance(from: text.startIndex, to: match.upperBound))
        }
        return nil
    }

    static func tidied(_ runs: [NoteRun]) -> [NoteRun] {
        var result: [NoteRun] = []
        var pendingSpace = false
        for run in runs {
            for character in run.text {
                if character.isWhitespace {
                    pendingSpace = !result.isEmpty
                    continue
                }
                if pendingSpace { result[result.count - 1].text += " " }
                pendingSpace = false
                var piece = run
                piece.text = String(character)
                if var last = result.last, sameMarks(last, piece) {
                    last.text += piece.text
                    result[result.count - 1] = last
                } else {
                    result.append(piece)
                }
            }
        }
        return result
    }

    private static func sameMarks(_ a: NoteRun, _ b: NoteRun) -> Bool {
        var x = a, y = b
        x.text = ""; y.text = ""
        return x == y
    }

    static func dropping(_ count: Int, from runs: [NoteRun]) -> [NoteRun] {
        var left = count
        return runs.compactMap { run in
            guard left > 0 else { return run }
            var run = run
            let cut = min(left, run.text.count)
            run.text = String(run.text.dropFirst(cut))
            left -= cut
            return run.text.isEmpty ? nil : run
        }
    }
}
