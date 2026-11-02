import AppKit
import PresenterCore

final class NoteBlockMarker: NSObject {
    static let key = NSAttributedString.Key("mxu.noteBlock")

    static let prefixKey = NSAttributedString.Key("mxu.noteMarkerPrefix")

    static let findKey = NSAttributedString.Key("mxu.noteFindHit")

    static let slideKey = NSAttributedString.Key("mxu.noteSlideMark")

    static let greyKey = NSAttributedString.Key("mxu.noteOffScreenColor")

    enum Kind: Equatable {
        case heading(level: Int)
        case paragraph
        case listItem(ordered: Bool, depth: Int)
        case taskItem(checked: Bool, depth: Int)
        case quote(depth: Int)
        case code(language: String?)
        case rule
        case image(url: String, width: Int?, alt: String?)

        case attachment(kind: String, hexId: String, filename: String, url: String?)
        case slide
        case unknown
    }

    let kind: Kind
    init(_ kind: Kind) { self.kind = kind }

    static func prefixLength(of paragraph: String) -> Int {
        let scalars = paragraph.unicodeScalars
        guard let tab = paragraph.firstIndex(of: "\t") else { return 0 }
        let head = String(paragraph[..<tab])
        let isMarker = ["•", "☐", "☑"].contains(head) || (head.hasSuffix(".") && head.dropLast().allSatisfy(\.isNumber) && head.count > 1)
        guard isMarker else { return 0 }
        _ = scalars
        return (head as NSString).length + 1
    }

    var depth: Int {
        switch kind {
        case .listItem(_, let depth), .taskItem(_, let depth), .quote(let depth): depth
        default: 0
        }
    }
}

final class NoteSlideMark: NSObject {
    let group: String
    let type: String?
    let slideId: String?
    let state: String?

    init(group: String, type: String? = nil, slideId: String? = nil, state: String? = nil) {
        self.group = group
        self.type = type
        self.slideId = slideId
        self.state = state
    }

    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? NoteSlideMark else { return false }
        return group == other.group && type == other.type && slideId == other.slideId && state == other.state
    }

    override var hash: Int { group.hashValue }
}

enum NoteDocumentParser {
    static func body(from text: NSAttributedString) -> NoteBody {
        let blocks = blocks(from: paragraphs(of: text))
        return NoteBody(blocks: blocks, plainText: plainText(blocks))
    }

    struct Paragraph {
        var marker: NoteBlockMarker.Kind
        var runs: [NoteRun]
        var slide: NoteSlideRef?
        var attachmentText: String

        var mediaMark: NoteSlideMark?

        var range = NSRange(location: 0, length: 0)
    }

    private static func paragraphs(of text: NSAttributedString) -> [Paragraph] {
        let string = text.string as NSString
        var result: [Paragraph] = []
        var location = 0
        while location <= string.length {
            let lineRange = location < string.length
                ? string.lineRange(for: NSRange(location: location, length: 0))
                : NSRange(location: location, length: 0)
            var content = lineRange
            if content.length > 0, string.character(at: content.location + content.length - 1) == 0x0A {
                content.length -= 1
            }
            var paragraph = paragraph(text, range: content)
            paragraph.range = content
            result.append(paragraph)
            location = lineRange.location + max(lineRange.length, 1)
            if lineRange.length == 0 { break }
        }

        if result.count > 1, let last = result.last, last.runs.isEmpty, last.slide == nil, last.marker == .paragraph {
            result.removeLast()
        }
        return result
    }

    static func runs(in text: NSAttributedString, range: NSRange) -> [NoteRun] {
        paragraph(text, range: range).runs
    }

    private static func paragraph(_ text: NSAttributedString, range: NSRange) -> Paragraph {
        var marker: NoteBlockMarker.Kind = .paragraph
        var runs: [NoteRun] = []
        var slide: NoteSlideRef?
        var attachmentText = ""
        var mediaMark: NoteSlideMark?
        if range.length == 0 {
            let probe = range.location < text.length ? range.location : max(0, text.length - 1)
            if text.length > 0, let found = text.attribute(NoteBlockMarker.key, at: probe, effectiveRange: nil) as? NoteBlockMarker {
                marker = found.kind
            }

            switch marker {
            case .image, .attachment, .slide: marker = .paragraph
            default: break
            }
            return Paragraph(marker: marker, runs: [], slide: nil, attachmentText: "")
        }
        if let found = text.attribute(NoteBlockMarker.key, at: range.location, effectiveRange: nil) as? NoteBlockMarker {
            marker = found.kind
        }

        let prefix = NoteBlockMarker.prefixLength(of: (text.string as NSString).substring(with: range))
        let content = NSRange(location: range.location + prefix, length: range.length - prefix)
        guard content.length > 0 else {
            return Paragraph(marker: marker, runs: [], slide: nil, attachmentText: "")
        }
        text.enumerateAttributes(in: content) { attributes, subrange, _ in
            if mediaMark == nil { mediaMark = attributes[NoteBlockMarker.slideKey] as? NoteSlideMark }
            if let attachment = attributes[.attachment] as? NoteSlideAttachment {
                slide = attachment.slide
                marker = .slide
                return
            }
            if let image = attributes[.attachment] as? NoteImageAttachment {
                marker = .image(url: image.url, width: image.width, alt: image.alt)
                return
            }
            if attributes[.attachment] != nil { return }
            let piece = (text.string as NSString).substring(with: subrange)
            attachmentText += piece
            runs.append(run(piece, attributes: attributes))
        }
        return Paragraph(marker: marker, runs: coalesce(runs), slide: slide, attachmentText: attachmentText, mediaMark: mediaMark)
    }

    private static func run(_ text: String, attributes: [NSAttributedString.Key: Any]) -> NoteRun {
        var run = NoteRun(text: text)
        if let font = attributes[.font] as? NSFont {
            let traits = font.fontDescriptor.symbolicTraits

            if NSFontManager.shared.weight(of: font) >= 9 { run.bold = true }
            if traits.contains(.italic) { run.italic = true }
            if traits.contains(.monoSpace) || font.isFixedPitch { run.code = true }
        }
        if (attributes[.underlineStyle] as? Int ?? 0) != 0 { run.underline = true }
        if (attributes[.strikethroughStyle] as? Int ?? 0) != 0 { run.strike = true }
        if attributes[NoteBlockMarker.findKey] == nil, let background = attributes[.backgroundColor] as? NSColor {
            run.highlight = NoteRunText.hex(of: background) ?? ""
        }
        let shown = attributes[NoteBlockMarker.greyKey] ?? attributes[.foregroundColor]
        if let color = shown as? NSColor, !NoteRunText.isLabelColor(color) {
            run.color = NoteRunText.hex(of: color)
        }
        if let link = attributes[.link] {
            run.href = (link as? URL)?.absoluteString ?? link as? String
        }
        if let mark = attributes[NoteBlockMarker.slideKey] as? NoteSlideMark {
            run.slideGroup = mark.group
            run.slideType = mark.type
            run.slideId = mark.slideId
            run.slideState = mark.state
        }
        return run
    }

    private static func coalesce(_ runs: [NoteRun]) -> [NoteRun] {
        runs.reduce(into: []) { result, run in
            if var last = result.last, sameMarks(last, run) {
                last.text += run.text
                result[result.count - 1] = last
            } else {
                result.append(run)
            }
        }
    }

    private static func sameMarks(_ a: NoteRun, _ b: NoteRun) -> Bool {
        var x = a, y = b
        x.text = ""; y.text = ""
        return x == y
    }

    private static func blocks(from paragraphs: [Paragraph]) -> [NoteBlock] {
        parsed(paragraphs).map(\.block)
    }

    private static func parsed(_ paragraphs: [Paragraph]) -> [(block: NoteBlock, count: Int)] {
        var result: [(block: NoteBlock, count: Int)] = []
        var index = 0
        while index < paragraphs.count {
            let paragraph = paragraphs[index]
            let start = index
            func append(_ block: NoteBlock) { result.append((block, index - start)) }
            switch paragraph.marker {
            case .heading(let level):
                index += 1
                append(NoteBlock(type: .heading, level: level, runs: paragraph.runs))
            case .paragraph, .unknown:
                index += 1
                append(NoteBlock(type: .paragraph, runs: paragraph.runs))
            case .listItem(let ordered, let depth):
                let (block, consumed) = list(paragraphs, from: index, ordered: ordered, task: false, depth: depth)
                index += consumed
                append(block)
            case .taskItem(_, let depth):
                let (block, consumed) = list(paragraphs, from: index, ordered: false, task: true, depth: depth)
                index += consumed
                append(block)
            case .quote(let depth):
                var inner: [Paragraph] = []
                while index < paragraphs.count, case .quote(let d) = paragraphs[index].marker, d == depth {
                    var lifted = paragraphs[index]
                    lifted.marker = .paragraph
                    inner.append(lifted)
                    index += 1
                }
                append(NoteBlock(type: .quote, blocks: blocks(from: inner)))
            case .code(let language):
                index += 1
                append(NoteBlock(type: .code, language: language, text: paragraph.runs.map(\.text).joined()))
            case .rule:
                index += 1
                append(NoteBlock(type: .rule))
            case .image(let url, let width, let alt):
                let block = NoteBlock(type: .image, url: url, width: width, alt: alt)
                index += 1
                append(marked(block, paragraph.mediaMark))
            case .attachment(let kind, let hexId, let filename, let url):
                let block = NoteBlock(type: .attachment, url: url, attachmentKind: kind, hexId: hexId.isEmpty ? nil : hexId, filename: filename)
                index += 1
                append(marked(block, paragraph.mediaMark))
            case .slide:
                index += 1
                append(NoteBlock(type: .slideRef, slide: paragraph.slide))
            }
        }
        return result
    }

    private static func marked(_ block: NoteBlock, _ mark: NoteSlideMark?) -> NoteBlock {
        var block = block
        block.slideGroup = mark?.group
        block.slideType = mark?.type
        block.slideId = mark?.slideId
        block.slideState = mark?.state
        return block
    }

    private static func list(_ paragraphs: [Paragraph], from start: Int, ordered: Bool, task: Bool, depth: Int) -> (NoteBlock, Int) {
        var items: [NoteListItem] = []
        var index = start
        while index < paragraphs.count {
            let paragraph = paragraphs[index]
            var checked: Bool?
            switch paragraph.marker {
            case .listItem(let o, let d) where !task && o == ordered && d == depth: break
            case .taskItem(let c, let d) where task && d == depth: checked = c
            default:
                if paragraph.marker.depthValue > depth, !items.isEmpty {
                    let nested = blocks(from: [paragraph])
                    items[items.count - 1].blocks = (items[items.count - 1].blocks ?? []) + nested
                    index += 1
                    continue
                }
                return (finish(items, ordered: ordered, task: task), index - start)
            }
            items.append(NoteListItem(runs: paragraph.runs, checked: task ? (checked ?? false) : nil))
            index += 1
        }
        return (finish(items, ordered: ordered, task: task), index - start)
    }

    private static func finish(_ items: [NoteListItem], ordered: Bool, task: Bool) -> NoteBlock {
        task ? NoteBlock(type: .taskList, items: items) : NoteBlock(type: .list, ordered: ordered, items: items)
    }

    private static func plainText(_ blocks: [NoteBlock]) -> String {
        blocks.map(NoteReading.text(of:)).filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

private extension NoteBlockMarker.Kind {
    var depthValue: Int {
        switch self {
        case .listItem(_, let depth), .taskItem(_, let depth), .quote(let depth): depth
        default: 0
        }
    }
}

extension NoteRunText {
    static func hex(of color: NSColor) -> String? {
        guard let rgb = color.usingColorSpace(.sRGB) else { return nil }
        let r = Int((rgb.redComponent * 255).rounded()), g = Int((rgb.greenComponent * 255).rounded()), b = Int((rgb.blueComponent * 255).rounded())
        return String(format: "#%02x%02x%02x", r, g, b)
    }

    static func isLabelColor(_ color: NSColor) -> Bool {
        [NSColor.labelColor, .secondaryLabelColor, .tertiaryLabelColor, .linkColor, .textColor].contains { candidate in
            candidate == color || candidate.usingColorSpace(.sRGB) == color.usingColorSpace(.sRGB)
        }
    }
}

@MainActor
enum NoteMediaFiles {
    static var save: NoteFileReader.SaveMedia?

    static func data(from url: URL) async throws -> Data {
        if url.isFileURL { return try await Task.detached(priority: .userInitiated) { try Data(contentsOf: url) }.value }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard (200..<300).contains((response as? HTTPURLResponse)?.statusCode ?? 200) else { throw URLError(.badServerResponse) }
        return data
    }
}
