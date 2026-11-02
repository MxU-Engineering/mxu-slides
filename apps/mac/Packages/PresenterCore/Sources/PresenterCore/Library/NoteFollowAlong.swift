import Foundation

public enum NoteFollowAlong {
    public struct Slot: Equatable, Hashable, Sendable {
        public var presentationId: String
        public var slideId: String

        public init(presentationId: String, slideId: String) {
            self.presentationId = presentationId
            self.slideId = slideId
        }
    }

    public struct Row: Equatable, Sendable, Identifiable {
        public var id: String

        public var kind: String
        public var words: String?
        public var slides: [Slot]
    }

    public enum Item: Equatable, Sendable, Identifiable {
        case prose(blocks: [Int])

        case passage(groupId: String, kind: String, blocks: ClosedRange<Int>, rows: [Row])

        case slide(Slot, inNote: Bool)

        public var id: String {
            switch self {
            case .prose(let blocks): "prose:\(blocks.first ?? 0)"
            case .passage(let groupId, _, _, _): "passage:\(groupId)"
            case .slide(let slot, _): "slide:\(slot.slideId)"
            }
        }

        public var slots: [Slot] {
            switch self {
            case .prose: []
            case .passage(_, _, _, let rows): rows.flatMap(\.slides)
            case .slide(let slot, _): [slot]
            }
        }

        public var blocks: [Int] {
            switch self {
            case .prose(let blocks): blocks
            case .passage(_, _, let range, _): Array(range)
            case .slide: []
            }
        }
    }

    public struct Line: Equatable, Sendable, Identifiable {
        public enum Content: Equatable, Sendable {
            case prose(blocks: [Int])
            case row(passageKind: String, row: Row, first: Bool, last: Bool)
            case slide(Slot, inNote: Bool)
        }

        public var id: String
        public var content: Content
    }

    public static func lines(_ items: [Item]) -> [Line] {
        items.flatMap { item -> [Line] in
            switch item {
            case .prose(let blocks):
                return [Line(id: item.id, content: .prose(blocks: blocks))]
            case .passage(_, let kind, _, let rows):
                return rows.enumerated().map { index, row in
                    Line(id: "row:\(row.id)", content: .row(passageKind: kind, row: row, first: index == 0, last: index == rows.count - 1))
                }
            case .slide(let slot, let inNote):
                return [Line(id: item.id, content: .slide(slot, inNote: inNote))]
            }
        }
    }

    public static func lineIndex(_ items: [Item]) -> (bySlide: [String: String], byBlock: [Int: String]) {
        var bySlide: [String: String] = [:]
        var byBlock: [Int: String] = [:]
        for item in items {
            switch item {
            case .prose(let blocks):
                for block in blocks { byBlock[block] = item.id }
            case .passage(_, _, let range, let rows):
                for row in rows {
                    for slot in row.slides where bySlide[slot.slideId] == nil { bySlide[slot.slideId] = "row:\(row.id)" }
                }
                if let first = rows.first { for block in range { byBlock[block] = "row:\(first.id)" } }
            case .slide(let slot, _):
                if bySlide[slot.slideId] == nil { bySlide[slot.slideId] = item.id }
            }
        }
        return (bySlide, byBlock)
    }

    public static func laneWidth(view width: Double) -> Double {
        guard width > 0 else { return 160 }
        return min(220, max(80, (width * 0.3 / 10).rounded() * 10))
    }

    public static func items(
        body: NoteBody, deck: Presentation?, memory: [NoteMadePassage] = [],
        slide: (Slot) -> Slide?, replan: (MarkedGroup, [Slide]) -> SlideRow?
    ) -> [Item] {
        let groups = Dictionary(NoteSlideMarks.groups(in: body).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var covered = Set<Int>()

        var shown = Set<Slot>()
        var placed: [(first: Int, item: Item)] = []
        for panel in NotePanels.panels(in: body) {
            let cards: [Slot] = panel.cards.compactMap { index in
                guard let ref = body.blocks[index].slide, let presentationId = ref.presentationId, let slideId = ref.slideId else { return nil }
                let slot = Slot(presentationId: presentationId, slideId: slideId)
                return shown.insert(slot).inserted ? slot : nil
            }
            covered.formUnion(panel.cards)
            if let groupId = panel.groupId, let words = panel.words, let group = groups[groupId] {
                var slots = cards.filter { slide($0) != nil }

                if slots.isEmpty, let deck, let made = memory.first(where: { $0.groupId == groupId }) {
                    slots = made.slides.map { Slot(presentationId: deck.id, slideId: $0.slideId) }
                        .filter { slide($0) != nil && shown.insert($0).inserted }
                }

                guard !slots.isEmpty else { continue }
                covered.formUnion(words)
                let marked = NoteSlideBuilder.marked(group)
                let slides = slots.compactMap(slide)
                let plan = replan(marked, slides)

                let kind = group.type ?? "slide"
                placed.append((words.lowerBound, .passage(
                    groupId: groupId, kind: kind, blocks: words,
                    rows: rows(group: group, slots: slots, slides: slides, plan: plan))))
            } else if let slot = cards.first, slide(slot) != nil {
                placed.append((panel.firstBlock, .slide(slot, inNote: true)))
            }
        }

        var run: [Int] = []
        for (index, block) in body.blocks.enumerated() {
            if covered.contains(index) || block.type == .slideRef {
                if !run.isEmpty { placed.append((run[0], .prose(blocks: run))) }
                run = []
            } else {
                run.append(index)
            }
        }
        if !run.isEmpty { placed.append((run[0], .prose(blocks: run))) }
        let items = placed.sorted { $0.first < $1.first }.map(\.item)
        guard let deck else { return items }
        return placingUnclaimed(deck: deck, in: items)
    }

    static func rows(group: NoteSlideMarks.Group, slots: [Slot], slides: [Slide], plan: SlideRow?) -> [Row] {
        let kind = plan?.kind.rawValue ?? group.type ?? SlideKind.body.rawValue
        let parts = plan.map(NoteSlideUpdate.texts(of:)) ?? []
        let partWords = parts.count > 1 ? parts.map(words(of:)) : [group.text]
        var partRows = partWords.enumerated().map { index, words in
            Row(id: "\(group.id):\(index)", kind: kind, words: words, slides: [])
        }
        let texts = slides.map { words(of: NoteSlideUpdate.boxes(of: $0)) }
        let blank = slides.map(isBlank)
        var part: [Int: Int] = [:]
        var claimed = Set<Int>()
        for index in slides.indices where !blank[index] {
            if let match = partWords.indices.first(where: { !claimed.contains($0) && partWords[$0] == texts[index] }) {
                part[index] = match
                claimed.insert(match)
            }
        }
        var ordinal = 0
        for index in slides.indices where !blank[index] {
            defer { ordinal += 1 }
            guard part[index] == nil else { continue }
            if partWords.indices.contains(ordinal), !claimed.contains(ordinal) {
                part[index] = ordinal
                claimed.insert(ordinal)
            } else {
                part[index] = 0
            }
        }
        for index in slides.indices where !blank[index] {
            partRows[part[index] ?? 0].slides.append(slots[index])
        }
        var result: [Row] = []
        var emitted = 0
        for index in slides.indices {
            if blank[index] {
                result.append(Row(id: slots[index].slideId, kind: SlideKind.blank.rawValue, words: nil, slides: [slots[index]]))
            } else {
                let target = part[index] ?? 0
                while emitted <= target {
                    result.append(partRows[emitted])
                    emitted += 1
                }
            }
        }
        result.append(contentsOf: partRows[emitted...])

        return result.map { row in
            var row = row
            if let first = row.slides.first { row.id = first.slideId }
            return row
        }
    }

    public static func isBlank(_ slide: Slide) -> Bool {
        slide.background == nil && slide.objects.allSatisfy {
            $0.objectKind == .text && $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    static func words(of boxes: [(name: String, text: String)]) -> String {
        boxes.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    static func placingUnclaimed(deck: Presentation, in items: [Item]) -> [Item] {
        var holder: [String: Int] = [:]
        for (index, item) in items.enumerated() {
            for slot in item.slots where slot.presentationId == deck.id && holder[slot.slideId] == nil { holder[slot.slideId] = index }
        }
        let firstHolder = holder.values.min()
        var after: [Int: [Item]] = [:]
        var before: [Item] = []
        var atEnd: [Item] = []
        var lastHolder: Int?
        for slide in deck.slides {
            if let index = holder[slide.id] {
                lastHolder = index
                continue
            }
            let item = Item.slide(Slot(presentationId: deck.id, slideId: slide.id), inNote: false)
            if let lastHolder {
                after[lastHolder, default: []].append(item)
            } else if firstHolder != nil {
                before.append(item)
            } else {
                atEnd.append(item)
            }
        }
        var result: [Item] = []
        for (index, item) in items.enumerated() {
            if index == firstHolder { result.append(contentsOf: before) }
            result.append(item)
            result.append(contentsOf: after[index] ?? [])
        }
        return result + atEnd
    }
}
