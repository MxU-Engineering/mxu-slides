import PresenterCore
import SwiftUI

struct ControlBoardFolderBlock<MemberRows: View>: View {
    let folder: ControlFolder

    let folderPrefix: String

    let isItemID: (String) -> Bool

    let updateBoard: (@escaping @Sendable (inout ControlBoard) -> Void) -> Void

    let memberNoun: String
    @Binding var dropTarget: String?
    @Binding var editingFolders: Set<String>
    @ViewBuilder let memberRows: () -> MemberRows

    @Environment(\.runOnly) private var runOnly

    var body: some View {
        let collapsed = folder.collapsed ?? false
        let editing = editingFolders.contains(folder.id)
        VStack(spacing: 0) {
            Button {
                if !runOnly {
                    updateBoard { [id = folder.id] in $0.setFolderCollapsed(id: id, !collapsed) }
                }
            } label: {
                headerStrip(collapsed: collapsed)
            }
            .buttonStyle(.plain)
            if editing, !runOnly {
                ControlFolderInlineEditor(
                    folder: folder, updateBoard: updateBoard, memberNoun: memberNoun
                ) {
                    editingFolders.remove(folder.id)
                }
            }
        }
        .background(
            Color.primary.opacity(0.03),
            in: RoundedRectangle.standard(CornerStandard.element)
        )
        .overlay(
            RoundedRectangle.standard(CornerStandard.element)
                .strokeBorder(
                    dropTarget == folder.id
                        ? Color(nsColor: .controlAccentColor).opacity(0.8)
                        : Color.clear,
                    lineWidth: 1.5
                )
        )
        .draggablePayload(runOnly ? nil : folderPrefix + folder.id)

        .dropDestination(for: String.self) { payloads, _ in
            dropTarget = nil
            guard !runOnly, let payload = payloads.first else { return false }
            if payload.hasPrefix(folderPrefix) {
                let id = String(payload.dropFirst(folderPrefix.count))
                guard id != folder.id else { return false }
                updateBoard { [before = folder.id] in $0.moveFolder(id: id, beforeNode: before) }
                return true
            }
            if isItemID(payload) {
                updateBoard { [into = folder.id] in $0.moveItem(id: payload, intoFolder: into) }
                return true
            }
            return false
        } isTargeted: { targeted in
            dropTarget = targeted
                ? folder.id
                : (dropTarget == folder.id ? nil : dropTarget)
        }
        .contextMenu {
            if !runOnly {
                Button(editing ? "Done Editing" : "Edit…") {
                    if editing {
                        editingFolders.remove(folder.id)
                    } else {
                        editingFolders.insert(folder.id)
                    }
                }
                Divider()
                Button("Delete Folder", role: .destructive) {
                    updateBoard { [id = folder.id] in $0.removeFolder(id: id) }
                }
            }
        }
        if !collapsed {
            VStack(spacing: 4) {
                memberRows()
                if folder.itemIds.isEmpty {
                    Text("Drag \(memberNoun) onto the folder name.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.leading, 14)
        }
    }

    private func headerStrip(collapsed: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "chevron.right")
                .font(.system(size: 7, weight: .semibold))
                .foregroundStyle(.tertiary)
                .rotationEffect(.degrees(collapsed ? 0 : 90))
                .frame(width: 12)
            Image(systemName: "folder")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
            Text(folder.name)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text("\(folder.itemIds.count)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
            Spacer(minLength: 6)
        }
        .padding(.horizontal, 8)
        .frame(height: 30)
        .contentShape(Rectangle())
    }
}

private struct ControlFolderInlineEditor: View {
    let folder: ControlFolder
    let updateBoard: (@escaping @Sendable (inout ControlBoard) -> Void) -> Void
    let memberNoun: String

    let dismiss: () -> Void

    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("NAME")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .tracking(0.5)
                TextField("Name", text: $name)
                    .textFieldStyle(.plain)
                    .font(.caption)
                    .onSubmit { apply() }
                Button(action: apply) {
                    Text("Apply")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .frame(height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(
                    Color.primary.opacity(0.06),
                    in: RoundedRectangle.standard(CornerStandard.element)
                )
                .overlay(
                    RoundedRectangle.standard(CornerStandard.element)
                        .strokeBorder(Color.separator.opacity(0.5), lineWidth: 1)
                )
                .help("Apply (or press Return)")
            }
            HStack {
                Text("Deleting a folder keeps its \(memberNoun).")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()

                Button {
                    dismiss()
                    updateBoard { [id = folder.id] in $0.removeFolder(id: id) }
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Delete folder — \(memberNoun) return to the top level")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .overlay(alignment: .top) {
            Divider().padding(.horizontal, 8)
        }
        .task(id: folder.id) { name = folder.name }
    }

    private func apply() {
        if name != folder.name {
            updateBoard { [name, id = folder.id] in $0.renameFolder(id: id, to: name) }
        }
        NSApp.keyWindow?.makeFirstResponder(nil)
    }
}

struct ControlBoardEndDropStrip: View {
    let folderPrefix: String
    let isItemID: (String) -> Bool
    let updateBoard: (@escaping @Sendable (inout ControlBoard) -> Void) -> Void

    @Environment(\.runOnly) private var runOnly
    @State private var targeted = false

    var body: some View {
        Color.clear
            .frame(height: 6)
            .dropDestination(for: String.self) { payloads, _ in
                targeted = false
                guard !runOnly, let payload = payloads.first else { return false }
                if payload.hasPrefix(folderPrefix) {
                    let id = String(payload.dropFirst(folderPrefix.count))
                    updateBoard { $0.moveFolder(id: id, beforeNode: nil) }
                    return true
                }
                if isItemID(payload) {
                    updateBoard { $0.moveItem(id: payload, beforeNode: nil) }
                    return true
                }
                return false
            } isTargeted: { targeted = $0 }
            .overlay(alignment: .top) {
                if targeted { ControlBoardInsertionLine() }
            }
    }
}

struct ControlBoardInsertionLine: View {
    var body: some View {
        RowInsertionLine()
            .padding(.horizontal, 2)
    }
}

func handleControlBoardRowDrop(
    _ payloads: [String], before targetID: String?, folderPrefix: String,
    isItemID: (String) -> Bool, updateBoard: (@escaping @Sendable (inout ControlBoard) -> Void) -> Void
) -> Bool {
    guard let payload = payloads.first else { return false }
    if payload.hasPrefix(folderPrefix) {
        let id = String(payload.dropFirst(folderPrefix.count))
        guard id != targetID else { return false }
        updateBoard { $0.moveFolder(id: id, beforeNode: targetID) }
        return true
    }
    if isItemID(payload) {
        guard payload != targetID else { return false }
        updateBoard { $0.moveItem(id: payload, beforeNode: targetID) }
        return true
    }
    return false
}
