import Foundation

public struct TimerBoard: Codable, Sendable, Equatable {
    public struct Folder: Codable, Sendable, Equatable, Identifiable {
        public var id: String
        public var name: String
        public var collapsed: Bool
        public var timerIDs: [String]

        public init(
            id: String = UUID().uuidString, name: String,
            collapsed: Bool = false, timerIDs: [String] = []
        ) {
            self.id = id
            self.name = name
            self.collapsed = collapsed
            self.timerIDs = timerIDs
        }
    }

    public enum Node: Codable, Sendable, Equatable {
        case timer(String)
        case folder(Folder)

        public var id: String {
            switch self {
            case .timer(let id): id
            case .folder(let folder): folder.id
            }
        }
    }

    public private(set) var nodes: [Node]

    public init(nodes: [Node] = []) {
        self.nodes = nodes
    }

    public var allTimerIDs: [String] {
        nodes.flatMap { node -> [String] in
            switch node {
            case .timer(let id): [id]
            case .folder(let folder): folder.timerIDs
            }
        }
    }

    public func folder(id: String) -> Folder? {
        for case .folder(let folder) in nodes where folder.id == id { return folder }
        return nil
    }

    public func folder(containing timerID: String) -> Folder? {
        for case .folder(let folder) in nodes where folder.timerIDs.contains(timerID) {
            return folder
        }
        return nil
    }

    public func filteredTimerIDs(matching query: String, name: (String) -> String?) -> [String] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return allTimerIDs }
        func matches(_ text: String?) -> Bool {
            text?.localizedCaseInsensitiveContains(trimmed) ?? false
        }
        return nodes.flatMap { node -> [String] in
            switch node {
            case .timer(let id):
                return matches(name(id)) ? [id] : []
            case .folder(let folder):
                if matches(folder.name) { return folder.timerIDs }
                return folder.timerIDs.filter { matches(name($0)) }
            }
        }
    }

    @discardableResult
    public mutating func addFolder(named name: String) -> String {
        let folder = Folder(name: name)
        nodes.append(.folder(folder))
        return folder.id
    }

    public mutating func ensureFolder(id: String, name: String) {
        guard folder(id: id) == nil else { return }
        nodes.append(.folder(Folder(id: id, name: name)))
    }

    public mutating func renameFolder(id: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        mutateFolder(id) { $0.name = trimmed }
    }

    public mutating func setCollapsed(id: String, _ collapsed: Bool) {
        mutateFolder(id) { $0.collapsed = collapsed }
    }

    public mutating func removeFolder(id: String) {
        guard let index = nodes.firstIndex(where: { $0.id == id }),
              case .folder(let folder) = nodes[index] else { return }
        nodes.replaceSubrange(index ... index, with: folder.timerIDs.map(Node.timer))
    }

    public mutating func moveTimer(id: String, beforeNode nodeID: String?) {
        guard knowsTimer(id), id != nodeID else { return }

        if let nodeID, let host = folder(containing: nodeID), host.id != id {
            detachTimer(id)
            mutateFolder(host.id) { folder in
                let at = folder.timerIDs.firstIndex(of: nodeID) ?? folder.timerIDs.count
                folder.timerIDs.insert(id, at: at)
            }
        } else {
            detachTimer(id)
            let at = nodeID.flatMap { target in
                nodes.firstIndex { $0.id == target }
            } ?? nodes.count
            nodes.insert(.timer(id), at: min(at, nodes.count))
        }
    }

    public mutating func moveTimer(id: String, intoFolder folderID: String) {
        guard knowsTimer(id), folder(id: folderID) != nil else { return }
        detachTimer(id)
        mutateFolder(folderID) { $0.timerIDs.append(id) }
    }

    public mutating func moveFolder(id: String, beforeNode nodeID: String?) {
        guard id != nodeID,
              let from = nodes.firstIndex(where: { $0.id == id }),
              case .folder = nodes[from] else { return }
        let resolvedTarget = nodeID.map { target in
            folder(containing: target)?.id ?? target
        }
        guard resolvedTarget != id else { return }
        let node = nodes.remove(at: from)
        let at = resolvedTarget.flatMap { target in
            nodes.firstIndex { $0.id == target }
        } ?? nodes.count
        nodes.insert(node, at: min(at, nodes.count))
    }

    public var orderSnapshot: TimerBoardOrder {
        TimerBoardOrder(
            nodeIDs: nodes.map(\.id),
            memberships: Dictionary(
                nodes.compactMap { node in
                    guard case .folder(let folder) = node else { return nil }
                    return (folder.id, folder.timerIDs)
                },
                uniquingKeysWith: { first, _ in first }
            )
        )
    }

    public mutating func restore(order: TimerBoardOrder) {
        let currentOrdered = allTimerIDs
        let currentTimers = Set(currentOrdered)
        var foldersByID: [String: Folder] = [:]
        var folderOrder: [String] = []
        for case .folder(var folder) in nodes {
            if let members = order.memberships[folder.id] {
                folder.timerIDs = members.filter { currentTimers.contains($0) }
            }
            foldersByID[folder.id] = folder
            folderOrder.append(folder.id)
        }
        let foldered = Set(foldersByID.values.flatMap(\.timerIDs))
        var restored: [Node] = order.nodeIDs.compactMap { id in
            if let folder = foldersByID[id] { return .folder(folder) }

            guard currentTimers.contains(id), !foldered.contains(id) else { return nil }
            return .timer(id)
        }
        let placedFolders = Set(restored.compactMap { node -> String? in
            guard case .folder(let folder) = node else { return nil }
            return folder.id
        })
        for id in folderOrder where !placedFolders.contains(id) {
            if let folder = foldersByID[id] { restored.append(.folder(folder)) }
        }
        nodes = restored
        let placed = Set(allTimerIDs)
        for id in currentOrdered where !placed.contains(id) {
            nodes.append(.timer(id))
        }
    }

    public mutating func reconcile(with timerIDs: [String]) {
        let known = Set(timerIDs)
        nodes = nodes.compactMap { node in
            switch node {
            case .timer(let id):
                return known.contains(id) ? node : nil
            case .folder(var folder):
                folder.timerIDs.removeAll { !known.contains($0) }
                return .folder(folder)
            }
        }
        let present = Set(allTimerIDs)
        for id in timerIDs where !present.contains(id) {
            nodes.append(.timer(id))
        }
    }

    private func knowsTimer(_ id: String) -> Bool {
        allTimerIDs.contains(id)
    }

    private mutating func detachTimer(_ id: String) {
        nodes = nodes.compactMap { node in
            switch node {
            case .timer(let timerID):
                return timerID == id ? nil : node
            case .folder(var folder):
                folder.timerIDs.removeAll { $0 == id }
                return .folder(folder)
            }
        }
    }

    private mutating func mutateFolder(_ id: String, _ change: (inout Folder) -> Void) {
        guard let index = nodes.firstIndex(where: { $0.id == id }),
              case .folder(var folder) = nodes[index] else { return }
        change(&folder)
        nodes[index] = .folder(folder)
    }
}

public struct TimerBoardOrder: Equatable, Sendable {
    public var nodeIDs: [String]

    public var memberships: [String: [String]]

    public init(nodeIDs: [String], memberships: [String: [String]]) {
        self.nodeIDs = nodeIDs
        self.memberships = memberships
    }

    public var membership: Set<String> {
        memberships.values.reduce(into: Set(nodeIDs)) { $0.formUnion($1) }
    }
}

extension TimerBoard {

    public static func featured(in timers: [TimerSnapshot], at date: Date) -> TimerSnapshot? {
        timers
            .filter(\.isLive)
            .min { remaining($0, at: date) < remaining($1, at: date) }
    }

    public static func rollupUrgency(
        of timers: [TimerSnapshot], at date: Date
    ) -> TimerSnapshot.Urgency {
        var rollup = TimerSnapshot.Urgency.normal
        for timer in timers {
            switch timer.urgency(at: date) {
            case .overrun: return .overrun
            case .warning: rollup = .warning
            case .normal: break
            }
        }
        return rollup
    }

    public static func rollupWarning(
        of timers: [TimerSnapshot], at date: Date
    ) -> TimerWarning? {
        timers
            .compactMap { $0.activeWarning(at: date) }
            .min { $0.remainingSeconds < $1.remainingSeconds }
    }

    private static func remaining(_ timer: TimerSnapshot, at date: Date) -> TimeInterval {
        switch timer.mode {
        case .countdown, .countdownToTime:
            return timer.value(at: date)
        case .countUp:
            guard timer.durationSeconds > 0 else { return .infinity }
            return timer.durationSeconds - timer.elapsed(at: date)
        }
    }
}
