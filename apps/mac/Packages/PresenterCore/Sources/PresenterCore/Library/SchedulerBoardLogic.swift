import Foundation

public extension SchedulerBoard {

    var allTriggerIDs: [String] {
        nodes.flatMap { id -> [String] in
            if let folder = folder(id: id) { return folder.triggerIds }
            return [id]
        }
    }

    func folder(id: String) -> ScheduleFolder? {
        folders.first { $0.id == id }
    }

    func folder(containing triggerID: String) -> ScheduleFolder? {
        folders.first { $0.triggerIds.contains(triggerID) }
    }

    func folderEnabled(forTrigger triggerID: String) -> Bool {
        guard let folder = folder(containing: triggerID) else { return true }
        return folder.enabled ?? true
    }

    @discardableResult
    mutating func addFolder(named name: String, id: String = UUID().uuidString) -> String {
        let folder = ScheduleFolder(id: id, name: name, triggerIds: [])
        folders.append(folder)
        nodes.append(folder.id)
        return folder.id
    }

    mutating func renameFolder(id: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        mutateFolder(id) { $0.name = trimmed }
    }

    mutating func setFolderEnabled(id: String, _ enabled: Bool) {

        mutateFolder(id) { $0.enabled = enabled ? nil : false }
    }

    mutating func setFolderCollapsed(id: String, _ collapsed: Bool) {
        mutateFolder(id) { $0.collapsed = collapsed ? true : nil }
    }

    mutating func removeFolder(id: String) {
        guard let folder = folder(id: id),
              let index = nodes.firstIndex(of: id) else { return }
        nodes.replaceSubrange(index ... index, with: folder.triggerIds)
        folders.removeAll { $0.id == id }
    }

    mutating func placeTrigger(id: String, afterSibling siblingID: String) {
        guard !knowsTrigger(id) else { return }
        if let host = folder(containing: siblingID) {
            mutateFolder(host.id) { folder in
                let at = folder.triggerIds.firstIndex(of: siblingID)
                    .map { $0 + 1 } ?? folder.triggerIds.count
                folder.triggerIds.insert(id, at: at)
            }
        } else {
            let at = nodes.firstIndex(of: siblingID).map { $0 + 1 } ?? nodes.count
            nodes.insert(id, at: min(at, nodes.count))
        }
    }

    @discardableResult
    mutating func duplicateFolder(id: String, memberIDs: [String], copyID: String = UUID().uuidString) -> String? {
        guard let source = folder(id: id) else { return nil }
        var copy = source
        copy.id = copyID
        copy.name = source.name + " Copy"
        copy.triggerIds = memberIDs.filter { !knowsTrigger($0) }
        folders.append(copy)
        let at = nodes.firstIndex(of: id).map { $0 + 1 } ?? nodes.count
        nodes.insert(copy.id, at: min(at, nodes.count))
        return copy.id
    }

    mutating func moveTrigger(id: String, beforeNode nodeID: String?) {
        guard knowsTrigger(id), id != nodeID else { return }

        if let nodeID, let host = folder(containing: nodeID), host.id != id {
            detachTrigger(id)
            mutateFolder(host.id) { folder in
                let at = folder.triggerIds.firstIndex(of: nodeID) ?? folder.triggerIds.count
                folder.triggerIds.insert(id, at: at)
            }
        } else {
            detachTrigger(id)
            let at = nodeID.flatMap { target in nodes.firstIndex(of: target) } ?? nodes.count
            nodes.insert(id, at: min(at, nodes.count))
        }
    }

    mutating func moveTrigger(id: String, intoFolder folderID: String) {
        guard knowsTrigger(id), folder(id: folderID) != nil else { return }
        detachTrigger(id)
        mutateFolder(folderID) { $0.triggerIds.append(id) }
    }

    mutating func moveFolder(id: String, beforeNode nodeID: String?) {
        guard id != nodeID, folder(id: id) != nil,
              let from = nodes.firstIndex(of: id) else { return }
        let resolvedTarget = nodeID.map { target in
            folder(containing: target)?.id ?? target
        }
        guard resolvedTarget != id else { return }
        nodes.remove(at: from)
        let at = resolvedTarget.flatMap { target in nodes.firstIndex(of: target) } ?? nodes.count
        nodes.insert(id, at: min(at, nodes.count))
    }

    var orderSnapshot: BoardOrder {
        BoardOrder(
            nodes: nodes,
            memberships: Dictionary(
                folders.map { ($0.id, $0.triggerIds) },
                uniquingKeysWith: { first, _ in first }
            )
        )
    }

    mutating func restore(order: BoardOrder) {
        let currentOrdered = allTriggerIDs
        let currentTriggers = Set(currentOrdered)
        let currentFolderIDs = Set(folders.map(\.id))
        for index in folders.indices {
            guard let members = order.memberships[folders[index].id] else { continue }
            folders[index].triggerIds = members.filter { currentTriggers.contains($0) }
        }
        var restored = order.nodes.filter {
            currentTriggers.contains($0) || currentFolderIDs.contains($0)
        }
        for id in folders.map(\.id) where !restored.contains(id) {
            restored.append(id)
        }

        let foldered = Set(folders.flatMap(\.triggerIds))
        restored.removeAll { foldered.contains($0) && !currentFolderIDs.contains($0) }
        nodes = restored
        let placed = Set(allTriggerIDs)
        for id in currentOrdered where !placed.contains(id) {
            nodes.append(id)
        }
    }

    mutating func reconcile(withTriggerIDs triggerIDs: [String]) {
        let known = Set(triggerIDs)
        let folderIDs = Set(folders.map(\.id))
        nodes = nodes.filter { known.contains($0) || folderIDs.contains($0) }

        for folder in folders where !nodes.contains(folder.id) {
            nodes.append(folder.id)
        }
        for index in folders.indices {
            folders[index].triggerIds.removeAll { !known.contains($0) }
        }
        let present = Set(allTriggerIDs)
        for id in triggerIDs where !present.contains(id) {
            nodes.append(id)
        }
    }

    private func knowsTrigger(_ id: String) -> Bool {
        allTriggerIDs.contains(id)
    }

    private mutating func detachTrigger(_ id: String) {

        let folderIDs = Set(folders.map(\.id))
        nodes.removeAll { $0 == id && !folderIDs.contains(id) }
        for index in folders.indices {
            folders[index].triggerIds.removeAll { $0 == id }
        }
    }

    private mutating func mutateFolder(_ id: String, _ change: (inout ScheduleFolder) -> Void) {
        guard let index = folders.firstIndex(where: { $0.id == id }) else { return }
        change(&folders[index])
    }
}
