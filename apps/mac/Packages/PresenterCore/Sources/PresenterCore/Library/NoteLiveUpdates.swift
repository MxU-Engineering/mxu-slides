import Foundation

public enum NoteLiveUpdates {
    public static let byHand = "hand"

    public struct Found: Equatable, Sendable {
        public var updates: [NotePendingUpdate] = []
        public var texts: [String: String] = [:]
        public var remarked: NoteBody?

        public init(updates: [NotePendingUpdate] = [], texts: [String: String] = [:], remarked: NoteBody? = nil) {
            self.updates = updates
            self.texts = texts
            self.remarked = remarked
        }
    }

    public static func buildMode(of body: NoteBody, autoMark: NoteSlideMarks.SuggestMode = .pickForMe) -> String {
        guard autoMark == .pickForMe else { return autoMark.rawValue }
        let bare = unmarked(body)
        let picked = NoteSlideMarks.suggestions(in: bare, mode: .pickForMe)
        return picked != NoteSlideMarks.suggestions(in: bare, mode: .structure)
            && picked == NoteSlideMarks.suggestions(in: bare, mode: .boldLines)
            ? NoteSlideMarks.SuggestMode.boldLines.rawValue : NoteSlideMarks.SuggestMode.structure.rawValue
    }

    public static func changes(
        body: NoteBody, deck: Presentation, memory: [NoteMadePassage], mode: String?,
        skipped: [NoteSkippedUpdate] = [], designMap: SlideDesignMap, theme: (String) -> Theme?,
        mediaIds: [String: String] = [:], refind: Bool = true
    ) -> Found {
        var found = Found()
        var body = filled(body)
        let inDeck = Dictionary(deck.slides.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let live = memory.filter { passage in passage.slides.contains { inDeck[$0.slideId] != nil } }

        let markedIds = Set(NoteSlideMarks.groups(in: body).map(\.id))
        let lost = live.filter { !markedIds.contains($0.groupId) }
        if refind, !lost.isEmpty {
            let matched = NoteSlideMatch.match(fresh: body, memory: lost)
            if !matched.matches.isEmpty {
                body = matched.body
                found.remarked = body
            }
        }
        let marks = NoteSlideMarks.groups(in: body)
        let byId = Dictionary(marks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        let memoryById = Dictionary(memory.map { ($0.groupId, $0) }, uniquingKeysWith: { first, _ in first })
        func slides(of passage: NoteMadePassage) -> [Slide] { passage.slides.compactMap { inDeck[$0.slideId] } }

        for mark in marks {
            guard let passage = memoryById[mark.id], mark.text != passage.text else { continue }
            let made = slides(of: passage)
            guard let first = made.first else { continue }
            let group = NoteSlideBuilder.marked(mark)
            let rowTheme = theme(first.themeId ?? deck.themeId)
            guard let row = NoteSlideUpdate.replan(group, like: made, theme: rowTheme, options: designMap.options) else { continue }
            let choice = NoteSlideBuilder.presetChoice(for: row.kind, override: .typeDefault, settings: designMap)
            var result = NoteSlideUpdate.updating(made, to: row)
            result.updated = NoteSlideUpdate.applyingSwitch(choice, to: result.updated)
            result.appended = NoteSlideUpdate.applyingSwitch(choice, to: result.appended)
            let remembered = Dictionary(passage.slides.map { ($0.slideId, $0.boxes) }, uniquingKeysWith: { first, _ in first })
            for after in result.updated {
                guard let before = inDeck[after.id], before.keepWords != true else { continue }
                let words = NoteSlideMatch.boxes(of: after)
                guard words != remembered[after.id], words != NoteSlideMatch.boxes(of: before) else { continue }
                add(NotePendingUpdate(
                    id: "words:\(after.id)", kind: NotePendingUpdate.words, groupId: mark.id, slideId: after.id,
                    before: NoteSlideMatch.boxes(of: before), after: words, proposed: after), text: mark.text, to: &found)
            }
            var previous = made.last?.id
            for (index, slide) in result.appended.enumerated() {
                add(NotePendingUpdate(
                    id: "new:\(mark.id):\(index)", kind: NotePendingUpdate.new, groupId: mark.id,
                    afterSlideId: previous, proposed: slide), text: mark.text, to: &found)
                previous = slide.id
            }
            for id in result.removedIds {
                guard let slide = inDeck[id] else { continue }
                add(NotePendingUpdate(
                    id: "remove:\(id)", kind: NotePendingUpdate.remove, groupId: mark.id, slideId: id,
                    before: NoteSlideMatch.boxes(of: slide)), text: mark.text, to: &found)
            }
        }

        for passage in live where byId[passage.groupId] == nil {
            for slide in slides(of: passage) {
                add(NotePendingUpdate(
                    id: "remove:\(slide.id)", kind: NotePendingUpdate.remove, groupId: passage.groupId, slideId: slide.id,
                    before: NoteSlideMatch.boxes(of: slide)), text: "", to: &found)
            }
        }

        var fresh = body
        var newGroups = marks.filter { memoryById[$0.id] == nil }.map(\.id)
        for candidate in candidates(in: body, mode: mode) {
            fresh = marking(candidate, in: fresh)
            newGroups.append(candidate.id)
        }
        if !newGroups.isEmpty {
            let freshMarks = NoteSlideMarks.groups(in: fresh)
            let planned = newSlides(
                for: NoteSlideBuilder.groups(in: fresh).filter { newGroups.contains($0.id) },
                deckThemeId: deck.themeId, designMap: designMap, theme: theme, mediaIds: mediaIds)
            for mark in freshMarks where newGroups.contains(mark.id) {
                var after = lastSlideId(before: mark.id, in: freshMarks, memory: memoryById, deck: deck)
                let own = planned.slides.filter { planned.group(of: $0.id) == mark.id }
                for (index, slide) in own.enumerated() {
                    add(NotePendingUpdate(
                        id: "new:\(mark.id):\(index)", kind: NotePendingUpdate.new, groupId: mark.id,
                        afterSlideId: after, proposed: slide), text: mark.text, to: &found)
                    after = slide.id
                }
            }
        }
        found.updates.removeAll { update in
            skipped.contains { $0.id == update.id && $0.text == found.texts[update.id] }
        }
        return found
    }

    private static func add(_ update: NotePendingUpdate, text: String, to found: inout Found) {
        found.updates.append(update)
        found.texts[update.id] = text
    }

    struct Candidate: Equatable {
        var id: String
        var blocks: [Int]
        var type: String?
    }

    static func candidates(in body: NoteBody, mode: String?) -> [Candidate] {
        guard let mode, let suggest = NoteSlideMarks.SuggestMode(rawValue: mode) else { return [] }
        let held = Set(body.blocks.indices.filter { isMarked(body.blocks[$0]) })
        let bare = unmarked(body)

        let suggested = (NoteSlideMarks.suggestions(in: bare, mode: suggest) + NoteSlideMarks.strongSuggestionsOutsideMarkers(in: bare))
            .sorted { $0.blocks[0] < $1.blocks[0] }
        return suggested.compactMap { passage in
            let blocks = passage.blocks.filter { !held.contains($0) }
            guard let first = blocks.first else { return nil }
            let words = blocks.map { NoteReading.text(of: body.blocks[$0]) }.joined(separator: "\n")

            let key = blocks.compactMap { NoteMedia.key(of: body.blocks[$0]) }.joined(separator: "\n")
            let type = blocks.count == passage.blocks.count
                ? passage.type : NoteSlideMarks.guessedType(of: words, shape: NoteSlideMarks.shape(of: body.blocks[first]))
            return Candidate(id: "add-" + fingerprint(NoteSlideMatch.normalized(words) + key), blocks: blocks, type: type)
        }
    }

    static func marking(_ candidate: Candidate, in body: NoteBody) -> NoteBody {
        var body = body
        for index in candidate.blocks {
            body.blocks[index] = NoteSlideMarks.marking(body.blocks[index], group: candidate.id, type: candidate.type)
        }
        return body
    }

    static func fingerprint(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100_0000_01b3
        }
        return String(hash, radix: 16)
    }

    static func lastSlideId(before groupId: String, in marks: [NoteSlideMarks.Group], memory: [String: NoteMadePassage], deck: Presentation) -> String? {
        guard let index = marks.firstIndex(where: { $0.id == groupId }) else { return nil }
        for mark in marks[..<index].reversed() {
            let ids = Set(memory[mark.id]?.slides.map(\.slideId) ?? [])
            if let last = deck.slides.last(where: { ids.contains($0.id) }) { return last.id }
        }
        return nil
    }

    public static func newSlides(
        for groups: [MarkedGroup], deckThemeId: String, designMap: SlideDesignMap,
        theme: (String) -> Theme?, planner: SlidePlanner? = nil, mediaIds: [String: String] = [:]
    ) -> NoteSlideBuilder.Built {
        let planner = planner ?? DeterministicSlidePlanner(options: designMap.options)
        var rows: [SlideRow] = []
        var rowThemeIds: [String: String] = [:]
        var blanks: [String: BlankPlacement] = [:]
        for group in groups {
            var rowThemeId = deckThemeId
            var design: String?
            if let first = planner.plan([group], theme: theme(rowThemeId), overrides: [:]).rows.first,
               let entry = designMap.entry(forType: first.typeKey), theme(entry.themeId) != nil {
                rowThemeId = entry.themeId
                design = entry.themeSlideName
            }
            let override = SlideRowOverride(themeSlideName: design)
            guard let row = planner.plan([group], theme: theme(rowThemeId), overrides: [group.id: override]).rows.first else { continue }
            rows.append(row)
            if rowThemeId != deckThemeId, !rowThemeId.isEmpty { rowThemeIds[group.id] = rowThemeId }
            if designMap.blanks != .none { blanks[group.id] = designMap.blanks }
        }
        guard !rows.isEmpty else { return NoteSlideBuilder.Built(slides: [], sections: [], arrangement: nil, groupBySlideId: [:]) }
        var built = NoteSlideBuilder.build(
            SlidePlan(rows: rows), blanks: blanks,
            blank: NoteSlides.blankStyle(designMap, deckThemeId: deckThemeId, theme: theme),
            options: designMap.options, media: { mediaIds[$0] })
        NoteSlideBuilder.attachingSwitches(to: &built, rows: rows, settings: designMap, overrides: [:])
        for index in built.slides.indices {
            if let group = built.groupBySlideId[built.slides[index].id], let own = rowThemeIds[group] {
                built.slides[index].themeId = own
            }
        }
        NoteSlideBuilder.attachingDesignActions(to: &built, deckThemeId: deckThemeId, theme: theme)
        return built
    }

    public struct Applied: Equatable, Sendable {
        public var deck: Presentation
        public var memory: [NoteMadePassage]
        public var body: NoteBody?

        public init(deck: Presentation, memory: [NoteMadePassage], body: NoteBody?) {
            self.deck = deck
            self.memory = memory
            self.body = body
        }
    }

    public static func applying(
        _ update: NotePendingUpdate, to deck: Presentation, memory: [NoteMadePassage], body: NoteBody,
        mode: String?, at now: String
    ) -> Applied {
        var applied = Applied(deck: deck, memory: memory, body: nil)
        let body = filled(body)
        switch update.kind {
        case NotePendingUpdate.words:
            guard let slideId = update.slideId, let after = update.after,
                  let index = deck.slides.firstIndex(where: { $0.id == slideId }), deck.slides[index].keepWords != true else { break }
            let current = deck.slides[index]
            let next = NoteSlideUpdate.applying(boxes: after, to: current)
            if next != current {
                applied.deck.slides[index] = SlideHistory.pushing(current, replacedBy: next, reason: NoteSlides.updatedReason, at: now)
            }
            remember(slide: slideId, boxes: after, group: update.groupId, body: body, in: &applied.memory)
        case NotePendingUpdate.remove, NotePendingUpdate.orphan:
            guard let slideId = update.slideId else { break }
            applied.deck.slides.removeAll { $0.id == slideId }
            for index in applied.memory.indices { applied.memory[index].slides.removeAll { $0.slideId == slideId } }

            let marked = Set(NoteSlideMarks.groups(in: body).map(\.id))
            applied.memory.removeAll { $0.slides.isEmpty && !marked.contains($0.groupId) }
        case NotePendingUpdate.new:
            guard let proposed = update.proposed, !deck.slides.contains(where: { $0.id == proposed.id }) else { break }
            var marked = body
            if !NoteSlideMarks.groups(in: body).contains(where: { $0.id == update.groupId }) {
                guard let candidate = candidates(in: body, mode: mode).first(where: { $0.id == update.groupId }) else { break }
                marked = marking(candidate, in: body)
                applied.body = marked
            }
            let own = Set(memory.first { $0.groupId == update.groupId }?.slides.map(\.slideId) ?? [])
            let at = update.afterSlideId.flatMap { id in deck.slides.firstIndex { $0.id == id } }
                ?? deck.slides.lastIndex { own.contains($0.id) }
            applied.deck.slides.insert(proposed, at: at.map { $0 + 1 } ?? 0)
            remember(slide: proposed.id, boxes: NoteSlideMatch.boxes(of: proposed), group: update.groupId, body: marked, in: &applied.memory, deck: applied.deck)
        default:
            break
        }
        return applied
    }

    private static func remember(
        slide slideId: String, boxes: [NoteMadeBox], group groupId: String, body: NoteBody,
        in memory: inout [NoteMadePassage], deck: Presentation? = nil
    ) {
        let mark = NoteSlideMarks.groups(in: body).first { $0.id == groupId }
        if let index = memory.firstIndex(where: { $0.groupId == groupId }) {
            if let slide = memory[index].slides.firstIndex(where: { $0.slideId == slideId }) {
                memory[index].slides[slide].boxes = boxes
            } else {
                memory[index].slides.append(NoteMadeSlide(slideId: slideId, boxes: boxes))
            }
            if let deck {
                let order = Dictionary(deck.slides.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
                memory[index].slides.sort { (order[$0.slideId] ?? .max) < (order[$1.slideId] ?? .max) }
            }
        } else {
            let made = deck?.slides.first { $0.id == slideId }
            let passage = NoteMadePassage(
                groupId: groupId, text: mark?.text ?? "", themeSlideName: made?.themeSlideName, themeId: made?.themeId,
                slides: [NoteMadeSlide(slideId: slideId, boxes: boxes)])

            let marks = NoteSlideMarks.groups(in: body).map(\.id)
            let position = marks.firstIndex(of: groupId) ?? marks.count
            let at = memory.firstIndex { (marks.firstIndex(of: $0.groupId) ?? marks.count) > position } ?? memory.count
            memory.insert(passage, at: at)
        }
    }

    public static func settlingTexts(_ memory: [NoteMadePassage], body: NoteBody, waiting: [NotePendingUpdate]) -> [NoteMadePassage] {
        let marks = Dictionary(NoteSlideMarks.groups(in: filled(body)).map { ($0.id, $0.text) }, uniquingKeysWith: { first, _ in first })
        let busy = Set(waiting.map(\.groupId))
        return memory.map { passage in
            var passage = passage
            if !busy.contains(passage.groupId), let text = marks[passage.groupId] { passage.text = text }
            return passage
        }
    }

    public static func baseline(_ found: Found) -> [NoteSkippedUpdate] {
        found.updates.map { NoteSkippedUpdate(id: $0.id, text: found.texts[$0.id] ?? "") }
    }

    public static func skipping(_ id: String, text: String, in skipped: [NoteSkippedUpdate]) -> [NoteSkippedUpdate] {
        skipped.filter { $0.id != id } + [NoteSkippedUpdate(id: id, text: text)]
    }

    public static func memory(of body: NoteBody, deck: Presentation, groupBySlideId: [String: String]) -> [NoteMadePassage] {
        NoteSlideMarks.groups(in: body).compactMap { group in
            let slides = deck.slides.filter { groupBySlideId[$0.id] == group.id }
            guard let first = slides.first else { return nil }
            return NoteMadePassage(
                groupId: group.id, text: group.text, themeSlideName: first.themeSlideName, themeId: first.themeId,
                slides: slides.map { NoteMadeSlide(slideId: $0.id, boxes: NoteSlideMatch.boxes(of: $0)) })
        }
    }

    public static func displayBody(_ body: NoteBody, memory: [NoteMadePassage], deck: Presentation?) -> NoteBody {
        guard let deck else { return body }
        var shown = savedBody(body, deckId: deck.id)
        guard !memory.isEmpty else { return shown }
        let byGroup = Dictionary(memory.map { ($0.groupId, Set($0.slides.map(\.slideId))) }, uniquingKeysWith: { first, _ in first })
        let marks = NoteSlideMarks.groups(in: shown)
        for mark in marks.reversed() {
            guard let ids = byGroup[mark.id], let last = mark.blockIndexes.last else { continue }
            let slides = deck.slides.filter { ids.contains($0.id) }
            guard let first = slides.first else { continue }
            let cards = slides.compactMap { slide in
                NoteSlides.dropRef(presentationId: deck.id, slideId: slide.id, presentation: { _ in deck })
            }.map { NoteBlock(type: .slideRef, slide: $0) }
            var at = last + 1
            while at < shown.blocks.count, shown.blocks[at].type == .slideRef { at += 1 }
            shown.blocks.insert(contentsOf: cards, at: at)
            shown = NoteSlideMarks.stamping(slideId: first.id, onGroup: mark.id, in: shown)
        }
        shown.plainText = shown.blocks.map(NoteReading.text(of:)).filter { !$0.isEmpty }.joined(separator: "\n")
        return shown
    }

    public static func savedBody(_ shown: NoteBody, deckId: String?) -> NoteBody {
        var saved = deckId.map { strippingMadeCards(shown, deckId: $0) } ?? shown
        if saved.blocks.contains(where: hasSlideId) { saved.blocks = saved.blocks.map(unstamped) }
        return saved
    }

    private static func hasSlideId(_ block: NoteBlock) -> Bool {
        block.slideId != nil || block.markRun?.slideId != nil || NoteSlideMarks.lines(of: block).joined().contains { $0.slideId != nil }
            || (block.blocks ?? []).contains(where: hasSlideId)
    }

    private static func unstamped(_ block: NoteBlock) -> NoteBlock {
        guard block.type != .slideRef else { return block }
        var block = block
        func clear(_ run: NoteRun) -> NoteRun {
            var run = run
            run.slideId = nil
            return run
        }
        block.slideId = nil
        block.markRun = block.markRun.map(clear)
        block.runs = block.runs?.map(clear)
        block.items = block.items?.map { item in
            var item = item
            item.runs = item.runs.map(clear)
            item.blocks = item.blocks?.map(unstamped)
            return item
        }
        block.blocks = block.blocks?.map(unstamped)
        return block
    }

    public static func strippingMadeCards(_ body: NoteBody, deckId: String) -> NoteBody {
        guard body.blocks.contains(where: { isMadeCard($0, deckId: deckId) }) else { return body }
        var saved = body
        saved.blocks.removeAll { isMadeCard($0, deckId: deckId) }
        saved.plainText = saved.blocks.map(NoteReading.text(of:)).filter { !$0.isEmpty }.joined(separator: "\n")
        return saved
    }

    static func isMadeCard(_ block: NoteBlock, deckId: String) -> Bool {
        block.type == .slideRef && block.slide?.presentationId == deckId && block.slide?.placedByHand != true
    }

    public static func passages(of memory: [NoteMadePassage]) -> [(groupId: String, slideIds: [String])] {
        memory.map { ($0.groupId, $0.slides.map(\.slideId)) }
    }

    public enum Cell: Hashable, Sendable {
        case slide(Int)
        case add(String)
    }

    public static func cells(slideIds: [String], updates: [NotePendingUpdate]) -> [Cell] {
        let adds = updates.filter { $0.kind == NotePendingUpdate.new }
        var placed = Set<String>()
        func after(_ id: String?) -> [Cell] {
            var out: [Cell] = []
            for add in adds where add.afterSlideId == id && !placed.contains(add.id) {
                placed.insert(add.id)
                out.append(.add(add.id))

                out += add.proposed.map { after($0.id) } ?? []
            }
            return out
        }
        var cells = after(nil)
        var seen = Set<String>()
        for (index, id) in slideIds.enumerated() {
            cells.append(.slide(index))
            if seen.insert(id).inserted { cells += after(id) }
        }

        cells += adds.filter { !placed.contains($0.id) }.map { .add($0.id) }
        return cells
    }

    public enum Change: Equatable, Sendable { case kept, removed, added }

    public static func wordDiff(_ before: String, _ after: String) -> [(text: String, change: Change)] {
        let a = before.split(whereSeparator: \.isWhitespace).map(String.init)
        let b = after.split(whereSeparator: \.isWhitespace).map(String.init)

        var table = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                table[i][j] = a[i] == b[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var out: [(text: String, change: Change)] = []
        func push(_ word: String, _ change: Change) {
            if let last = out.last, last.change == change { out[out.count - 1].text += " " + word } else { out.append((word, change)) }
        }
        var i = 0, j = 0
        while i < a.count || j < b.count {
            if i < a.count, j < b.count, a[i] == b[j] {
                push(a[i], .kept); i += 1; j += 1
            } else if i < a.count, j == b.count || table[i + 1][j] >= table[i][j + 1] {
                push(a[i], .removed); i += 1
            } else {
                push(b[j], .added); j += 1
            }
        }
        return out
    }

    static func unmarked(_ body: NoteBody) -> NoteBody {
        var body = body
        body.blocks = body.blocks.map(unmarked)
        return body
    }

    private static func unmarked(_ block: NoteBlock) -> NoteBlock {
        var block = block
        block.markRun = block.markRun.map(unmarked)
        block.runs = block.runs?.map(unmarked)
        block.items = block.items?.map { item in
            var item = item
            item.runs = item.runs.map(unmarked)
            item.blocks = item.blocks?.map(unmarked)
            return item
        }
        block.blocks = block.blocks?.map(unmarked)
        block.slideGroup = nil
        block.slideType = nil
        block.slideId = nil
        block.slideState = nil
        return block
    }

    private static func unmarked(_ run: NoteRun) -> NoteRun {
        var run = run
        run.slideGroup = nil
        run.slideType = nil
        run.slideId = nil
        run.slideState = nil
        return run
    }

    static func isMarked(_ block: NoteBlock) -> Bool {
        block.slideGroup != nil || block.markRun?.slideGroup != nil
            || NoteSlideMarks.lines(of: block).joined().contains { $0.slideGroup != nil }
    }

    static func filled(_ body: NoteBody) -> NoteBody {
        var body = body
        for (index, block) in body.blocks.enumerated() {
            let runs = NoteSlideMarks.lines(of: block).joined()
            let marked = runs.filter { $0.slideGroup != nil }
            guard let first = marked.first, let group = first.slideGroup, first.slideState != NoteSlideMarks.declined,
                  marked.allSatisfy({ $0.slideGroup == group }),
                  runs.contains(where: { $0.slideGroup == nil && !$0.text.trimmingCharacters(in: .whitespaces).isEmpty })
            else { continue }
            let type = marked.lazy.compactMap(\.slideType).first
            body.blocks[index] = NoteSlideMarks.marking(block, group: group, type: type, state: first.slideState)
        }
        return body
    }
}
