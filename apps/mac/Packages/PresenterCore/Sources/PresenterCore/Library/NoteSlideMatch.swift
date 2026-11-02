import Foundation

public enum NoteSlideMatch {
    public static let similarityThreshold = 0.6

    public struct Match: Equatable, Sendable {
        public enum Rung: Equatable, Sendable {
            case mark, text, scripture, title, similar
        }
        public var groupId: String
        public var rung: Rung
    }

    public struct Result: Equatable, Sendable {
        public var body: NoteBody
        public var matches: [Match]

        public var orphans: [NoteMadePassage]
    }

    public static func match(fresh: NoteBody, memory: [NoteMadePassage]) -> Result {
        var result = Result(body: fresh, matches: [], orphans: [])
        guard !memory.isEmpty else { return result }
        let marked = NoteSlideMarks.groups(in: fresh)
        var unmatched = memory

        for group in marked {
            if let index = unmatched.firstIndex(where: { $0.groupId == group.id }) {
                unmatched.remove(at: index)
                result.matches.append(Match(groupId: group.id, rung: .mark))
            }
        }
        let markedIds = Set(marked.map(\.id))
        let candidates = NoteSlideMarks.groups(in: NoteSlideMarks.markingByStructure(fresh))
            .filter { !markedIds.contains($0.id) }
        var lastMemoryIndex = -1
        for candidate in candidates {
            guard !unmatched.isEmpty else { break }
            var best: (index: Int, rung: Match.Rung, rank: Int, distance: Int)?
            for (index, passage) in unmatched.enumerated() {
                guard let rung = rung(candidate, passage) else { continue }
                let rank = rank(of: rung)
                let distance = abs(index - (lastMemoryIndex + 1))
                if best == nil || rank < best!.rank || (rank == best!.rank && distance < best!.distance) {
                    best = (index, rung, rank, distance)
                }
            }
            guard let best else { continue }
            let passage = unmatched.remove(at: best.index)
            lastMemoryIndex = best.index
            result.body = NoteSlideMarks.marking(
                blockIndexes: candidate.blockIndexes, group: passage.groupId,
                slideId: passage.slides.first?.slideId, in: result.body)
            result.matches.append(Match(groupId: passage.groupId, rung: best.rung))
        }
        result.orphans = unmatched
        return result
    }

    private static func rank(of rung: Match.Rung) -> Int {
        switch rung {
        case .mark: 0
        case .text: 1
        case .scripture: 2
        case .title: 3
        case .similar: 4
        }
    }

    static func rung(_ candidate: NoteSlideMarks.Group, _ passage: NoteMadePassage) -> Match.Rung? {
        let a = normalized(candidate.text), b = normalized(passage.text)
        guard !a.isEmpty, !b.isEmpty else { return nil }
        if a == b { return .text }
        let refsA = references(in: candidate.text), refsB = references(in: passage.text)
        if !refsA.isEmpty, refsA == refsB { return .scripture }
        if candidate.shape == .heading || candidate.shape == .list,
           let titleA = firstLine(candidate.text), let titleB = firstLine(passage.text), titleA == titleB {
            return .title
        }
        if similarity(a, b) >= similarityThreshold { return .similar }
        return nil
    }

    static func normalized(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).map { line -> String in
            var line = line.lowercased()
            line = line.replacingOccurrences(of: "^\\s*(\\d+[.)]|[-*\u{2022}])\\s+", with: "", options: .regularExpression)
            line = String(line.map { $0.isLetter || $0.isNumber || $0.isWhitespace ? $0 : " " })
            line = line.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            return line.trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    static func references(in text: String) -> Set<String> {
        Set(text.split(whereSeparator: \.isNewline).flatMap { line in
            ScriptureReference.matches(in: String(line)).map { normalized($0.text) }
        })
    }

    static func firstLine(_ text: String) -> String? {
        normalized(text).split(separator: "\n").first.map(String.init)
    }

    static func similarity(_ a: String, _ b: String) -> Double {
        func words(_ s: String) -> Set<String> {
            Set(s.split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count >= 2 })
        }
        let x = words(a), y = words(b)
        let union = x.union(y).count
        guard union > 0 else { return 0 }
        return Double(x.intersection(y).count) / Double(union)
    }

    public static func memory(of body: NoteBody, deck: Presentation, kinds: [String: SlideKind] = [:]) -> [NoteMadePassage] {
        NoteSlideMarks.groups(in: body).compactMap { group in
            guard group.slideId != nil else { return nil }
            var slides = NoteSlideUpdate.cards(after: group, in: body)
                .compactMap { card in deck.slides.first { $0.id == card.slideId } }
            if slides.isEmpty, let own = deck.slides.first(where: { $0.id == group.slideId }) { slides = [own] }
            guard let first = slides.first else { return nil }
            return NoteMadePassage(
                groupId: group.id, text: group.text, kind: kinds[group.id]?.rawValue,
                themeSlideName: first.themeSlideName, themeId: first.themeId,
                slides: slides.map { NoteMadeSlide(slideId: $0.id, boxes: boxes(of: $0)) })
        }
    }

    public static func boxes(of slide: Slide) -> [NoteMadeBox] {
        slide.objects.filter { $0.objectKind == .text }.map { NoteMadeBox(name: $0.name, text: $0.text) }
    }

    public static func isUntouched(_ slide: Slide, memory: NoteMadeSlide, passage: NoteMadePassage) -> Bool {
        guard boxes(of: slide) == memory.boxes,
              slide.themeSlideName == passage.themeSlideName, slide.themeId == passage.themeId
        else { return false }
        var bare = Slide(id: slide.id, name: slide.name, objects: slide.objects.map {
            SlideObject(id: $0.id, objectKind: .text, name: $0.name, text: $0.text)
        })
        bare.themeSlideName = slide.themeSlideName
        bare.themeId = slide.themeId
        var stripped = slide
        stripped.actions = nil
        stripped.notes = nil
        stripped.history = nil
        stripped.keepWords = nil
        return stripped == bare
    }
}
