import Foundation

public struct InputTrail: Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        public let what: String
        public let at: TimeInterval
    }

    public static let capacity = 4

    public private(set) var entries: [Entry] = []

    public init() {}

    public mutating func record(_ what: String, at time: TimeInterval) {
        if entries.last?.what == what {
            entries[entries.count - 1] = Entry(what: what, at: time)
        } else {
            entries.append(Entry(what: what, at: time))
            if entries.count > Self.capacity {
                entries.removeFirst(entries.count - Self.capacity)
            }
        }
    }

    public func summary(at now: TimeInterval) -> String {
        if entries.isEmpty {
            "no input yet"
        } else {
            entries.reversed()
                .map { "\($0.what) \(String(format: "%.2f", max(0, now - $0.at))) s ago" }
                .joined(separator: " · ")
        }
    }

    public func age(of prefix: String, at now: TimeInterval) -> TimeInterval? {
        entries.last { $0.what.hasPrefix(prefix) }.map { now - $0.at }
    }

    public static func keyName(
        keyCode: UInt16, characters: String?,
        command: Bool = false, option: Bool = false, control: Bool = false, shift: Bool = false
    ) -> String {
        let named: [UInt16: String] = [
            123: "←", 124: "→", 125: "↓", 126: "↑",
            116: "page up", 121: "page down", 115: "home", 119: "end",
            36: "return", 76: "enter", 49: "space", 48: "tab", 53: "esc",
            51: "delete", 117: "forward delete",
        ]
        let key = named[keyCode]
            ?? characters.flatMap { $0.isEmpty ? nil : $0.lowercased() }
            ?? "code \(keyCode)"
        let modifiers = (control ? "⌃" : "") + (option ? "⌥" : "") + (shift ? "⇧" : "") + (command ? "⌘" : "")
        return modifiers + key
    }
}

public enum PresentJumpRule {

    public static let viewportShare: CGFloat = 0.75

    public static let scrollWindow: TimeInterval = 0.5

    public static let focusWindow: TimeInterval = 1.0

    public static func isUnprompted(
        delta: CGFloat, viewport: CGFloat,
        sinceScroll: TimeInterval?, sinceFocus: TimeInterval?
    ) -> Bool {
        viewport > 0
            && abs(delta) >= viewport * viewportShare
            && (sinceScroll ?? .infinity) > scrollWindow
            && (sinceFocus ?? .infinity) > focusWindow
    }

    public static func isReflow(delta: CGFloat, offset: CGFloat, viewport: CGFloat) -> Bool {
        viewport > 0 && offset > 0 && abs(delta) >= viewport * viewportShare
    }
}

public enum PresentLanding {
    public struct Card: Equatable, Sendable {
        public let id: String
        public let top: CGFloat
        public let height: CGFloat

        public init(id: String, top: CGFloat, height: CGFloat) {
            self.id = id
            self.top = top
            self.height = height
        }
    }

    public static func cardAtTop(_ cards: [Card]) -> Card? {
        cards.first { $0.top <= 1 && $0.top + $0.height > 1 }
            ?? cards.filter { $0.top > 1 }.min { $0.top < $1.top }
    }

    public struct Grid: Equatable, Sendable {
        public let id: String
        public let top: CGFloat
        public let rowPitch: CGFloat
        public let across: Int
        public let count: Int

        public init(id: String, top: CGFloat, rowPitch: CGFloat, across: Int, count: Int) {
            self.id = id
            self.top = top
            self.rowPitch = rowPitch
            self.across = across
            self.count = count
        }
    }

    public struct Anchor: Equatable, Sendable {
        public let id: String
        public let fraction: CGFloat
        public let slide: Int?
        public let intoRow: CGFloat

        public init(id: String, fraction: CGFloat, slide: Int? = nil, intoRow: CGFloat = 0) {
            self.id = id
            self.fraction = fraction
            self.slide = slide
            self.intoRow = intoRow
        }
    }

    public static func anchor(_ cards: [Card], grids: [Grid] = []) -> Anchor? {
        cardAtTop(cards).map { card in
            let fraction = card.height > 0 ? min(max(-card.top / card.height, 0), 1) : 0
            let grid = grids.first { $0.id == card.id }
            if let grid, grid.top <= 0, grid.rowPitch > 0, grid.across > 0, grid.count > 0 {
                let rows = (grid.count + grid.across - 1) / grid.across
                let row = min(Int(-grid.top / grid.rowPitch), rows - 1)
                let intoRow = min((-grid.top - CGFloat(row) * grid.rowPitch) / grid.rowPitch, 1)
                return Anchor(id: card.id, fraction: fraction, slide: row * grid.across, intoRow: intoRow)
            } else {
                return Anchor(id: card.id, fraction: fraction)
            }
        }
    }

    public static func correction(for anchor: Anchor, in cards: [Card], grids: [Grid] = []) -> CGFloat? {
        let grid = grids.first { $0.id == anchor.id }
        if let slide = anchor.slide, let grid, grid.across > 0, grid.rowPitch > 0 {
            let row = CGFloat(min(slide, max(grid.count - 1, 0)) / grid.across)
            return grid.top + row * grid.rowPitch + anchor.intoRow * grid.rowPitch
        } else {
            return cards.first { $0.id == anchor.id }.map { $0.top + anchor.fraction * $0.height }
        }
    }

    public static func rowTop(slide: Int, in grid: Grid) -> CGFloat {
        let row = min(max(slide, 0), max(grid.count - 1, 0)) / max(grid.across, 1)
        return grid.top + CGFloat(row) * grid.rowPitch
    }

    public static func reveal(
        rowTop: CGFloat, rowPitch: CGFloat, viewport: CGFloat, topInset: CGFloat, margin: CGFloat = 12
    ) -> CGFloat? {
        let top = topInset + margin
        let room = viewport - top
        let bandTop = top + room / 4
        let bandBottom = top + room * 3 / 4
        if rowTop < bandTop {
            return rowTop - bandTop
        } else if rowTop + rowPitch > bandBottom {

            return min(rowTop + rowPitch - bandBottom, rowTop - bandTop)
        } else {
            return nil
        }
    }
}

public enum PresentHold {

    public static func correction(heldTop: CGFloat, nowTop: CGFloat) -> CGFloat? {
        let delta = nowTop - heldTop
        return abs(delta) >= 1 ? delta : nil
    }

    public static let burst = 6
    public static let window: TimeInterval = 1

    public static func mayCorrect(recent: [TimeInterval], now: TimeInterval) -> Bool {
        recent.filter { now - $0 < window }.count < burst
    }

    public static func recording(_ time: TimeInterval, in recent: [TimeInterval]) -> [TimeInterval] {
        (recent.filter { time - $0 < window } + [time]).suffix(burst)
    }

    public static func changes(
        before: [String: CGFloat], after: [String: CGFloat], names: [String: String], limit: Int = 3
    ) -> String {
        let moved = after.compactMap { id, height -> (String, CGFloat)? in
            before[id].flatMap { old in abs(height - old) >= 1 ? (id, height - old) : nil }
        }
        let top = moved.sorted { abs($0.1) > abs($1.1) }.prefix(limit)
        return top.isEmpty
            ? "no card changed height"
            : top.map { "\"\(names[$0.0] ?? $0.0)\" \($0.1 > 0 ? "+" : "")\(Int($0.1))" }.joined(separator: ", ")
    }
}
