import PresenterCore
import RenderEngine
import SlideScene
import SwiftUI

struct AlertsModule: View {
    let model: AppModel
    let controls: ServiceControls

    @Environment(\.runOnly) private var runOnly

    @State private var expandedAlerts: Set<String> = []

    @State private var tokenValues: [String: [String: String]] = [:]

    @State private var editingFolders: Set<String> = []

    @State private var folderDropTarget: String?

    @State private var dropBefore: String?

    @State private var searching = false
    @State private var searchQuery = ""

    private static let folderPrefix = "mxualertfolder::"

    var body: some View {

        let alertIDs = Set(model.alertPresets.map(\.id))
        VStack(alignment: .leading, spacing: 6) {
            ModuleHeaderBar {

            } trailing: {
                if !alertIDs.isEmpty {
                    ModuleSearchButton(isSearching: $searching, query: $searchQuery)
                }
                if !runOnly {
                    addMenu
                }
            }
            if searching {
                ModuleSearchField(query: $searchQuery, isSearching: $searching)
            }
            if alertIDs.isEmpty {
                Text("Alerts fire to confidence monitors, audience screens, or both.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 2)
            }

            if searching, !searchQuery.trimmingCharacters(in: .whitespaces).isEmpty {
                filteredList
            } else {
                boardList(alertIDs: alertIDs)
            }
        }
    }

    private var filteredList: some View {
        let ids = model.alertBoard.filteredItemIDs(matching: searchQuery) {
            (try? model.alertPreset($0))?.name
        }
        return VStack(spacing: 4) {
            ForEach(ids, id: \.self) { alertID in
                if let preset = try? model.alertPreset(alertID) {
                    alertRow(preset)
                }
            }
            if ids.isEmpty {
                Text("No alerts match.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var addMenu: some View {
        Menu {
            Button("New Alert") {
                if let id = model.createAlertPreset(
                    message: "New alert {message}", behavior: .flash,
                    target: .confidence, themeId: nil
                ) {
                    model.updateAlertPreset(id) { $0.name = "New Alert" }
                    expandedAlerts.insert(id)
                }
            }
            Divider()
            Button("New Folder") {
                model.updateAlertBoard { $0.addFolder(named: "New Folder") }
            }
        } label: {

            Image(systemName: "plus").moduleHeaderGlyph()
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Add an alert — write the phrase once, fill the blanks at fire time — or a folder")
    }

    @ViewBuilder
    private func boardList(alertIDs: Set<String>) -> some View {
        let board = model.alertBoard
        if !board.nodes.isEmpty {
            VStack(spacing: 4) {
                ForEach(board.nodes, id: \.self) { nodeID in
                    if let folder = board.folder(id: nodeID) {
                        ControlBoardFolderBlock(
                            folder: folder,
                            folderPrefix: Self.folderPrefix,
                            isItemID: { alertIDs.contains($0) },
                            updateBoard: model.updateAlertBoard,
                            memberNoun: "alerts",
                            dropTarget: $folderDropTarget,
                            editingFolders: $editingFolders
                        ) {
                            ForEach(folder.itemIds, id: \.self) { alertID in
                                if let preset = try? model.alertPreset(alertID) {
                                    alertRow(preset)
                                }
                            }
                        }
                    } else if let preset = try? model.alertPreset(nodeID) {
                        alertRow(preset)
                    }
                }

                ControlBoardEndDropStrip(
                    folderPrefix: Self.folderPrefix,
                    isItemID: { alertIDs.contains($0) },
                    updateBoard: model.updateAlertBoard
                )
            }
        }
    }

    private func alertRow(_ preset: AlertPreset) -> some View {
        let expanded = expandedAlerts.contains(preset.id)
        let isLive = controls.state.liveAlert?.id == preset.id

        let tokens = AlertTokens.tokenNames(in: preset.message)
            .filter { !isTimerToken($0) }
        return VStack(spacing: 0) {
            Button {
                if !runOnly { toggleExpanded(preset.id) }
            } label: {
                alertRowStrip(preset, tokens: tokens, expanded: expanded, isLive: isLive)
            }
            .buttonStyle(.plain)
            if expanded, !runOnly {
                AlertInlineEditor(model: model, preset: preset) {
                    expandedAlerts.remove(preset.id)
                }
            }
        }
        .background(
            isLive ? Color.orange.opacity(0.06) : Color.primary.opacity(0.03),
            in: RoundedRectangle.standard(CornerStandard.element)
        )
        .draggablePayload(runOnly ? nil : preset.id)
        .dropDestination(for: String.self) { payloads, _ in
            dropBefore = nil
            guard !runOnly else { return false }
            let alertIDs = Set(model.alertPresets.map(\.id))
            return handleControlBoardRowDrop(
                payloads, before: preset.id, folderPrefix: Self.folderPrefix,
                isItemID: { alertIDs.contains($0) },
                updateBoard: model.updateAlertBoard
            )
        } isTargeted: { targeted in
            dropBefore = targeted
                ? preset.id : (dropBefore == preset.id ? nil : dropBefore)
        }
        .overlay(alignment: .top) {
            if dropBefore == preset.id { ControlBoardInsertionLine() }
        }
        .contextMenu {
            if !runOnly {
                Button(expanded ? "Collapse" : "Edit…") { toggleExpanded(preset.id) }
                Divider()
                Button("Delete", role: .destructive) {
                    if let entry = model.indexEntry(preset.id) {
                        model.delete(entry)
                    }
                }
            }
        }
    }

    private func alertRowStrip(
        _ preset: AlertPreset, tokens: [String], expanded: Bool, isLive: Bool
    ) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 7, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .frame(width: 12)
                Text(preset.name)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(isLive ? Color.orange : .secondary)
                    .lineLimit(1)
                Text(Self.locationCaption(preset.target ?? .confidence))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                Spacer(minLength: 6)

                Text(isLive ? "Turn Off" : "Go Live")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(isLive ? Color.orange : .secondary)
                    .padding(.horizontal, 7)
                    .frame(height: 18)
                    .background(
                        Color.primary.opacity(0.06),
                        in: RoundedRectangle.standard(CornerStandard.element)
                    )
                    .overlay(
                        RoundedRectangle.standard(CornerStandard.element)
                            .strokeBorder(
                                isLive ? Color.orange.opacity(0.4) : Color.separator.opacity(0.5),
                                lineWidth: 1
                            )
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if isLive {
                            controls.dismissAlert()
                        } else {
                            fire(preset)
                        }
                    }
                    .help(isLive ? "Take this alert down" : "Go live (Return in a blank fires too)")
            }
            .padding(.horizontal, 8)
            .frame(height: 30)
            .contentShape(Rectangle())
            if tokens.isEmpty && !isLive {
                Spacer().frame(height: 4)
            } else {
                HStack(spacing: 8) {
                    ForEach(tokens, id: \.self) { token in
                        HStack(spacing: 4) {
                            Text(token.uppercased())
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(.tertiary)
                                .tracking(0.5)
                                .fixedSize()
                            TextField(token, text: Binding(
                                get: { tokenValues[preset.id]?[token] ?? "" },
                                set: { tokenValues[preset.id, default: [:]][token] = $0 }
                            ))
                            .textFieldStyle(.roundedBorder)
                            .controlSize(.small)
                            .font(.caption.monospacedDigit())
                            .frame(maxWidth: 110)
                            .onSubmit { fire(preset) }
                        }
                    }
                    Spacer(minLength: 0)
                    if isLive {

                        Text("Send Update")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 7)
                            .frame(height: 18)
                            .background(
                                Color.primary.opacity(0.06),
                                in: RoundedRectangle.standard(CornerStandard.element)
                            )
                            .overlay(
                                RoundedRectangle.standard(CornerStandard.element)
                                    .strokeBorder(Color.separator.opacity(0.5), lineWidth: 1)
                            )
                            .contentShape(Rectangle())
                            .onTapGesture { fire(preset) }
                            .help("Update the on-air alert with the text and blanks as they read now")
                    }
                }
                .padding(.horizontal, 8)
                .padding(.leading, 12)
                .padding(.bottom, 6)
            }
        }
    }

    private func isTimerToken(_ name: String) -> Bool {
        controls.timers.timers.contains {
            $0.name.caseInsensitiveCompare(name) == .orderedSame
        }
    }

    private func timerTokenIdentity(_ template: String) -> [String: String] {
        var values: [String: String] = [:]
        for name in AlertTokens.tokenNames(in: template) where isTimerToken(name) {
            values[name] = "{\(name)}"
        }
        return values
    }

    private func fire(_ preset: AlertPreset) {
        controls.fireAlert(
            id: preset.id,
            message: AlertTokens.compose(
                template: preset.message,
                values: (tokenValues[preset.id] ?? [:]).merging(
                    timerTokenIdentity(preset.message)
                ) { _, identity in identity }
            ),
            behavior: preset.behavior,
            target: preset.target ?? .confidence,
            themeId: preset.themeId,
            layer: preset.layer.flatMap(LayerKind.init(rawValue:))
        )
    }

    private func toggleExpanded(_ id: String) {
        withAnimation(.easeOut(duration: 0.12)) {
            if expandedAlerts.contains(id) {
                expandedAlerts.remove(id)
            } else {
                expandedAlerts.insert(id)
            }
        }
    }

    static func locationCaption(_ target: AlertTarget) -> String {
        switch target {
        case .confidence: "Confidence"
        case .audience: "Audience"
        case .both: "Confidence + Audience"
        }
    }
}

private struct AlertInlineEditor: View {
    let model: AppModel
    let preset: AlertPreset

    let dismiss: () -> Void

    @State private var name = ""
    @State private var template = ""
    @State private var showingLocationHelp = false

    private var target: AlertTarget { preset.target ?? .confidence }

    var body: some View {

        let themes = model.entries(in: .themes)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                fieldLabel("NAME")
                TextField("Name", text: $name)
                    .textFieldStyle(.plain)
                    .font(.caption)
                    .onSubmit { commit() }
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                fieldLabel("TEXT")
                TextField("Phrase — {token} makes a fill-in blank", text: $template, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.caption)
                    .lineLimit(1 ... 3)
                    .onSubmit { commit() }
            }
            HStack(spacing: 6) {
                fieldLabel("OUTPUT LOCATION")
                Menu {
                    Toggle("Confidence and Audience", isOn: option(target == .both) {
                        model.updateAlertPreset(preset.id) { $0.target = .both }
                    })
                    Toggle("Confidence Monitors", isOn: option(target == .confidence) {
                        model.updateAlertPreset(preset.id) { $0.target = nil }
                    })
                    Toggle("Audience Screens", isOn: option(target == .audience) {
                        model.updateAlertPreset(preset.id) { $0.target = .audience }
                    })
                } label: {
                    menuLabel(locationTitle)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                Button {
                    showingLocationHelp = true
                } label: {
                    Image(systemName: "questionmark.circle")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showingLocationHelp, arrowEdge: .bottom) {
                    Text(
                        """
                        Confidence monitors show this alert only when their \
                        layout includes Alerts — and, once layout links land, \
                        when this specific alert is linked as a text object.

                        Audience screens show it only when the active screen \
                        preset enables its layer (default: the Alerts layer).
                        """
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 260, alignment: .leading)
                    .padding(12)
                }
                Spacer()
            }
            if target != .confidence {
                HStack(spacing: 6) {
                    fieldLabel("LAYER")
                    Menu {

                        ForEach(Array(LayerKind.allCases.reversed()), id: \.self) { layer in
                            Toggle(layer.displayName, isOn: option(assignedLayer == layer) {
                                model.updateAlertPreset(preset.id) {
                                    $0.layer = layer == .alerts ? nil : layer.rawValue
                                }
                            })
                        }
                    } label: {
                        menuLabel(assignedLayer.displayName)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("The audience-side layer this alert renders on — screen presets route it like any layer")
                    fieldLabel("THEME")
                    Menu {
                        Toggle("Built-in Banner", isOn: option((preset.themeId ?? "").isEmpty) {
                            model.updateAlertPreset(preset.id) { $0.themeId = nil }
                        })
                        Divider()
                        ForEach(themes, id: \.id) { theme in
                            Toggle(theme.name, isOn: option(preset.themeId == theme.id) {
                                model.updateAlertPreset(preset.id) { $0.themeId = theme.id }
                            })
                        }
                    } label: {
                        menuLabel(themeName)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Styling only: the composed phrase renders through the theme's “Alerts” slide")
                    Spacer()
                }
            }
            HStack(spacing: 6) {
                fieldLabel("BEHAVIOR")
                Menu {
                    Toggle("Flash", isOn: option(preset.behavior == .flash) {
                        model.updateAlertPreset(preset.id) { $0.behavior = .flash }
                    })
                    Toggle("Persist", isOn: option(preset.behavior == .persist) {
                        model.updateAlertPreset(preset.id) { $0.behavior = .persist }
                    })
                } label: {
                    menuLabel(preset.behavior == .flash ? "Flash" : "Persist")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Flash blinks for attention; Persist holds steady until taken down")
                Spacer()

                Button {
                    dismiss()
                    if let entry = model.indexEntry(preset.id) {
                        model.delete(entry)
                    }
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Delete alert")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .overlay(alignment: .top) {
            Divider().padding(.horizontal, 8)
        }
        .task(id: preset.id) {
            name = preset.name
            template = preset.message
        }

        .onChange(of: name) { _, _ in commit() }
        .onChange(of: template) { _, _ in commit() }
    }

    private var assignedLayer: LayerKind {
        preset.layer.flatMap(LayerKind.init(rawValue:)) ?? .alerts
    }

    private var locationTitle: String {
        switch target {
        case .both: "Confidence and Audience"
        case .confidence: "Confidence Monitors"
        case .audience: "Audience Screens"
        }
    }

    private var themeName: String {
        guard let id = preset.themeId, !id.isEmpty,
              let entry = model.indexEntry(id)
        else { return "Banner" }
        return entry.name
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 8, weight: .semibold))
            .foregroundStyle(.tertiary)
            .tracking(0.5)

            .fixedSize()
    }

    private func menuLabel(_ text: String) -> some View {
        HStack(spacing: 4) {
            Text(text)
                .font(.caption)
            Image(systemName: "chevron.down")
                .font(.system(size: 7, weight: .semibold))
        }
        .foregroundStyle(.secondary)
    }

    private func commit() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let trimmedTemplate = template.trimmingCharacters(in: .whitespacesAndNewlines)
        model.updateAlertPreset(preset.id) {
            if !trimmedName.isEmpty { $0.name = trimmedName }
            if !trimmedTemplate.isEmpty { $0.message = trimmedTemplate }
        }
    }

    private func option(_ value: Bool, _ select: @escaping () -> Void) -> Binding<Bool> {
        Binding(get: { value }, set: { _ in select() })
    }
}
