import Foundation

public enum NotePanels {
    public struct Panel: Equatable, Sendable, Identifiable {
        public var id: String
        public var groupId: String?

        public var type: String?

        public var made: Bool

        public var words: ClosedRange<Int>?

        public var cards: [Int]

        public var lines: Int

        public var placedByHand: Bool { groupId == nil }
        public var firstBlock: Int { min(words?.lowerBound ?? Int.max, cards.first ?? Int.max) }
        public var lastBlock: Int { max(words?.upperBound ?? 0, cards.last ?? 0) }

        public init(id: String, groupId: String?, type: String? = nil, made: Bool, words: ClosedRange<Int>?, cards: [Int], lines: Int = 0) {
            self.id = id
            self.groupId = groupId
            self.type = type
            self.made = made
            self.words = words
            self.cards = cards
            self.lines = lines
        }
    }

    public static func panels(in body: NoteBody) -> [Panel] {
        var claimed = Set<Int>()
        var result: [Panel] = []
        let groups = NoteSlideMarks.groups(in: body)
        for (position, group) in groups.enumerated() {
            guard let first = group.blockIndexes.first, let last = group.blockIndexes.last else { continue }
            let range = NoteSlideUpdate.cardRange(of: group, in: body)
            var cards = range.map { Array($0).filter { body.blocks[$0].slide?.placedByHand != true && !claimed.contains($0) } } ?? []

            if position + 1 < groups.count, let stamp = groups[position + 1].slideId, stamp != group.slideId,
               let cut = cards.firstIndex(where: { body.blocks[$0].slide?.slideId == stamp }) {
                cards = Array(cards[..<cut])
            }
            claimed.formUnion(cards)
            let lines = group.text.split(separator: "\n", omittingEmptySubsequences: true).count
            result.append(Panel(id: group.id, groupId: group.id, type: group.type, made: group.slideId != nil, words: first ... last, cards: cards, lines: lines))
        }
        for (index, block) in body.blocks.enumerated() where block.type == .slideRef && !claimed.contains(index) {
            result.append(Panel(id: "card:\(block.slide?.slideId ?? String(index))", groupId: nil, made: true, words: nil, cards: [index]))
        }
        return result.sorted { $0.firstBlock < $1.firstBlock }
    }

    public static func title(slideNumbers: [Int]) -> String? {
        let numbers = slideNumbers.sorted()
        guard let first = numbers.first, let last = numbers.last else { return nil }
        if numbers.count == 1 { return "Slide \(first)" }
        if last - first == numbers.count - 1 { return "Slides \(first) to \(last)" }
        return "Slides " + numbers.map(String.init).joined(separator: ", ")
    }

    public static func foldedTitle(lines: Int) -> String {
        lines == 1 ? "1 line" : "\(lines) lines"
    }
}
