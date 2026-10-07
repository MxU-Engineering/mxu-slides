import PresenterCore
import RenderEngine
import SwiftUI

struct OverlaysModule: View {
    let model: AppModel
    let controls: ServiceControls

    @Environment(\.runOnly) private var runOnly

    @AppStorage("appMode") private var appModeRaw = AppMode.edit.rawValue
    @AppStorage("overlays.scope") private var scopeRaw = "all"

    @AppStorage("overlays.pinnedIDs") private var pinnedRaw = ""
    @AppStorage("overlays.viewMode") private var viewModeRaw = "list"
    @AppStorage("overlays.listThumbs") private var listThumbs = true

    @AppStorage("overlays.gridColumns") private var gridColumns = 2
    @State private var hoveredID: String?

    @State private var searching = false
    @State private var searchQuery = ""

    private var isGrid: Bool { viewModeRaw == "grid" }

    private enum Scope: Equatable {
        case all, pinned, recent
        case folder(String)
    }

    private var folderPaths: [String] { model.folders(in: .overlays) }

    private var scope: Scope {
        switch scopeRaw {
        case "pinned": return .pinned
        case "recent": return .recent
        default:
            if scopeRaw.hasPrefix("folder:") {
                let path = String(scopeRaw.dropFirst("folder:".count))
                if folderPaths.contains(path) { return .folder(path) }
            }
            return .all
        }
    }

    private var pinnedIDs: [String] {
        pinnedRaw.split(separator: ",").map(String.init)
    }

    private static let recentLimit = 12

    var body: some View {
        let query = searchQuery.trimmingCharacters(in: .whitespaces)
        let filtering = searching && !query.isEmpty
        let all = model.entries(in: .overlays)
        VStack(alignment: .leading, spacing: 6) {
            ModuleHeaderBar {
                scopeMenu
            } trailing: {
                viewOptionsMenu
                ModuleSearchButton(isSearching: $searching, query: $searchQuery)
            }
            if searching {
                ModuleSearchField(query: $searchQuery, isSearching: $searching)
            }
            if filtering {
                let hits = all.filter { $0.name.localizedCaseInsensitiveContains(query) }
                if hits.isEmpty {
                    emptyText("No overlays match.")
                } else {
                    itemsBlock(hits)
                }
            } else {
                scopeContent(all: all)
            }
        }
    }

    @ViewBuilder
    private func scopeContent(all: [LibraryIndex.Entry]) -> some View {
        switch scope {
        case .all:
            if all.isEmpty {
                emptyText("Create overlays in Edit → Overlays; they go live from here and persist across slides.")
            } else {

                let groups = ControlRackLogic.groupedByFolder(all) { $0.subkind }
                ForEach(groups, id: \.folder) { group in
                    if !group.folder.isEmpty {
                        folderHeader(group.folder)
                    }
                    itemsBlock(group.items)
                }
            }
        case .pinned:
            let entries = pinnedIDs.compactMap { id in all.first { $0.id == id } }
            if entries.isEmpty {
                emptyText("Pin overlays from their right-click menu; they line up here in pin order.")
            } else {
                itemsBlock(entries)
            }
        case .recent:
            let entries = all
                .filter { $0.lastUsedAt != nil }
                .sorted { ($0.lastUsedAt ?? .distantPast) > ($1.lastUsedAt ?? .distantPast) }
                .prefix(Self.recentLimit)
            if entries.isEmpty {
                emptyText("Overlays you fire appear here, newest first.")
            } else {
                itemsBlock(Array(entries))
            }
        case .folder(let path):
            let entries = model.entriesUnder(
                in: .overlays, prefix: path.split(separator: "/").map(String.init))
            if entries.isEmpty {
                emptyText("This folder is empty.")
            } else {
                itemsBlock(entries)
            }
        }
    }

    private func emptyText(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 2)
    }

    private func folderHeader(_ path: String) -> some View {
        Text(path.replacingOccurrences(of: "/", with: " / ").uppercased())
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(.tertiary)
            .tracking(0.4)
            .padding(.horizontal, 2)
            .padding(.top, 4)
    }

    @ViewBuilder
    private func itemsBlock(_ entries: [LibraryIndex.Entry]) -> some View {
        if isGrid {
            LazyVGrid(
                columns: Array(
                    repeating: GridItem(.flexible(), spacing: 8),
                    count: max(1, min(gridColumns, 4))
                ),
                spacing: 10
            ) {
                ForEach(entries, id: \.id) { entry in
                    overlayTile(entry)
                }
            }
        } else {
            VStack(spacing: 4) {
                ForEach(entries, id: \.id) { entry in
                    overlayRow(entry)
                }
            }
        }
    }

    private var scopeTitle: String {
        switch scope {
        case .all: "All Overlays"
        case .pinned: "Pinned"
        case .recent: "Recent"
        case .folder(let path): path.split(separator: "/").last.map(String.init) ?? path
        }
    }

    private var scopeMenu: some View {
        Menu {
            scopeItem("All Overlays", raw: "all", active: scope == .all)
            scopeItem("Pinned", raw: "pinned", active: scope == .pinned)
            scopeItem("Recent", raw: "recent", active: scope == .recent)
            if !folderPaths.isEmpty {
                Divider()

                FolderScopeMenuItems(
                    nodes: FolderTreeLogic.tree(paths: folderPaths),
                    isActive: { scope == .folder($0) },
                    select: { scopeRaw = "folder:\($0)" })
            }
        } label: {
            HStack(spacing: 3) {
                Text(scopeTitle.uppercased())
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.4)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 7, weight: .semibold))
            }

            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Show all overlays, pinned, recent, or one folder")
    }

    private func scopeItem(_ title: String, raw: String, active: Bool) -> some View {
        Toggle(title, isOn: Binding(get: { active }, set: { _ in scopeRaw = raw }))
    }

    private var viewOptionsMenu: some View {
        Menu {
            Picker("View", selection: $viewModeRaw) {
                Text("List").tag("list")
                Text("Grid").tag("grid")
            }
            if isGrid {
                Picker("Thumbnail Size", selection: $gridColumns) {
                    Text("Small").tag(4)
                    Text("Medium").tag(3)
                    Text("Large").tag(2)
                    Text("Extra Large").tag(1)
                }
            } else {
                Toggle("Thumbnails", isOn: $listThumbs)
            }
        } label: {
            Image(systemName: isGrid ? "square.grid.2x2" : "list.bullet")
                .moduleHeaderGlyph()
        }
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("View options")
    }

    private func overlayRow(_ entry: LibraryIndex.Entry) -> some View {
        let isLive = controls.state.liveOverlays.contains { $0.id == entry.id }
        let hovering = hoveredID == entry.id
        return HStack(spacing: 6) {
            if listThumbs {
                ZStack {
                    Color.black.opacity(0.35)
                    LibraryItemFace(model: model, render: controls.render, entry: entry)
                }
                .aspectRatio(16 / 9, contentMode: .fit)
                .frame(width: 46)
                .clipShape(RoundedRectangle.standard(CornerStandard.element))
                .overlay(
                    RoundedRectangle.standard(CornerStandard.element)
                        .strokeBorder(
                            isLive ? Color.green : Color.separator.opacity(0.5),
                            lineWidth: isLive ? 1.5 : 1
                        )
                )
            }
            Text(entry.name)
                .font(.caption)
                .foregroundStyle(isLive ? Color.green : .secondary)
                .lineLimit(1)
            Spacer(minLength: 6)

            if isLive {
                liveChip(entry, isLive: true)
            } else if hovering {
                liveChip(entry, isLive: false)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: listThumbs ? 34 : 26)
        .contentShape(Rectangle())
        .onTapGesture { if !isLive { goLive(entry) } }
        .onHover { inside in
            hoveredID = inside ? entry.id : (hoveredID == entry.id ? nil : hoveredID)
        }
        .background(
            isLive ? Color.green.opacity(0.12) : Color.primary.opacity(0.03),
            in: RoundedRectangle.standard(CornerStandard.element)
        )
        .contextMenu { rackMenu(entry) }
    }

    private func overlayTile(_ entry: LibraryIndex.Entry) -> some View {
        let isLive = controls.state.liveOverlays.contains { $0.id == entry.id }
        let hovering = hoveredID == entry.id
        return LibraryItemCard(model: model, render: controls.render, entry: entry)
            .overlay(
                RoundedRectangle.standard(CornerStandard.element)
                    .strokeBorder(isLive ? Color.green : .clear, lineWidth: 2)
                    .padding(.bottom, 18) 
            )
            .overlay {

                if isLive {
                    liveChip(entry, isLive: true)
                } else if hovering {
                    liveChip(entry, isLive: false)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { if !isLive { goLive(entry) } }
            .onHover { inside in
                hoveredID = inside ? entry.id : (hoveredID == entry.id ? nil : hoveredID)
            }
            .contextMenu { rackMenu(entry) }
    }

    private func goLive(_ entry: LibraryIndex.Entry) {
        if let overlay = model.overlay(entry.id) {
            controls.fire(overlay: overlay)
        }
    }

    private func liveChip(_ entry: LibraryIndex.Entry, isLive: Bool) -> some View {
        Text(isLive ? "Take Down" : "Go Live")
            .font(.caption2.weight(.medium))
            .foregroundStyle(isLive ? Color.green : .secondary)
            .padding(.horizontal, 7)
            .frame(height: 18)
            .background(.thickMaterial, in: RoundedRectangle.standard(CornerStandard.element))
            .overlay(
                RoundedRectangle.standard(CornerStandard.element)
                    .strokeBorder(
                        isLive ? Color.green.opacity(0.4) : Color.separator.opacity(0.5),
                        lineWidth: 1
                    )
            )
            .contentShape(Rectangle())
            .onTapGesture {
                if isLive {
                    controls.dismissOverlay(id: entry.id)
                } else {
                    goLive(entry)
                }
            }
            .help(isLive ? "Take this overlay down" : "Go live — persists across slides")
    }

    @ViewBuilder
    private func rackMenu(_ entry: LibraryIndex.Entry) -> some View {
        let pinned = pinnedIDs.contains(entry.id)
        Button(pinned ? "Unpin" : "Pin") { togglePin(entry.id) }
        layerMenu(entry)
        if !runOnly {
            Divider()
            Button("Edit in Library") {
                model.openInEditor(entryID: entry.id)
                appModeRaw = AppMode.edit.rawValue
            }
        }
    }

    private func togglePin(_ id: String) {
        var ids = pinnedIDs
        if let index = ids.firstIndex(of: id) {
            ids.remove(at: index)
        } else {
            ids.append(id)
        }
        pinnedRaw = ids.joined(separator: ",")
    }

    @ViewBuilder
    private func layerMenu(_ entry: LibraryIndex.Entry) -> some View {
        if !runOnly, let overlay = model.overlay(entry.id) {
            let assigned = overlay.layer.flatMap(LayerKind.init(rawValue:)) ?? .overlays
            Menu("Layer") {

                ForEach(Array(LayerKind.allCases.reversed()), id: \.self) { layer in
                    Toggle(layer.displayName, isOn: Binding(
                        get: { assigned == layer },
                        set: { _ in
                            model.updateOverlay(entry.id) {
                                $0.layer = layer == .overlays ? nil : layer.rawValue
                            }
                        }
                    ))
                }
            }
        }
    }
}
