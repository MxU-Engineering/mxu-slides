import PresenterCore
import SwiftUI

struct FolderScopeMenuItems: View {
    let nodes: [FolderNode]
    let isActive: (String) -> Bool
    let select: (String) -> Void

    var body: some View {
        ForEach(nodes, id: \.path) { node in
            if node.children.isEmpty {
                toggle(node.name, path: node.path)
            } else {
                Menu(node.name) {
                    toggle("All in \u{201C}\(node.name)\u{201D}", path: node.path)
                    Divider()
                    FolderScopeMenuItems(nodes: node.children, isActive: isActive, select: select)
                }
            }
        }
    }

    private func toggle(_ title: String, path: String) -> some View {
        Toggle(title, isOn: Binding(
            get: { isActive(path) }, set: { _ in select(path) }
        ))
    }
}

struct EntryFolderMenuItems: View {
    let nodes: [FolderNode]

    let entries: [LibraryIndex.Entry]
    let selectedID: String?
    let select: (String) -> Void

    var body: some View {
        ForEach(nodes, id: \.path) { node in
            Menu(node.name) {
                ForEach(entries.filter { $0.subkind == node.path }, id: \.id) { entry in
                    Toggle(entry.name, isOn: Binding(
                        get: { selectedID == entry.id }, set: { _ in select(entry.id) }
                    ))
                }
                if !node.children.isEmpty {
                    Divider()
                    EntryFolderMenuItems(
                        nodes: node.children, entries: entries,
                        selectedID: selectedID, select: select)
                }
            }
        }
    }
}
