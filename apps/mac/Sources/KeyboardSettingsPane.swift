import PresenterCore
import SwiftUI

struct KeyboardMapPane: View {
    let model: AppModel
    let controls: ServiceControls?
    @State private var store = KeyMapStore.shared
    @State private var filter: RowFilter = .assigned

    @State private var recordingComboID: String?

    enum RowFilter: String, CaseIterable {
        case assigned, all, customized, conflicts, unused

        var title: String {
            switch self {
            case .assigned: "Assigned"
            case .all: "All"
            case .customized: "Customized"
            case .conflicts: "Conflicts"
            case .unused: "Unused"
            }
        }
    }

    var body: some View {
        Form {
            Section {
                Picker("", selection: $filter) {
                    ForEach(RowFilter.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            ForEach(KeyCommandGroup.allCases, id: \.self) { group in
                let commands = visibleCommands(in: group)
                if !commands.isEmpty {
                    Section(group.displayName) {
                        ForEach(commands, id: \.self) { command in
                            KeyCommandRow(
                                command: command, store: store,
                                conflictCaption: conflictCaption(for: command)
                            )
                        }
                    }
                }
            }
            ForEach(generatedSections, id: \.title) { section in
                let rows = visibleGeneratedRows(section.rows)
                if !rows.isEmpty {
                    Section {
                        ForEach(rows) { spec in
                            generatedRow(spec)
                        }
                    } header: {
                        Text(section.title)
                    } footer: {
                        if let footer = section.footer { Text(footer) }
                    }
                }
            }
            combosSection
            hotKeysSection
            Section {
                Button("Restore Defaults\u{2026}") {

                    store.map.chords = store.map.chords.filter {
                        GeneratedKey.parse($0.key) != nil
                    }
                }
                .disabled(store.map.chords.allSatisfy {
                    GeneratedKey.parse($0.key) != nil
                })
            } footer: {
                Text("Single letters and numbers only fire in Present, and never while typing. F-keys on a laptop need fn, or \u{201C}Use F1, F2, etc. keys as standard function keys\u{201D} in System Settings.")
            }
        }
        .settingsForm()
    }

    private func visibleCommands(in group: KeyCommandGroup) -> [KeyCommand] {
        let conflicted = store.map.conflictedKeys()
        return KeyCommand.allCases.filter { command in
            guard command.group == group else { return false }
            switch filter {
            case .all: return true
            case .assigned:
                return !store.map.chords(for: command).isEmpty
                    || command.fixedKeyDescription != nil
            case .customized: return store.map.isCustomized(command)
            case .conflicts: return conflicted.contains(command.rawValue)
            case .unused:
                return store.map.chords(for: command).isEmpty
                    && command.fixedKeyDescription == nil
            }
        }
    }

    private func conflictCaption(for command: KeyCommand) -> String? {
        guard store.map.conflictedKeys().contains(command.rawValue) else { return nil }
        return conflictCaption(
            mapKey: command.rawValue,
            chords: store.map.chords(for: command),
            scope: command.scope
        )
    }

    private struct GeneratedRowSpec: Identifiable {
        let key: GeneratedKey
        let label: String
        var id: String { key.mapKey }
    }

    private var generatedSections: [(title: String, footer: String?, rows: [GeneratedRowSpec])] {
        var sections: [(String, String?, [GeneratedRowSpec])] = []
        let presets = model.entries(of: .outputPreset)
        if !presets.isEmpty {
            sections.append(("Output Presets", nil, presets.map {
                GeneratedRowSpec(
                    key: GeneratedKey(.outputPreset, $0.id),
                    label: "Switch to \u{201C}\($0.name)\u{201D}")
            }))
        }
        if let timers = controls?.timers.timers, !timers.isEmpty {
            sections.append(("Timers", nil, timers.flatMap { timer in
                [
                    GeneratedRowSpec(
                        key: GeneratedKey(.timerStart, timer.id),
                        label: "Start \u{201C}\(timer.name)\u{201D}"),
                    GeneratedRowSpec(
                        key: GeneratedKey(.timerPause, timer.id),
                        label: "Pause \u{201C}\(timer.name)\u{201D}"),
                    GeneratedRowSpec(
                        key: GeneratedKey(.timerReset, timer.id),
                        label: "Reset \u{201C}\(timer.name)\u{201D}"),
                ]
            }))
        }
        let overlays = model.entries(of: .overlay)
        if !overlays.isEmpty {
            sections.append((
                "Overlays",
                "Toggle: fires the overlay, or dismisses it when it's live.",
                overlays.map {
                    GeneratedRowSpec(
                        key: GeneratedKey(.overlayToggle, $0.id),
                        label: "Toggle \u{201C}\($0.name)\u{201D}")
                }
            ))
        }
        if let screens = WindowBridge.previewScreens?(), !screens.isEmpty {
            sections.append(("Preview Windows", nil, screens.map {
                GeneratedRowSpec(
                    key: GeneratedKey(.preview, $0.id),
                    label: "Open Preview: \($0.name)")
            }))
        }
        var settingsRows = SettingsCategory.allCases.map {
            GeneratedRowSpec(
                key: GeneratedKey(.settingsPage, $0.rawValue),
                label: "Open Settings \u{2023} \($0.title)")
        }
        settingsRows.append(contentsOf: StreamRecordPane.Tab.allCases.map {
            GeneratedRowSpec(
                key: GeneratedKey(.settingsPage, "streamRecord/\($0.rawValue)"),
                label: "Open Settings \u{2023} Stream & Record \u{2023} \($0.title)")
        })
        sections.append(("Settings Pages", nil, settingsRows))
        return sections
    }

    private func visibleGeneratedRows(_ rows: [GeneratedRowSpec]) -> [GeneratedRowSpec] {
        let conflicted = store.map.conflictedKeys()
        return rows.filter { spec in
            let bound = store.map.chord(for: spec.key) != nil
            switch filter {
            case .all: return true
            case .assigned, .customized: return bound
            case .conflicts: return conflicted.contains(spec.key.mapKey)
            case .unused: return !bound
            }
        }
    }

    private func generatedRow(_ spec: GeneratedRowSpec) -> some View {
        let conflicted = store.map.conflictedKeys().contains(spec.key.mapKey)
        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(spec.label)
                if conflicted, let caption = conflictCaption(
                    mapKey: spec.key.mapKey,
                    chords: store.map.chord(for: spec.key).map { [$0] } ?? [],
                    scope: spec.key.kind.scope
                ) {
                    Text(caption).font(.caption2).foregroundStyle(.orange)
                }
            }
            Spacer()
            Text(spec.key.kind.scope.displayName)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(width: 58, alignment: .trailing)
            KeyChordChip(
                chords: store.map.chord(for: spec.key).map { [$0] } ?? [],
                fixedText: nil,
                isCustomized: false,
                conflicted: conflicted,
                onRecord: { result in
                    switch result {
                    case .chord(let chord): store.map.setChord(chord, for: spec.key)
                    case .unbind: store.map.setChord(nil, for: spec.key)
                    case .cancel: break
                    }
                }
            )
        }
    }

    private func conflictCaption(
        mapKey: String, chords: [KeyChord], scope: KeyCommandScope
    ) -> String? {
        let labels = allBindingLabels
        var others: [String] = []
        for command in KeyCommand.allCases where command.rawValue != mapKey {
            let scopesMeet = command.scope == scope
                || command.scope == .anywhere || scope == .anywhere
            guard scopesMeet else { continue }
            if store.map.chords(for: command).contains(where: { a in
                chords.contains { a.matches($0) }
            }) {
                others.append(command.displayName)
            }
        }
        for key in store.map.boundGeneratedKeys where key.mapKey != mapKey {
            let scopesMeet = key.kind.scope == scope
                || key.kind.scope == .anywhere || scope == .anywhere
            guard scopesMeet, let chord = store.map.chord(for: key),
                  chords.contains(where: { chord.matches($0) })
            else { continue }
            others.append(labels[key.mapKey] ?? key.id)
        }
        guard !others.isEmpty else { return nil }
        return "Also used by \(others.joined(separator: ", "))"
    }

    private var allBindingLabels: [String: String] {
        var labels: [String: String] = [:]
        for command in KeyCommand.allCases { labels[command.rawValue] = command.displayName }
        for section in generatedSections {
            for spec in section.rows { labels[spec.id] = spec.label }
        }
        for id in store.map.boundComboIDs {
            labels[GeneratedKey(.combo, id).mapKey] = comboName(id)
        }
        return labels
    }

    private var combosSection: some View {
        Section {
            ForEach(visibleComboIDs, id: \.self) { id in
                HStack(spacing: 8) {
                    Text(comboName(id))
                    Spacer()
                    KeyChordChip(
                        chords: store.map.chord(forComboID: id).map { [$0] } ?? [],
                        fixedText: nil, isCustomized: false,
                        onRecord: { result in
                            switch result {
                            case .chord(let chord): store.map.setChord(chord, forComboID: id)
                            case .unbind: store.map.setChord(nil, forComboID: id)
                            case .cancel: break
                            }
                        }
                    )
                }
            }
            if filter == .assigned || filter == .all {
                addComboControl
            }
        } header: {
            Text("Action Combos")
        } footer: {
            Text("Any combo can wear a key — features without their own command are one combo away from a shortcut.")
        }
    }

    private var visibleComboIDs: [String] {
        switch filter {
        case .unused: []
        case .conflicts:
            store.map.boundComboIDs.filter {
                store.map.conflictedKeys().contains(KeyCommandMap.comboPrefix + $0)
            }
        default: store.map.boundComboIDs
        }
    }

    @ViewBuilder
    private var addComboControl: some View {
        if let recording = recordingComboID {
            HStack(spacing: 8) {
                Text(comboName(recording))
                Spacer()
                KeyChordChip(
                    chords: [], fixedText: nil, isCustomized: false,
                    startRecording: true,
                    onRecord: { result in
                        if case .chord(let chord) = result {
                            store.map.setChord(chord, forComboID: recording)
                        }
                        recordingComboID = nil
                    }
                )
            }
        } else {
            Menu("Add Combo Shortcut\u{2026}") {
                let unbound = model.comboBoard.allItemIDs.filter {
                    store.map.chord(forComboID: $0) == nil
                }
                if unbound.isEmpty {
                    Text("No combos without a shortcut")
                }
                ForEach(unbound, id: \.self) { id in
                    Button(comboName(id)) { recordingComboID = id }
                }
            }
            .fixedSize()
        }
    }

    private func comboName(_ id: String) -> String {
        (try? model.actionCombo(id))?.name ?? "Combo"
    }

    private var hotKeysSection: some View {
        Section {
            ForEach(visibleGroups) { group in
                HStack(spacing: 10) {
                    Circle()
                        .fill(GroupColor.color(group.colorHex) ?? Color(.sRGB, white: 0.5))
                        .frame(width: 10, height: 10)
                    Text(group.name)
                    Spacer()
                    GroupHotKeyChip(model: model, group: group)
                }
            }
        } header: {
            Text("Group Hot Keys")
        } footer: {
            Text("Single letters that jump the live song to a section — press again to cycle repeats. These ride the group palette (Settings › Groups edits the same list).")
        }
    }

    private var visibleGroups: [GroupDefinition] {
        let groups = model.groupPalette.groups
        switch filter {
        case .all: return groups
        case .assigned: return groups.filter { GroupPalette.effectiveHotKey(for: $0) != nil }
        case .conflicts: return []
        case .customized: return groups.filter { $0.hotKey != nil }
        case .unused: return groups.filter { GroupPalette.effectiveHotKey(for: $0) == nil }
        }
    }
}

private struct KeyCommandRow: View {
    let command: KeyCommand
    let store: KeyMapStore
    let conflictCaption: String?

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    if store.map.isCustomized(command) {
                        Circle().fill(Color.accentColor).frame(width: 5, height: 5)
                    }
                    Text(command.displayName)
                }
                if let conflictCaption {
                    Text(conflictCaption)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
            Spacer()
            if store.map.isCustomized(command) {
                Button {
                    store.map.resetToDefault(command)
                } label: {
                    Image(systemName: "arrow.uturn.backward.circle")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Reset to default")
            }
            Text(command.scope.displayName)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(width: 58, alignment: .trailing)
            KeyChordChip(
                chords: store.map.chords(for: command),
                fixedText: command.fixedKeyDescription,
                isCustomized: store.map.isCustomized(command),
                conflicted: conflictCaption != nil,
                onRecord: { result in
                    switch result {
                    case .chord(let chord): store.map.setChord(chord, for: command)
                    case .unbind: store.map.setChord(nil, for: command)
                    case .cancel: break
                    }
                }
            )
        }
    }
}

struct KeyChordChip: View {
    let chords: [KeyChord]
    let fixedText: String?
    let isCustomized: Bool
    var conflicted = false
    var startRecording = false
    let onRecord: (KeyRecorderResult) -> Void

    @State private var recording = false

    var body: some View {
        Button(action: beginRecording) {
            Group {
                if recording {
                    Text("Type shortcut \u{00B7} esc cancels")
                        .foregroundStyle(Color.accentColor)
                } else if let fixedText {
                    Text(fixedText).foregroundStyle(.secondary)
                } else if chords.isEmpty {
                    Text("\u{2014}").foregroundStyle(.tertiary)
                } else {
                    HStack(spacing: 4) {
                        ForEach(Array(chords.enumerated()), id: \.offset) { _, chord in
                            Text(chord.display)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(.quaternary.opacity(0.6)))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 4)
                                        .strokeBorder(
                                            conflicted ? Color.orange.opacity(0.7) : Color.clear))
                        }
                    }
                }
            }
            .font(.caption.monospaced())
            .padding(.vertical, 2)
            .padding(.horizontal, recording ? 8 : 2)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(
                        recording ? Color.accentColor : Color.clear,
                        style: StrokeStyle(lineWidth: 1, dash: recording ? [3, 2] : []))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(fixedText != nil)
        .onAppear { if startRecording { beginRecording() } }
        .onDisappear { releaseClaimIfMine() }
    }

    private func beginRecording() {
        guard !recording, fixedText == nil else { return }
        recording = true
        KeyMapStore.shared.recorder = { result in
            recording = false
            KeyMapStore.shared.recorder = nil
            onRecord(result)
        }
    }

    private func releaseClaimIfMine() {
        if recording {
            recording = false
            KeyMapStore.shared.recorder = nil
        }
    }
}

struct GroupHotKeyChip: View {
    let model: AppModel
    let group: GroupDefinition

    var body: some View {
        KeyChordChip(
            chords: GroupPalette.effectiveHotKey(for: group).map { [KeyChord($0)] } ?? [],
            fixedText: nil,
            isCustomized: group.hotKey != nil,
            onRecord: { result in
                switch result {
                case .chord(let chord):
                    let token = KeyChord.normalizeToken(chord.key)
                    guard chord.isBare, token.count == 1,
                          token.first?.isLetter == true else { return }
                    write(token)
                case .unbind:
                    write("")
                case .cancel:
                    break
                }
            }
        )
    }

    private func write(_ hotKey: String) {

        let value: String? =
            hotKey == GroupPalette.defaultHotKeys[GroupPalette.normalizedName(group.name)]
                ? nil : hotKey
        model.updateGroupPalette { palette in
            guard let index = palette.groups.firstIndex(where: { $0.id == group.id })
            else { return }
            palette.groups[index].hotKey = value
        }
    }
}
