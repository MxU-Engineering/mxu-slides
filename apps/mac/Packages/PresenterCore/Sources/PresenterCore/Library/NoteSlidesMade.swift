import Foundation

public extension NoteSlides {
    struct Made: Equatable, Sendable {
        public var body: NoteBody
        public var newSlides: [Slide] = []
        public var sections: [PresentationSection] = []
        public var arrangement: Arrangement?
        public var groupBySlideId: [String: String] = [:]
        public var groupOrder: [String] = []

        public var markedByStructure: Bool?
    }

    static let updatedReason = "Updated from the notes"

    static func make(
        body: NoteBody, themeId: String, designMap: SlideDesignMap,
        theme: (String) -> Theme?, planner: SlidePlanner? = nil, mediaIds: [String: String] = [:]
    ) -> Made {
        let planner = planner ?? DeterministicSlidePlanner(options: designMap.options)
        var body = body
        var markedByStructure: Bool?
        if NoteSlideMarks.groups(in: body).contains(where: { $0.state == NoteSlideMarks.suggested }) {
            body = NoteSlideMarks.acceptingSuggestions(in: body)
        } else if NoteSlideMarks.groups(in: body).isEmpty {
            body = markingByStructure(body, ownTypes: designMap.options.ownTypes.map(\.name))
            markedByStructure = true
        }
        let groups = NoteSlideBuilder.groups(in: body)
        let built = NoteLiveUpdates.newSlides(
            for: groups, deckThemeId: themeId, designMap: designMap, theme: theme, planner: planner, mediaIds: mediaIds)
        return Made(
            body: body, newSlides: built.slides, sections: built.sections, arrangement: built.arrangement,
            groupBySlideId: built.groupBySlideId, groupOrder: groups.map(\.id), markedByStructure: markedByStructure)
    }

    static func markingByStructure(_ body: NoteBody, ownTypes: [String]) -> NoteBody {
        NoteSlideMarks.acceptingSuggestions(in: NoteSlideMarks.suggesting(body, mode: .structure, ownTypes: ownTypes))
    }

    static func blankStyle(_ map: SlideDesignMap, deckThemeId: String, theme: (String) -> Theme?) -> NoteSlideBuilder.BlankStyle {
        var style = NoteSlideBuilder.BlankStyle(actions: map.preset(for: .blank).map { [$0.action()] } ?? [])
        if let entry = map.entry(for: .blank), theme(entry.themeId) != nil {
            style.themeId = entry.themeId == deckThemeId ? nil : entry.themeId
            style.themeSlideName = entry.themeSlideName
        } else {
            style.themeSlideName = NoteSlideBuilder.designName(for: .blank, in: theme(deckThemeId))
        }
        return style
    }
}

public extension NotePendingUpdate {
    static let new = "new"
    static let words = "words"
    static let remove = "remove"
    static let orphan = "orphan"
}
