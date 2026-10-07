import Foundation

public struct PlaylistQueue: Sendable, Equatable {

    public enum RepeatBehavior: Sendable, Equatable {
        case none
        case playlist
        case single
    }

    public private(set) var entryIDs: [String]
    public var repeatBehavior: RepeatBehavior
    public private(set) var isShuffled: Bool

    private var order: [Int]

    private var cursor: Int?

    public init(
        entryIDs: [String],
        repeatBehavior: RepeatBehavior = .none,
        shuffled: Bool = false
    ) {
        self.entryIDs = entryIDs
        self.repeatBehavior = repeatBehavior
        self.isShuffled = shuffled
        self.order = Array(entryIDs.indices)
        self.cursor = nil
    }

    public var currentEntryID: String? {
        guard let cursor, order.indices.contains(cursor) else { return nil }
        return entryIDs[order[cursor]]
    }

    public var positionInPass: (index: Int, count: Int)? {
        guard let cursor, order.indices.contains(cursor) else { return nil }
        return (cursor + 1, order.count)
    }

    public mutating func start<R: RandomNumberGenerator>(
        at entryID: String? = nil, using rng: inout R
    ) {
        guard !entryIDs.isEmpty else { return }
        let chosen = entryID.flatMap { id in entryIDs.firstIndex(of: id) } ?? {
            isShuffled ? Int.random(in: entryIDs.indices, using: &rng) : 0
        }()
        if isShuffled {
            var rest = Array(entryIDs.indices.filter { $0 != chosen })
            rest.shuffle(using: &rng)
            order = [chosen] + rest
        } else {
            order = Array(entryIDs.indices)
        }
        cursor = order.firstIndex(of: chosen)
    }

    public mutating func start(at entryID: String? = nil) {
        var rng = SystemRandomNumberGenerator()
        start(at: entryID, using: &rng)
    }

    public mutating func next<R: RandomNumberGenerator>(using rng: inout R) -> String? {
        step(using: &rng)
    }

    public mutating func next() -> String? {
        var rng = SystemRandomNumberGenerator()
        return next(using: &rng)
    }

    public mutating func previous() -> String? {
        guard !order.isEmpty else { return nil }
        guard let position = cursor else {
            cursor = 0
            return currentEntryID
        }
        if position > 0 {
            cursor = position - 1
        } else if repeatBehavior != .none {
            cursor = order.count - 1
        }
        return currentEntryID
    }

    public mutating func advanceAfterNaturalEnd<R: RandomNumberGenerator>(
        using rng: inout R
    ) -> String? {
        if repeatBehavior == .single { return currentEntryID }
        return step(using: &rng)
    }

    public mutating func advanceAfterNaturalEnd() -> String? {
        var rng = SystemRandomNumberGenerator()
        return advanceAfterNaturalEnd(using: &rng)
    }

    private mutating func step<R: RandomNumberGenerator>(using rng: inout R) -> String? {
        guard !order.isEmpty else { return nil }
        guard let position = cursor else {
            start(using: &rng)
            return currentEntryID
        }
        if position + 1 < order.count {
            cursor = position + 1
            return currentEntryID
        }
        guard repeatBehavior != .none else {
            cursor = nil
            return nil
        }

        if isShuffled {
            let justPlayed = order[position]
            order.shuffle(using: &rng)
            if order.count > 1, order[0] == justPlayed {
                order.swapAt(0, Int.random(in: 1 ..< order.count, using: &rng))
            }
        }
        cursor = 0
        return currentEntryID
    }

    public mutating func setShuffled<R: RandomNumberGenerator>(
        _ shuffled: Bool, using rng: inout R
    ) {
        guard shuffled != isShuffled else { return }
        isShuffled = shuffled
        let currentIndex = cursor.flatMap { order.indices.contains($0) ? order[$0] : nil }
        if shuffled {
            guard let currentIndex else { return }
            var rest = Array(entryIDs.indices.filter { $0 != currentIndex })
            rest.shuffle(using: &rng)
            order = [currentIndex] + rest
            cursor = 0
        } else {
            order = Array(entryIDs.indices)
            cursor = currentIndex
        }
    }

    public mutating func setShuffled(_ shuffled: Bool) {
        var rng = SystemRandomNumberGenerator()
        setShuffled(shuffled, using: &rng)
    }

    public mutating func updateEntries<R: RandomNumberGenerator>(
        _ newEntryIDs: [String], using rng: inout R
    ) {
        let currentID = currentEntryID
        let oldIDs = entryIDs
        entryIDs = newEntryIDs
        guard !newEntryIDs.isEmpty else {
            order = []
            cursor = nil
            return
        }
        let newIndexByID = Dictionary(
            newEntryIDs.enumerated().map { ($1, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var seen = Set<Int>()
        var survivors: [Int] = []
        for oldIndex in order {
            guard oldIDs.indices.contains(oldIndex),
                  let newIndex = newIndexByID[oldIDs[oldIndex]],
                  seen.insert(newIndex).inserted
            else { continue }
            survivors.append(newIndex)
        }
        var added = newEntryIDs.indices.filter { !seen.contains($0) }
        if isShuffled {
            added.shuffle(using: &rng)
            order = survivors + added
        } else {
            order = Array(newEntryIDs.indices)
        }
        if let currentID, let newIndex = newIndexByID[currentID] {
            cursor = order.firstIndex(of: newIndex)
        } else if cursor != nil {

            cursor = nil
        }
    }

    public mutating func updateEntries(_ newEntryIDs: [String]) {
        var rng = SystemRandomNumberGenerator()
        updateEntries(newEntryIDs, using: &rng)
    }
}
