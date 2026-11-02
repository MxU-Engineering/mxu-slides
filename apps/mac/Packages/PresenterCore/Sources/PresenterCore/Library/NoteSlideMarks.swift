import Foundation

public enum NoteSlideMarks {
    public enum SlideType: String, CaseIterable, Sendable {
        case scripture, points, quote, title, lyrics, picture, video

        case body

        public var label: String { self == .body ? "Statement" : rawValue.capitalized }

        public static let textKinds: [SlideType] = [.body, .points, .scripture, .quote, .title, .lyrics]
    }

    public static let suggested = "suggested"
    public static let declined = "declined"

    public enum Shape: Equatable, Sendable {
        case heading, list, quote, paragraph
    }

    public struct Group: Equatable, Sendable, Identifiable {
        public var id: String
        public var type: String?

        public var slideId: String?

        public var blockIndexes: [Int]

        public var text: String
        public var shape: Shape = .paragraph

        public var state: String?

        public var underlines: [String] = []

        public var media: [String] = []

        public var links: [String] = []
    }

    static func shape(of block: NoteBlock) -> Shape {
        switch block.type {
        case .heading: .heading
        case .list, .taskList: .list
        case .quote: .quote
        default: .paragraph
        }
    }

    public static func groups(in body: NoteBody) -> [Group] {
        var order: [String] = []
        var groups: [String: Group] = [:]
        for (index, block) in body.blocks.enumerated() {
            if let run = block.markRun, let id = run.slideGroup, !id.isEmpty, run.slideState != declined, let key = NoteMedia.key(of: block) {
                if groups[id] == nil {
                    groups[id] = Group(
                        id: id, type: run.slideType, slideId: run.slideId, blockIndexes: [], text: "",
                        shape: .paragraph, state: run.slideState == suggested ? suggested : nil)
                    order.append(id)
                }
                if groups[id]!.type == nil { groups[id]!.type = run.slideType }
                if groups[id]!.slideId == nil { groups[id]!.slideId = run.slideId }
                if groups[id]!.blockIndexes.last != index { groups[id]!.blockIndexes.append(index) }
                groups[id]!.media.append(key)
            }
            for line in lines(of: block) {
                var lineText: [String: String] = [:]
                var lineOrder: [String] = []
                var underlining: String?
                for run in line {
                    defer { if run.underline != true || run.slideGroup != underlining { underlining = nil } }
                    guard let id = run.slideGroup, !id.isEmpty, run.slideState != declined else { continue }
                    if groups[id] == nil {
                        groups[id] = Group(
                            id: id, type: run.slideType, slideId: run.slideId, blockIndexes: [], text: "",
                            shape: shape(of: block), state: run.slideState == suggested ? suggested : nil)
                        order.append(id)
                    }
                    if groups[id]!.type == nil { groups[id]!.type = run.slideType }
                    if groups[id]!.slideId == nil { groups[id]!.slideId = run.slideId }
                    if lineText[id] == nil { lineOrder.append(id); lineText[id] = "" }
                    lineText[id]! += run.text
                    if let href = run.href, !href.isEmpty, groups[id]!.links.last != href { groups[id]!.links.append(href) }
                    if run.underline == true {
                        if underlining == id, let last = groups[id]!.underlines.indices.last {
                            groups[id]!.underlines[last] += run.text
                        } else if !run.text.trimmingCharacters(in: .whitespaces).isEmpty {
                            groups[id]!.underlines.append(run.text)
                            underlining = id
                        }
                    }
                }
                for id in lineOrder {
                    var group = groups[id]!

                    let stanzaBreak = group.blockIndexes.last.map { $0 < index - 1 } ?? false
                    if group.blockIndexes.last != index { group.blockIndexes.append(index) }
                    let text = lineText[id]!.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty { group.text += (group.text.isEmpty ? "" : (stanzaBreak ? "\n\n" : "\n")) + text }
                    groups[id] = group
                }
            }
        }
        return order.compactMap { groups[$0] }
    }

    public static func acceptingSuggestions(in body: NoteBody) -> NoteBody {
        var body = body
        body.blocks = body.blocks.map { block in
            mappingRuns(in: block) { run in
                guard run.slideState == suggested else { return run }
                var run = run
                run.slideState = nil
                return run
            }
        }
        return body
    }

    private static func mappingRuns(in block: NoteBlock, _ transform: (NoteRun) -> NoteRun) -> NoteBlock {
        var block = block
        block.markRun = block.markRun.map(transform)
        block.runs = block.runs?.map(transform)
        block.items = block.items?.map { item in
            var item = item
            item.runs = item.runs.map(transform)
            item.blocks = item.blocks?.map { mappingRuns(in: $0, transform) }
            return item
        }
        block.blocks = block.blocks?.map { mappingRuns(in: $0, transform) }
        return block
    }

    public static func blockIndex(ofGroup id: String, in body: NoteBody) -> Int? {
        groups(in: body).first { $0.id == id }?.blockIndexes.first
    }

    public static func mintGroupID() -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        return String((0 ..< 6).map { _ in alphabet[Int.random(in: 0 ..< alphabet.count)] })
    }

    public static func stamping(slideId: String, onGroup id: String, in body: NoteBody) -> NoteBody {
        var body = body
        body.blocks = body.blocks.map { stamp(slideId, group: id, in: $0) }
        return body
    }

    private static func stamp(_ slideId: String, group: String, in block: NoteBlock) -> NoteBlock {
        var block = block
        block.markRun = block.markRun.map { stamp(slideId, group: group, run: $0) }
        block.runs = block.runs?.map { stamp(slideId, group: group, run: $0) }
        block.items = block.items?.map { item in
            var item = item
            item.runs = item.runs.map { stamp(slideId, group: group, run: $0) }
            item.blocks = item.blocks?.map { stamp(slideId, group: group, in: $0) }
            return item
        }
        block.blocks = block.blocks?.map { stamp(slideId, group: group, in: $0) }
        return block
    }

    private static func stamp(_ slideId: String, group: String, run: NoteRun) -> NoteRun {
        guard run.slideGroup == group else { return run }
        var run = run
        run.slideId = slideId

        if run.slideState == suggested { run.slideState = nil }
        return run
    }

    public static func placingMadeSlides(_ made: [(groupId: String, refs: [NoteSlideRef])], in body: NoteBody) -> NoteBody {
        var body = body
        let known = groups(in: body)
        let placements = made.compactMap { item -> (last: Int, item: (groupId: String, refs: [NoteSlideRef]))? in
            guard let last = known.first(where: { $0.id == item.groupId })?.blockIndexes.last else { return nil }
            return (last, item)
        }
        for placement in placements.sorted(by: { $0.last > $1.last }) {
            let cards = placement.item.refs.map { NoteBlock(type: .slideRef, slide: $0) }

            let first = known.first { $0.id == placement.item.groupId }?.blockIndexes.first ?? placement.last
            if let marker = markerIndex(above: first, in: body) {
                body.blocks.insert(contentsOf: cards, at: first)
                body.blocks.remove(at: marker)
            } else {
                body.blocks.insert(contentsOf: cards, at: placement.last + 1)
            }
            if let slideId = placement.item.refs.first?.slideId {
                body = stamping(slideId: slideId, onGroup: placement.item.groupId, in: body)
            }
        }
        body.plainText = body.blocks.map(NoteReading.text(of:)).filter { !$0.isEmpty }.joined(separator: "\n")
        return body
    }

    public static func markingByStructure(_ body: NoteBody) -> NoteBody {
        if body.blocks.contains(where: NoteSlides.startsSlide) { return markingByMarkers(body) }
        var body = body
        let labels = body.blocks.filter { $0.type == .paragraph || $0.type == .heading }
            .filter { Reflow.labelName(of: NoteReading.text(of: $0.runs)) != nil }.count
        let lyricsGroup = labels >= 2 ? mintGroupID() : nil
        for index in body.blocks.indices {
            let block = body.blocks[index]
            guard [.heading, .paragraph, .list, .taskList, .quote].contains(block.type),
                  !NoteSlides.isMarker(block, marker: NoteSlides.defaultMarker),
                  !NoteReading.text(of: block).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  lines(of: block).joined().allSatisfy({ $0.slideGroup == nil })
            else { continue }
            let group = lyricsGroup ?? mintGroupID()
            body.blocks[index] = marking(block, group: group)
        }
        return body
    }

    public static func markingByMarkers(_ body: NoteBody) -> NoteBody {
        var body = body
        for passage in markerPassages(in: body) {
            let group = mintGroupID()
            for index in passage { body.blocks[index] = marking(body.blocks[index], group: group) }
        }
        return body
    }

    static func markerIndex(above first: Int, in body: NoteBody) -> Int? {
        guard body.blocks.indices.contains(first), NoteSlides.inlineMarkerLabelLength(body.blocks[first]) == nil else { return nil }
        var index = first - 1
        while index >= 0 {
            let block = body.blocks[index]
            if NoteSlides.isMarker(block, marker: NoteSlides.defaultMarker) { return index }
            let text = NoteReading.text(of: block).trimmingCharacters(in: .whitespacesAndNewlines)
            guard block.type == .paragraph, text.isEmpty || isAside(text) else { return nil }
            index -= 1
        }
        return nil
    }

    static func splitting(_ runs: [NoteRun], at count: Int) -> ([NoteRun], [NoteRun]) {
        var head: [NoteRun] = []
        var tail: [NoteRun] = []
        var left = count
        for run in runs {
            if left <= 0 { tail.append(run); continue }
            if run.text.count <= left {
                head.append(run)
                left -= run.text.count
                continue
            }
            var first = run, second = run
            first.text = String(run.text.prefix(left))
            second.text = String(run.text.dropFirst(left))
            head.append(first)
            tail.append(second)
            left = 0
        }
        return (head, tail)
    }

    static func markerPassages(in body: NoteBody) -> [[Int]] {
        var passages: [[Int]] = []
        var words: Int?
        var pictures: Int?
        var underMarker = false
        var took = false
        var endsAtEmptyLine = false
        for (index, block) in body.blocks.enumerated() {
            let oneLine = NoteSlides.inlineMarkerLabelLength(block) != nil
            if oneLine || NoteSlides.isMarker(block, marker: NoteSlides.defaultMarker) {
                underMarker = true
                took = false
                endsAtEmptyLine = NoteReading.text(of: block).trimmingCharacters(in: .whitespacesAndNewlines)
                    .caseInsensitiveCompare(NoteSlides.defaultMarker) != .orderedSame
                words = nil
                pictures = nil

                if !oneLine { continue }
            }
            guard underMarker else { continue }
            if !NoteMedia.blocks(in: NoteBody(blocks: [block], plainText: "")).isEmpty {
                guard block.slideGroup == nil else { continue }
                took = true
                if !NoteMedia.isVideo(block), let row = pictures {
                    passages[row].append(index)
                } else {
                    passages.append([index])
                    pictures = NoteMedia.isVideo(block) ? nil : passages.count - 1
                }
                continue
            }
            let text = NoteReading.text(of: block).trimmingCharacters(in: .whitespacesAndNewlines)
            if block.type == .paragraph, text.isEmpty {
                if took, endsAtEmptyLine { underMarker = false }
                continue
            }
            pictures = nil
            guard [.heading, .paragraph, .list, .taskList, .quote].contains(block.type), !text.isEmpty, !isAside(text),
                  lines(of: block).joined().allSatisfy({ $0.slideGroup == nil }) else { continue }
            took = true
            if isVideoFileLink(block) {
                passages.append([index])
            } else if let row = words {
                passages[row].append(index)
            } else {
                passages.append([index])
                words = passages.count - 1
            }
        }
        return passages
    }

    static func marking(blockIndexes: [Int], group: String, slideId: String?, in body: NoteBody) -> NoteBody {
        var body = body
        for index in blockIndexes where body.blocks.indices.contains(index) {
            body.blocks[index] = marking(body.blocks[index], group: group)
        }
        return slideId.map { stamping(slideId: $0, onGroup: group, in: body) } ?? body
    }

    static func marking(_ block: NoteBlock, group: String, type: String? = nil, state: String? = nil) -> NoteBlock {
        var block = block

        if let label = NoteSlides.inlineMarkerLabelLength(block), let runs = block.runs {
            let (head, tail) = splitting(runs, at: label)
            block.runs = head + tail.map { marking($0, group: group, type: type, state: state) }
            return block
        }
        block.markRun = block.markRun.map { marking($0, group: group, type: type, state: state) }
        block.runs = block.runs?.map { marking($0, group: group, type: type, state: state) }
        block.items = block.items?.map { item in
            var item = item
            item.runs = item.runs.map { marking($0, group: group, type: type, state: state) }
            item.blocks = item.blocks?.map { marking($0, group: group, type: type, state: state) }
            return item
        }
        block.blocks = block.blocks?.map { marking($0, group: group, type: type, state: state) }
        return block
    }

    private static func marking(_ run: NoteRun, group: String, type: String?, state: String?) -> NoteRun {
        var run = run
        run.slideGroup = group
        if type != nil { run.slideType = type }
        run.slideState = state
        return run
    }

    public static func replacingText(ofGroup id: String, with text: String, in body: NoteBody) -> NoteBody {
        var body = body
        var placed = false
        body.blocks = body.blocks.compactMap { replacing(id, with: text, in: $0, placed: &placed) }
        return body
    }

    private static func replacing(_ id: String, with text: String, in block: NoteBlock, placed: inout Bool) -> NoteBlock? {
        var block = block
        if let runs = block.runs {
            block.runs = replacing(id, with: text, runs: runs, placed: &placed)
            if block.runs?.isEmpty == true, block.type == .paragraph || block.type == .heading { return nil }
        }
        if let items = block.items {
            block.items = items.compactMap { item in
                var item = item
                item.runs = replacing(id, with: text, runs: item.runs, placed: &placed)
                item.blocks = item.blocks?.compactMap { replacing(id, with: text, in: $0, placed: &placed) }
                return item.runs.isEmpty && (item.blocks ?? []).isEmpty ? nil : item
            }
            if block.items?.isEmpty == true { return nil }
        }
        if let blocks = block.blocks {
            block.blocks = blocks.compactMap { replacing(id, with: text, in: $0, placed: &placed) }
            if block.blocks?.isEmpty == true, block.type == .quote { return nil }
        }
        return block
    }

    private static func replacing(_ id: String, with text: String, runs: [NoteRun], placed: inout Bool) -> [NoteRun] {
        var result: [NoteRun] = []
        for run in runs {
            guard run.slideGroup == id else { result.append(run); continue }
            if placed { continue }
            placed = true
            var replacement = run
            replacement.text = text
            result.append(replacement)
        }
        return result
    }

    public static func unmarking(group id: String, in body: NoteBody) -> NoteBody {
        var body = body
        body.blocks = body.blocks.map { unmarking(id, in: $0) }
        return body
    }

    private static func unmarking(_ id: String, in block: NoteBlock) -> NoteBlock {
        func clear(_ run: NoteRun) -> NoteRun {
            guard run.slideGroup == id else { return run }
            var run = run
            run.slideGroup = nil
            run.slideType = nil
            run.slideId = nil
            run.slideState = nil
            return run
        }
        var block = block
        block.markRun = block.markRun.map(clear)
        block.runs = block.runs?.map(clear)
        block.items = block.items?.map { item in
            var item = item
            item.runs = item.runs.map(clear)
            item.blocks = item.blocks?.map { unmarking(id, in: $0) }
            return item
        }
        block.blocks = block.blocks?.map { unmarking(id, in: $0) }
        return block
    }

    static func lines(of block: NoteBlock) -> [[NoteRun]] {
        switch block.type {
        case .heading, .paragraph:
            return [block.runs ?? []]
        case .list, .taskList:
            return (block.items ?? []).flatMap { item in
                [item.runs] + (item.blocks ?? []).flatMap(lines(of:))
            }
        case .quote:
            return (block.blocks ?? []).flatMap(lines(of:))
        default:
            return []
        }
    }
}

extension NoteBlock {
    var markRun: NoteRun? {
        get {
            guard type == .image || type == .attachment else { return nil }
            return NoteRun(text: "", slideGroup: slideGroup, slideType: slideType, slideId: slideId, slideState: slideState)
        }
        set {
            guard type == .image || type == .attachment else { return }
            slideGroup = newValue?.slideGroup
            slideType = newValue?.slideType
            slideId = newValue?.slideId
            slideState = newValue?.slideState
        }
    }
}
