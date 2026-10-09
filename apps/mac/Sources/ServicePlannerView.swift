import PresenterCore
import SlideScene
import SwiftUI

struct RunOrderList: View {
    let model: AppModel
    var controls: ServiceControls?
    let serviceID: String

    var render: RenderContext?
    @Binding var selectedItemID: String?

    var onReselect: () -> Void = {}

    @Environment(\.runOnly) private var runOnly

    @AppStorage("appMode") private var appModeRaw = AppMode.edit.rawValue

    @State private var addingHeader = false
    @State private var headerText = ""
    @State private var collapsedHeaders: Set<String> = []

    @State private var showHidden = false

    private var collapseKey: String { "runOrder.collapsed.\(serviceID)" }

    private func loadCollapsed() {
        collapsedHeaders = Set(
            UserDefaults.standard.stringArray(forKey: collapseKey) ?? []
        )
    }

    private func persistCollapsed() {
        UserDefaults.standard.set(Array(collapsedHeaders), forKey: collapseKey)
    }

    @State private var renamingItem: ServiceItem?
    @State private var itemRenameText = ""

    @State private var applyThemeTarget: ApplyThemeTarget?

    @State private var selection: Set<String> = []

    @State private var rowFrames: [String: CGRect] = [:]

    @State private var marqueeRect: CGRect?

    @State private var marqueeBase: Set<String> = []

    @State private var addingFromLibrary = false

    @State private var dropTargetItemID: String?

    @State private var emptyDropTargeted = false

    @State private var mediaMenuState = MediaCueMenuState()

    private var renamingItemActive: Binding<Bool> {
        Binding(get: { renamingItem != nil }, set: { if !$0 { renamingItem = nil } })
    }

    var body: some View {
        if let service = try? model.service(serviceID) {
            let visible = visibleItems(service)
            let order = visible.map(\.id)
            let changed = model.versionChangedItemIDs(serviceID)
            VStack(spacing: 0) {
                runOrderList(service: service, visible: visible, order: order, changed: changed)
                if !runOnly {
                    Divider()
                    addBar
                }
            }
            .onAppear {
                loadCollapsed()
                if let id = selectedItemID { selection = [id] }
            }
            .onChange(of: selection) { _, selection in selectionChanged(selection, visible: visible) }
            .onChange(of: selectedItemID) { _, id in surfaceItemChanged(id) }
            .alert("Add Header", isPresented: $addingHeader) {
                TextField("Header", text: $headerText)
                Button("Add") {
                    model.addServiceHeader(serviceID, name: headerText)
                    headerText = ""
                }
                Button("Cancel", role: .cancel) { headerText = "" }
            }
            .sheet(item: $applyThemeTarget) { target in
                ApplyThemeSheet(
                    appModel: model, render: render, deckThemeId: model.themeID(of: target.presentationID),
                    scope: "Applies to every slide in \u{201C}\(model.entry(target.presentationID)?.name ?? "this presentation")\u{201D}"
                        + (model.presentationHasSlideThemes(target.presentationID)
                            ? ", slides with a theme of their own too." : ".")
                ) { themeId, design in
                    model.applyTheme(to: target.presentationID, themeID: themeId, design: design)
                }
            }
            .alert("Rename Item", isPresented: renamingItemActive) {
                TextField("Name", text: $itemRenameText)
                Button("Rename") {
                    if let target = renamingItem,
                       let entry = model.indexEntry(target.refId) {
                        model.rename(entry, to: itemRenameText)
                    }
                    renamingItem = nil
                }
                Button("Cancel", role: .cancel) { renamingItem = nil }
            } message: {
                Text("This renames the item in the library too — everywhere it's used.")
            }
            .sheet(isPresented: $addingFromLibrary) {
                LibrarySearchSheet(model: model, serviceID: serviceID)
            }
            .mediaCueSheets(model: model, state: mediaMenuState)
        } else {
            ContentUnavailableView("Service not found", systemImage: "calendar.badge.exclamationmark")
        }
    }

    private func runOrderList(
        service: Service, visible: [ServiceItem], order: [String], changed: Set<String>
    ) -> some View {
        List(selection: $selection) {
            ForEach(visible, id: \.id) { item in
                if item.itemKind == .header {

                    headerRow(item, order: order)
                        .tag(item.id)
                        .listRowSeparator(.hidden)
                        .reportingGlobalFrame(id: item.id, into: $rowFrames)

                        .draggablePayload(runOnly ? nil : "svc::" + item.id)
                } else {
                    itemRow(item, order: order, changed: changed.contains(item.id))
                        .tag(item.id)
                        .listRowSeparator(.hidden)
                        .listRowBackground(liveRowBackground(item))
                        .reportingGlobalFrame(id: item.id, into: $rowFrames)
                        .draggablePayload(runOnly ? nil : "svc::" + item.id)
                }
            }
            .onInsert(of: [.plainText, .text, .fileURL]) { index, providers in
                guard !runOnly else { return }
                let anchorID = visible.indices.contains(index) ? visible[index].id : nil

                let fileURLs = Self.draggedFileURLs()
                let mediaBatch = fileURLs.isEmpty ? draggedMediaBatch() : []
                if !fileURLs.isEmpty {
                    DiagnosticsStore.shared.note("runOrder.insert.files", detail: "\(fileURLs.count)")
                    Task { await model.insertDroppedMedia(fromFiles: fileURLs, service: serviceID, beforeItemID: anchorID) }
                } else if !mediaBatch.isEmpty {
                    DiagnosticsStore.shared.note("runOrder.insert.mediaBatch", detail: "\(mediaBatch.count)")
                    Task { await model.insertDroppedMedia(mediaBatch, service: serviceID, beforeItemID: anchorID) }
                }
                for provider in providers where fileURLs.isEmpty && mediaBatch.isEmpty {
                    _ = provider.loadObject(ofClass: NSString.self) { object, _ in
                        guard let payload = object as? String else { return }
                        Task { @MainActor in
                            insertPayload(payload, beforeItemID: anchorID)
                        }
                    }
                }
            }
            if visible.isEmpty, !runOnly {
                emptyDropRow
                    .listRowSeparator(.hidden)
                    .selectionDisabled()
            }
            let hidden = ServiceRunOrder.hidden(service.items)
            if !hidden.isEmpty {
                hiddenGroupRow(count: hidden.count)
                    .listRowSeparator(.hidden)
                    .selectionDisabled()
                if showHidden {
                    ForEach(hidden, id: \.id) { item in
                        hiddenRow(item)
                            .listRowSeparator(.hidden)
                            .selectionDisabled()
                    }
                }
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)

        .onDeleteCommand {
            guard !runOnly, !selection.isEmpty else { return }
            requestRemoval(order.filter(selection.contains))
        }
        .listMarquee(
            active: !runOnly, rowFrames: Array(rowFrames.values),
            began: marqueeBegan, changed: marqueeChanged, ended: marqueeEnded,
            pressedRow: { rowPressed($0, $1, visible: visible) })
        .inputRegion("run order")
        .overlay { ListMarqueeBand(rect: marqueeRect) }
    }

    private var emptyDropRow: some View {
        VStack(spacing: 6) {
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 18))
            Text("Drag presentations or media here")
                .font(.callout)
        }
        .foregroundStyle(.tertiary)
        .frame(maxWidth: .infinity, minHeight: 140)
        .contentShape(Rectangle())
        .overlay(
            RoundedRectangle.standard(CornerStandard.element)
                .strokeBorder(
                    emptyDropTargeted ? Color.accentColor : Color(nsColor: .separatorColor).opacity(0.7),
                    style: emptyDropTargeted
                        ? StrokeStyle(lineWidth: 1.5)
                        : StrokeStyle(lineWidth: 1, dash: [4, 3]))
        )
        .padding(.vertical, 6)

        .onDrop(of: [.plainText, .fileURL], isTargeted: $emptyDropTargeted) { _ in
            let fileURLs = Self.draggedFileURLs()
            let payloads = Self.draggedStrings()
            let mediaBatch = RunOrderMediaDrop.libraryBatch(payloads) { model.media($0) }
            if runOnly {
                return false
            } else if !fileURLs.isEmpty {
                DiagnosticsStore.shared.note("runOrder.emptyDrop.files", detail: "\(fileURLs.count)")
                Task { await model.insertDroppedMedia(fromFiles: fileURLs, service: serviceID, beforeItemID: nil) }
                return true
            } else if !mediaBatch.isEmpty {
                DiagnosticsStore.shared.note("runOrder.emptyDrop.mediaBatch", detail: "\(mediaBatch.count)")
                Task { await model.insertDroppedMedia(mediaBatch, service: serviceID, beforeItemID: nil) }
                return true
            } else {
                var added = false
                for payload in payloads where model.addServiceItem(serviceID, refID: payload) {
                    added = true
                }
                return added
            }
        }
    }

    private func draggedMediaBatch() -> [MediaItem] {
        RunOrderMediaDrop.libraryBatch(Self.draggedStrings()) { model.media($0) }
    }

    private static func draggedStrings() -> [String] {
        NSPasteboard(name: .drag).pasteboardItems?.compactMap { $0.string(forType: .string) } ?? []
    }

    private static func draggedFileURLs() -> [URL] {
        (NSPasteboard(name: .drag).readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    private func marqueeBegan(_ modifiers: NSEvent.ModifierFlags) {
        InputTrailRecorder.shared.record("marquee in run order")
        marqueeBase = modifiers.contains(.shift) ? selection : []
        if !modifiers.contains(.shift), !modifiers.contains(.command) {
            selection = []
        }
    }

    private func rowPressed(
        _ point: CGPoint, _ modifiers: NSEvent.ModifierFlags, visible: [ServiceItem]
    ) -> (() -> Void)? {
        let id = rowFrames.first(where: { $0.value.contains(point) })?.key
        if let id, RunOrderSelection.isReselect(
            pressed: id, current: selectedItemID,
            command: modifiers.contains(.command), shift: modifiers.contains(.shift),
            control: modifiers.contains(.control)) {
            let name = visible.first { $0.id == id }?.name ?? "-"
            return {
                DiagnosticsStore.shared.note(
                    "runOrder.click", detail: "\(id) \"\(name)\" already selected: jump back to it")
                onReselect()
            }
        } else {
            return nil
        }
    }

    private func marqueeChanged(_ band: CGRect) {
        marqueeRect = band
        selection = RunOrderSelection.swept(frames: rowFrames, band: band, keeping: marqueeBase)
    }

    private func marqueeEnded() {
        marqueeRect = nil
        marqueeBase = []
    }

    private func selectionChanged(_ selection: Set<String>, visible: [ServiceItem]) {
        let surface = RunOrderSelection.surfaceItem(
            selection: selection, current: selectedItemID, rows: visible)
        if surface != selectedItemID {

            let name = { (id: String?) in id.flatMap { id in visible.first { $0.id == id }?.name } ?? "-" }
            DiagnosticsStore.shared.note(
                "runOrder.surface",
                detail: "\(selectedItemID ?? "-") → \(surface ?? "-") (\(selection.count) selected)"
                    + " \"\(name(selectedItemID))\" → \"\(name(surface))\"; \(InputTrailRecorder.shared.cause())")
            selectedItemID = surface
        }
    }

    private func surfaceItemChanged(_ id: String?) {
        if let id {
            if !selection.contains(id) { selection = [id] }
        } else if !selection.isEmpty {
            selection = []
        }
    }

    private func visibleItems(_ service: Service) -> [ServiceItem] {
        ServiceRunOrder.sidebarRows(service.items, collapsedHeaders: collapsedHeaders, timeHexId: nil, order: nil)
    }

    private func insertPayload(_ payload: String, beforeItemID: String?) {
        let added: ServiceItem? = if !payload.hasPrefix("svc::"), let ref = model.indexEntry(payload),
            let kind = ServiceRunOrder.itemKind(adding: ref.kind) {
            ServiceItem(id: UUID().uuidString, itemKind: kind, name: ref.name, refId: payload)
        } else {
            nil
        }
        model.updateService(serviceID) { service in
            let insertIndex = beforeItemID.flatMap { id in
                service.items.firstIndex { $0.id == id }
            } ?? service.items.count
            if payload.hasPrefix("svc::") {
                let movingID = String(payload.dropFirst("svc::".count))
                guard let from = service.items.firstIndex(where: { $0.id == movingID })
                else { return }
                let item = service.items.remove(at: from)
                let target = from < insertIndex ? insertIndex - 1 : insertIndex
                service.items.insert(item, at: min(max(target, 0), service.items.count))
            } else if let added {
                service.items.insert(added, at: min(insertIndex, service.items.count))
            }
        }
    }

    private func headerRow(_ item: ServiceItem, order: [String]) -> some View {
        let collapsed = collapsedHeaders.contains(item.id)
        let tint = item.colorHex.flatMap(ColorHex.color).map {
            Color(red: $0.red, green: $0.green, blue: $0.blue, opacity: $0.alpha)
        }

        return HStack(spacing: 6) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) {
                    if collapsed {
                        collapsedHeaders.remove(item.id)
                    } else {
                        collapsedHeaders.insert(item.id)
                    }
                }
                persistCollapsed()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(collapsed ? -90 : 0))
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(collapsed ? "Expand" : "Collapse")
            rule(tint)
            Text(item.name.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(tint ?? Color.secondary.opacity(0.8))
                .tracking(0.6)
                .layoutPriority(1)
            rule(tint)

            Color.clear.frame(width: 14, height: 1)
        }
        .contentShape(Rectangle())
        .contextMenu {
            if !runOnly {
                let batch = ListMultiSelect.batch(clicked: item.id, selection: selection, order: order)
                if batch.count > 1 {
                    bulkMenu(batch)
                } else {
                    headerColorMenu(item)
                    Divider()

                    Button("Hide") { hide([item.id]) }
                    removeButton(item)
                }
            }
        }

        .id("runOrderHeaderMenu|\(item.id)|\(inMultiSelection(item.id))")
    }

    private func inMultiSelection(_ id: String) -> Bool {
        selection.count > 1 && selection.contains(id)
    }

    @ViewBuilder
    private func bulkMenu(_ ids: [String]) -> some View {
        Text("\(ids.count) Items")
        Divider()
        Button("Hide") { hide(ids) }
        Button("Remove from Service", role: .destructive) { requestRemoval(ids) }
    }

    @ViewBuilder
    private func itemRow(_ item: ServiceItem, order: [String], changed: Bool) -> some View {
        HStack(spacing: 8) {

            Text(displayName(item))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(item.itemKind == .info ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                .layoutPriority(0)
            Spacer(minLength: 4)

            if changed {
                Text("Changed")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.12), in: Capsule())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help("Changed in this version. Right-click and choose Use Main's to undo it.")
            }

            if item.itemKind == .presentation,
               let override = arrangementName(item) {
                Text(override)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if item.itemKind != .info {
                Glyph(
                    kind: item.itemKind == .presentation ? .presentations
                        : item.itemKind == .audio || item.itemKind == .playlist ? .audio
                        : .media,
                    size: 13
                )
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
            }
        }
        .overlay(
            RoundedRectangle.standard(CornerStandard.element)
                .strokeBorder(Color.accentColor, lineWidth: 1.5)
                .padding(-4)
                .opacity(dropTargetItemID == item.id ? 1 : 0)
        )
        .dropDestination(for: String.self) { payloads, _ in

            if !runOnly, item.itemKind == .presentation,
               let dragged = payloads.first.flatMap(SlideBulkEdit.draggedSlide(in:)) {
                return model.copySlide(
                    dragged.slideID, from: dragged.presentationID,
                    to: item.refId, beforeSlideID: nil)
            } else {
                return false
            }
        } isTargeted: { over in

            let slideDrag = NSPasteboard(name: .drag).string(forType: .string)
                .flatMap(SlideBulkEdit.draggedSlide(in:))
            let accepts = item.itemKind == .presentation && slideDrag.map { $0.presentationID != item.refId } == true
            if over, accepts {
                dropTargetItemID = item.id
            } else if !over, dropTargetItemID == item.id {
                dropTargetItemID = nil
            }
        }
        .contextMenu {
            let batch = ListMultiSelect.batch(clicked: item.id, selection: selection, order: order)
            if !runOnly, batch.count > 1 {
                bulkMenu(batch)
            } else if !runOnly {

                if let entry = model.entry(item.refId), entry.kind.opensInEditor {
                    Button("Edit…") {
                        model.openInEditor(entryID: entry.id)
                        appModeRaw = AppMode.edit.rawValue
                    }
                    Divider()
                }

                if item.itemKind == .media {

                    MediaCueMenuItems(
                        model: model, actionRouter: controls?.actionRouter,
                        mediaID: item.refId, state: mediaMenuState,
                        fallbackName: item.name
                    )
                    Divider()
                    outputPresetMenu(item)
                } else if item.itemKind != .info {

                    Button("Rename…") {
                        renamingItem = item
                        itemRenameText = displayName(item)
                    }
                    if item.itemKind == .presentation {
                        arrangementMenu(item)
                        outputPresetMenu(item)

                        Button("Apply Theme…") {
                            applyThemeTarget = ApplyThemeTarget(presentationID: item.refId, slideIDs: nil)
                        }
                    }
                }
                Divider()
                Button("Hide") { hide([item.id]) }
                if changed {
                    Button("Use Main's") { model.useMainForServiceItem(serviceID, itemID: item.id) }
                }
                removeButton(item)
            }
        }

        .id("runOrderRowMenu|\(item.id)|\(item.itemKind.rawValue)|\(item.itemKind == .media && model.media(item.refId) == nil)|\(inMultiSelection(item.id))")
    }

    private func displayName(_ item: ServiceItem) -> String {
        model.entry(item.refId)?.name ?? item.name
    }

    @ViewBuilder
    private func liveRowBackground(_ item: ServiceItem) -> some View {
        if isItemLive(item) {
            RoundedRectangle.standard(CornerStandard.element)
                .fill(Color.primary.opacity(0.08))
                .padding(.vertical, 1)
        }
    }

    private func isItemLive(_ item: ServiceItem) -> Bool {
        guard let controls else { return false }
        switch item.itemKind {
        case .presentation: return controls.liveContextID == item.id
        case .media: return controls.isMediaLive(item.refId)
        case .audio: return controls.state.liveAudio.contains { $0.audioItemId == item.refId }
        case .playlist: return controls.state.liveAudio.contains { $0.playlistId == item.refId }
        case .header, .info: return false
        }
    }

    private func rule(_ tint: Color?) -> some View {
        Rectangle()
            .fill(tint?.opacity(0.5) ?? Color(nsColor: .separatorColor).opacity(0.4))
            .frame(height: 1)
            .frame(maxWidth: .infinity)
    }

    private static let headerColors: [(name: String, hex: String)] = [
        ("Red", "#FF5F57FF"), ("Orange", "#FFA344FF"), ("Yellow", "#FFD60AFF"),
        ("Green", "#32D74BFF"), ("Blue", "#4B9BFFFF"), ("Purple", "#BF5AF2FF"),
    ]

    @ViewBuilder
    private func headerColorMenu(_ item: ServiceItem) -> some View {
        Menu("Color") {
            Toggle("None", isOn: Binding(
                get: { item.colorHex == nil },
                set: { _ in
                    model.setServiceHeaderColor(serviceID, itemID: item.id, colorHex: nil)
                }
            ))
            Divider()
            ForEach(Self.headerColors, id: \.hex) { color in
                Toggle(color.name, isOn: Binding(
                    get: { item.colorHex == color.hex },
                    set: { _ in
                        model.setServiceHeaderColor(
                            serviceID, itemID: item.id, colorHex: color.hex
                        )
                    }
                ))
            }
        }
    }

    private func importMediaIntoService() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.image, .movie, .video]
        panel.begin { response in
            guard response == .OK else { return }
            let urls = panel.urls
            Task { @MainActor in
                let before = Set(model.entries(in: .media).map(\.id))
                await model.importFiles(urls)
                let added = model.entries(in: .media).map(\.id).filter { !before.contains($0) }
                for id in added {
                    model.addServiceItem(serviceID, refID: id)
                }
            }
        }
    }

    private func hiddenGroupRow(count: Int) -> some View {
        HStack(spacing: 6) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { showHidden.toggle() }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(showHidden ? 0 : -90))
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(showHidden ? "Collapse" : "Expand")
            rule(nil)
            Text("HIDDEN (\(count))")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Color.secondary.opacity(0.8))
                .tracking(0.6)
                .layoutPriority(1)
            rule(nil)
            Color.clear.frame(width: 14, height: 1)
        }
        .padding(.top, 6)
        .contentShape(Rectangle())
    }

    private func hiddenRow(_ item: ServiceItem) -> some View {
        HStack(spacing: 8) {

            Text(item.itemKind == .header ? item.name.uppercased() : displayName(item))
                .font(item.itemKind == .header ? .caption2.weight(.semibold) : .body)
                .tracking(item.itemKind == .header ? 0.6 : 0)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.tertiary)
            Spacer(minLength: 4)
            if !runOnly {
                Button("Unhide") {
                    model.setServiceItemHidden(serviceID, itemID: item.id, hidden: false)
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
        .contextMenu {
            if !runOnly {
                Button("Unhide") {
                    model.setServiceItemHidden(serviceID, itemID: item.id, hidden: false)
                }
                Divider()
                removeButton(item)
            }
        }
    }

    private func removeButton(_ item: ServiceItem) -> some View {
        Button("Remove from Service", role: .destructive) { requestRemoval([item.id]) }
    }

    private func requestRemoval(_ ids: [String]) {
        guard let service = try? model.service(serviceID) else { return }
        let removal = RunOrderSelection.removal(of: ids, in: service.items)
        guard removal.count > 0 else { return }
        for item in removal.local + removal.synced {
            model.removeServiceItem(serviceID, itemID: item.id)
        }
        deselect(removal.ids)
    }

    private func hide(_ ids: [String]) {
        for id in ids {
            model.setServiceItemHidden(serviceID, itemID: id, hidden: true)
        }
        deselect(ids)
    }

    private func deselect(_ ids: [String]) {
        let wasSelected = !selection.isDisjoint(with: ids)
        selection.subtract(ids)
        if !wasSelected, let current = selectedItemID, ids.contains(current) {
            selectedItemID = nil
        }
    }

    @ViewBuilder
    private func arrangementMenu(_ item: ServiceItem) -> some View {

        let arrangements = model.presentation(item.refId)?.arrangements
        if let arrangements, !arrangements.isEmpty {
            Menu("Arrangement") {
                Toggle(
                    "Default",
                    isOn: Binding(
                        get: { item.arrangementId?.isEmpty ?? true },
                        set: { _ in
                            model.setServiceItemArrangement(
                                serviceID, itemID: item.id, arrangementID: nil
                            )
                        }
                    )
                )
                Divider()
                ForEach(arrangements, id: \.id) { arrangement in
                    Toggle(
                        arrangement.name,
                        isOn: Binding(
                            get: { item.arrangementId == arrangement.id },
                            set: { _ in
                                model.setServiceItemArrangement(
                                    serviceID, itemID: item.id, arrangementID: arrangement.id
                                )
                            }
                        )
                    )
                }
            }
        }
    }

    @ViewBuilder
    private func outputPresetMenu(_ item: ServiceItem) -> some View {
        let presets = model.entries(of: .outputPreset)
        if !presets.isEmpty {
            Menu("Output Preset") {
                Toggle(
                    "Keep Current Look",
                    isOn: Binding(
                        get: { item.outputPresetId?.isEmpty ?? true },
                        set: { _ in
                            model.setServiceItemOutputPreset(
                                serviceID, itemID: item.id, presetID: nil)
                        }
                    )
                )
                Divider()
                ForEach(presets, id: \.id) { preset in
                    Toggle(
                        preset.name,
                        isOn: Binding(
                            get: { item.outputPresetId == preset.id },
                            set: { _ in
                                model.setServiceItemOutputPreset(
                                    serviceID, itemID: item.id, presetID: preset.id)
                            }
                        )
                    )
                }
            }
        }
    }

    private var addBar: some View {
        HStack(spacing: 10) {
            Menu {
                Button("New Slides Presentation") {
                    if let id = model.createEntity(in: .presentations) {
                        model.addServiceItem(serviceID, refID: id)
                    }
                }
                Button("New Media Item…") { importMediaIntoService() }
                Button("Header…") { addingHeader = true }
                Divider()
                Button("Add From Library…") { addingFromLibrary = true }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .medium))
                    Text("Add Item")
                }
            }
            Spacer()
            if let service = try? model.service(serviceID) {
                Text(itemCountLabel(service))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(.borderless)
        .menuStyle(.borderlessButton)
        .controlSize(.small)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    private func itemCountLabel(_ service: Service) -> String {
        let count = service.items.filter { $0.itemKind != .header }.count
        return count == 1 ? "1 item" : "\(count) items"
    }

    private func arrangementName(_ item: ServiceItem) -> String? {

        guard let id = item.arrangementId, !id.isEmpty,
              let presentation = model.presentation(item.refId)
        else { return nil }
        return presentation.arrangements?.first { $0.id == id }?.name
    }
}

struct ServiceItemDetailView: View {
    let model: AppModel
    let render: RenderContext?
    let controls: ServiceControls?
    let serviceID: String
    let itemID: String?

    var body: some View {
        if let itemID,
           let service = try? model.service(serviceID),
           let item = service.items.first(where: { $0.id == itemID }),
           item.itemKind != .header {
            switch item.itemKind {
            case .presentation:
                PresentGridView(
                    model: model, render: render, controls: controls,
                    presentationID: item.refId, arrangementId: item.arrangementId,
                    contextID: item.id,
                    serviceID: serviceID, serviceItem: item
                )
                .id(item.id)
            case .media:
                MediaFireView(model: model, controls: controls, mediaID: item.refId, serviceItemID: item.id)
            case .audio:
                AudioFireView(model: model, controls: controls, audioID: item.refId)
            case .playlist:
                PlaylistFireView(model: model, controls: controls, playlistID: item.refId)
            case .header:
                EmptyView()
            case .info:

                ContentUnavailableView(
                    "Not Linked", systemImage: "link",
                    description: Text("This item isn't linked to a presentation or media yet.")
                )
            }
        } else {
            ContentUnavailableView(
                "No Item Selected", systemImage: "rectangle.grid.3x2",
                description: Text("Select a service item to see its slides.")
            )
        }
    }
}

struct LibrarySearchSheet: View {
    let model: AppModel
    let serviceID: String

    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var scopes: Set<LibrarySection> = []

    @State private var searchHits: [LibraryIndex.Hit] = []
    @FocusState private var fieldFocused: Bool

    private var addableTabs: [LibrarySection] { [.presentations, .media] }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                HStack(spacing: 5) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                        .imageScale(.small)
                    TextField("Search the library", text: $searchText)
                        .textFieldStyle(.plain)
                        .focused($fieldFocused)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    Color.primary.opacity(0.06),
                    in: RoundedRectangle.standard(CornerStandard.element)
                )
                Menu {
                    ForEach(addableTabs) { section in
                        Toggle(section.displayName, isOn: Binding(
                            get: { scopes.isEmpty || scopes.contains(section) },
                            set: { include in
                                var next = scopes.isEmpty ? Set(addableTabs) : scopes
                                if include { next.insert(section) } else { next.remove(section) }
                                scopes = next.count == addableTabs.count ? [] : next
                            }
                        ))
                    }
                } label: {
                    Image(systemName: "line.3.horizontal.decrease")
                        .imageScale(.small)
                        .foregroundStyle(scopes.isEmpty ? .secondary : .primary)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(10)
            Divider()
            resultsList
        }
        .frame(width: 380, height: 420)
        .onAppear { fieldFocused = true }
        .task(id: searchText) {
            searchHits = await model.search(searchText)
        }
    }

    @ViewBuilder
    private var resultsList: some View {
        let hits = results
        List(hits, id: \.entry.id) { hit in
            Button {
                model.addServiceItem(serviceID, refID: hit.entry.id)
            } label: {
                HStack(alignment: .firstTextBaseline) {
                    Glyph(
                        kind: hit.entry.kind == .presentation ? .presentations : .media,
                        size: 13
                    )
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
                    if let used = hit.entry.lastUsedAt {
                        Text("Used \(used, format: .relative(presentation: .named))")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Image(systemName: "plus.circle")
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .overlay {
            if hits.isEmpty {
                if searchText.isEmpty {
                    ContentUnavailableView(
                        "Search the Library", systemImage: "magnifyingglass",
                        description: Text("Matches names and lyrics; click a result to add it.")
                    )
                } else {
                    ContentUnavailableView.search(text: searchText)
                }
            }
        }
    }

    private var results: [LibraryIndex.Hit] {
        let hits = searchText.isEmpty
            ? addableTabs.flatMap { section in
                model.entries(in: section).map { LibraryIndex.Hit(entry: $0, snippet: nil) }
            }
            : searchHits
        return hits.filter { hit in
            guard [.presentation, .media, .audio].contains(hit.entry.kind) else { return false }
            let section: LibrarySection = hit.entry.kind == .presentation ? .presentations : .media
            return scopes.isEmpty || scopes.contains(section)
        }
    }
}
