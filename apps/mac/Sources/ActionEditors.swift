import PresenterCore
import RenderEngine
import SwiftUI

extension SlideActionKind {
    var displayName: String {
        switch self {
        case .clearLayer: "Clear Layer"
        case .clearAll: "Clear All"
        case .clearAudio: "Clear Music"
        case .clearSignage: "Clear Signage"
        case .switchOutputPreset: "Switch Output Preset"
        case .fireMedia: "Fire Media"
        case .fireAlert: "Fire Alert"
        case .dismissAlert: "Dismiss Alert"
        case .timerStart: "Start Timer"
        case .timerPause: "Pause Timer"
        case .timerReset: "Reset Timer"
        case .timerConfigure: "Configure Timer"
        case .midiOut: "MIDI Out"
        case .fireCombo: "Fire Action Combo"
        case .captureStart: "Start Capture"
        case .captureStop: "Stop Capture"
        case .firePresentation: "Fire Presentation"
        case .setConfidenceLayout: "Set Confidence Layout"
        case .fireOverlay: "Fire Overlay"
        case .dismissOverlay: "Take Down Overlay"
        case .fireLiveInput: "Fire Live Input"
        case .setSignage: "Set Signage Content"
        case .setScreenSource: "Set Screen Source"
        case .enableAudioInput: "Audio Input On"
        case .disableAudioInput: "Audio Input Off"
        case .fireAudio: "Music File"
        case .fireAudioPlaylist: "Music Playlist"
        }
    }
}

struct ActionListEditor: View {
    let model: AppModel
    @Binding var actions: [SlideAction]

    var editingComboID: String? = nil

    @Environment(\.actionRouter) private var router
    @State private var pickingMediaFor: String?
    @State private var pickingAudioFor: String?

    @State private var placing: SlideAction?

    var body: some View {
        ForEach(actions) { action in
            actionRow(action)
                .contextMenu {
                    Button("Move Up") { move(action, by: -1) }
                        .disabled(actions.first?.id == action.id)
                    Button("Move Down") { move(action, by: 1) }
                        .disabled(actions.last?.id == action.id)
                    Divider()
                    Button("Remove", role: .destructive) {
                        actions.removeAll { $0.id == action.id }
                    }
                }
        }
        Menu("Add Action\u{2026}") {
            AddActionMenuItems(
                model: model,
                timers: router?.timerChoices ?? [],
                excludeComboID: editingComboID
            ) { action in
                placing = action
            }
        }
        .sheet(item: $placing) { draft in
            ActionPlacementSheet(
                model: model, editingComboID: editingComboID, draft: draft
            ) { actions.append($0) }
        }
        .sheet(isPresented: Binding(
            get: { pickingMediaFor != nil },
            set: { if !$0 { pickingMediaFor = nil } }
        )) {
            LibraryPickerSheet(appModel: model) { entry in
                if let id = pickingMediaFor {
                    update(id) { $0.mediaId = entry.id }
                }
                pickingMediaFor = nil
            }
        }
        .sheet(isPresented: Binding(
            get: { pickingAudioFor != nil },
            set: { if !$0 { pickingAudioFor = nil } }
        )) {
            LibraryPickerSheet(appModel: model, kind: .audio) { entry in
                if let id = pickingAudioFor {
                    update(id) { $0.audioItemId = entry.id }
                }
                pickingAudioFor = nil
            }
        }
    }

    private func update(_ id: String, _ mutate: (inout SlideAction) -> Void) {
        guard let index = actions.firstIndex(where: { $0.id == id }) else { return }
        mutate(&actions[index])
    }

    private func move(_ action: SlideAction, by offset: Int) {
        guard let index = actions.firstIndex(where: { $0.id == action.id }) else { return }
        let target = index + offset
        guard actions.indices.contains(target) else { return }
        actions.swapAt(index, target)
    }

    private func binding(for id: String) -> Binding<SlideAction> {
        Binding(
            get: { actions.first { $0.id == id } ?? SlideAction(id: id, kind: .clearAll) },
            set: { value in
                if let index = actions.firstIndex(where: { $0.id == id }) {
                    actions[index] = value
                }
            }
        )
    }

    @ViewBuilder
    private func actionRow(_ action: SlideAction) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(action.kind.displayName.uppercased())
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .tracking(0.5)
                Spacer(minLength: 2)
                Button {
                    actions.removeAll { $0.id == action.id }
                } label: {
                    Image(systemName: "minus.circle")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Remove action")
            }
            ActionParameterFields(
                model: model, action: binding(for: action.id),
                editingComboID: editingComboID,
                pickMedia: { pickingMediaFor = action.id },
                pickAudio: { pickingAudioFor = action.id }
            )
        }
    }
}

struct ActionParameterFields: View {
    let model: AppModel
    @Binding var action: SlideAction

    var editingComboID: String? = nil
    let pickMedia: () -> Void
    let pickAudio: () -> Void

    @Environment(\.actionRouter) private var router
    @Environment(\.confidenceMonitor) private var confidenceMonitor
    @Environment(\.signage) private var signage

    @AppStorage("appMode") private var appModeRaw = AppMode.edit.rawValue

    var body: some View {
        parameters(action)

        SecondsRow(label: "Delay", seconds: Binding(
            get: { action.delaySeconds ?? 0 },
            set: { seconds in
                action.delaySeconds = seconds > 0 ? seconds : nil
            }
        ))
    }

    @ViewBuilder
    private func parameters(_ action: SlideAction) -> some View {
        switch action.kind {
        case .clearLayer:
            Picker("Layer", selection: stringBinding(action, \.layer)) {
                Text("Choose\u{2026}").tag("")

                ForEach(LayerKind.allCases.reversed(), id: \.rawValue) { layer in
                    Text(layer.displayName).tag(layer.rawValue)
                }
            }
        case .switchOutputPreset:
            Picker("Preset", selection: stringBinding(action, \.presetId)) {
                Text("Choose\u{2026}").tag("")
                ForEach(entries(of: .outputPreset), id: \.id) { entry in
                    Text(entry.name).tag(entry.id)
                }
            }
        case .fireMedia:
            LabeledContent("Media") {
                HStack(spacing: 4) {
                    Button(mediaName(action.mediaId)) { pickMedia() }
                    if let id = action.mediaId, !id.isEmpty {
                        openInEditorButton(id, help: "Edit Media")
                    }
                }
            }
        case .fireAlert:
            Picker("Alert", selection: stringBinding(action, \.alertId)) {
                Text("Choose\u{2026}").tag("")
                ForEach(entries(of: .alertPreset), id: \.id) { entry in
                    Text(entry.name).tag(entry.id)
                }
            }
        case .timerStart, .timerPause, .timerReset:
            Picker("Timer", selection: stringBinding(action, \.timerId)) {
                Text("Choose\u{2026}").tag("")
                ForEach(router?.timerChoices ?? [], id: \.id) { timer in
                    Text(timer.name).tag(timer.id)
                }
            }
        case .timerConfigure:
            Picker("Timer", selection: stringBinding(action, \.timerId)) {
                Text("Choose\u{2026}").tag("")
                ForEach(router?.timerChoices ?? [], id: \.id) { timer in
                    Text(timer.name).tag(timer.id)
                }
            }
            Picker("Mode", selection: Binding(
                get: { action.timerMode?.rawValue ?? "" },
                set: { raw in update(action.id) { $0.timerMode = TimerMode(rawValue: raw) } }
            )) {
                Text("Keep Mode").tag("")
                Text("Countdown").tag(TimerMode.countdown.rawValue)
                Text("Countdown to Time").tag(TimerMode.countdownToTime.rawValue)
                Text("Count Up").tag(TimerMode.countUp.rawValue)
            }
            if action.timerMode == .countdownToTime {
                intField(action, "Hour", \.timerHour, default: 9, range: 0...23)
                intField(action, "Minute", \.timerMinute, default: 0, range: 0...59)
            } else {
                durationSteppers(action)
            }
        case .fireCombo:
            Picker("Combo", selection: stringBinding(action, \.comboId)) {
                Text("Choose\u{2026}").tag("")
                ForEach(model.actionCombos.filter { $0.id != editingComboID }, id: \.id) { entry in
                    Text(entry.name).tag(entry.id)
                }
            }
        case .midiOut:
            Picker("Device", selection: stringBinding(action, \.midiDeviceId)) {

                Text("All Enabled Devices").tag("")
                ForEach(
                    MIDIDeviceInventory.shared.items.filter(\.wantsOutput), id: \.id
                ) { item in
                    Text(item.device.name).tag(item.id)
                }
            }
            Picker("Message", selection: Binding(
                get: { action.midiKind ?? .noteOn },
                set: { value in update(action.id) { $0.midiKind = value } }
            )) {
                Text("Note On").tag(MIDIMessageKind.noteOn)
                Text("Control Change").tag(MIDIMessageKind.controlChange)
            }
            intField(action, "Channel", \.midiChannel, default: 1, range: 1...16)
            if action.midiKind == .controlChange {
                intField(action, "Controller", \.midiNumber, default: 0, range: 0...127)
                intField(action, "Value", \.midiValue, default: 127, range: 0...127)
            } else {

                Stepper(value: Binding(
                    get: { action.midiNumber ?? 0 },
                    set: { value in
                        update(action.id) { $0.midiNumber = value.clamped(to: 0...127) }
                    }
                ), in: 0...127) {
                    LabeledContent(
                        "Note",
                        value: "\(MIDINote.name(action.midiNumber ?? 0)) · \(action.midiNumber ?? 0)")
                }
                intField(action, "Velocity", \.midiValue, default: 127, range: 0...127)
            }
        case .captureStart:
            Picker("Preset", selection: stringBinding(action, \.capturePresetId)) {
                Text("Choose\u{2026}").tag("")
                ForEach(entries(of: .streamRecordPreset), id: \.id) { entry in
                    Text(entry.name).tag(entry.id)
                }
            }
        case .captureStop:
            Picker("Preset", selection: stringBinding(action, \.capturePresetId)) {

                Text("All Capture").tag("")
                ForEach(entries(of: .streamRecordPreset), id: \.id) { entry in
                    Text(entry.name).tag(entry.id)
                }
            }
        case .firePresentation:
            Picker("Presentation", selection: stringBinding(action, \.presentationId)) {
                Text("Choose\u{2026}").tag("")
                ForEach(entries(of: .presentation), id: \.id) { entry in
                    Text(entry.name).tag(entry.id)
                }
            }

            Stepper(value: Binding(
                get: { (action.slideIndex ?? 0) + 1 },
                set: { shown in
                    update(action.id) { $0.slideIndex = max(0, shown - 1) }
                }
            ), in: 1...999) {
                LabeledContent("Slide", value: "\((action.slideIndex ?? 0) + 1)")
            }
        case .setConfidenceLayout:
            Picker("Layout", selection: stringBinding(action, \.confidenceLayoutId)) {

                Text("Built-in Layout").tag("")
                ForEach(entries(of: .confidenceLayout), id: \.id) { entry in
                    Text(entry.name).tag(entry.id)
                }
            }
            Picker("Screen", selection: stringBinding(action, \.confidenceScreenId)) {

                Text("All Confidence Monitors").tag("")
                ForEach(confidenceMonitor?.confidenceScreens ?? [], id: \.id) { screen in
                    Text(screen.name).tag(screen.id.uuidString)
                }
            }
        case .fireOverlay:
            Picker("Overlay", selection: stringBinding(action, \.overlayId)) {
                Text("Choose\u{2026}").tag("")
                ForEach(entries(of: .overlay), id: \.id) { entry in
                    Text(entry.name).tag(entry.id)
                }
            }
        case .dismissOverlay:
            Picker("Overlay", selection: stringBinding(action, \.overlayId)) {

                Text("All Overlays").tag("")
                ForEach(entries(of: .overlay), id: \.id) { entry in
                    Text(entry.name).tag(entry.id)
                }
            }
        case .fireLiveInput:
            Picker("Source", selection: Binding(
                get: {
                    LiveInputCatalog.selectionToken(
                        liveInputId: action.liveInputId,
                        kind: action.inputSourceKind, id: action.inputSourceId)
                },
                set: { token in
                    update(action.id) { step in
                        step.inputSourceKind = nil
                        step.inputSourceId = nil
                        if let itemId = LiveInputCatalog.liveInputId(for: token) {
                            step.liveInputId = itemId
                        } else if let choice = LiveInputCatalog.choice(for: token) {

                            step.liveInputId = nil
                            step.inputSourceKind = choice.kind
                            step.inputSourceId = choice.id
                        } else {
                            step.liveInputId = nil
                        }
                    }
                }
            )) {
                Text("Choose\u{2026}").tag("")
                ForEach(LiveInputCatalog.choices, id: \.token) { choice in
                    Text(choice.name).tag(choice.token)
                }

                if action.liveInputId?.isEmpty != false,
                   let sourceId = action.inputSourceId, !sourceId.isEmpty {
                    Text(LiveInputCatalog.legacyLabel(
                        kind: action.inputSourceKind, id: sourceId))
                        .tag(LiveInputCatalog.selectionToken(
                            liveInputId: nil,
                            kind: action.inputSourceKind, id: sourceId))
                }
            }
            Picker("Layer", selection: stringBinding(action, \.layer)) {
                Text("Video Input").tag("")
                ForEach(LayerKind.allCases.reversed(), id: \.rawValue) { layer in
                    if layer != .videoInput {
                        Text(layer.displayName).tag(layer.rawValue)
                    }
                }
            }
        case .setSignage:
            Picker("Signage", selection: stringBinding(action, \.signageId)) {
                Text("Choose\u{2026}").tag("")
                ForEach(signage?.channels ?? [], id: \.id) { channel in
                    Text(channel.name).tag(channel.id)
                }
            }
            Picker("Playlist", selection: stringBinding(action, \.playlistId)) {

                Text("Choose\u{2026}").tag("")
                ForEach(model.playlists(in: .media), id: \.id) { entry in
                    Text(entry.name).tag(entry.id)
                }
            }
        case .setScreenSource:
            Picker("Screen", selection: stringBinding(action, \.screenId)) {
                Text("Choose\u{2026}").tag("")
                ForEach(signage?.screens ?? [], id: \.id) { screen in
                    Text(screen.name).tag(screen.id.uuidString)
                }
            }
            Picker("Source", selection: stringBinding(action, \.signageId)) {

                Text("Program").tag("")
                ForEach(signage?.channels ?? [], id: \.id) { channel in
                    Text("Signage — \(channel.name)").tag(channel.id)
                }
            }
        case .enableAudioInput, .disableAudioInput:
            Picker("Input", selection: stringBinding(action, \.audioInputId)) {
                Text("Choose\u{2026}").tag("")
                ForEach(AudioInputInventory.shared.entries) { entry in
                    Text(entry.name).tag(entry.id)
                }
            }
        case .fireAudio:
            LabeledContent("File") {
                HStack(spacing: 4) {
                    Button(entryName(action.audioItemId, missing: "Missing music")) {
                        pickAudio()
                    }
                    if let id = action.audioItemId, !id.isEmpty {
                        openInEditorButton(id, help: "Edit Music")
                    }
                }
            }

            Toggle("Repeat", isOn: Binding(
                get: { action.audioRepeat ?? false },
                set: { on in update(action.id) { $0.audioRepeat = on ? true : nil } }
            ))
        case .fireAudioPlaylist:
            Picker("Playlist", selection: stringBinding(action, \.playlistId)) {
                Text("Choose\u{2026}").tag("")
                ForEach(model.playlists(in: .audio), id: \.id) { entry in
                    Text(entry.name).tag(entry.id)
                }
            }
            repeatPicker(action)
        case .clearAll, .clearAudio, .clearSignage, .dismissAlert:
            EmptyView()
        }
    }

    @ViewBuilder
    private func durationSteppers(_ action: SlideAction) -> some View {
        let total = Int(action.timerDurationSeconds ?? 0)
        Stepper(value: Binding(
            get: { total / 60 },
            set: { minutes in update(action.id) { $0.timerDurationSeconds = Double(minutes * 60 + total % 60) } }
        ), in: 0...600) {
            LabeledContent("Minutes", value: "\(total / 60)")
        }
        Stepper(value: Binding(
            get: { total % 60 },
            set: { seconds in update(action.id) { $0.timerDurationSeconds = Double((total / 60) * 60 + seconds) } }
        ), in: 0...59) {
            LabeledContent("Seconds", value: "\(total % 60)")
        }
    }

    private func intField(
        _ action: SlideAction, _ label: String,
        _ keyPath: WritableKeyPath<SlideAction, Int?>,
        default fallback: Int, range: ClosedRange<Int>
    ) -> some View {
        Stepper(value: Binding(
            get: { action[keyPath: keyPath] ?? fallback },
            set: { value in update(action.id) { $0[keyPath: keyPath] = value.clamped(to: range) } }
        ), in: range) {
            LabeledContent(label, value: "\(action[keyPath: keyPath] ?? fallback)")
        }
    }

    private func stringBinding(
        _ action: SlideAction, _ keyPath: WritableKeyPath<SlideAction, String?>
    ) -> Binding<String> {
        Binding(
            get: { action[keyPath: keyPath] ?? "" },
            set: { value in
                update(action.id) { $0[keyPath: keyPath] = value.isEmpty ? nil : value }
            }
        )
    }

    private func update(_ id: String, _ mutate: (inout SlideAction) -> Void) {
        mutate(&action)
    }

    private func entries(of kind: DocumentKind) -> [LibraryIndex.Entry] {
        model.entries(of: kind)
    }

    private func mediaName(_ id: String?) -> String {
        guard let id, !id.isEmpty else { return "Choose\u{2026}" }
        return model.indexEntry(id)?.name ?? "Missing media"
    }

    private func entryName(_ id: String?, missing: String) -> String {
        guard let id, !id.isEmpty else { return "Choose\u{2026}" }
        return model.indexEntry(id)?.name ?? missing
    }

    private func openInEditorButton(_ entryID: String, help: String) -> some View {
        Button {
            model.openInEditor(entryID: entryID)
            appModeRaw = AppMode.edit.rawValue
        } label: {
            Image(systemName: "pencil")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func repeatPicker(_ action: SlideAction) -> some View {
        Picker("Repeat", selection: Binding(
            get: {
                switch action.audioRepeat {
                case true?: "on"
                case false?: "off"
                case nil: ""
                }
            },
            set: { (token: String) in
                update(action.id) {
                    $0.audioRepeat = token.isEmpty ? nil : token == "on"
                }
            }
        )) {
            Text("Playlist Setting").tag("")
            Text("On").tag("on")
            Text("Off").tag("off")
        }
    }
}

private extension Int {
    func clamped(to range: ClosedRange<Int>) -> Int {
        Swift.min(range.upperBound, Swift.max(range.lowerBound, self))
    }
}

struct SlideActionsSheet: View {
    let model: AppModel
    let slideName: String
    @Binding var actions: [SlideAction]

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(slideName.isEmpty ? "Slide Actions" : "Slide Actions — \(slideName)")
                    .font(.headline)
                Spacer()
            }
            .padding(16)
            Form {
                Section {

                    ActionListEditor(model: model, actions: $actions)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 440, height: 460)
    }
}

struct ActionPlacementSheet: View {
    let model: AppModel
    var editingComboID: String? = nil
    @State private var draft: SlideAction
    let commit: (SlideAction) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.actionRouter) private var router
    @State private var pickingMedia = false
    @State private var pickingAudio = false

    init(
        model: AppModel, editingComboID: String? = nil,
        draft: SlideAction, commit: @escaping (SlideAction) -> Void
    ) {
        self.model = model
        self.editingComboID = editingComboID
        self.commit = commit
        _draft = State(initialValue: draft)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Add Action")
                    .font(.headline)
                Spacer()
            }
            .padding(16)
            Form {
                Section {

                    LabeledContent("Action") {
                        Menu(draft.kind.displayName) {
                            AddActionMenuItems(
                                model: model,
                                timers: router?.timerChoices ?? [],
                                excludeComboID: editingComboID
                            ) { replacement in
                                var next = replacement
                                next.id = draft.id
                                next.delaySeconds = draft.delaySeconds
                                draft = next
                            }
                        }
                    }
                    ActionParameterFields(
                        model: model, action: $draft,
                        editingComboID: editingComboID,
                        pickMedia: { pickingMedia = true },
                        pickAudio: { pickingAudio = true }
                    )
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Add") {
                    commit(draft)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 440, height: 420)
        .sheet(isPresented: $pickingMedia) {
            LibraryPickerSheet(appModel: model) { entry in
                draft.mediaId = entry.id
                pickingMedia = false
            }
        }
        .sheet(isPresented: $pickingAudio) {
            LibraryPickerSheet(appModel: model, kind: .audio) { entry in
                draft.audioItemId = entry.id
                pickingAudio = false
            }
        }
    }
}

struct AddActionMenuItems: View {
    let model: AppModel

    var timers: [(id: String, name: String)] = []

    var excludeComboID: String? = nil

    let add: (SlideAction) -> Void

    @Environment(\.signage) private var signage

    var body: some View {
        let presets = entries(of: .outputPreset)
        if !presets.isEmpty {
            Menu("Output Preset") {
                ForEach(presets, id: \.id) { preset in
                    Button(preset.name) {
                        add(make(.switchOutputPreset) { $0.presetId = preset.id })
                    }
                }
            }
        }
        Menu("Clear") {
            Button("Clear All") { add(make(.clearAll)) }
            Divider()

            ForEach(LayerKind.allCases.reversed(), id: \.rawValue) { layer in
                Button(layer.displayName) {
                    add(make(.clearLayer) { $0.layer = layer.rawValue })
                }
            }
            Divider()

            Button("Clear Music") { add(make(.clearAudio)) }
            Button("Clear Signage") { add(make(.clearSignage)) }
        }
        Button("Fire Media\u{2026}") { add(make(.fireMedia)) }
        Button("Fire Presentation") { add(make(.firePresentation)) }

        let musicPlaylists = model.playlists(in: .audio)
        Menu("Music") {
            if !musicPlaylists.isEmpty {
                Menu("Playlist") {
                    ForEach(musicPlaylists, id: \.id) { playlist in
                        Button(playlist.name) {
                            add(make(.fireAudioPlaylist) { $0.playlistId = playlist.id })
                        }
                    }
                }
            }
            Button("File\u{2026}") { add(make(.fireAudio)) }
        }
        let alerts = entries(of: .alertPreset)
        Menu("Alert") {
            ForEach(alerts, id: \.id) { alert in
                Button(alert.name) {
                    add(make(.fireAlert) { $0.alertId = alert.id })
                }
            }
            if !alerts.isEmpty { Divider() }
            Button("Dismiss Alert") { add(make(.dismissAlert)) }
        }
        let overlays = entries(of: .overlay)
        Menu("Overlay") {
            ForEach(overlays, id: \.id) { overlay in
                Button(overlay.name) {
                    add(make(.fireOverlay) { $0.overlayId = overlay.id })
                }
            }
            if !overlays.isEmpty { Divider() }
            Button("Take Down Overlays") { add(make(.dismissOverlay)) }
        }
        let inputs = LiveInputCatalog.choices
        if !inputs.isEmpty {
            Menu("Live Input") {
                ForEach(inputs, id: \.token) { choice in
                    Button(choice.name) {
                        add(make(.fireLiveInput) { $0.liveInputId = choice.id })
                    }
                }
            }
        }
        let audioInputs = AudioInputInventory.shared.entries
        if !audioInputs.isEmpty {
            Menu("Audio Input") {
                ForEach(audioInputs) { entry in
                    Button("\(entry.name) On") {
                        add(make(.enableAudioInput) { $0.audioInputId = entry.id })
                    }
                    Button("\(entry.name) Off") {
                        add(make(.disableAudioInput) { $0.audioInputId = entry.id })
                    }
                }
            }
        }
        let layouts = entries(of: .confidenceLayout)
        Menu("Confidence Layout") {
            Button("Built-in Layout") { add(make(.setConfidenceLayout)) }
            if !layouts.isEmpty { Divider() }
            ForEach(layouts, id: \.id) { layout in
                Button(layout.name) {
                    add(make(.setConfidenceLayout) { $0.confidenceLayoutId = layout.id })
                }
            }
        }

        let channels = signage?.channels ?? []
        if !channels.isEmpty {
            let signagePlaylists = model.playlists(in: .media)
            Menu("Signage") {
                if !signagePlaylists.isEmpty {
                    Menu("Set Content") {
                        ForEach(channels, id: \.id) { channel in
                            Menu(channel.name) {
                                ForEach(signagePlaylists, id: \.id) { playlist in
                                    Button(playlist.name) {
                                        add(make(.setSignage) {
                                            $0.signageId = channel.id
                                            $0.playlistId = playlist.id
                                        })
                                    }
                                }
                            }
                        }
                    }
                }
                let screens = signage?.screens ?? []
                if !screens.isEmpty {
                    Menu("Screen Source") {
                        ForEach(screens, id: \.id) { screen in
                            Menu(screen.name) {
                                Button("Program") {
                                    add(make(.setScreenSource) {
                                        $0.screenId = screen.id.uuidString
                                    })
                                }
                                ForEach(channels, id: \.id) { channel in
                                    Button("Signage — \(channel.name)") {
                                        add(make(.setScreenSource) {
                                            $0.screenId = screen.id.uuidString
                                            $0.signageId = channel.id
                                        })
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        if !timers.isEmpty {
            Menu("Timer") {
                timerOps("Start", .timerStart)
                timerOps("Pause", .timerPause)
                timerOps("Reset", .timerReset)

                Menu("Configure") {
                    ForEach(timers, id: \.id) { timer in
                        Button(timer.name) {
                            add(make(.timerConfigure) {
                                $0.timerId = timer.id
                                $0.timerMode = .countdown
                                $0.timerDurationSeconds = 300
                            })
                        }
                    }
                }
            }
        }
        let combos = model.actionCombos.filter { $0.id != excludeComboID }
        if !combos.isEmpty {
            Menu("Action Combo") {
                ForEach(combos, id: \.id) { combo in
                    Button(combo.name) {
                        add(make(.fireCombo) { $0.comboId = combo.id })
                    }
                }
            }
        }
        let capturePresets = entries(of: .streamRecordPreset)
        Menu("Capture") {
            if !capturePresets.isEmpty {
                Menu("Start") {
                    ForEach(capturePresets, id: \.id) { preset in
                        Button(preset.name) {
                            add(make(.captureStart) { $0.capturePresetId = preset.id })
                        }
                    }
                }
                Menu("Stop") {
                    ForEach(capturePresets, id: \.id) { preset in
                        Button(preset.name) {
                            add(make(.captureStop) { $0.capturePresetId = preset.id })
                        }
                    }
                }
                Divider()
            }
            Button("Stop All Capture") { add(make(.captureStop)) }
        }
        Button("MIDI Out") { add(make(.midiOut)) }
    }

    @ViewBuilder
    private func timerOps(_ label: String, _ kind: SlideActionKind) -> some View {
        Menu(label) {
            ForEach(timers, id: \.id) { timer in
                Button(timer.name) {
                    add(make(kind) { $0.timerId = timer.id })
                }
            }
        }
    }

    private func make(
        _ kind: SlideActionKind, _ fill: (inout SlideAction) -> Void = { _ in }
    ) -> SlideAction {
        var action = SlideAction(id: UUID().uuidString, kind: kind)
        fill(&action)
        return action
    }

    private func entries(of kind: DocumentKind) -> [LibraryIndex.Entry] {
        model.entries(of: kind)
    }
}
