import Foundation

@MainActor
public final class MoveUndoJournal {

    public enum Step {
        case done(Bool)
        case later(Task<Bool, Never>)
    }

    public struct Entry {
        let label: String
        let undo: () -> Step
        let redo: () -> Step

        var coalescingKey: String? = nil
        var registeredAt: Date
    }

    public let capacity: Int

    public let coalescingWindow: TimeInterval
    private let now: () -> Date
    private var undoStack: [Entry] = []
    private var redoStack: [Entry] = []

    public private(set) var isRestoring = false

    private var isDeciding = false
    private var waitingKeystrokes: [Direction] = []

    private var registeredWhileDeciding = false

    private enum Direction {
        case undo
        case redo
    }

    public init(
        capacity: Int = 50, coalescingWindow: TimeInterval = 5,
        now: @escaping () -> Date = Date.init
    ) {
        self.capacity = capacity
        self.coalescingWindow = coalescingWindow
        self.now = now
    }

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    public func registerMove(
        label: String, undo: @escaping () -> Bool, redo: @escaping () -> Bool
    ) {
        guard !isRestoring else { return }
        noteRegistration()
        undoStack.append(Entry(label: label, undo: { .done(undo()) }, redo: { .done(redo()) }, registeredAt: now()))
        if undoStack.count > capacity {
            undoStack.removeFirst(undoStack.count - capacity)
        }
        redoStack.removeAll()
    }

    public func registerEdit(
        key: String, label: String,
        undo: @escaping () -> Bool, redo: @escaping () -> Bool
    ) {
        registerEdit(key: key, label: label, undoing: { .done(undo()) }, redoing: { .done(redo()) })
    }

    public func registerEdit(
        key: String, label: String,
        undoing undo: @escaping () -> Step, redoing redo: @escaping () -> Step
    ) {
        guard !isRestoring else { return }
        noteRegistration()
        if let top = undoStack.last, top.coalescingKey == key,
           now().timeIntervalSince(top.registeredAt) < coalescingWindow {
            undoStack[undoStack.count - 1] = Entry(
                label: top.label, undo: top.undo, redo: redo,
                coalescingKey: key, registeredAt: now()
            )
            redoStack.removeAll()
            return
        }
        undoStack.append(Entry(
            label: label, undo: undo, redo: redo,
            coalescingKey: key, registeredAt: now()
        ))
        if undoStack.count > capacity {
            undoStack.removeFirst(undoStack.count - capacity)
        }
        redoStack.removeAll()
    }

    public func registerReorder(
        label: String, before: [String], after: [String],
        apply: @escaping ([String]) -> Bool
    ) {
        guard before != after, before.count == after.count,
              Set(before) == Set(after) else { return }
        registerMove(label: label, undo: { apply(before) }, redo: { apply(after) })
    }

    public func registerBoardMove(
        label: String, before: BoardOrder, after: BoardOrder,
        apply: @escaping (BoardOrder) -> Bool
    ) {
        guard before != after, before.membership == after.membership else { return }
        registerMove(label: label, undo: { apply(before) }, redo: { apply(after) })
    }

    public func registerRemoval<Element: Sendable>(
        label: String, removal: ListRemoval<Element>,
        update: @escaping (@escaping @Sendable (inout [Element]) -> Void) -> Bool
    ) {
        registerMove(
            label: label,
            undo: { update { removal.restore(into: &$0) } },
            redo: { update { removal.remove(from: &$0) } }
        )
    }

    public func registerInsertion<Element: Sendable>(
        label: String, insertion: ListInsertion<Element>,
        update: @escaping (@escaping @Sendable (inout [Element]) -> Void) -> Bool
    ) {
        registerMove(
            label: label,
            undo: { update { insertion.remove(from: &$0) } },
            redo: { update { insertion.restore(into: &$0) } }
        )
    }

    @discardableResult
    public func undo() -> Bool {
        press(.undo)
    }

    @discardableResult
    public func redo() -> Bool {
        press(.redo)
    }

    public func whileRestoring<T>(_ body: () -> T) -> T {
        let was = isRestoring
        isRestoring = true
        defer { isRestoring = was }
        return body()
    }

    private func press(_ direction: Direction) -> Bool {
        if isDeciding {
            waitingKeystrokes.append(direction)
            return true
        } else {
            return step(direction)
        }
    }

    private func step(_ direction: Direction) -> Bool {
        var outcome: Bool?
        while outcome == nil, let entry = direction == .undo ? undoStack.popLast() : redoStack.popLast() {
            switch whileRestoring({ direction == .undo ? entry.undo() : entry.redo() }) {
            case .done(let applied):
                if applied {
                    trail(entry, direction)
                    outcome = true
                }
            case .later(let answer):
                isDeciding = true
                registeredWhileDeciding = false
                Task { [weak self] in
                    let applied = await answer.value
                    self?.decided(entry, direction, applied: applied)
                }
                outcome = true
            }
        }
        return outcome ?? false
    }

    private func decided(_ entry: Entry, _ direction: Direction, applied: Bool) {
        isDeciding = false
        if applied {
            if !registeredWhileDeciding { trail(entry, direction) }
        } else {
            _ = step(direction)
        }
        while !isDeciding, !waitingKeystrokes.isEmpty {
            _ = step(waitingKeystrokes.removeFirst())
        }
    }

    private func trail(_ entry: Entry, _ direction: Direction) {
        switch direction {
        case .undo: redoStack.append(entry)
        case .redo: undoStack.append(entry)
        }
    }

    private func noteRegistration() {
        if isDeciding { registeredWhileDeciding = true }
    }
}

public struct BoardOrder: Equatable, Sendable {
    public var nodes: [String]

    public var memberships: [String: [String]]

    public init(nodes: [String], memberships: [String: [String]]) {
        self.nodes = nodes
        self.memberships = memberships
    }

    public var membership: Set<String> {
        memberships.values.reduce(into: Set(nodes)) { $0.formUnion($1) }
    }
}

public enum ListOrder {
    public static func apply<Element>(
        _ order: [String], to items: [Element], id: (Element) -> String
    ) -> [Element] {
        let rank = Dictionary(
            order.enumerated().map { ($1, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return items.enumerated()
            .sorted { a, b in
                let rankA = rank[id(a.element)] ?? Int.max
                let rankB = rank[id(b.element)] ?? Int.max
                return rankA == rankB ? a.offset < b.offset : rankA < rankB
            }
            .map(\.element)
    }
}

public struct SlideOrder: Equatable, Sendable {
    public var ids: [String]
    public var sections: [String: String?]

    public init(slides: [Slide]) {
        ids = slides.map(\.id)
        sections = Dictionary(
            slides.map { ($0.id, $0.sectionId) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    public func apply(to slides: [Slide]) -> [Slide] {
        var restored = ListOrder.apply(ids, to: slides, id: \.id)
        for index in restored.indices {
            if let section = sections[restored[index].id] {
                restored[index].sectionId = section
            }
        }
        return restored
    }
}

public struct ListRemoval<Element> {
    public let removed: [(index: Int, element: Element)]
    public let ids: Set<String>
    private let id: @Sendable (Element) -> String

    public init?(before: [Element], after: [Element], id: @escaping @Sendable (Element) -> String) {
        let afterIDs = after.map(id)
        guard afterIDs.count < before.count else { return nil }
        let remaining = Set(afterIDs)
        var removed: [(index: Int, element: Element)] = []
        var survivors: [String] = []
        for (index, element) in before.enumerated() {
            let key = id(element)
            if remaining.contains(key) {
                survivors.append(key)
            } else {
                removed.append((index, element))
            }
        }
        guard !removed.isEmpty, survivors == afterIDs else { return nil }
        self.removed = removed
        self.ids = Set(removed.map { id($0.element) })
        self.id = id
    }

    public func restore(into list: inout [Element]) {
        var present = Set(list.map(id))
        for entry in removed where !present.contains(id(entry.element)) {
            list.insert(entry.element, at: min(entry.index, list.count))
            present.insert(id(entry.element))
        }
    }

    public func remove(from list: inout [Element]) {
        list.removeAll { ids.contains(id($0)) }
    }
}

public struct ListInsertion<Element> {
    private let removal: ListRemoval<Element>

    public init?(before: [Element], after: [Element], id: @escaping @Sendable (Element) -> String) {
        if let removal = ListRemoval(before: after, after: before, id: id) {
            self.removal = removal
        } else {
            return nil
        }
    }

    public var added: [(index: Int, element: Element)] { removal.removed }
    public var ids: Set<String> { removal.ids }

    public func remove(from list: inout [Element]) { removal.remove(from: &list) }
    public func restore(into list: inout [Element]) { removal.restore(into: &list) }
}

extension ListRemoval: Sendable where Element: Sendable {}
extension ListInsertion: Sendable where Element: Sendable {}

struct ListMove: Equatable {
    let from: Int
    let before: Int?

    init?(before old: [String], after new: [String]) {
        let differing = old.indices.filter { new.indices.contains($0) && old[$0] != new[$0] }
        if old.count == new.count, let low = differing.first, let high = differing.last,
           let move = Self.move(old, new, low: low, high: high) {
            (from, before) = move
        } else {
            return nil
        }
    }

    private static func move(_ old: [String], _ new: [String], low: Int, high: Int) -> (Int, Int?)? {
        if new[high] == old[low], old[(low + 1)...high].elementsEqual(new[low..<high]) {
            (low, high + 1 < old.count ? high + 1 : nil)
        } else if new[low] == old[high], old[low..<high].elementsEqual(new[(low + 1)...high]) {
            (high, low)
        } else {
            nil
        }
    }
}
