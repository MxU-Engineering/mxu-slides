import Foundation

public struct NotePassages: Sendable {
    public let groups: [MarkedGroup]

    public let cards: [String: [NoteSlideRef]]

    public init(body: NoteBody) {
        let marks = NoteSlideMarks.groups(in: body)
        groups = marks.map(NoteSlideBuilder.marked)
        cards = Dictionary(
            marks.map { ($0.id, NoteSlideUpdate.cards(after: $0, in: body)) },
            uniquingKeysWith: { first, _ in first })
    }

    public func passage(containingSlide slideId: String) -> (group: MarkedGroup, cards: [NoteSlideRef])? {
        groups.lazy.compactMap { group in
            (cards[group.id] ?? []).contains { $0.slideId == slideId } ? (group, cards[group.id] ?? []) : nil
        }.first
    }
}

@MainActor
public final class NotePassagesMemo {
    private var body: NoteBody?
    private var held: NotePassages?

    public private(set) var parses = 0

    public init() {}

    public func passages(for body: NoteBody) -> NotePassages {
        let current: NotePassages
        if let held, self.body == body {
            current = held
        } else {
            current = NotePassages(body: body)
            held = current
            parses += 1
        }
        self.body = body
        return current
    }
}
