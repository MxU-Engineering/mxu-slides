import Foundation

extension NoteSlideMarks {
    public enum SuggestMode: String, Sendable, CaseIterable {
        case pickForMe, boldLines, structure
    }

    public enum AutoMark: String, Sendable, CaseIterable {
        case pickForMe, boldLines, structure, nothing

        public var title: String {
            switch self {
            case .pickForMe: "Pick for me"
            case .boldLines: "Bold lines only"
            case .structure: "By structure"
            case .nothing: "Nothing"
            }
        }

        public func marking(_ body: NoteBody, ownTypes: [String] = []) -> NoteBody {
            SuggestMode(rawValue: rawValue).map { NoteSlideMarks.suggesting(body, mode: $0, ownTypes: ownTypes) } ?? body
        }
    }

    public static func suggesting(_ body: NoteBody, mode: SuggestMode = .pickForMe, ownTypes: [String] = []) -> NoteBody {
        var body = body
        for passage in suggestions(in: body, mode: mode, ownTypes: ownTypes) {
            let group = mintGroupID()
            for index in passage.blocks {
                body.blocks[index] = marking(body.blocks[index], group: group, type: passage.type, state: suggested)
            }
        }
        return body
    }

    struct Suggestion: Equatable {
        var blocks: [Int]
        var type: String?
    }

    static func suggestions(in body: NoteBody, mode: SuggestMode, ownTypes: [String] = []) -> [Suggestion] {
        if body.blocks.contains(where: NoteSlides.startsSlide) {
            let before = Set(groups(in: body).map(\.id))
            return groups(in: markingByMarkers(body)).filter { !before.contains($0.id) }.compactMap { group in
                let first = body.blocks[group.blockIndexes[0]]
                if !group.media.isEmpty {
                    return Suggestion(blocks: group.blockIndexes, type: (NoteMedia.isVideo(first) ? SlideType.video : SlideType.picture).rawValue)
                }
                if isVideoFileLink(first) { return Suggestion(blocks: group.blockIndexes, type: SlideType.video.rawValue) }
                if readsAsListUnderHeading(group.blockIndexes, in: body), ownType(of: group.text, in: ownTypes) == nil {
                    return Suggestion(blocks: group.blockIndexes, type: SlideType.points.rawValue)
                }
                return suggestion(blocks: group.blockIndexes, text: group.text, shape: group.shape, ownTypes: ownTypes)
            }
        }
        let texts = body.blocks.map(lineText)

        func isOwn(_ text: String) -> Bool { ownType(of: text, in: ownTypes) != nil }
        func isSubtitle(_ text: String) -> Bool { Self.isSubtitle(text) && !isOwn(text) }

        let mediaType: [Int: String] = Dictionary(uniqueKeysWithValues: body.blocks.indices.compactMap { index in
            let block = body.blocks[index]
            guard block.slideGroup == nil, !NoteMedia.blocks(in: NoteBody(blocks: [block], plainText: "")).isEmpty else { return nil }
            return (index, (NoteMedia.isVideo(block) ? SlideType.video : SlideType.picture).rawValue)
        })
        let candidates = body.blocks.indices.filter { index in
            if mediaType[index] != nil { return true }
            let block = body.blocks[index]
            let text = texts[index]
            return [.heading, .paragraph, .list, .taskList, .quote].contains(block.type)
                && !text.isEmpty && !NoteSlides.isMarker(block, marker: NoteSlides.defaultMarker)
                && lines(of: block).joined().allSatisfy { $0.slideGroup == nil }
                && (!isRunSheet(text) || isOwn(text) || isVideoLink(block)) && !isAside(text)
        }
        let open = Set(candidates)
        func isParagraph(_ index: Int) -> Bool { open.contains(index) && body.blocks[index].type == .paragraph }
        func isReference(_ index: Int) -> Bool { ScriptureReference.isReferenceLine(texts[index]) }

        let firstContent = body.blocks.indices.first { !texts[$0].isEmpty }
        func isTitle(_ index: Int) -> Bool {
            body.blocks[index].type == .heading
                || (index == firstContent && body.blocks[index].type == .paragraph && isSubtitle(texts[index]) && !isReference(index)
                    && !DeterministicSlidePlanner.readsAsQuote(texts[index]))
        }
        var passages: [[Int]] = []
        var titles = Set<Int>()
        var used = Set<Int>()
        for index in candidates where !used.contains(index) {
            var passage = [index]
            let next = index + 1
            if isTitle(index) { titles.insert(index) }
            if mediaType[index] == SlideType.picture.rawValue {
                var after = next
                while after < body.blocks.count {
                    if mediaType[after] == SlideType.picture.rawValue {
                        passage.append(after)
                    } else if !(body.blocks[after].type == .paragraph && texts[after].isEmpty) {
                        break
                    }
                    after += 1
                }
            } else if isOwn(texts[index]) || mediaType[index] != nil || isVideoLink(body.blocks[index]) {
            } else if DeterministicSlidePlanner.isPointLine(texts[index]), isParagraph(index) {
                var after = next
                while isParagraph(after), DeterministicSlidePlanner.isPointLine(texts[after]) {
                    passage.append(after)
                    after += 1
                }
            } else if isParagraph(index), Self.isListHeading(texts[index]), !isOwn(texts[index]),
                      open.contains(next), [.list, .taskList].contains(body.blocks[next].type) {
                var after = next
                while open.contains(after), [.list, .taskList].contains(body.blocks[after].type) {
                    passage.append(after)
                    after += 1
                }
            } else if isTitle(index), isParagraph(next), isSubtitle(texts[next]) {
                passage.append(next)
            } else if isReference(index) {
                let first = ScriptureReference.verses(of: texts[index]).map { "\($0.verses.lowerBound) " }
                let previous = index - 1
                let forward = isParagraph(next) && !isReference(next) && !isOwn(texts[next])
                if forward, let first, texts[next].hasPrefix(first) {
                    passage.append(next)
                } else if passages.last == [previous], isParagraph(previous), readsAsVerse(texts[previous]), !isOwn(texts[previous]) {
                    passages[passages.count - 1].append(index)
                    used.insert(index)
                    continue
                } else if forward {
                    passage.append(next)
                }
            }
            used.formUnion(passage)
            passages.append(passage)
        }

        var found = passages.compactMap { blocks in
            if let type = mediaType[blocks[0]] { return Suggestion(blocks: blocks, type: type) }
            if isVideoFileLink(body.blocks[blocks[0]]) { return Suggestion(blocks: blocks, type: SlideType.video.rawValue) }
            if readsAsListUnderHeading(blocks, in: body), !isOwn(texts[blocks[0]]) { return Suggestion(blocks: blocks, type: SlideType.points.rawValue) }
            return suggestion(blocks: blocks, text: blocks.map { texts[$0] }.joined(separator: "\n"),
                       shape: titles.contains(blocks[0]) ? .heading : shape(of: body.blocks[blocks[0]]), ownTypes: ownTypes)
        }
        if mode == .boldLines || (mode == .pickForMe && mixesBold(body, candidates: candidates, texts: texts)) {
            found = found.filter { passage in
                passage.type == SlideType.scripture.rawValue || passage.type == SlideType.quote.rawValue
                    || passage.type == SlideType.title.rawValue || passage.type == SlideType.picture.rawValue
                    || passage.type == SlideType.video.rawValue
                    || passage.blocks.allSatisfy { isBold(body.blocks[$0]) }
            }
        }
        return found
    }

    static func strongSuggestionsOutsideMarkers(in body: NoteBody, ownTypes: [String] = []) -> [Suggestion] {
        guard body.blocks.contains(where: NoteSlides.startsSlide) else { return [] }
        let held = Set(markerPassages(in: body).joined())
        var rest = body
        for index in rest.blocks.indices where held.contains(index) || NoteSlides.startsSlide(rest.blocks[index]) {
            rest.blocks[index] = NoteBlock(type: .paragraph, runs: [])
        }
        let texts = body.blocks.map(lineText)
        let lines = body.blocks.indices.filter { !texts[$0].isEmpty && !NoteSlides.startsSlide(body.blocks[$0]) }
        let usesBold = mixesBold(body, candidates: lines, texts: texts)
        let strong = Set([SlideType.scripture, .quote, .picture, .video].map(\.rawValue) + ownTypes)
        return suggestions(in: rest, mode: .structure, ownTypes: ownTypes).filter { passage in
            if let type = passage.type, strong.contains(type) { return true }
            if DeterministicSlidePlanner.leadingLabel(of: texts[passage.blocks[0]]) != nil { return true }
            return usesBold && passage.blocks.allSatisfy { isBold(body.blocks[$0]) }
        }
    }

    private static func suggestion(blocks: [Int], text: String, shape: Shape, ownTypes: [String]) -> Suggestion? {
        if let own = ownType(of: text, in: ownTypes) { return Suggestion(blocks: blocks, type: own) }

        guard let kind = kind(of: text, shape: shape), kind != .media, kind != .picture else { return nil }

        return Suggestion(blocks: blocks, type: kind == .body ? nil : SlideType(rawValue: kind.rawValue)?.rawValue)
    }

    static func ownType(of text: String, in ownTypes: [String]) -> String? {
        guard !ownTypes.isEmpty, let label = DeterministicSlidePlanner.leadingLabel(of: text) else { return nil }
        return ownTypes.first { $0.caseInsensitiveCompare(label.name) == .orderedSame }
    }

    private static func kind(of text: String, shape: Shape) -> SlideKind? {
        if shape == .heading { return .title }
        if DeterministicSlidePlanner.readsAsQuote(text) { return .quote }
        let group = MarkedGroup(id: "", shape: shape, text: text)
        return DeterministicSlidePlanner().plan([group], theme: nil, overrides: [:]).rows.first?.kind
    }

    public static func guessedType(of text: String, shape: Shape, ownTypes: [String] = []) -> String? {
        if let own = ownType(of: text, in: ownTypes) { return own }
        let kind = kind(of: text, shape: shape)
        return kind == nil || kind == .body ? nil : kind?.rawValue
    }

    public static func selectionBarKinds(guess: String?, ownTypes: [String] = []) -> (shown: [String?], more: [String]) {
        let shown = ["points", "scripture", "quote", "title"]
        let more = ["lyrics", "body", "media"] + ownTypes
        return ([guess] + shown.filter { $0 != guess }, more.filter { $0 != guess })
    }

    public static func selectionBarLabel(_ type: String?) -> String {
        guard let type else { return "Slide" }
        if type == SlideType.points.rawValue { return "Point" }
        if let known = SlideType(rawValue: type) { return known.label }
        return SlideKind(rawValue: type) == nil ? type : type.capitalized
    }

    private static func lineText(_ block: NoteBlock) -> String {
        lines(of: block).map { NoteReading.text(of: $0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }.joined(separator: "\n")
    }

    static func isRunSheet(_ text: String) -> Bool {
        var lower = text.lowercased()
        for lead in ["closing ", "opening "] where lower.hasPrefix(lead) { lower.removeFirst(lead.count) }
        if ["pictures of", "photos of"].contains(where: { lower.hasPrefix($0) }) { return true }
        return ["intro", "introduction", "illustration", "offering", "prayer", "video", "announcements"].contains { lead in
            guard lower.hasPrefix(lead) else { return false }
            let after = lower.dropFirst(lead.count).first { !$0.isWhitespace }
            return after == nil || after.map { ":,–—-(.".contains($0) } == true
        }
    }

    static func isVideoLink(_ block: NoteBlock) -> Bool {
        if isVideoFileLink(block) { return true }
        guard block.type == .paragraph else { return false }
        let text = lineText(block)
        guard text.lowercased().hasPrefix("video"), isRunSheet(text) else { return false }
        return DeterministicSlidePlanner.firstLink(in: text) != nil
            || lines(of: block).joined().contains { $0.href?.isEmpty == false }
    }

    static func isVideoFileLink(_ block: NoteBlock) -> Bool {
        guard block.type == .paragraph, lines(of: block).joined().contains(where: { $0.href?.isEmpty == false }) else { return false }
        let text = lineText(block)
        return !text.contains("\n") && text.range(of: videoFilePattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    static let videoFilePattern = #"\.(mp4|mov|m4v|avi|wmv|webm|mkv|mpe?g)$"#

    static func readsAsListUnderHeading(_ blocks: [Int], in body: NoteBody) -> Bool {
        guard blocks.count >= 2, body.blocks[blocks[0]].type == .paragraph, isListHeading(lineText(body.blocks[blocks[0]])) else { return false }
        return blocks.dropFirst().allSatisfy { [.list, .taskList].contains(body.blocks[$0].type) }
    }

    static func isListHeading(_ text: String) -> Bool {
        !text.contains("\n") && text.count <= 80 && text.hasSuffix(":") && !DeterministicSlidePlanner.isPointLine(text)
    }

    static func isAside(_ text: String) -> Bool {
        text.hasPrefix("(") && text.hasSuffix(")")
    }

    private static func isSubtitle(_ text: String) -> Bool {
        !text.contains("\n") && text.count <= 60 && !text.hasSuffix(".") && !text.hasSuffix("?") && !text.hasSuffix("!")
            && !DeterministicSlidePlanner.isPointLine(text) && DeterministicSlidePlanner.labelledPoint(text) == nil
    }

    private static func readsAsVerse(_ text: String) -> Bool {
        ScriptureReference.split(text) == nil && !DeterministicSlidePlanner.isPointLine(text)
            && DeterministicSlidePlanner.labelledPoint(text) == nil
    }

    private static func isBold(_ block: NoteBlock) -> Bool {
        if block.type == .heading { return true }
        let runs = lines(of: block).joined().filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return !runs.isEmpty && runs.allSatisfy { $0.bold == true }
    }

    private static func mixesBold(_ body: NoteBody, candidates: [Int], texts: [String]) -> Bool {
        let lines = candidates.filter { body.blocks[$0].type != .heading && !ScriptureReference.isReferenceLine(texts[$0]) }
        let bold = lines.filter { isBold(body.blocks[$0]) }.count
        return bold >= 2 && bold < lines.count
    }
}
