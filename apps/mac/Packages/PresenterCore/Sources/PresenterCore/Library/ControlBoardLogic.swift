import Foundation

public extension ControlBoard {

    var allItemIDs: [String] {
        nodes.flatMap { id -> [String] in
            if let folder = folder(id: id) { return folder.itemIds }
            return [id]
        }
    }

    func folder(id: String) -> ControlFolder? {
        folders.first { $0.id == id }
    }

    var orderedFolders: [ControlFolder] {
        nodes.compactMap { folder(id: $0) }
    }

    func folder(containing itemID: String) -> ControlFolder? {
        folders.first { $0.itemIds.contains(itemID) }
    }

    func filteredItemIDs(matching query: String, name: (String) -> String?) -> [String] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return allItemIDs }
        func matches(_ text: String?) -> Bool {
            text?.localizedCaseInsensitiveContains(trimmed) ?? false
        }
        return nodes.flatMap { id -> [String] in
            if let folder = folder(id: id) {
                if matches(folder.name) { return folder.itemIds }
                return folder.itemIds.filter { matches(name($0)) }
            }
            return matches(name(id)) ? [id] : []
        }
    }

    @discardableResult
    mutating func addFolder(named name: String, id: String = UUID().uuidString) -> String {
        let folder = ControlFolder(id: id, name: name, itemIds: [])
        folders.append(folder)
        nodes.append(folder.id)
        return folder.id
    }

    mutating func renameFolder(id: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        mutateFolder(id) { $0.name = trimmed }
    }

    mutating func setFolderCollapsed(id: String, _ collapsed: Bool) {
        mutateFolder(id) { $0.collapsed = collapsed ? true : nil }
    }

    mutating func removeFolder(id: String) {
        guard let folder = folder(id: id),
              let index = nodes.firstIndex(of: id) else { return }
        nodes.replaceSubrange(index ... index, with: folder.itemIds)
        folders.removeAll { $0.id == id }
    }

    mutating func moveItem(id: String, beforeNode nodeID: String?) {
        guard knowsItem(id), id != nodeID else { return }

        if let nodeID, let host = folder(containing: nodeID), host.id != id {
            detachItem(id)
            mutateFolder(host.id) { folder in
                let at = folder.itemIds.firstIndex(of: nodeID) ?? folder.itemIds.count
                folder.itemIds.insert(id, at: at)
            }
        } else {
            detachItem(id)
            let at = nodeID.flatMap { target in nodes.firstIndex(of: target) } ?? nodes.count
            nodes.insert(id, at: min(at, nodes.count))
        }
    }

    mutating func moveItem(id: String, intoFolder folderID: String) {
        guard knowsItem(id), folder(id: folderID) != nil else { return }
        detachItem(id)
        mutateFolder(folderID) { $0.itemIds.append(id) }
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
                folders.map { ($0.id, $0.itemIds) },
                uniquingKeysWith: { first, _ in first }
            )
        )
    }

    mutating func restore(order: BoardOrder) {
        let currentOrdered = allItemIDs
        let currentItems = Set(currentOrdered)
        let currentFolderIDs = Set(folders.map(\.id))
        for index in folders.indices {
            guard let members = order.memberships[folders[index].id] else { continue }
            folders[index].itemIds = members.filter { currentItems.contains($0) }
        }
        var restored = order.nodes.filter {
            currentItems.contains($0) || currentFolderIDs.contains($0)
        }
        for id in folders.map(\.id) where !restored.contains(id) {
            restored.append(id)
        }

        let foldered = Set(folders.flatMap(\.itemIds))
        restored.removeAll { foldered.contains($0) && !currentFolderIDs.contains($0) }
        nodes = restored
        let placed = Set(allItemIDs)
        for id in currentOrdered where !placed.contains(id) {
            nodes.append(id)
        }
    }

    mutating func reconcile(withItemIDs itemIDs: [String]) {
        let known = Set(itemIDs)
        let folderIDs = Set(folders.map(\.id))
        nodes = nodes.filter { known.contains($0) || folderIDs.contains($0) }

        for folder in folders where !nodes.contains(folder.id) {
            nodes.append(folder.id)
        }
        for index in folders.indices {
            folders[index].itemIds.removeAll { !known.contains($0) }
        }
        let present = Set(allItemIDs)
        for id in itemIDs where !present.contains(id) {
            nodes.append(id)
        }
    }

    private func knowsItem(_ id: String) -> Bool {
        allItemIDs.contains(id)
    }

    private mutating func detachItem(_ id: String) {

        let folderIDs = Set(folders.map(\.id))
        nodes.removeAll { $0 == id && !folderIDs.contains(id) }
        for index in folders.indices {
            folders[index].itemIds.removeAll { $0 == id }
        }
    }

    private mutating func mutateFolder(_ id: String, _ change: (inout ControlFolder) -> Void) {
        guard let index = folders.firstIndex(where: { $0.id == id }) else { return }
        change(&folders[index])
    }
}
