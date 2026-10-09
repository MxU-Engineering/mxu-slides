import Foundation

public enum ChordProExport {
    public static func text(for presentation: Presentation) -> String {
        var lines: [String] = ["{title: \(presentation.name)}"]
        if let author = presentation.ccli?.author, !author.isEmpty {
            lines.append("{artist: \(author)}")
        }
        if let key = presentation.musicKey, !key.isEmpty {
            lines.append("{key: \(key)}")
        }
        for copyright in (presentation.ccli?.copyright ?? "").components(separatedBy: "\n") where !copyright.isEmpty {
            lines.append("{copyright: \(copyright)}")
        }
        if let number = presentation.ccli?.songNumber {
            lines.append("{ccli: \(number)}")
        }

        for block in blocks(of: presentation) {
            lines.append("")
            let environment = block.name.flatMap(environment(for:))
            if let name = block.name, let environment {
                lines.append("{start_of_\(environment): \(name)}")
            } else if let name = block.name {
                lines.append("{comment: \(name)}")
            }
            lines.append(block.stanzas.joined(separator: "\n\n"))
            if let environment {
                lines.append("{end_of_\(environment)}")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    public enum FileFormat: String, CaseIterable, Sendable {
        case plainText = "txt"
        case chordPro = "cho"

        public var label: String {
            switch self {
            case .plainText: "Plain Text (.txt)"
            case .chordPro: "ChordPro (.cho)"
            }
        }
    }

    public static func fileName(for presentation: Presentation, format: FileFormat = .plainText) -> String {
        let name = presentation.name
            .components(separatedBy: CharacterSet(charactersIn: "/:\\"))
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespaces)
        return (name.isEmpty ? "Song" : name) + "." + format.rawValue
    }

    struct Block: Equatable {
        var name: String?

        var stanzas: [String]
    }

    static func blocks(of presentation: Presentation, sungOrder: Bool = true) -> [Block] {
        let sections = presentation.sections ?? []
        let arrangement = sungOrder
            ? presentation.arrangements?.first { $0.id == presentation.defaultArrangementId }
            : nil
        let order = arrangement?.sectionIds ?? sections.map(\.id)
        let names = Dictionary(sections.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        let known = Set(sections.map(\.id))
        let unsectioned = presentation.slides.filter { $0.sectionId.map { !known.contains($0) } ?? true }

        let sectioned: [Block] = order.compactMap { sectionID in
            names[sectionID].map { name in
                Block(name: name, stanzas: presentation.slides.filter { $0.sectionId == sectionID }.compactMap(stanza))
            }
        }
        let loose = unsectioned.isEmpty ? [] : [Block(name: nil, stanzas: unsectioned.compactMap(stanza))]
        return (loose + sectioned).filter { !$0.stanzas.isEmpty }
    }

    static func stanza(_ slide: Slide) -> String? {
        let object = slide.objects.first { $0.objectKind == .text && !$0.text.isEmpty }
            ?? slide.objects.first { $0.objectKind == .text }
        return object.flatMap { object in
            let text = ChordMath.bracketed(object.text, chords: object.chords ?? [])
            return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
        }
    }

    private static func environment(for name: String) -> String? {
        let word = name.lowercased().split(separator: " ").first.map(String.init) ?? ""
        if ["verse", "chorus", "bridge"].contains(word) {
            return word
        } else if Reflow.labelName(of: name) == nil {
            return "part"
        } else {
            return nil
        }
    }

    public static func reflowSeed(for presentation: Presentation) -> String {
        let fromSlides = blocks(of: presentation, sungOrder: false).map { block in
            ([block.name].compactMap(\.self) + [block.stanzas.joined(separator: "\n\n")]).joined(separator: "\n")
        }.joined(separator: "\n\n")
        if let source = presentation.reflowSource, !source.isEmpty,
           lyricLines(ofSource: source) == lyricLines(of: fromSlides) {
            return source
        } else {
            return fromSlides
        }
    }

    private static func lyricLines(ofSource text: String) -> [String] {
        Reflow.parse(text, linesPerSlide: 1).sections
            .flatMap { [$0.name] + $0.slides }
            .map(canonical)
    }

    private static func lyricLines(of text: String) -> [String] {
        lyricLines(ofSource: text)
    }

    private static func canonical(_ line: String) -> String {
        let extracted = ChordMath.extract(line)
        return ChordMath.bracketed(extracted.text, chords: extracted.chords)
    }
}
