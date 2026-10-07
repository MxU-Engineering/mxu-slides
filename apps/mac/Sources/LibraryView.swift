import PPTXImport
import PresenterCore
import ProImport
import SlideScene
import SwiftUI
import UniformTypeIdentifiers

struct LibrarySidebar: View {
    @Bindable var model: AppModel
    var render: RenderContext?

    @AppStorage("appMode") private var appModeRaw = AppMode.edit.rawValue

    @State private var folderPath: [String]? = []

    static let unfiledToken = "\u{1}uncategorized"

    private func isUnfiled(_ path: [String]) -> Bool {
        path.last == Self.unfiledToken
    }

    private func realPath(_ path: [String]) -> [String] {
        isUnfiled(path) ? Array(path.dropLast()) : path
    }

    private var viewedFolder: LibraryHome.Viewed? {
        folderPath.map {
            LibraryHome.Viewed(kind: model.selectedSection.kind, area: .team, path: realPath($0).joined(separator: "/"))
        }
    }
    @State private var renameTarget: LibraryIndex.Entry?
    @State private var renameText = ""
    @State private var mediaSettingsTarget: MediaSettingsTarget?
    @State private var newFolderTarget: LibraryIndex.Entry?
    @State private var chordEditTarget: LibraryIndex.Entry?

    @State private var pendingApplyTheme: PendingDeckTheme?
    @State private var creatingFolder = false
    @State private var importingLyrics = false
    @State private var searchText = ""
    @FocusState private var searchFocused: Bool
    @Environment(\.openWindow) private var openWindow
    @Environment(\.runOnly) private var runOnly

    @FocusedValue(\.slideEditor) private var slideEditor
    @State private var slideDropTargetID: String?

    var layout: PresentLayoutController? = nil

    var controls: ServiceControls? = nil

    @State private var findSpotlight = LibraryFindSpotlight()
    @State private var folderRenameTarget: FolderRenameTarget?

    private struct FolderRenameTarget: Identifiable {
        let path: [String]
        var id: String { path.joined(separator: "/") }
    }

    private let shownArea = LibraryArea.team

    var body: some View {
        let _ = BodyMeter.tick(.librarySidebar)
        VStack(spacing: 0) {
            headerRow
            sectionPicker
            Divider()
            if searchText.isEmpty {
                entryList
            } else {
                searchResults
            }
            Divider()
            footer
        }
        .onChange(of: viewedFolder, initial: true) { _, viewed in
            model.viewedLibraryFolder = viewed
        }
        .onChange(of: model.libraryRevealID) { _, id in
            if let id {
                model.libraryRevealID = nil
                showHome(id)
            }
        }
        .overlay {
            if findSpotlight.active {

                RoundedRectangle.standard(CornerStandard.panel)
                    .inset(by: 1)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .allowsHitTesting(false)
            }
        }
        .animation(.easeOut(duration: 0.15), value: findSpotlight.active)
        .onClickOutside(active: findSpotlight.active) {
            findSpotlight.clicked(insideLibrary: false)
        }

        .onChange(of: model.libraryFindPending, initial: true) { _, pending in
            guard pending else { return }
            model.libraryFindPending = false
            findSpotlight.invoke()
            searchFocused = true

            DispatchQueue.main.async { searchFocused = true }
        }
        .focusedSceneValue(\.presentLyricImport, MenuAction("importLyrics") { importingLyrics = true })
        .sheet(isPresented: $importingLyrics) {
            ImportLyricsSheet(model: model, render: render, onImported: showImported)
        }
        .deckThemeConfirmation(model: model, pending: $pendingApplyTheme)
        .sheet(item: $newFolderTarget) { entry in
            NewFolderSheet(model: model, entry: entry, parentPath: realPath(folderPath ?? []))
        }
        .sheet(item: $mediaSettingsTarget) { target in
            MediaSettingsSheet(model: model, mediaID: target.id)
        }
        .sheet(item: $chordEditTarget) { entry in
            ChordEditorSheet(model: model, presentationID: entry.id)
        }
        .sheet(isPresented: $creatingFolder) {
            NewFolderSheet(model: model, entry: nil, parentPath: realPath(folderPath ?? []))
        }
        .sheet(item: $folderRenameTarget) { target in
            FolderNameSheet(
                title: "Rename Folder", confirm: "Rename",
                initial: target.path.last ?? ""
            ) { name in
                model.renameFolder(in: model.selectedSection, path: target.path, to: name)
                if folderPath.map({ Array($0.prefix(target.path.count)) }) == target.path { folderPath = Array(target.path.dropLast()) }
                return true
            }
        }
        .alert("Rename", isPresented: renameActive) {
            TextField("Name", text: $renameText)
            Button("Rename") {
                if let target = renameTarget { model.rename(target, to: renameText) }
                renameTarget = nil
            }
            Button("Cancel", role: .cancel) { renameTarget = nil }
        }
        .confirmationDialog(
            deleteBatch.count == 1
                ? "Delete \u{201C}\(deleteBatch.first?.name ?? "")\u{201D}?"
                : "Delete \(deleteBatch.count) items?",
            isPresented: deleteConfirmActive,
            titleVisibility: .visible
        ) {
            Button(deleteBatch.count == 1 ? "Delete" : "Delete \(deleteBatch.count) Items", role: .destructive) {
                model.delete(deleteBatch)
                deleteBatch = []
            }
            Button("Cancel", role: .cancel) { deleteBatch = [] }
        } message: {
            if deleteUsedCount > 0 {
                Text(
                    "Used in \(deleteUsedCount) place\(deleteUsedCount == 1 ? "" : "s"). Each spot shows a missing-media warning until the file is restored or replaced. This can't be undone."
                )
            } else {
                Text("This can't be undone.")
            }
        }
        .sheet(isPresented: $locatePanelShown) {
            LocateMissingMediaView(model: model)
        }
        .mediaCueSheets(model: model, state: mediaMenuState)
    }

    @State private var deleteBatch: [LibraryIndex.Entry] = []
    @State private var deleteUsedCount = 0

    @State private var locatePanelShown = false

    @State private var mediaMenuState = MediaCueMenuState()

    private var deleteConfirmActive: Binding<Bool> {
        Binding(get: { !deleteBatch.isEmpty }, set: { if !$0 { deleteBatch = [] } })
    }

    private func requestDelete(_ entries: [LibraryIndex.Entry]) {

        let mediaIds = Set(entries.filter { $0.kind == .media }.map(\.id))
        Task {
            let used = await model.mediaReferenceDocumentCount(of: mediaIds)
            if entries.count > 1 || used > 0 {
                deleteUsedCount = used
                deleteBatch = entries
            } else if let entry = entries.first {
                model.delete(entry)
            }
        }
    }

    private func selectionBatch(for entry: LibraryIndex.Entry, selection: [LibraryIndex.Entry]) -> [LibraryIndex.Entry] {
        model.selectedEntryIDs.count > 1 && model.selectedEntryIDs.contains(entry.id) ? selection : [entry]
    }

    private func showInFinder(_ entries: [LibraryIndex.Entry]) {
        let urls = entries.compactMap { model.fileURL(of: $0) }
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    @State private var searchScopes: Set<LibrarySection> = []

    @State private var searchHits: [LibraryIndex.Hit] = []

    @State private var cloudSearchHits: [TeamCloudItem] = []

    private var headerRow: some View {
        HStack(spacing: 8) {
            Text("Libraries")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .imageScale(.small)
                TextField("Search", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.caption)
                    .focused($searchFocused)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                            .imageScale(.small)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                findSpotlight.active ? Color.accentColor.opacity(0.22) : Color.primary.opacity(0.06),
                in: RoundedRectangle.standard(CornerStandard.element)
            )
            .overlay {
                if findSpotlight.active {
                    RoundedRectangle.standard(CornerStandard.element)
                        .strokeBorder(Color.accentColor, lineWidth: 1)
                        .allowsHitTesting(false)
                }
            }
            if !searchText.isEmpty {
                Menu {
                    Section("Search In") {
                        ForEach(orderedTabs) { section in
                            Toggle(section.displayName, isOn: Binding(
                                get: { searchScopes.isEmpty || searchScopes.contains(section) },
                                set: { include in
                                    var scopes = searchScopes.isEmpty
                                        ? Set(orderedTabs) : searchScopes
                                    if include { scopes.insert(section) } else { scopes.remove(section) }
                                    searchScopes = scopes.count == orderedTabs.count ? [] : scopes
                                }
                            ))
                        }
                    }
                    Divider()
                    Button("All Libraries") { searchScopes = [] }
                } label: {
                    Image(systemName: "line.3.horizontal.decrease")
                        .imageScale(.small)
                        .foregroundStyle(searchScopes.isEmpty ? .secondary : .primary)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Limit which libraries results come from")
            } else {
                filterMenu
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 3)
    }

    private var filterMenu: some View {
        let section = model.selectedSection
        let sort = model.librarySorts[section] ?? .name
        let filtered = model.isFiltered(section)
        let upcoming = UpcomingUse.kinds.contains(section.kind)
        return Menu {
            Section("Sort By") {
                ForEach(LibrarySort.allCases, id: \.self) { choice in
                    Toggle(choice.title, isOn: Binding(get: { sort == choice }, set: { if $0 { model.setSort(choice, for: section) } }))
                }
            }
            if upcoming {
                Divider()
                Toggle("Used in an Upcoming Service", isOn: Binding(get: { model.upcomingOnly }, set: { model.upcomingOnly = $0 }))
            }
        } label: {
            Image(systemName: filtered ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease")
                .imageScale(.small)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()

        .tint(filtered ? Color.accentColor : Color.secondary)
        .opacity(filtered ? 1 : 0.75)
        .help(filtered ? "Showing only what's used in an upcoming service"
            : upcoming ? "Sort, or show only what's used in an upcoming service" : "Sort")
    }

    private func searchHitRow(_ hit: LibraryIndex.Hit) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Glyph(kind: section(for: hit.entry)?.glyph ?? .presentations, size: 13)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(hit.entry.name)
                if let snippet = hit.snippet {

                    Text(snippet)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text(section(for: hit.entry)?.displayName ?? hit.entry.kind.rawValue)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let used = hit.entry.lastUsedAt {
                    Text("Used \(used, format: .relative(presentation: .named))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .tag(hit.entry.id)
        .draggable(hit.entry.id)
        .contextMenu {
            if [.presentation, .media, .audio].contains(hit.entry.kind) {
                Button("Add to Service") { model.addToCurrentService(hit.entry) }
            }
        }
    }

    @ViewBuilder
    private var searchResults: some View {
        let hits = searchHits.filter { hit in
            guard let section = section(for: hit.entry) else { return false }
            return (searchScopes.isEmpty || searchScopes.contains(section))
                && model.showFiltersAdmit(id: hit.entry.id, kind: hit.entry.kind)
        }
        let cloudHits = cloudSearchHits.filter { item in
            searchScopes.isEmpty || searchScopes.contains { $0.kind == item.kind }
        }
        List(selection: $model.selectedEntryID) {
            ForEach(TeamDriveLogic.searchRows(hits: hits, cloud: cloudHits, query: searchText)) { row in
                switch row {
                case .hit(let hit):
                    searchHitRow(hit)
                case .cloud(let item):
                    HStack(alignment: .firstTextBaseline) {
                        Glyph(kind: LibrarySection.libraryTabs.first { $0.kind == item.kind }?.glyph ?? .presentations, size: 13)
                            .foregroundStyle(.tertiary)
                            .frame(width: 18)
                        Text(item.name).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)

        .task(id: "\(model.listVersion)|\(model.teamCloudItems.count)|\(searchText)") {
            searchHits = await model.search(searchText)
            cloudSearchHits = model.cloudSearch(searchText)
        }
        .onChange(of: model.selectedEntryID) { _, id in
            guard let id, let hit = hits.first(where: { $0.entry.id == id }),
                  let section = section(for: hit.entry) else { return }
            model.selectedSection = section
        }
        .overlay {
            if hits.isEmpty, cloudHits.isEmpty {
                ContentUnavailableView.search(text: searchText)
            }
        }
    }

    @AppStorage("library.tabOrder") private var tabOrderRaw = ""
    @AppStorage("library.hiddenTabs") private var hiddenTabsRaw = ""

    private var orderedTabs: [LibrarySection] {
        let stored = tabOrderRaw.split(separator: ",").compactMap {
            LibrarySection(rawValue: String($0))
        }
        var order = stored.filter { LibrarySection.libraryTabs.contains($0) }
        for section in LibrarySection.libraryTabs where !order.contains(section) {
            order.append(section)
        }
        return order
    }

    private var hiddenTabs: Set<LibrarySection> {
        Set(hiddenTabsRaw.split(separator: ",").compactMap {
            LibrarySection(rawValue: String($0))
        })
    }

    private var visibleTabs: [LibrarySection] {
        let visible = orderedTabs.filter { !hiddenTabs.contains($0) }
        return visible.isEmpty ? orderedTabs : visible
    }

    private var sectionPicker: some View {

        PriorityTabRow(
            card: "library",
            tabs: visibleTabs.map { section in
                PriorityTabDescriptor(
                    id: section.rawValue,
                    title: section.displayName,
                    glyph: section.glyph
                )
            },
            selectedID: model.selectedSection.rawValue,
            onSelect: { id in
                if let section = LibrarySection(rawValue: id) {
                    model.switchLibrarySection(section)
                }
            },
            onReorder: { movedID, beforeID in
                guard let moved = LibrarySection(rawValue: movedID) else { return }
                reorderTab(moved, before: beforeID.flatMap(LibrarySection.init(rawValue:)))
            }
        ) { _ in
            Section("Libraries") {
                ForEach(orderedTabs) { candidate in
                    Toggle(candidate.displayName, isOn: Binding(
                        get: { !hiddenTabs.contains(candidate) },
                        set: { show in setTab(candidate, visible: show) }
                    ))
                }
            }
            Divider()
            Button("Reset Tabs") {
                tabOrderRaw = ""
                hiddenTabsRaw = ""
            }
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 5)
        .onChange(of: hiddenTabsRaw) { _, _ in
            if hiddenTabs.contains(model.selectedSection),
               let first = visibleTabs.first {
                model.switchLibrarySection(first)
            }
        }
    }

    private func reorderTab(_ moved: LibrarySection, before target: LibrarySection?) {
        var order = orderedTabs
        order.removeAll { $0 == moved }
        let index = target.flatMap { order.firstIndex(of: $0) } ?? order.endIndex
        order.insert(moved, at: index)
        tabOrderRaw = order.map(\.rawValue).joined(separator: ",")
    }

    private func setTab(_ section: LibrarySection, visible: Bool) {
        var hidden = hiddenTabs
        if visible {
            hidden.remove(section)
        } else {
            guard visibleTabs.count > 1 else { return }
            hidden.insert(section)
        }
        hiddenTabsRaw = hidden.map(\.rawValue).sorted().joined(separator: ",")
    }

    private var viewModeKey: String { "library.viewMode.\(model.selectedSection.rawValue)" }
    @State private var viewModeBump = 0
    private var isGridMode: Bool {
        _ = viewModeBump
        return UserDefaults.standard.bool(forKey: viewModeKey)
    }

    @ViewBuilder
    private var entryList: some View {
        let folderable = AppModel.folderableSections.contains(model.selectedSection)
        VStack(spacing: 0) {
            if folderable, folderPath != [] {
                breadcrumbBar
            }
            if isGridMode, folderable {
                browserGrid
            } else {
                browserList(folderable: folderable)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard acceptsImport else { return false }
            Task { await model.importFiles(urls) }
            return true
        }
    }

    private var breadcrumbBar: some View {
        HStack(spacing: 3) {

            if folderPath == nil {
                backChevron(to: [])
                crumb("Top Level", path: [])
                crumbSeparator
                Text("All \(model.selectedSection.displayName)")
                    .font(.caption)
                    .foregroundStyle(.primary)
            } else if let path = folderPath, !path.isEmpty {
                backChevron(to: Array(path.dropLast()))
                crumb("Top Level", path: [])
                ForEach(Array(path.enumerated()), id: \.offset) { index, component in
                    crumbSeparator
                    crumb(
                        component == Self.unfiledToken ? unfiledTitle(at: Array(path.prefix(index))) : component,
                        path: Array(path.prefix(index + 1))
                    )
                }
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }

    private var crumbSeparator: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 7, weight: .semibold))
            .foregroundStyle(.tertiary)
    }

    private func backChevron(to path: [String]) -> some View {
        Button {
            folderPath = path
        } label: {
            Image(systemName: "chevron.left")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Back")
    }

    private func crumb(_ title: String, path: [String]) -> some View {
        let isCurrent = folderPath == path
        return Button {
            folderPath = path
        } label: {
            Text(title)
                .font(.caption.weight(isCurrent ? .medium : .regular))
                .foregroundStyle(isCurrent ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
        }
        .buttonStyle(.plain)
    }

    private struct BrowserContents {
        var path: [String]
        var folders: [(name: String, count: Int)]
        var items: [LibraryIndex.Entry]
        var cloud: [TeamCloudItem]

        var rows: [LibraryBrowserRow]

        var tucked: Int
        var menus: RowMenuLists
    }

    private struct RowMenuLists {

        var folders: [String]

        var playlists: [LibraryIndex.Entry]

        var themes: [LibraryIndex.Entry]

        var selection: [LibraryIndex.Entry]
    }

    private func rowMenuLists(for section: LibrarySection) -> RowMenuLists {
        let selection = model.selectedEntryIDs.count > 1 ? model.selectedEntries() : []
        return RowMenuLists(
            folders: AppModel.folderableSections.contains(section) ? model.folders(in: section) : [],
            playlists: model.playlists(in: section),
            themes: section == .presentations ? model.entries(in: .themes) : [],
            selection: selection)
    }

    private func browserContents(folderable: Bool) -> BrowserContents {
        let section = model.selectedSection
        let unfiled = folderPath.map(isUnfiled) ?? false
        let path = realPath(folderPath ?? [])
        let drillable = folderable && folderPath != nil && !unfiled
        let folders = drillable ? model.childFolders(in: section, under: path) : []
        let flat = folderPath == nil || !folderable
        let looseItems = flat ? model.browserEntries(in: section) : model.items(in: section, at: path)
        let looseCloud = flat ? model.cloudItems(in: section) : model.cloudItems(in: section, at: path)
        let tucksLoose = !folders.isEmpty && !(looseItems.isEmpty && looseCloud.isEmpty)
        let items = tucksLoose ? [] : looseItems
        let cloud = tucksLoose ? [] : looseCloud
        return BrowserContents(
            path: path, folders: folders, items: items, cloud: cloud,
            rows: (model.librarySorts[section] ?? .name).merged(items, cloud: cloud),
            tucked: tucksLoose ? looseItems.count + looseCloud.count : 0, menus: rowMenuLists(for: section))
    }

    private func unfiledTitle(at path: [String]) -> String {
        path.isEmpty ? "Not in a Folder" : "Uncategorized"
    }

    @ViewBuilder
    private func browserList(folderable: Bool) -> some View {
        let contents = browserContents(folderable: folderable)
        let path = contents.path
        List(selection: $model.librarySelection) {
            if folderable, folderPath == [] {
                allRow
            }
            ForEach(contents.folders, id: \.name) { folder in
                folderRow(folder.name, count: folder.count, path: path + [folder.name])
            }
            if contents.tucked > 0 {
                folderRow(
                    unfiledTitle(at: path), count: contents.tucked,
                    path: path + [Self.unfiledToken]
                )
            }
            ForEach(contents.rows) { row in
                switch row {
                case .held(let entry):
                    entryRow(entry, menus: contents.menus)
                case .cloud(let item):
                    Text(item.name).foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .onDeleteCommand {
            requestDelete(model.selectedEntries())
        }
        .overlay {
            if contents.items.isEmpty, contents.cloud.isEmpty, contents.folders.isEmpty {
                ContentUnavailableView(
                    "No \(model.selectedSection.displayName)",
                    systemImage: model.selectedSection.systemImage,
                    description: Text(emptyDescription)
                )
            }
        }
    }

    private var allRow: some View {
        Button {
            folderPath = nil
        } label: {
            HStack(spacing: 8) {
                Glyph(kind: .folder, size: 14)
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                Text("All \(model.selectedSection.displayName)")
                Spacer()
                Text("\(model.browserEntries(in: model.selectedSection).count + model.cloudItems(in: model.selectedSection).count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func folderRow(_ name: String, count: Int, path: [String]) -> some View {
        HStack(spacing: 6) {
            Button {
                folderPath = path
            } label: {
                HStack(spacing: 8) {
                    Glyph(kind: .folder, size: 14)
                        .foregroundStyle(.secondary)
                        .frame(width: 18)
                    Text(name)
                    Spacer()
                    Text("\(count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .contextMenu { folderMenu(path) }
        .draggable(isUnfiled(path) ? "" : TeamDriveLogic.folderPayload(path: path, area: shownArea))
        .dropDestination(for: String.self) { payloads, _ in
            handleDrop(payloads, into: path)
        }
    }

    @ViewBuilder
    private func folderMenu(_ path: [String]) -> some View {
        if !isUnfiled(path), !runOnly {
            Button("Rename Folder…") { folderRenameTarget = FolderRenameTarget(path: path) }
        }
    }

    private func handleDrop(_ payloads: [String], into path: [String]) -> Bool {
        let destination = realPath(path)
        var handled = false
        for payload in payloads where !payload.isEmpty {
            if let folder = TeamDriveLogic.parseFolderPayload(payload, fallback: shownArea) {
                guard !isUnfiled(path) else { continue }
                model.moveFolder(in: model.selectedSection, from: folder.path, into: destination)
                handled = true
            } else if let entry = model.indexEntry(payload) {
                let target = isUnfiled(path) ? destination : path
                model.moveToFolder(entry, folder: target.isEmpty ? nil : target.joined(separator: "/"))
                handled = true
            }
        }
        return handled
    }

    private var columnsKey: String { "library.gridColumns.\(model.selectedSection.rawValue)" }
    private var gridColumns: Int {
        _ = viewModeBump
        let stored = UserDefaults.standard.integer(forKey: columnsKey)
        return stored == 0 ? 2 : min(max(stored, 1), 6)
    }

    private var browserGrid: some View {
        let contents = browserContents(folderable: true)
        let path = contents.path
        let folders = contents.folders
        let items = contents.items
        let columns = Array(
            repeating: GridItem(.flexible(), spacing: 8), count: gridColumns
        )
        return ScrollView {
            LazyVGrid(columns: columns, spacing: 10) {
                if folderPath == [] {
                    let all = model.browserEntries(in: model.selectedSection)
                    FolderPreviewCard(
                        model: model, render: render,
                        name: "All \(model.selectedSection.displayName)",
                        count: all.count,
                        entries: all
                    ) {
                        folderPath = nil
                    }
                }
                ForEach(folders, id: \.name) { folder in
                    let folderFull = path + [folder.name]
                    FolderPreviewCard(
                        model: model, render: render,
                        name: folder.name,
                        count: folder.count,
                        entries: model.entriesUnder(
                            in: model.selectedSection, prefix: folderFull
                        )
                    ) {
                        folderPath = folderFull
                    }
                    .contextMenu { folderMenu(folderFull) }
                    .draggable(TeamDriveLogic.folderPayload(path: folderFull, area: shownArea))
                    .dropDestination(for: String.self) { payloads, _ in
                        handleDrop(payloads, into: folderFull)
                    }
                }
                if contents.tucked > 0 {
                    FolderPreviewCard(
                        model: model, render: render,
                        name: unfiledTitle(at: path),
                        count: contents.tucked,
                        entries: model.items(in: model.selectedSection, at: path)
                    ) {
                        folderPath = path + [Self.unfiledToken]
                    }
                    .dropDestination(for: String.self) { payloads, _ in
                        handleDrop(payloads, into: path + [Self.unfiledToken])
                    }
                }
                ForEach(contents.rows) { row in
                    switch row {
                    case .held(let entry):
                        gridItem(entry, menus: contents.menus)
                    case .cloud(let item):
                        Text(item.name).foregroundStyle(.secondary)
                            .font(.caption)
                            .padding(8)
                            .background(.quaternary.opacity(0.4), in: RoundedRectangle.standard(CornerStandard.element))
                    }
                }
            }
            .padding(8)
        }
        .overlay {
            if items.isEmpty, contents.cloud.isEmpty, folders.isEmpty {
                ContentUnavailableView(
                    "No \(model.selectedSection.displayName)",
                    systemImage: model.selectedSection.systemImage,
                    description: Text(emptyDescription)
                )
            }
        }
    }

    private func gridItem(_ entry: LibraryIndex.Entry, menus: RowMenuLists) -> some View {

        gridCard(selected: model.selectedEntryIDs.contains(entry.id)) {
            if NSEvent.modifierFlags.contains(.command) {
                var selection = model.librarySelection
                if !selection.insert(entry.id).inserted {
                    selection.remove(entry.id)
                }
                model.librarySelection = selection
            } else {
                model.librarySelection = [entry.id]
            }
        } content: {
            LibraryItemCard(model: model, render: render, entry: entry)
        }
        .draggable(entry.id)
        .contextMenu { entryMenu(entry, menus: menus) }
        .modifier(slideDropTarget(entry))
    }

    private func gridCard<Content: View>(
        selected: Bool, action: @escaping () -> Void, @ViewBuilder content: () -> Content
    ) -> some View {
        Button(action: action) {
            content()
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay {
            if selected {
                RoundedRectangle.standard(CornerStandard.element)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
            }
        }
    }

    private func entryRow(_ entry: LibraryIndex.Entry, menus: RowMenuLists) -> some View {
        EntryRow(model: model, entry: entry)
            .tag(entry.id)
            .draggable(entry.id)
            .contextMenu { entryMenu(entry, menus: menus) }
            .modifier(slideDropTarget(entry))
    }

    private func slideDropTarget(_ entry: LibraryIndex.Entry) -> SlideDropTarget {
        let targeted = Binding(
            get: { slideDropTargetID == entry.id },
            set: { on in
                if on {
                    slideDropTargetID = entry.id
                } else if slideDropTargetID == entry.id {
                    slideDropTargetID = nil
                }
            }
        )
        if entry.kind == .theme, !runOnly, let editor = slideEditor, editor.isThemeEditor {
            return SlideDropTarget(
                enabled: true,
                accepts: { EditSlideDrag.ids(in: $0) != nil },
                perform: { payloads in
                    let ids = payloads.compactMap(EditSlideDrag.ids(in:)).flatMap { $0 }
                    return !ids.isEmpty && editor.moveSlides(ids, toTheme: entry.id)
                },
                targeted: targeted
            )
        } else {
            return SlideDropTarget(
                enabled: entry.kind == .presentation && !runOnly,
                accepts: { payload in
                    SlideBulkEdit.draggedSlide(in: payload).map { $0.presentationID != entry.id } ?? false
                },
                perform: { payloads in
                    payloads.compactMap(SlideBulkEdit.draggedSlide(in:)).map { dragged in
                        model.copySlide(
                            dragged.slideID, from: dragged.presentationID,
                            to: entry.id, beforeSlideID: nil)
                    }.contains(true)
                },
                targeted: targeted
            )
        }
    }

    @ViewBuilder
    private func entryMenu(_ entry: LibraryIndex.Entry, menus: RowMenuLists) -> some View {
        let batch = selectionBatch(for: entry, selection: menus.selection)
        if batch.count > 1 {
            massEntryMenu(batch, menus: menus)
        } else {
            singleEntryMenu(entry, menus: menus)
        }
    }

    @ViewBuilder
    private func massEntryMenu(_ batch: [LibraryIndex.Entry], menus: RowMenuLists) -> some View {
        let addable = batch.filter { [.presentation, .media, .audio].contains($0.kind) }
        if !addable.isEmpty {
            Button("Add \(addable.count) to Service") {
                for entry in addable { model.addToCurrentService(entry) }
            }
            Divider()
        }
        let tracks = batch.filter { $0.kind == .media || $0.kind == .audio }
        if !tracks.isEmpty, tracks.allSatisfy({ $0.kind == tracks[0].kind }) {
            Menu("Add to Playlist") {
                ForEach(menus.playlists, id: \.id) { playlist in
                    Button(playlist.name) {
                        for entry in tracks { model.addToPlaylist(playlist.id, itemID: entry.id) }
                    }
                }
                if !menus.playlists.isEmpty { Divider() }
                Button("New Playlist…") {
                    if let id = model.createPlaylist(in: model.selectedSection) {
                        for entry in tracks { model.addToPlaylist(id, itemID: entry.id) }
                    }
                }
            }
        }
        let folderable = batch.filter { entry in
            AppModel.folderableSections.contains { $0.kind == entry.kind }
        }
        if !folderable.isEmpty {
            Menu("Move to Folder") {
                Button("None") {
                    for entry in folderable { model.moveToFolder(entry, folder: nil) }
                }
                if !menus.folders.isEmpty {
                    Divider()
                    ForEach(menus.folders, id: \.self) { folder in
                        Button(folder) {
                            for entry in folderable { model.moveToFolder(entry, folder: folder) }
                        }
                    }
                }
            }
        }
        if !tracks.isEmpty {
            Button("Show in Finder") { showInFinder(tracks) }
        }
        Divider()
        Button("Delete \(batch.count) Items", role: .destructive) {
            requestDelete(batch)
        }
    }

    @ViewBuilder
    private func singleEntryMenu(_ entry: LibraryIndex.Entry, menus: RowMenuLists) -> some View {
        if [.presentation, .media, .audio].contains(entry.kind) {
            Button("Add to Service") { model.addToCurrentService(entry) }
            Divider()
        }
        if entry.kind.opensInEditor {

            Button("Edit…") {
                model.openInEditor(entryID: entry.id)
                appModeRaw = AppMode.edit.rawValue
            }
        }
        if entry.kind == .media {
            Button("Media Settings…") { mediaSettingsTarget = MediaSettingsTarget(id: entry.id) }

            MediaCueGrammarItems(
                model: model, actionRouter: nil,
                mediaID: entry.id, state: mediaMenuState
            )
        }
        if entry.kind == .audio {

            Button("Replace Music File…") {
                let panel = NSOpenPanel()
                panel.allowsMultipleSelection = false
                panel.allowedContentTypes = [.audio]
                panel.begin { response in
                    guard response == .OK, let url = panel.url else { return }
                    Task { @MainActor in model.replaceAudioFile(entry.id, with: url) }
                }
            }
        }
        if entry.kind == .media {

            Button("Replace Media File…") {
                let panel = NSOpenPanel()
                panel.allowsMultipleSelection = false
                panel.allowedContentTypes = [.image, .movie]
                panel.begin { response in
                    guard response == .OK, let url = panel.url else { return }
                    Task { @MainActor in
                        if let carried = await model.replaceMediaFile(entry.id, with: url) {
                            MediaRelinkAlerts.carriedSettingsWarning(itemName: entry.name, carried: carried)
                        }
                    }
                }
            }
            Button("Locate Missing Media…") { locatePanelShown = true }
        }
        if entry.kind == .audio || entry.kind == .media {

            Menu("Add to Playlist") {
                ForEach(menus.playlists, id: \.id) { playlist in
                    Button(playlist.name) { model.addToPlaylist(playlist.id, itemID: entry.id) }
                }
                if !menus.playlists.isEmpty { Divider() }
                Button("New Playlist…") {
                    if let id = model.createPlaylist(in: model.selectedSection) {
                        model.addToPlaylist(id, itemID: entry.id)
                    }
                }
            }
        }
        Button("Rename…") {
            renameTarget = entry
            renameText = entry.name
        }
        Button("Duplicate") { model.duplicate(entry) }
        if entry.kind == .theme {
            Button("Apply to All Presentations") {
                model.applyThemeToAllPresentations(entry.id)
            }
        }
        if entry.kind == .presentation {

            Menu("Apply Theme") {
                DeckThemeMenuItems(model: model, presentationID: entry.id, themes: menus.themes, pending: $pendingApplyTheme)
            }
            Button("Edit Chords…") { chordEditTarget = entry }
        }
        if AppModel.folderableSections.contains(where: { $0.kind == entry.kind }) {
            Menu("Move to Folder") {
                Button("None") { model.moveToFolder(entry, folder: nil) }
                    .disabled(entry.subkind.isEmpty)
                if !menus.folders.isEmpty {
                    Divider()
                    ForEach(menus.folders, id: \.self) { folder in
                        Button(folder) { model.moveToFolder(entry, folder: folder) }
                            .disabled(entry.subkind == folder)
                    }
                }
                Divider()
                Button("New Folder…") { newFolderTarget = entry }
            }
        }
        if entry.kind == .media || entry.kind == .audio {
            Button("Show in Finder") { showInFinder([entry]) }
        }
        Divider()
        Button("Delete", role: .destructive) { requestDelete([entry]) }
    }

    private func section(for entry: LibraryIndex.Entry) -> LibrarySection? {
        switch entry.kind {
        case .presentation: .presentations
        case .media: .media
        case .audio: .audio
        case .playlist:
            (try? model.playlist(entry.id))?.effectiveKind == .media ? .media : .audio
        case .theme: .themes
        case .service: nil
        case .streamRecordPreset: nil
        case .overlay: .overlays
        case .outputPreset: nil
        case .alertPreset: nil
        case .actionCombo: nil
        case .confidenceLayout: .confidence
        case .note: nil
        case .midiDevice: nil  
        case .streamDestination: nil  
        case .scheduleTrigger, .schedulerBoard, .controlBoard, .groupPalette, .signageBoard,
            .effectPresetBoard, .animationPresetBoard, .importLedger, .serviceLinkRules, .stationSettings, .slideBuildingSettings, .font, .workspaceSettings: nil
        }
    }

    private var acceptsImport: Bool {
        model.selectedSection == .media || model.selectedSection == .audio
    }

    private var emptyDescription: String {
        switch model.selectedSection {
        case .media, .audio: "Drop files here or use Import."
        default: "Use New to create one."
        }
    }

    private var renameActive: Binding<Bool> {
        Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })
    }

    private func fileNewEntry(_ id: String?) {
        if let id {
            model.selectedEntryID = id
            showHome(id)
        }
    }

    private func showHome(_ id: String) {
        if let entry = model.indexEntry(id), LibraryHome.area(for: entry.kind) != nil {
            folderPath = TeamFoldered.kinds.contains(entry.kind) && !entry.subkind.isEmpty
                ? entry.subkind.components(separatedBy: "/") : []
        }
    }

    private func showImported(_ id: String) {
        showHome(id)
        if appModeRaw == AppMode.edit.rawValue {
            model.openInEditor(entryID: id)
            model.retargetPresentReturn(entryID: id)
        } else {
            model.openInPresent(entryID: id, presenting: appModeRaw == AppMode.present.rawValue)
            appModeRaw = AppMode.present.rawValue
        }
    }

    private var footer: some View {
        VStack(spacing: 0) {
            if let summary = model.lastImportSummary {
                Text(summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                Divider()
            }
            HStack(spacing: 10) {
                if acceptsImport {
                    Button {
                        presentImportPanel()
                    } label: {
                        Label("Import…", systemImage: "square.and.arrow.down")
                    }
                    .disabled(model.isImporting)
                } else if model.selectedSection == .confidence {

                    Menu {
                        ForEach(ConfidenceLayoutTemplate.allCases, id: \.rawValue) { template in
                            Button(template.title) {
                                fileNewEntry(model.createConfidenceLayout(from: template))
                            }
                        }

                        Section("MultiView") {
                            ForEach(MultiViewTemplate.allCases, id: \.rawValue) { template in
                                Button(template.title) {
                                    let sources = render.map(PreviewTargets.screens) ?? []
                                    fileNewEntry(model.createMultiView(
                                        from: template,
                                        sources: sources.map { .init(screenId: $0.id, name: $0.name) }
                                    ))
                                }
                            }
                        }
                    } label: {
                        Label("New", systemImage: "plus")
                    }
                    .fixedSize()
                } else {
                    Button {
                        fileNewEntry(model.createEntity(in: model.selectedSection))
                    } label: {
                        Label("New", systemImage: "plus")
                    }
                }
                if AppModel.folderableSections.contains(model.selectedSection) {
                    Button {
                        creatingFolder = true
                    } label: {
                        Label("New Folder", systemImage: "folder.badge.plus")
                    }
                    .disabled(folderPath == nil || (folderPath.map(isUnfiled) ?? false))
                }
                Spacer()
                if AppModel.folderableSections.contains(model.selectedSection) {
                    Button {
                        UserDefaults.standard.set(!isGridMode, forKey: viewModeKey)
                        viewModeBump += 1
                    } label: {

                        Image(systemName: isGridMode ? "square.grid.2x2" : "list.bullet")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(isGridMode ? "Grid view — click for list" : "List view — click for grid")
                    if isGridMode {
                        thumbnailSizer
                    }
                }
                if model.selectedSection == .media, model.flaggedMediaCount() > 0 {
                    Button {
                        Task { await model.transcodeFlagged() }
                    } label: {
                        if model.isTranscoding {
                            Label("Transcoding…", systemImage: "arrow.triangle.2.circlepath")
                        } else {
                            Label("Transcode \(model.flaggedMediaCount())", systemImage: "wrench.adjustable")
                        }
                    }
                }
            }
            .buttonStyle(.borderless)
            .labelStyle(.titleAndIcon)
            .controlSize(.small)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
        }
    }

    @State private var showingSizePopover = false

    private var thumbnailSizer: some View {
        Button {
            showingSizePopover.toggle()
        } label: {
            Image(systemName: "plus.forwardslash.minus")
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Thumbnail size")
        .popover(isPresented: $showingSizePopover, arrowEdge: .bottom) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5)
                    .strokeBorder(lineWidth: 1.2)
                    .frame(width: 6, height: 6)
                    .foregroundStyle(.secondary)
                Slider(
                    value: Binding(
                        get: { Double(7 - gridColumns) },
                        set: {
                            UserDefaults.standard.set(
                                7 - Int($0.rounded()), forKey: columnsKey
                            )
                            viewModeBump += 1
                        }
                    ),
                    in: 1...6, step: 1
                )
                .controlSize(.small)
                .frame(width: 140)
                RoundedRectangle(cornerRadius: 2)
                    .strokeBorder(lineWidth: 1.2)
                    .frame(width: 11, height: 11)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    private func presentImportPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.allowedContentTypes = model.selectedSection == .audio
            ? [.audio]
            : [.image, .movie, .video, .audio]
        panel.begin { response in
            guard response == .OK else { return }
            let urls = panel.urls
            Task { @MainActor in await model.importFiles(urls) }
        }
    }
}

struct LibraryCommands: Commands {
    @FocusedValue(\.presentLibrarySearch) private var presentSearch
    @FocusedValue(\.presentLyricImport) private var presentLyricImport
    @FocusedValue(\.presentWorkspaceImport) private var presentWorkspaceImport
    @FocusedValue(\.libraryModel) private var model
    @FocusedValue(\.slideEditor) private var slideEditor
    @FocusedValue(\.presentNewSlide) private var presentNewSlide

    @AppStorage(PresentLayoutController.lockedKey) private var runOnly = false

    var body: some Commands {

        CommandGroup(replacing: .newItem) {
            Button("New Presentation") { createAndSelect(.presentations) }
                .keyboardShortcut(command: .newPresentation)
                .disabled(model == nil || runOnly)

            Button("New Slide…") {
                if let slideEditor {
                    slideEditor.addSlide()
                } else {
                    presentNewSlide?()
                }
            }
            .keyboardShortcut(command: .newSlide)
            .disabled((slideEditor == nil && presentNewSlide == nil) || runOnly)
            Divider()
            Button("New Service") {
                guard let model, let id = model.createEntity(in: .services) else { return }
                model.currentServiceID = id
            }
            .keyboardShortcut(command: .newService)
            .disabled(model == nil || runOnly)
            Button("New Overlay") { createAndSelect(.overlays) }
                .keyboardShortcut(command: .newOverlay)
                .disabled(model == nil || runOnly)
            Button("New Theme") { createAndSelect(.themes) }
                .keyboardShortcut(command: .newTheme)
                .disabled(model == nil || runOnly)
        }
        CommandGroup(after: .sidebar) {
            Divider()
            Button("Find in Library") { presentSearch?() }
                .keyboardShortcut(command: .findInLibrary)
                .disabled(presentSearch == nil || runOnly)
        }
        CommandGroup(after: .importExport) {
            Button("Import Lyrics…") { presentLyricImport?() }
                .disabled(presentLyricImport == nil || runOnly)
            Button("Import from ProPresenter…") { importProPresenter() }
                .disabled(model == nil || runOnly)
            Button("Import ProPresenter Workspace…") { presentWorkspaceImport?() }
                .disabled(presentWorkspaceImport == nil || runOnly)
            Button("Import PowerPoint…") { importPowerPoint() }
                .disabled(model == nil || runOnly)
            Divider()
            Button("Export Library Backup…") { exportBackup() }
                .disabled(model == nil || runOnly)
            Button("Import Library Backup…") { importBackup() }
                .disabled(model == nil || runOnly)
        }
    }

    private func createAndSelect(_ section: LibrarySection) {
        guard let model, let id = model.createEntity(in: section) else { return }
        model.selectedSection = section
        model.selectedEntryID = id
        model.libraryRevealID = id
    }

    private func importProPresenter() {
        guard let model else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = ["pro", "probundle", "proPlaylist", "protheme"].compactMap { UTType(filenameExtension: $0) }
        panel.message = "Choose .pro documents, .probundle, .proPlaylist, or .protheme exports, or a ProPresenter library folder"
        if let showDirectory = ProPresenterImporter.proPresenterShowDirectory() {
            panel.directoryURL = showDirectory
        }
        panel.begin { response in
            guard response == .OK, !panel.urls.isEmpty else { return }
            let urls = panel.urls
            Task { @MainActor in
                await runImport(model: model, urls: urls)
            }
        }
    }

    private func importPowerPoint() {
        guard let model else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true

        panel.allowedContentTypes = ["pptx", "ppt"].compactMap { UTType(filenameExtension: $0) }
        panel.message = "Choose PowerPoint decks (.pptx) or a folder of decks"
        panel.begin { response in
            guard response == .OK, !panel.urls.isEmpty else { return }
            let urls = panel.urls
            Task { @MainActor in
                await runPowerPointImport(model: model, urls: urls)
            }
        }
    }

    @MainActor
    private func runPowerPointImport(model: AppModel, urls: [URL]) async {
        let activity = ImportActivityModel(title: "Import PowerPoint")
        ImportActivityWindow.present(activity)
        activity.phase = "Decks"
        let summaries = await model.importPowerPoint(urls: urls) { url in
            activity.detail = url.deletingPathExtension().lastPathComponent
        }
        let imported = summaries.filter { $0.presentationID != nil }
        let mediaCount = summaries.reduce(0) { $0 + $1.mediaImported }
        var summaryLines = ["\(imported.count) of \(summaries.count) decks imported\(mediaCount > 0 ? ", \(mediaCount) media files" : "")"]
        if summaries.isEmpty { summaryLines = ["Nothing to import"] }
        var warnings: [String] = []
        for summary in summaries where summary.presentationID == nil {
            warnings.append("✕ \(summary.name): \(summary.warnings.joined(separator: "; "))")
        }
        for summary in summaries where summary.presentationID != nil && !summary.warnings.isEmpty {
            warnings.append("△ \(summary.name): \(summary.warnings.joined(separator: "; "))")
        }
        activity.finish(summaryLines: summaryLines, warnings: warnings)

        let importedIDs = summaries.compactMap(\.presentationID)
        var missingFamilies: [String] = []
        for summary in summaries where summary.presentationID != nil {
            for family in summary.missingFonts where !missingFamilies.contains(family) {
                missingFamilies.append(family)
            }
        }
        if !missingFamilies.isEmpty {
            ResolveMissingFontsWindow.present(missingFamilies: missingFamilies) { replacements in
                model.applyFontReplacements(replacements, to: importedIDs)
            }
        }
    }

    @MainActor
    private func runImport(model: AppModel, urls: [URL]) async {
        let playlistBundles = urls.filter { $0.pathExtension.lowercased() == "proplaylist" }
        let themes = urls.filter { $0.pathExtension.lowercased() == "protheme" }
        let documents = urls.filter { !["proplaylist", "protheme"].contains($0.pathExtension.lowercased()) }

        let activity = ImportActivityModel(title: "Import from ProPresenter")
        ImportActivityWindow.present(activity)

        var summaryLines: [String] = []
        var warnings: [String] = []

        if !themes.isEmpty {
            activity.phase = "Themes"
            activity.detail = ""
            let summaries = await model.importProPresenterThemes(urls: themes)
            let imported = summaries.filter { $0.themeID != nil && $0.skipped == nil }
            let mediaCount = summaries.reduce(0) { $0 + $1.mediaImported }
            summaryLines.append("\(imported.count) of \(summaries.count) themes imported\(mediaCount > 0 ? ", \(mediaCount) media files" : "")")
            for summary in summaries {
                if let reason = summary.skipped {
                    warnings.append("△ \(summary.name): kept the copy already here (\(reason == .edited ? "edited in MxU Slides" : "existing"))")
                } else if summary.themeID == nil {
                    warnings.append("✕ \(summary.name): \(summary.warnings.joined(separator: "; "))")
                } else if !summary.warnings.isEmpty {
                    warnings.append("△ \(summary.name): \(summary.warnings.joined(separator: "; "))")
                }
            }
        }

        if !documents.isEmpty {
            activity.phase = "Presentations"
            let summaries = await model.importProPresenter(urls: documents) { url in
                activity.detail = url.deletingPathExtension().lastPathComponent
            }
            let imported = summaries.filter { $0.presentationID != nil }
            let mediaCount = summaries.reduce(0) { $0 + $1.mediaImported }
            summaryLines.append("\(imported.count) of \(summaries.count) documents imported\(mediaCount > 0 ? ", \(mediaCount) media files" : "")")
            for summary in summaries where summary.presentationID == nil {
                warnings.append("✕ \(summary.name): \(summary.warnings.joined(separator: "; "))")
            }
            for summary in summaries where summary.presentationID != nil && !summary.warnings.isEmpty {
                warnings.append("△ \(summary.name): \(summary.warnings.joined(separator: "; "))")
            }
        }

        if !playlistBundles.isEmpty {
            activity.phase = "Playlists"
            activity.detail = ""
            let summaries = await model.importProPresenterPlaylists(urls: playlistBundles)
            for (url, summary) in zip(playlistBundles, summaries) {
                if let reason = summary.failureReason {
                    warnings.append("✕ \(url.lastPathComponent): \(reason)")
                    continue
                }
                if !summary.services.isEmpty {
                    summaryLines.append("\(summary.services.joined(separator: ", ")) → Services (\(summary.documents.count) presentations)")
                }
                warnings.append(contentsOf: summary.warnings)
                for document in summary.documents where document.presentationID == nil {
                    warnings.append("✕ \(document.name): \(document.warnings.joined(separator: "; "))")
                }
            }
        }

        activity.finish(summaryLines: summaryLines, warnings: warnings)
    }

    private func exportBackup() {
        if let model {
            BackupTransferRunner(model: model).presentExport()
        }
    }

    private func importBackup() {
        if let model {
            BackupTransferRunner(model: model).presentImport()
        }
    }
}

struct MultiViewBadge: View {
    var body: some View {
        Label("MultiView", systemImage: "square.grid.2x2.fill")
            .font(.caption2.weight(.medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(.black.opacity(0.6), in: Capsule())
            .help("A MultiView — opens with tile tools")
    }
}

private struct EntryRow: View {
    let model: AppModel
    let entry: LibraryIndex.Entry

    var body: some View {
        HStack {
            Text(entry.name)
            Spacer()
            switch entry.kind {
            case .media:
                if let item = model.media(entry.id) {
                    if item.favorite { star }
                    if model.isMediaFileMissing(item) {
                        missingBadge
                    } else {
                        statusBadge(item.fileStatus)
                    }
                }
            case .audio:
                if let item = model.audio(entry.id), item.favorite { star }
            case .service:

                Text(entry.subkind)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .confidenceLayout:
                if model.isMultiView(entry.id) { MultiViewBadge() }
            default:
                EmptyView()
            }
        }
    }

    private var star: some View {
        Image(systemName: "star.fill")
            .foregroundStyle(.yellow)
            .imageScale(.small)
    }

    private var missingBadge: some View {
        Label("missing on this Mac", systemImage: "exclamationmark.triangle.fill")
            .font(.caption2)
            .foregroundStyle(.red)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(.red.opacity(0.15), in: Capsule())
    }

    @ViewBuilder
    private func statusBadge(_ status: MediaFileStatus) -> some View {
        switch status {
        case .ready:
            EmptyView()
        case .needsTranscode:
            Text("needs transcode")
                .font(.caption2)
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(.orange.opacity(0.25), in: Capsule())
        case .transcoding:
            ProgressView().controlSize(.mini)
        case .transcodeFailed:
            Text("transcode failed")
                .font(.caption2)
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(.red.opacity(0.25), in: Capsule())
        }
    }
}

extension LibraryIndex.Entry: @retroactive Identifiable {}

private struct ImportLyricsSheet: View {
    let model: AppModel
    let render: RenderContext?
    let onImported: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var title = ""
    @State private var linesPerSlide = 2

    private var themeId: String { model.slideBuilding.lyricsImportThemeId ?? "" }

    private var detected: LyricTextFormat? {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? nil
            : LyricTextImporter.detectFormat(text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Import Lyrics")
                .font(.headline)
            TextEditor(text: $text)
                .font(.body)
                .frame(minWidth: 420, minHeight: 240)
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text("Paste lyrics — SongSelect and ChordPro files are detected automatically")
                            .foregroundStyle(.tertiary)
                            .padding(.top, 8)
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
            HStack {
                Button("Load File…", action: loadFile)
                if let detected {
                    Text(formatCaption(detected))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            HStack(spacing: 16) {
                TextField("Title (optional — SongSelect and ChordPro carry their own)", text: $title)
                    .textFieldStyle(.roundedBorder)
                Stepper("Lines per slide: \(linesPerSlide)", value: $linesPerSlide, in: 1...8)
                    .fixedSize()
            }
            HStack {
                LyricsThemeChooser(appModel: model, render: render, themeId: model.slideBuildingBinding(\.lyricsImportThemeId))
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Import", action: importNow)
                    .keyboardShortcut(.defaultAction)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 520)
    }

    private func formatCaption(_ format: LyricTextFormat) -> String {
        switch format {
        case .songSelect: return "Detected: SongSelect lyrics — CCLI number will be stamped"
        case .chordPro: return "Detected: ChordPro — chords stripped for slides, kept for charts"
        case .plainText: return "Plain text — blank lines split slides, labels make sections"
        }
    }

    private func loadFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText]
            + ["cho", "chopro", "crd", "chordpro"].compactMap { UTType(filenameExtension: $0) }
        panel.begin { response in
            guard response == .OK, let url = panel.url,
                  let contents = try? String(contentsOf: url, encoding: .utf8)
            else { return }
            Task { @MainActor in
                text = contents
                if title.isEmpty { title = url.deletingPathExtension().lastPathComponent }
            }
        }
    }

    private func importNow() {
        let fallback = title.trimmingCharacters(in: .whitespaces)
        let id = model.importLyrics(
            text: text,
            fallbackTitle: fallback.isEmpty ? nil : fallback,
            linesPerSlide: linesPerSlide,
            themeId: themeId
        )
        dismiss()
        if let id { onImported(id) }
    }
}

private struct NewFolderSheet: View {
    let model: AppModel

    let entry: LibraryIndex.Entry?

    var parentPath: [String] = []

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Folder")
                .font(.headline)
            TextField("Folder name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(create)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Create", action: create)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 380)
    }

    private func create() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let fullPath = (parentPath + [trimmed]).joined(separator: "/")
        if let entry {
            model.moveToFolder(entry, folder: fullPath)
        } else {
            model.createFolder(fullPath, in: model.selectedSection)
        }
        dismiss()
    }
}

struct LibraryItemCard: View {
    let model: AppModel
    let render: RenderContext?
    let entry: LibraryIndex.Entry

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                Color.black.opacity(0.35)
                LibraryItemFace(model: model, render: render, entry: entry)
            }
            .overlay(alignment: .topLeading) {
                if entry.kind == .confidenceLayout, model.isMultiView(entry.id) {
                    MultiViewBadge().padding(5)
                }
            }
            .frame(maxWidth: .infinity)
            .aspectRatio(16 / 9, contentMode: .fit)
            .clipShape(RoundedRectangle.standard(CornerStandard.element))
            .overlay(
                RoundedRectangle.standard(CornerStandard.element)
                    .strokeBorder(Color(nsColor: .separatorColor).opacity(0.4), lineWidth: 1)
            )
            HStack(spacing: 4) {
                Text(entry.name)
                    .font(.caption)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 2)
        }
    }
}

struct LibraryItemFace: View {
    let model: AppModel
    let render: RenderContext?
    let entry: LibraryIndex.Entry

    private enum Face {
        case presentation(Presentation, Theme?)
        case overlay(Overlay)
        case confidenceLayout(ConfidenceLayout)
    }

    @State private var loaded: Face?

    @State private var loadedStamp = ""

    private var updatedAt: TimeInterval {
        model.entry(entry.id)?.updatedAt.timeIntervalSince1970 ?? 0
    }

    var body: some View {
        face
            .task(id: "\(entry.id)|\(updatedAt)") { await load() }
    }

    @ViewBuilder
    private var face: some View {
        switch entry.kind {
        case .media:
            PosterImage(model: model, mediaId: entry.id)
        case .presentation, .overlay, .confidenceLayout:
            switch loaded {
            case .presentation(let presentation, let theme):
                if let slide = presentation.slides.first {
                    SlideThumbnailView(
                        model: model, render: render,
                        slide: slide, presentation: presentation, theme: theme,
                        arrangementId: nil,
                        hideScopedBackgrounds: false, legibleText: false,
                        contentStamp: loadedStamp
                    )
                } else {
                    glyphFace
                }
            case .overlay(let overlay):
                let slide = Slide(id: overlay.id, name: overlay.name, objects: overlay.objects)
                let presentation = Presentation(
                    id: overlay.id, name: overlay.name, presentationKind: .deck,
                    themeId: "", slides: [slide]
                )
                SlideThumbnailView(
                    model: model, render: render,
                    slide: slide, presentation: presentation, theme: nil,
                    arrangementId: nil,
                    hideScopedBackgrounds: false, legibleText: false,
                    contentStamp: loadedStamp
                )
            case .confidenceLayout(let layout):

                let slide = Slide(
                    id: layout.id, name: layout.name,
                    objects: LinkedText.previewObjects(layout.objects)
                )
                let presentation = {
                    var mirror = Presentation(
                        id: layout.id, name: layout.name, presentationKind: .deck,
                        themeId: "", slides: [slide]
                    )
                    mirror.canvasWidth = layout.canvasWidth
                    mirror.canvasHeight = layout.canvasHeight
                    return mirror
                }()
                SlideThumbnailView(
                    model: model, render: render,
                    slide: slide, presentation: presentation, theme: nil,
                    arrangementId: nil,
                    hideScopedBackgrounds: false, legibleText: false,
                    contentStamp: loadedStamp
                )
            case nil:
                glyphFace
            }
        default:
            glyphFace
        }
    }

    private func load() async {
        let client = model.client
        let stamp = updatedAt
        switch entry.kind {
        case .presentation:
            if let presentation = await ThumbnailStore.shared.faceValue(
                Presentation.self, id: entry.id, updatedAt: stamp, client: client
            ) {
                var theme: Theme?
                var themeStamp: TimeInterval = 0

                let themeId = presentation.slides.first.map { presentation.themeId(for: $0) } ?? presentation.themeId
                if !themeId.isEmpty {
                    themeStamp = model.entry(themeId)?.updatedAt.timeIntervalSince1970 ?? 0
                    theme = await ThumbnailStore.shared.faceValue(
                        Theme.self, id: themeId, updatedAt: themeStamp, client: client
                    )
                }
                loaded = .presentation(presentation, theme)
                loadedStamp = "\(stamp)|\(themeStamp)"
            }
        case .overlay:
            if let overlay = await ThumbnailStore.shared.faceValue(
                Overlay.self, id: entry.id, updatedAt: stamp, client: client
            ) {
                loaded = .overlay(overlay)
                loadedStamp = "\(stamp)"
            }
        case .confidenceLayout:
            if let layout = await ThumbnailStore.shared.faceValue(
                ConfidenceLayout.self, id: entry.id, updatedAt: stamp, client: client
            ) {
                loaded = .confidenceLayout(layout)
                loadedStamp = "\(stamp)"
            }
        default:
            break
        }
    }

    private var glyphFace: some View {
        Glyph(kind: sectionGlyph, size: 22)
            .foregroundStyle(.secondary)
    }

    private var sectionGlyph: GlyphKind {
        switch entry.kind {
        case .audio: .audio
        case .theme: .themes
        case .confidenceLayout: .confidence
        default: .presentations
        }
    }
}

struct FolderPreviewCard: View {
    let model: AppModel
    let render: RenderContext?
    let name: String
    let count: Int

    let entries: [LibraryIndex.Entry]
    let action: () -> Void

    @State private var hovering = false
    @State private var page = 0

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                face
                    .frame(maxWidth: .infinity)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .clipShape(RoundedRectangle.standard(CornerStandard.element))
                    .overlay(
                        RoundedRectangle.standard(CornerStandard.element)
                            .strokeBorder(
                                Color(nsColor: .separatorColor).opacity(0.4), lineWidth: 1
                            )
                    )
                HStack(spacing: 4) {
                    Glyph(kind: .folder, size: 10)
                        .foregroundStyle(.tertiary)
                    Text(name)
                        .font(.caption)
                        .lineLimit(1)
                    Text("\(count)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .task(id: hovering) {

            guard hovering, entries.count > 4 else { return }
            let pages = (entries.count + 3) / 4
            while hovering, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(0.9))
                if Task.isCancelled { return }
                page = (page + 1) % pages
            }
        }
        .onChange(of: hovering) { _, inside in
            if !inside { page = 0 }
        }
    }

    @ViewBuilder
    private var face: some View {
        if entries.isEmpty {
            ZStack {
                Color.primary.opacity(0.04)
                Glyph(kind: .folder, size: 26)
                    .foregroundStyle(.secondary)
            }
        } else {
            quadrants
        }
    }

    private var quadrants: some View {
        let visible = Array(entries.dropFirst(page * 4).prefix(4))
        return VStack(spacing: 1) {
            HStack(spacing: 1) {
                quadrant(visible.indices.contains(0) ? visible[0] : nil)
                quadrant(visible.indices.contains(1) ? visible[1] : nil)
            }
            HStack(spacing: 1) {
                quadrant(visible.indices.contains(2) ? visible[2] : nil)
                quadrant(visible.indices.contains(3) ? visible[3] : nil)
            }
        }
        .background(Color.black.opacity(0.35))
    }

    @ViewBuilder
    private func quadrant(_ entry: LibraryIndex.Entry?) -> some View {
        ZStack {
            Color.primary.opacity(0.04)
            if let entry {
                LibraryItemFace(model: model, render: render, entry: entry)
            }
        }
        .clipped()
    }
}

struct SlideDropTarget: ViewModifier {
    let enabled: Bool
    let accepts: (String) -> Bool
    let perform: ([String]) -> Bool
    @Binding var targeted: Bool

    func body(content: Content) -> some View {
        if enabled {
            content
                .dropDestination(for: String.self) { payloads, _ in
                    perform(payloads)
                } isTargeted: { on in
                    let payload = NSPasteboard(name: .drag).string(forType: .string)
                    targeted = on && accepts(payload ?? "")
                }
                .overlay {
                    if targeted {

                        RoundedRectangle.standard(CornerStandard.element)
                            .strokeBorder(
                                Color(nsColor: .controlAccentColor).opacity(0.9),
                                lineWidth: 2)
                    }
                }
        } else {
            content
        }
    }
}

struct LyricsThemeChooser: View {
    let appModel: AppModel
    let render: RenderContext?
    @Binding var themeId: String

    @State private var choosing = false

    var body: some View {
        Button {
            choosing.toggle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "paintpalette")
                Text(title)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
            }
        }
        .fixedSize()
        .help("Theme — how the lyrics will look; pick from rendered samples")
        .popover(isPresented: $choosing, arrowEdge: .top) {
            catalog
        }
    }

    private var title: String {
        guard !themeId.isEmpty else { return "Theme: None" }
        return "Theme: \(appModel.entry(themeId)?.name ?? "Missing")"
    }

    private var catalog: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 168), spacing: 10)],
                alignment: .leading, spacing: 10
            ) {
                card(id: "", name: "None")
                ForEach(appModel.entries(in: .themes), id: \.id) { entry in
                    card(id: entry.id, name: entry.name)
                }
            }
            .padding(12)
        }
        .frame(width: 580, height: 360)
    }

    private func card(id: String, name: String) -> some View {
        let selected = id == themeId
        return Button {
            themeId = id
            choosing = false
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                LyricsThemeSample(appModel: appModel, render: render, themeId: id)
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .clipShape(RoundedRectangle.standard(CornerStandard.element))
                    .overlay(
                        RoundedRectangle.standard(CornerStandard.element)
                            .strokeBorder(
                                selected ? Color.accentColor : Color.separator.opacity(0.5),
                                lineWidth: selected ? 2 : 1
                            )
                    )
                Text(name)
                    .font(.caption2)
                    .lineLimit(1)
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct LyricsThemeSample: View {
    let appModel: AppModel
    let render: RenderContext?
    let themeId: String

    @State private var loaded: Theme?

    @State private var loadedStamp: String?

    static let sampleText = "Amazing grace how sweet the sound\nThat saved a wretch like me"

    private var updatedAt: TimeInterval {
        appModel.entry(themeId)?.updatedAt.timeIntervalSince1970 ?? 0
    }

    private var slide: Slide {
        var slide = Slide(
            id: "lyrics-theme-sample", name: "",
            objects: [SlideObject(
                id: "lyrics-theme-sample-text", objectKind: .text,
                name: "Lyrics", text: Self.sampleText
            )]
        )
        slide.themeSlideName = "Lyrics"
        return slide
    }

    var body: some View {
        let slide = slide
        let presentation = Presentation(
            id: "lyrics-theme-sample|\(themeId)", name: "Sample", presentationKind: .deck,
            themeId: themeId, slides: [slide]
        )
        ZStack {
            Color.clear
            if let loadedStamp {
                SlideThumbnailView(
                    model: appModel, render: render,
                    slide: slide, presentation: presentation,
                    theme: loaded,
                    arrangementId: nil,
                    hideScopedBackgrounds: false, legibleText: false,
                    contentStamp: loadedStamp
                )
            }
        }
        .task(id: "\(themeId)|\(updatedAt)") { await load() }
    }

    private func load() async {
        let stamp = updatedAt
        if !themeId.isEmpty {
            loaded = await ThumbnailStore.shared.faceValue(
                Theme.self, id: themeId, updatedAt: stamp, client: appModel.client
            )
        }
        loadedStamp = "\(stamp)"
    }
}
