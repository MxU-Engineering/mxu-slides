import PresenterCore
import RenderEngine
import SlideScene
import SwiftUI

struct ActionCombosModule: View {
    let model: AppModel
    let controls: ServiceControls

    @Environment(\.runOnly) private var runOnly
    @Environment(\.actionRouter) private var router
    @Environment(\.confidenceMonitor) private var confidenceMonitor
    @Environment(\.signage) private var signage

    @State private var expanded: Set<String> = []
    @State private var mediaPick: MediaPickTarget?

    @State private var actionPlacement: ComboActionPlacement?

    @State private var dropTarget: String?

    @State private var editingFolders: Set<String> = []

    @State private var searching = false
    @State private var searchQuery = ""

    private static let folderPrefix = "mxucombofolder::"

    private struct ComboActionPlacement: Identifiable {
        let comboID: String
        let draft: SlideAction
        var id: String { draft.id }
    }

    private struct MediaPickTarget: Identifiable {
        let comboID: String
        let actionID: String

        var kind: DocumentKind = .media
        var id: String { actionID }
    }

    var body: some View {

        let comboIDs = Set(model.actionCombos.map(\.id))
        VStack(alignment: .leading, spacing: 6) {
            ModuleHeaderBar {

            } trailing: {
                if !comboIDs.isEmpty {
                    ModuleSearchButton(isSearching: $searching, query: $searchQuery)
                }
                if !runOnly {
                    addMenu
                }
            }
            if searching {
                ModuleSearchField(query: $searchQuery, isSearching: $searching)
            }
            if comboIDs.isEmpty {
                Text("Chains of actions — one tap runs them in order.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 2)
            }
            if searching, !searchQuery.trimmingCharacters(in: .whitespaces).isEmpty {
                filteredList
            } else {
                boardList(comboIDs: comboIDs)
            }
        }
        .sheet(item: $mediaPick) { pick in
            LibraryPickerSheet(appModel: model, kind: pick.kind) { entry in
                updateAction(pick.comboID, pick.actionID) {
                    if pick.kind == .audio {
                        $0.audioItemId = entry.id
                    } else {
                        $0.mediaId = entry.id
                    }
                }
                mediaPick = nil
            }
        }
        .sheet(item: $actionPlacement) { placement in
            ActionPlacementSheet(
                model: model, editingComboID: placement.comboID,
                draft: placement.draft
            ) { action in
                model.updateActionCombo(placement.comboID) { $0.actions.append(action) }
                expanded.insert(placement.comboID)
            }
        }
    }

    private var addMenu: some View {
        Menu {
            Button("New Combo") {
                if let id = model.createActionCombo(name: "New Combo") {
                    expanded.insert(id)
                }
            }
            Divider()
            Button("New Folder") {
                model.updateComboBoard { $0.addFolder(named: "New Folder") }
            }
        } label: {

            Image(systemName: "plus").moduleHeaderGlyph()
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Add a combo or a folder")
    }

    private var filteredList: some View {
        let ids = model.comboBoard.filteredItemIDs(matching: searchQuery) {
            (try? model.actionCombo($0))?.name
        }
        return VStack(spacing: 4) {
            ForEach(ids, id: \.self) { comboID in
                comboBlock(comboID)
            }
            if ids.isEmpty {
                Text("No combos match.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func boardList(comboIDs: Set<String>) -> some View {
        let board = model.comboBoard
        return VStack(spacing: 4) {
            ForEach(board.nodes, id: \.self) { nodeID in
                if let folder = board.folder(id: nodeID) {
                    ControlBoardFolderBlock(
                        folder: folder,
                        folderPrefix: Self.folderPrefix,
                        isItemID: { comboIDs.contains($0) },
                        updateBoard: model.updateComboBoard,
                        memberNoun: "combos",
                        dropTarget: $dropTarget,
                        editingFolders: $editingFolders
                    ) {
                        ForEach(folder.itemIds, id: \.self) { comboID in
                            comboBlock(comboID)
                        }
                    }
                } else {
                    comboBlock(nodeID)
                }
            }

            if !board.nodes.isEmpty {
                ControlBoardEndDropStrip(
                    folderPrefix: Self.folderPrefix,
                    isItemID: { comboIDs.contains($0) },
                    updateBoard: model.updateComboBoard
                )
            }
        }
    }

    @ViewBuilder
    private func comboBlock(_ comboID: String) -> some View {
        if let combo = try? model.actionCombo(comboID) {
            let isOpen = expanded.contains(comboID)
            VStack(spacing: 0) {
                HStack(spacing: 6) {

                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 7, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(isOpen ? 90 : 0))

                        Glyph(kind: icon(of: combo), size: 11)
                            .foregroundStyle(
                                tint(of: combo).map(AnyShapeStyle.init)
                                    ?? AnyShapeStyle(.secondary))
                        Text(combo.name)
                            .font(.system(size: 11, weight: .medium))
                            .lineLimit(1)
                        Text(stepCaption(combo))
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                        Spacer(minLength: 4)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.easeOut(duration: 0.12)) {
                            if isOpen { expanded.remove(comboID) } else { expanded.insert(comboID) }
                        }
                    }

                    Button("Run") {
                        router?.fire(comboID: comboID)
                    }
                    .buttonStyle(CardButtonStyle())
                    .disabled(combo.actions.isEmpty || router == nil)
                }
                .padding(.horizontal, 8)
                .frame(height: 30)

                .draggablePayload(runOnly ? nil : comboID)
                .contextMenu {
                    if !runOnly {
                        addActionMenu(comboID)
                        Divider()
                        colorMenu(combo)
                        iconMenu(combo)

                        Picker("Trigger on Startup", selection: Binding(
                            get: { combo.runOnStartup == true },
                            set: { value in
                                model.updateActionCombo(comboID) {
                                    $0.runOnStartup = value ? true : nil
                                }
                            }
                        )) {
                            Text("Yes").tag(true)
                            Text("No").tag(false)
                        }
                        Divider()
                        Button("Cut") {
                            ComboPasteboard.copy(combo)
                            model.deleteActionCombo(comboID)
                            expanded.remove(comboID)
                        }
                        Button("Copy") { ComboPasteboard.copy(combo) }
                        Button("Paste") {
                            if let pasted = ComboPasteboard.paste() {
                                paste(pasted)
                            }
                        }
                        .disabled(!ComboPasteboard.hasCombo)
                        Button("Duplicate") {
                            duplicate(combo)
                        }
                        Divider()
                        Button("Delete", role: .destructive) {
                            model.deleteActionCombo(comboID)
                            expanded.remove(comboID)
                        }
                    }
                }
                if isOpen {
                    comboEditor(combo)
                        .padding(.horizontal, 8)
                        .padding(.bottom, 8)
                }
            }
            .background(
                Color.primary.opacity(0.03),
                in: RoundedRectangle.standard(CornerStandard.element)
            )

            .overlay(
                RoundedRectangle.standard(CornerStandard.element)
                    .strokeBorder(
                        dropTarget == comboID
                            ? Color(nsColor: .controlAccentColor).opacity(0.8) : .clear,
                        lineWidth: 1.5)
            )
            .dropDestination(for: String.self) { payloads, _ in
                guard !runOnly else { return false }
                return dropEntries(payloads, into: comboID)
            } isTargeted: { targeted in
                dropTarget = targeted ? comboID : (dropTarget == comboID ? nil : dropTarget)
            }
        }
    }

    private func dropEntries(_ payloads: [String], into comboID: String) -> Bool {
        var appended = false
        for payload in payloads {
            guard let entry = model.indexEntry(payload) else { continue }
            switch entry.kind {
            case .media:
                let action = SlideAction(id: UUID().uuidString, kind: .fireMedia, mediaId: entry.id)
                model.updateActionCombo(comboID) { $0.actions.append(action) }
                appended = true
            case .actionCombo where entry.id != comboID:
                let action = SlideAction(id: UUID().uuidString, kind: .fireCombo, comboId: entry.id)
                model.updateActionCombo(comboID) { $0.actions.append(action) }
                appended = true
            default:
                continue
            }
        }
        if appended { expanded.insert(comboID) }
        return appended
    }

    private func stepCaption(_ combo: ActionCombo) -> String {
        switch combo.actions.count {
        case 0: "empty"
        case 1: "1 action"
        case let count: "\(count) actions"
        }
    }

    @ViewBuilder
    private func comboEditor(_ combo: ActionCombo) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if !runOnly {
                TextField("Name", text: nameBinding(combo.id))
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                    .padding(5)
                    .background(
                        Color.primary.opacity(0.05),
                        in: RoundedRectangle.standard(CornerStandard.element)
                    )
            }
            ForEach(combo.actions) { action in
                actionRow(combo.id, action)
            }
            if !runOnly {

                Menu {
                    addActionItems(combo.id)
                } label: {
                    Text("+ Add Action")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .contentShape(Rectangle())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .padding(.top, 2)
            }
        }
    }

    @ViewBuilder
    private func addActionMenu(_ comboID: String) -> some View {
        Menu("Add Action") {
            addActionItems(comboID)
        }
    }

    @ViewBuilder
    private func addActionItems(_ comboID: String) -> some View {
        AddActionMenuItems(
            model: model,
            timers: controls.timers.timers.map { ($0.id, $0.name) },
            excludeComboID: comboID
        ) { action in

            actionPlacement = ComboActionPlacement(comboID: comboID, draft: action)
        }
    }

    @ViewBuilder
    private func actionRow(_ comboID: String, _ action: SlideAction) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(action.kind.displayName.uppercased())
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .tracking(0.5)
                Spacer(minLength: 2)
                if !runOnly {
                    Button {
                        model.updateActionCombo(comboID) {
                            $0.actions.removeAll { $0.id == action.id }
                        }
                    } label: {
                        Image(systemName: "minus.circle")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Remove action")
                }
            }
            if hasParameters(action.kind) {
                HStack(spacing: 6) {
                    parameterChip(comboID, action)
                }
            }
            if action.kind == .midiOut {
                midiFields(comboID, action)
            }
        }
        .padding(7)
        .background(
            Color.basePlane.opacity(0.45),
            in: RoundedRectangle.standard(CornerStandard.element)
        )
        .overlay(
            RoundedRectangle.standard(CornerStandard.element)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 1)
        )
        .contextMenu {
            if !runOnly {
                Button("Move Up") { move(comboID, action, by: -1) }
                Button("Move Down") { move(comboID, action, by: 1) }
                Divider()
                Button("Remove", role: .destructive) {
                    model.updateActionCombo(comboID) {
                        $0.actions.removeAll { $0.id == action.id }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func parameterChip(_ comboID: String, _ action: SlideAction) -> some View {
        switch action.kind {
        case .clearLayer:
            QuietMenuChip(title: action.layer.flatMap(LayerKind.init(rawValue:))?.displayName ?? "Layer\u{2026}") {

                ForEach(LayerKind.allCases.reversed(), id: \.rawValue) { layer in
                    Button(layer.displayName) {
                        updateAction(comboID, action.id) { $0.layer = layer.rawValue }
                    }
                }
            }
        case .switchOutputPreset:
            QuietMenuChip(title: entryName(action.presetId) ?? "Preset\u{2026}") {
                ForEach(entries(of: .outputPreset), id: \.id) { preset in
                    Button(preset.name) {
                        updateAction(comboID, action.id) { $0.presetId = preset.id }
                    }
                }
            }
        case .fireMedia:
            Button {
                mediaPick = MediaPickTarget(comboID: comboID, actionID: action.id)
            } label: {
                Text(entryName(action.mediaId) ?? "Media\u{2026}")
                    .font(.system(size: 10))
                    .lineLimit(1)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(
                Color.primary.opacity(0.05),
                in: RoundedRectangle.standard(CornerStandard.element)
            )
        case .fireAlert:
            QuietMenuChip(title: entryName(action.alertId) ?? "Alert\u{2026}") {
                ForEach(entries(of: .alertPreset), id: \.id) { alert in
                    Button(alert.name) {
                        updateAction(comboID, action.id) { $0.alertId = alert.id }
                    }
                }
            }
        case .timerStart, .timerPause, .timerReset:
            QuietMenuChip(title: timerName(action.timerId) ?? "Timer\u{2026}") {
                ForEach(controls.timers.timers, id: \.id) { timer in
                    Button(timer.name) {
                        updateAction(comboID, action.id) { $0.timerId = timer.id }
                    }
                }
            }
        case .timerConfigure:
            QuietMenuChip(title: timerName(action.timerId) ?? "Timer\u{2026}") {
                ForEach(controls.timers.timers, id: \.id) { timer in
                    Button(timer.name) {
                        updateAction(comboID, action.id) { $0.timerId = timer.id }
                    }
                }
            }
            QuietMenuChip(title: timerModeTitle(action.timerMode)) {
                Button("Keep Mode") { updateAction(comboID, action.id) { $0.timerMode = nil } }
                Button("Countdown") { updateAction(comboID, action.id) { $0.timerMode = .countdown } }
                Button("Countdown to Time") { updateAction(comboID, action.id) { $0.timerMode = .countdownToTime } }
                Button("Count Up") { updateAction(comboID, action.id) { $0.timerMode = .countUp } }
            }
            if action.timerMode != .countdownToTime {
                QuietMenuChip(title: durationTitle(action.timerDurationSeconds)) {

                    ForEach([60, 120, 180, 300, 450, 600, 900, 1200, 1800], id: \.self) { seconds in
                        Button(durationLabel(seconds)) {
                            updateAction(comboID, action.id) { $0.timerDurationSeconds = Double(seconds) }
                        }
                    }
                }
            }
        case .fireCombo:
            QuietMenuChip(title: entryName(action.comboId) ?? "Combo\u{2026}") {
                ForEach(model.actionCombos.filter { $0.id != comboID }, id: \.id) { combo in
                    Button(combo.name) {
                        updateAction(comboID, action.id) { $0.comboId = combo.id }
                    }
                }
            }
        case .midiOut:
            QuietMenuChip(title: (action.midiKind ?? .noteOn) == .noteOn ? "Note On" : "Control Change") {
                Button("Note On") { updateAction(comboID, action.id) { $0.midiKind = .noteOn } }
                Button("Control Change") { updateAction(comboID, action.id) { $0.midiKind = .controlChange } }
            }
            QuietMenuChip(title: midiDeviceTitle(action.midiDeviceId)) {

                Button("All Enabled Devices") {
                    updateAction(comboID, action.id) { $0.midiDeviceId = nil }
                }
                ForEach(
                    MIDIDeviceInventory.shared.items.filter(\.wantsOutput), id: \.id
                ) { item in
                    Button(item.device.name) {
                        updateAction(comboID, action.id) { $0.midiDeviceId = item.id }
                    }
                }
            }
        case .captureStart:
            QuietMenuChip(title: entryName(action.capturePresetId) ?? "Preset\u{2026}") {
                ForEach(entries(of: .streamRecordPreset), id: \.id) { preset in
                    Button(preset.name) {
                        updateAction(comboID, action.id) { $0.capturePresetId = preset.id }
                    }
                }
            }
        case .captureStop:
            QuietMenuChip(title: entryName(action.capturePresetId) ?? "All Capture") {

                Button("All Capture") {
                    updateAction(comboID, action.id) { $0.capturePresetId = nil }
                }
                Divider()
                ForEach(entries(of: .streamRecordPreset), id: \.id) { preset in
                    Button(preset.name) {
                        updateAction(comboID, action.id) { $0.capturePresetId = preset.id }
                    }
                }
            }
        case .firePresentation:
            QuietMenuChip(title: entryName(action.presentationId) ?? "Presentation\u{2026}") {
                ForEach(entries(of: .presentation), id: \.id) { presentation in
                    Button(presentation.name) {
                        updateAction(comboID, action.id) {
                            $0.presentationId = presentation.id
                            $0.slideIndex = nil
                        }
                    }
                }
            }
            if let presentationID = action.presentationId,
               let slideCount = model.presentation(presentationID)?.slides.count,
               slideCount > 1
            {

                QuietMenuChip(title: "Slide \((action.slideIndex ?? 0) + 1)") {
                    ForEach(0..<slideCount, id: \.self) { index in
                        Button("Slide \(index + 1)") {
                            updateAction(comboID, action.id) {
                                $0.slideIndex = index == 0 ? nil : index
                            }
                        }
                    }
                }
            }
        case .setConfidenceLayout:
            QuietMenuChip(title: confidenceLayoutTitle(action.confidenceLayoutId)) {

                Button("Built-in Layout") {
                    updateAction(comboID, action.id) { $0.confidenceLayoutId = nil }
                }
                Divider()
                ForEach(entries(of: .confidenceLayout), id: \.id) { layout in
                    Button(layout.name) {
                        updateAction(comboID, action.id) { $0.confidenceLayoutId = layout.id }
                    }
                }
            }
            QuietMenuChip(title: confidenceScreenTitle(action.confidenceScreenId)) {

                Button("All Confidence Monitors") {
                    updateAction(comboID, action.id) { $0.confidenceScreenId = nil }
                }
                Divider()
                ForEach(confidenceMonitor?.confidenceScreens ?? [], id: \.id) { screen in
                    Button(screen.name) {
                        updateAction(comboID, action.id) {
                            $0.confidenceScreenId = screen.id.uuidString
                        }
                    }
                }
            }
        case .fireOverlay:
            QuietMenuChip(title: entryName(action.overlayId) ?? "Overlay\u{2026}") {
                ForEach(entries(of: .overlay), id: \.id) { overlay in
                    Button(overlay.name) {
                        updateAction(comboID, action.id) { $0.overlayId = overlay.id }
                    }
                }
            }
        case .dismissOverlay:
            QuietMenuChip(title: (action.overlayId?.isEmpty ?? true) ? "All Overlays" : (entryName(action.overlayId) ?? "Overlay\u{2026}")) {
                Button("All Overlays") {
                    updateAction(comboID, action.id) { $0.overlayId = nil }
                }
                Divider()
                ForEach(entries(of: .overlay), id: \.id) { overlay in
                    Button(overlay.name) {
                        updateAction(comboID, action.id) { $0.overlayId = overlay.id }
                    }
                }
            }
        case .fireLiveInput:
            QuietMenuChip(title: liveInputTitle(action)) {
                ForEach(LiveInputCatalog.choices, id: \.token) { choice in
                    Button(choice.name) {
                        updateAction(comboID, action.id) {
                            $0.liveInputId = choice.id
                            $0.inputSourceKind = nil
                            $0.inputSourceId = nil
                        }
                    }
                }
            }
        case .setSignage:
            QuietMenuChip(title: signageChannelTitle(action.signageId) ?? "Signage\u{2026}") {
                ForEach(signage?.channels ?? [], id: \.id) { channel in
                    Button(channel.name) {
                        updateAction(comboID, action.id) { $0.signageId = channel.id }
                    }
                }
            }

            QuietMenuChip(title: (action.playlistId?.isEmpty ?? true)
                ? "Playlist\u{2026}" : (entryName(action.playlistId) ?? "Playlist\u{2026}")
            ) {
                ForEach(model.playlists(in: .media), id: \.id) { playlist in
                    Button(playlist.name) {
                        updateAction(comboID, action.id) { $0.playlistId = playlist.id }
                    }
                }
            }
        case .setScreenSource:
            QuietMenuChip(title: signageScreenTitle(action.screenId)) {
                ForEach(signage?.screens ?? [], id: \.id) { screen in
                    Button(screen.name) {
                        updateAction(comboID, action.id) { $0.screenId = screen.id.uuidString }
                    }
                }
            }
            QuietMenuChip(title: (action.signageId?.isEmpty ?? true)
                ? "Program" : (signageChannelTitle(action.signageId) ?? "Signage\u{2026}")
            ) {
                Button("Program") {
                    updateAction(comboID, action.id) { $0.signageId = nil }
                }
                Divider()
                ForEach(signage?.channels ?? [], id: \.id) { channel in
                    Button("Signage — \(channel.name)") {
                        updateAction(comboID, action.id) { $0.signageId = channel.id }
                    }
                }
            }
        case .enableAudioInput, .disableAudioInput:
            QuietMenuChip(title: audioInputTitle(action)) {
                ForEach(AudioInputInventory.shared.entries) { entry in
                    Button(entry.name) {
                        updateAction(comboID, action.id) { $0.audioInputId = entry.id }
                    }
                }
            }
        case .fireAudio:

            Button {
                mediaPick = MediaPickTarget(
                    comboID: comboID, actionID: action.id, kind: .audio)
            } label: {
                Text(entryName(action.audioItemId) ?? "File\u{2026}")
                    .font(.system(size: 10))
                    .lineLimit(1)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(
                Color.primary.opacity(0.05),
                in: RoundedRectangle.standard(CornerStandard.element)
            )
            QuietMenuChip(title: action.audioRepeat == true ? "Repeat: On" : "Repeat: Off") {
                Button("Repeat: Off") {
                    updateAction(comboID, action.id) { $0.audioRepeat = nil }
                }
                Button("Repeat: On") {
                    updateAction(comboID, action.id) { $0.audioRepeat = true }
                }
            }
        case .fireAudioPlaylist:
            QuietMenuChip(title: entryName(action.playlistId) ?? "Playlist\u{2026}") {
                ForEach(model.playlists(in: .audio), id: \.id) { playlist in
                    Button(playlist.name) {
                        updateAction(comboID, action.id) { $0.playlistId = playlist.id }
                    }
                }
            }
            QuietMenuChip(title: repeatTitle(action.audioRepeat)) {
                Button("Repeat: Playlist Setting") {
                    updateAction(comboID, action.id) { $0.audioRepeat = nil }
                }
                Button("Repeat: On") {
                    updateAction(comboID, action.id) { $0.audioRepeat = true }
                }
                Button("Repeat: Off") {
                    updateAction(comboID, action.id) { $0.audioRepeat = false }
                }
            }
        case .clearAll, .clearAudio, .clearSignage, .dismissAlert:
            EmptyView()
        }
    }

    private func timerModeTitle(_ mode: TimerMode?) -> String {
        switch mode {
        case .countdown?: "Countdown"
        case .countdownToTime?: "Countdown to Time"
        case .countUp?: "Count Up"
        case nil: "Keep Mode"
        }
    }

    private func durationTitle(_ seconds: Double?) -> String {
        guard let seconds, seconds > 0 else { return "Duration\u{2026}" }
        return durationLabel(Int(seconds))
    }

    private func durationLabel(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private func repeatTitle(_ audioRepeat: Bool?) -> String {
        switch audioRepeat {
        case true?: "Repeat: On"
        case false?: "Repeat: Off"
        case nil: "Repeat: Playlist Setting"
        }
    }

    private func audioInputTitle(_ action: SlideAction) -> String {
        guard let id = action.audioInputId, !id.isEmpty else { return "Input\u{2026}" }
        return AudioInputInventory.shared.name(forId: id) ?? "Missing input"
    }

    private func signageChannelTitle(_ id: String?) -> String? {
        guard let id, !id.isEmpty else { return nil }
        return signage?.channel(id)?.name ?? "Missing"
    }

    private func signageScreenTitle(_ id: String?) -> String {
        guard let id, !id.isEmpty else { return "Screen\u{2026}" }
        return signage?.screens.first { $0.id.uuidString == id }?.name ?? "Screen\u{2026}"
    }

    private func liveInputTitle(_ action: SlideAction) -> String {
        if let itemId = action.liveInputId, !itemId.isEmpty {
            return VideoInputInventory.shared.entry(id: itemId)?.name ?? "Missing input"
        }

        guard let id = action.inputSourceId, !id.isEmpty else { return "Source\u{2026}" }
        return LiveInputCatalog.legacyLabel(kind: action.inputSourceKind, id: id)
    }

    private func confidenceLayoutTitle(_ id: String?) -> String {
        guard let id, !id.isEmpty else { return "Built-in Layout" }
        return entryName(id) ?? "Layout\u{2026}"
    }

    private func confidenceScreenTitle(_ id: String?) -> String {
        guard let id, !id.isEmpty else { return "All Confidence Monitors" }
        return confidenceMonitor?.confidenceScreens
            .first { $0.id.uuidString == id }?.name ?? "Screen\u{2026}"
    }

    private func hasParameters(_ kind: SlideActionKind) -> Bool {
        switch kind {
        case .clearAll, .clearAudio, .clearSignage, .dismissAlert: false

        case .midiOut: true
        default: true
        }
    }

    private func midiFields(_ comboID: String, _ action: SlideAction) -> some View {
        HStack(spacing: 10) {
            midiStepper(comboID, action, "CH", \.midiChannel, default: 1, range: 1...16)
            if action.midiKind == .controlChange {
                midiStepper(comboID, action, "CC", \.midiNumber, default: 0, range: 0...127)
            } else {

                midiStepper(
                    comboID, action, "NOTE", \.midiNumber, default: 0, range: 0...127,
                    display: { "\(MIDINote.name($0)) · \($0)" })
            }
            midiStepper(
                comboID, action,
                action.midiKind == .controlChange ? "VAL" : "VEL",
                \.midiValue, default: 127, range: 0...127)
            Spacer()
        }
    }

    private func midiDeviceTitle(_ id: String?) -> String {
        guard let id, !id.isEmpty else { return "All Enabled Devices" }
        return MIDIDeviceInventory.shared.items
            .first { $0.id == id }?.device.name ?? "Device\u{2026}"
    }

    private func midiStepper(
        _ comboID: String, _ action: SlideAction, _ label: String,
        _ keyPath: WritableKeyPath<SlideAction, Int?> & Sendable,
        default fallback: Int, range: ClosedRange<Int>,
        display: (Int) -> String = { "\($0)" }
    ) -> some View {
        HStack(spacing: 3) {
            Text(label)
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.tertiary)
                .tracking(0.5)
            Stepper(value: Binding(
                get: { action[keyPath: keyPath] ?? fallback },
                set: { value in
                    updateAction(comboID, action.id) {
                        $0[keyPath: keyPath] = min(range.upperBound, max(range.lowerBound, value))
                    }
                }
            ), in: range) {
                Text(display(action[keyPath: keyPath] ?? fallback))
                    .font(.system(size: 10).monospacedDigit())
            }
            .controlSize(.mini)
        }
    }

    private func nameBinding(_ comboID: String) -> Binding<String> {
        Binding(
            get: { (try? model.actionCombo(comboID))?.name ?? "" },
            set: { value in
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                model.updateActionCombo(comboID) { $0.name = trimmed }
            }
        )
    }

    private func updateAction(
        _ comboID: String, _ actionID: String, _ mutate: @escaping @Sendable (inout SlideAction) -> Void
    ) {
        model.updateActionCombo(comboID) { combo in
            guard let index = combo.actions.firstIndex(where: { $0.id == actionID }) else { return }
            mutate(&combo.actions[index])
        }
    }

    private func move(_ comboID: String, _ action: SlideAction, by offset: Int) {
        let actionID = action.id
        model.updateActionCombo(comboID) { combo in
            guard let index = combo.actions.firstIndex(where: { $0.id == actionID }) else { return }
            let target = index + offset
            guard combo.actions.indices.contains(target) else { return }
            combo.actions.swapAt(index, target)
        }
    }

    private func duplicate(_ combo: ActionCombo) {
        guard let id = model.createActionCombo(name: combo.name + " Copy") else { return }
        let actions = combo.actions.map { action in
            var action = action
            action.id = UUID().uuidString
            return action
        }
        model.updateActionCombo(id) { copy in
            copy.actions = actions
            copy.colorHex = combo.colorHex
            copy.iconName = combo.iconName

        }
    }

    private func paste(_ combo: ActionCombo) {
        guard let id = model.createActionCombo(name: combo.name) else { return }
        model.updateActionCombo(id) { fresh in
            fresh.actions = combo.actions.map { action in
                var action = action
                action.id = UUID().uuidString
                return action
            }
            fresh.colorHex = combo.colorHex
            fresh.iconName = combo.iconName
        }
    }

    private static let palette: [(name: String, hex: String)] = [
        ("Red", "#FF5F57FF"), ("Orange", "#FFA344FF"), ("Yellow", "#FFD60AFF"),
        ("Green", "#32D74BFF"), ("Blue", "#4B9BFFFF"), ("Purple", "#BF5AF2FF"),
    ]

    private static let icons: [(kind: GlyphKind, name: String)] = [
        (.combos, "Bolt"), (.timers, "Timer"), (.alerts, "Bell"),
        (.media, "Media"), (.audio, "Music"), (.screens, "Screen"),
        (.clear, "Clear"), (.midi, "MIDI"), (.broadcast, "Record"),
        (.overlays, "Overlay"),
    ]

    private func icon(of combo: ActionCombo) -> GlyphKind {
        combo.iconName.flatMap(GlyphKind.init(rawValue:)) ?? .combos
    }

    private func tint(of combo: ActionCombo) -> Color? {
        combo.colorHex.flatMap(ColorHex.color).map {
            Color(red: $0.red, green: $0.green, blue: $0.blue, opacity: $0.alpha)
        }
    }

    private func colorMenu(_ combo: ActionCombo) -> some View {
        Menu("Color") {
            Toggle("None", isOn: Binding(
                get: { combo.colorHex == nil },
                set: { _ in model.updateActionCombo(combo.id) { $0.colorHex = nil } }
            ))
            Divider()
            ForEach(Self.palette, id: \.hex) { color in
                Toggle(color.name, isOn: Binding(
                    get: { combo.colorHex == color.hex },
                    set: { _ in
                        model.updateActionCombo(combo.id) { $0.colorHex = color.hex }
                    }
                ))
            }
        }
    }

    private func iconMenu(_ combo: ActionCombo) -> some View {
        Menu("Icon") {
            ForEach(Self.icons, id: \.kind) { choice in
                Toggle(choice.name, isOn: Binding(
                    get: { icon(of: combo) == choice.kind },
                    set: { _ in
                        model.updateActionCombo(combo.id) {
                            $0.iconName = choice.kind == .combos ? nil : choice.kind.rawValue
                        }
                    }
                ))
            }
        }
    }

    private func entries(of kind: DocumentKind) -> [LibraryIndex.Entry] {
        model.entries(of: kind)
    }

    private func entryName(_ id: String?) -> String? {
        guard let id, !id.isEmpty else { return nil }
        return model.indexEntry(id)?.name ?? "Missing"
    }

    private func timerName(_ id: String?) -> String? {
        guard let id, !id.isEmpty else { return nil }
        return controls.timers.snapshot(id: id)?.name ?? "Missing timer"
    }
}

enum ComboPasteboard {
    static let type = NSPasteboard.PasteboardType("com.example.mxuslides.actioncombo")

    static func copy(_ combo: ActionCombo) {
        guard let data = try? JSONEncoder().encode(combo) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setData(data, forType: type)
    }

    static var hasCombo: Bool {
        NSPasteboard.general.data(forType: type) != nil
    }

    static func paste() -> ActionCombo? {
        guard let data = NSPasteboard.general.data(forType: type) else { return nil }
        return try? JSONDecoder().decode(ActionCombo.self, from: data)
    }
}
