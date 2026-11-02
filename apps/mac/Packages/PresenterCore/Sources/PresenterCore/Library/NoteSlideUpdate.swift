import Foundation

public enum NoteSlideUpdate {
    public static func cards(afterGroup id: String, in body: NoteBody) -> [NoteSlideRef] {
        NoteSlideMarks.groups(in: body).first { $0.id == id }.map { cards(after: $0, in: body) } ?? []
    }

    public static func cards(after group: NoteSlideMarks.Group, in body: NoteBody) -> [NoteSlideRef] {
        cardRange(of: group, in: body).map { body.blocks[$0].compactMap(\.slide).filter { $0.placedByHand != true } } ?? []
    }

    public struct MadeSlides: Equatable, Sendable {
        public var positions: [String: Int] = [:]

        public var dead: Set<String> = []
        public var isMade: Bool { !positions.isEmpty }
    }

    public static func madeSlides(
        ids: [String], deckId: String?, presentation lookup: (String) -> Presentation?
    ) -> MadeSlides {
        var made = MadeSlides()
        let deck = deckId.flatMap(lookup)
        for id in ids {
            if let index = deck?.slides.firstIndex(where: { $0.id == id }) {
                made.positions[id] = index + 1
            } else {
                made.dead.insert(id)
            }
        }
        return made
    }

    static func cardRange(ofGroup id: String, in body: NoteBody) -> Range<Int>? {
        NoteSlideMarks.groups(in: body).first { $0.id == id }.flatMap { cardRange(of: $0, in: body) }
    }

    static func cardRange(of group: NoteSlideMarks.Group, in body: NoteBody) -> Range<Int>? {
        var range: Range<Int>?
        if let first = group.blockIndexes.first, let last = group.blockIndexes.last {
            var end = last + 1
            while end < body.blocks.count, body.blocks[end].type == .slideRef { end += 1 }
            let after: Range<Int>? = end > last + 1 ? (last + 1) ..< end : nil
            var start = first
            while start > 0, body.blocks[start - 1].type == .slideRef { start -= 1 }
            let before: Range<Int>? = start < first ? start ..< first : nil

            let stampedRun = group.slideId.flatMap { stamped in
                [before, after].compactMap { $0 }.first { run in
                    body.blocks[run].contains { $0.slide?.slideId == stamped }
                }
            }
            range = stampedRun ?? after ?? before
        }
        return range
    }

    public static func replan(_ group: MarkedGroup, like slides: [Slide], theme: Theme?, options: SlideOptions = SlideOptions()) -> SlideRow? {
        let override = SlideRowOverride(themeSlideName: slides.first?.themeSlideName)
        return DeterministicSlidePlanner(options: options).plan([group], theme: theme, overrides: [group.id: override]).rows.first
    }

    public static func isBehind(_ group: MarkedGroup, slides: [Slide], theme: Theme?, options: SlideOptions = SlideOptions()) -> Bool {
        guard let row = replan(group, like: slides, theme: theme, options: options) else { return false }
        if row.holdsMedia { return false }
        return texts(of: row) != slides.map { boxes(of: $0) }
    }

    public struct Result: Equatable {
        public var updated: [Slide]
        public var appended: [Slide]
        public var removedIds: [String]
    }

    public static func updating(_ slides: [Slide], to row: SlideRow) -> Result {
        if row.holdsMedia {
            return Result(updated: slides.map { slide in
                var slide = slide
                let scale = row.scale == .fill ? nil : row.scale
                if row.kind == .picture, slide.background != nil { slide.background?.scaleMode = scale }

                if row.kind == .picture {
                    let spotScale = row.scaleChosen ? scale : scale?.inPhotoSpot
                    for index in slide.objects.indices where slide.objects[index].isPhotoSpot && slide.objects[index].fill?.fillKind == .media {
                        if !row.scaleChosen, (spotScale ?? .fill) == .fill, slide.objects[index].fill?.mediaScaleMode == .scaleAndBlur { continue }
                        slide.objects[index].fill?.mediaScaleMode = spotScale == .fill ? nil : spotScale
                    }
                }
                return slide
            }, appended: [], removedIds: [])
        }
        let parts = texts(of: row)
        var updated: [Slide] = []
        var appended: [Slide] = []
        var removed: [String] = []
        for (index, slide) in slides.enumerated() {
            guard index < parts.count else {
                if slide.objects.allSatisfy({ $0.objectKind == .text }) { removed.append(slide.id) } else { updated.append(slide) }
                continue
            }

            if row.lyrics == nil, let design = row.themeSlideName, let was = slide.themeSlideName, design != was {
                var slide = slide
                slide.objects = slide.objects.filter { $0.objectKind != .text } + row.parts[index].map(NoteSlideBuilder.textObject)
                slide.themeSlideName = design
                updated.append(slide)
                continue
            }
            updated.append(applying(parts[index], to: slide, boxes: row.lyrics == nil ? row.parts[index] : nil))
        }
        for (index, part) in parts.enumerated().dropFirst(slides.count) {
            var slide = Slide(id: UUID().uuidString, name: "", objects: row.lyrics == nil
                ? row.parts[index].map(NoteSlideBuilder.textObject)
                : part.map { name, text in SlideObject(id: UUID().uuidString, objectKind: .text, name: name, text: text) })
            slide.themeSlideName = row.themeSlideName
            slide.themeId = slides.first?.themeId

            slide.actions = slides.first?.actions.map { $0.map { action in var copy = action; copy.id = UUID().uuidString; return copy } }
            appended.append(slide)
        }
        return Result(updated: updated, appended: appended, removedIds: removed)
    }

    public static func applyingSwitch(_ choice: SlidePresetChoice?, to slides: [Slide]) -> [Slide] {
        slides.map { slide in
            var slide = slide
            var actions = (slide.actions ?? []).filter { $0.kind != .switchOutputPreset }
            if let choice, !actions.contains(where: { choice.matches($0) }) {
                actions.append(choice.action())
            }
            slide.actions = actions.isEmpty ? nil : actions
            return slide
        }
    }

    public static func applying(boxes: [NoteMadeBox], to slide: Slide) -> Slide {
        applying(boxes.map { (name: $0.name, text: $0.text) }, to: slide)
    }

    private static func applying(_ part: [(name: String, text: String)], to slide: Slide, boxes: [SlideBox]? = nil) -> Slide {
        var slide = slide
        var remaining = part
        for index in slide.objects.indices where slide.objects[index].objectKind == .text {
            guard let match = remaining.firstIndex(where: { $0.name.caseInsensitiveCompare(slide.objects[index].name) == .orderedSame }) else { continue }
            if let boxes, slide.objects[index].text != remaining[match].text {
                slide.objects[index].styleRuns = boxes.first { $0.name == remaining[match].name }?.styleRuns
            }
            slide.objects[index].text = remaining[match].text
            remaining.remove(at: match)
        }
        for box in remaining {
            slide.objects.append(SlideObject(id: UUID().uuidString, objectKind: .text, name: box.name, text: box.text))
        }
        return slide
    }

    public static func syncingCards(
        afterGroup id: String, appending refs: [NoteSlideRef], removing ids: Set<String>, in body: NoteBody
    ) -> NoteBody {
        guard let group = NoteSlideMarks.groups(in: body).first(where: { $0.id == id }), let last = group.blockIndexes.last else { return body }
        var body = body

        let end = cardRange(of: group, in: body).map { range in
            range.last { body.blocks[$0].slide?.placedByHand != true }.map { $0 + 1 } ?? range.upperBound
        } ?? (last + 1)
        body.blocks.insert(contentsOf: refs.map { NoteBlock(type: .slideRef, slide: $0) }, at: end)
        body.blocks.removeAll { block in
            block.type == .slideRef && block.slide?.slideId.map(ids.contains) == true
        }
        body.plainText = body.blocks.map(NoteReading.text(of:)).filter { !$0.isEmpty }.joined(separator: "\n")
        return body
    }

    static func texts(of row: SlideRow) -> [[(name: String, text: String)]] {
        if let lyrics = row.lyrics {
            return Reflow.build(lyrics, themeSlideName: row.themeSlideName ?? "Lyrics").slides.map { slide in
                slide.objects.filter { $0.objectKind == .text }.map { ($0.name, $0.text) }
            }
        }
        return row.parts.map { $0.map { ($0.name, $0.text) } }
    }

    static func boxes(of slide: Slide) -> [(name: String, text: String)] {
        slide.objects.filter { $0.objectKind == .text }.map { ($0.name, $0.text) }
    }
}

private func != (lhs: [[(name: String, text: String)]], rhs: [[(name: String, text: String)]]) -> Bool {
    guard lhs.count == rhs.count else { return true }
    for (a, b) in zip(lhs, rhs) {
        guard a.count == b.count else { return true }
        let sortedA = a.sorted { $0.name < $1.name }, sortedB = b.sorted { $0.name < $1.name }
        for (x, y) in zip(sortedA, sortedB) where x.name != y.name || x.text != y.text { return true }
    }
    return false
}
