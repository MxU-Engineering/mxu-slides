import PresenterCore
import SwiftUI

struct InspectorView: View {
    let model: AppModel
    let entry: LibraryIndex.Entry

    var body: some View {
        Group {
            if entry.kind == .playlist {

                PlaylistEditor(model: model, playlistID: entry.id)
            } else {
                Form {
                    switch entry.kind {
                    case .media: mediaForm
                    case .audio: audioForm
                    case .presentation: presentationForm
                    case .playlist: EmptyView()
                    case .theme: Text("Themes are edited in the slide editor.")
                    case .service: Text("Services are edited in the Service planner.")
                    case .overlay: Text("Overlays are edited in the slide editor.")
                    case .outputPreset: Text("Output Presets are edited in the Outputs panel.")
                    case .streamRecordPreset:
                        Text("Stream & Record Presets are edited in the Stream & Record module.")
                    case .alertPreset: Text("Alerts are edited in the Service Controls panel.")
                    case .actionCombo:
                        Text("Action Combos run and edit in the Service Controls rail.")
                    case .scheduleTrigger, .schedulerBoard:
                        Text("Triggers are edited in Scheduler mode.")
                    case .confidenceLayout:
                        Text("Confidence Layouts are edited in the slide editor.")
                    case .midiDevice: Text("MIDI devices are managed in Settings \u{203A} MIDI.")
                    case .streamDestination: Text("Destinations are managed in Settings \u{203A} Stream & Record.")
                    case .note: EmptyView()
                    case .controlBoard, .groupPalette, .signageBoard, .effectPresetBoard,
                         .animationPresetBoard, .importLedger, .serviceLinkRules, .stationSettings, .slideBuildingSettings, .font, .workspaceSettings: EmptyView() 
                    }
                }
                .formStyle(.grouped)
            }
        }
        .navigationTitle(entry.name)
        .sheet(
            item: Binding(
                get: { mediaActionsEditorID.map { MediaSettingsTarget(id: $0) } },
                set: { mediaActionsEditorID = $0?.id }
            )
        ) { target in
            SlideActionsSheet(
                model: model,
                slideName: entry.name,
                actions: Binding(
                    get: { model.media(target.id)?.actions ?? [] },
                    set: { actions in
                        model.updateMedia(target.id) {
                            $0.actions = actions.isEmpty ? nil : actions
                        }
                    }
                )
            )
        }
    }

    @ViewBuilder
    private var mediaForm: some View {

        if let item = model.media(entry.id) {
            Section("File") {
                LabeledContent("Kind", value: item.mediaKind.rawValue.capitalized)
                LabeledContent("Original name", value: item.fileName)
                if let w = item.pixelWidth, let h = item.pixelHeight {
                    LabeledContent("Dimensions", value: "\(w) × \(h)")
                }
                if let duration = item.durationSeconds {
                    LabeledContent("Duration", value: String(format: "%.1fs", duration))
                }
                LabeledContent("Status") {

                    if model.isMediaFileMissing(item) {
                        Text("Missing — the file isn't on this Mac").foregroundStyle(.red)
                    } else {
                        switch item.fileStatus {
                        case .ready: Text("Ready").foregroundStyle(.green)
                        case .needsTranscode: Text("Needs transcode — \(item.statusDetail)").foregroundStyle(.orange)
                        case .transcoding: Text("Transcoding…")
                        case .transcodeFailed: Text("Transcode failed — \(item.statusDetail)").foregroundStyle(.red)
                        }
                    }
                }
                if item.fileStatus == .needsTranscode || item.fileStatus == .transcodeFailed {
                    Button("Transcode Now") {
                        Task { _ = await model.transcodeQueue?.transcode(itemID: item.id) }
                    }
                    .disabled(model.isTranscoding)
                }
            }

            Section("On Fire") {
                AutoAdvanceControls(
                    advance: binding(item, \.autoAdvance),
                    mediaScope: true, showsCountFrom: item.mediaKind == .video
                )
                LabeledContent(
                    "Actions",
                    value: (item.actions ?? []).isEmpty
                        ? "None" : "\((item.actions ?? []).count)"
                )
                Button("Edit Actions…") { mediaActionsEditorID = item.id }
            }
            Section("Organization") {
                Picker("Classification", selection: binding(item, \.classification)) {
                    Text("Background").tag(MediaClassification.background)
                    Text("Foreground").tag(MediaClassification.foreground)
                }
                Toggle("Favorite", isOn: binding(item, \.favorite))
                Toggle("Loops", isOn: binding(item, \.loops))
                TagsField(tags: binding(item, \.tags))
            }
        } else {
            Text("Item unavailable.")
        }
    }

    @State private var mediaActionsEditorID: String?

    private func binding<T: Equatable & Sendable>(_ item: MediaItem, _ keyPath: WritableKeyPath<MediaItem, T> & Sendable) -> Binding<T> {
        Binding(
            get: { model.media(item.id)?[keyPath: keyPath] ?? item[keyPath: keyPath] },
            set: { newValue in model.updateMedia(item.id) { $0[keyPath: keyPath] = newValue } }
        )
    }

    @ViewBuilder
    private var audioForm: some View {
        if let item = model.audio(entry.id) {
            Section("File") {
                LabeledContent("Original name", value: item.fileName)
                if let duration = item.durationSeconds {
                    LabeledContent("Duration", value: String(format: "%.1fs", duration))
                }
            }
            Section("Organization") {
                Toggle("Favorite", isOn: Binding(
                    get: { model.audio(item.id)?.favorite ?? false },
                    set: { v in model.updateAudio(item.id) { $0.favorite = v } }
                ))
                TagsField(tags: Binding(
                    get: { model.audio(item.id)?.tags ?? [] },
                    set: { v in model.updateAudio(item.id) { $0.tags = v } }
                ))
            }
        }
    }

    @ViewBuilder
    private var presentationForm: some View {

        if let value = model.presentation(entry.id) {
            Section("Presentation") {
                LabeledContent("Type", value: value.presentationKind == .song ? "Song" : "Presentation")
                LabeledContent("Slides", value: "\(value.slides.count)")
                LabeledContent("Theme", value: value.themeId.isEmpty ? "None" : value.themeId)
            }
            Section {
                Text("Slides are edited in the slide editor.")
                    .foregroundStyle(.secondary)
            }
        }
    }

}

struct MediaSettingsTarget: Identifiable {
    let id: String
}

struct MediaSettingsSheet: View {
    let model: AppModel
    let mediaID: String

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                PosterImage(model: model, mediaId: mediaID)
                    .frame(width: 96, height: 54)
                    .clipShape(RoundedRectangle.standard(CornerStandard.element))
                    .overlay {
                        RoundedRectangle.standard(CornerStandard.element)
                            .strokeBorder(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 1)
                    }
                Text(model.indexEntry(mediaID)?.name ?? "Media")
                    .font(.headline)
                    .lineLimit(2)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
            Divider()
            if let entry = model.indexEntry(mediaID) {
                InspectorView(model: model, entry: entry)
            }
        }
        .frame(width: 460, height: 540)
    }
}

struct TagsField: View {
    @Binding var tags: [String]
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("Tags (comma-separated)", text: $text)
            .focused($focused)
            .onAppear { text = tags.joined(separator: ", ") }
            .onChange(of: tags) { _, newValue in
                if !focused { text = newValue.joined(separator: ", ") }
            }
            .onSubmit { commit() }
            .onChange(of: focused) { _, isFocused in
                if !isFocused { commit() }
            }
    }

    private func commit() {
        let parsed = text
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if parsed != tags { tags = parsed }
    }
}

struct PlaylistEditor: View {
    let model: AppModel
    let playlistID: String
    @State private var hoveredEntryID: String?

    var body: some View {
        if let list = try? model.playlist(playlistID) {

            let candidates = model.entries(in: (list.playlistKind ?? .audio) == .media ? .media : .audio)
            VStack(spacing: 0) {
                playbackControls(list)
                Divider()
                HStack {
                    Text("ITEMS (\(list.entries.count))")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .tracking(0.6)
                    Spacer()

                    Menu {
                        ForEach(candidates, id: \.id) { candidate in
                            Button(candidate.name) {
                                model.addToPlaylist(list.id, itemID: candidate.id)
                            }
                        }
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Add a track")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                if list.entries.isEmpty {
                    Text("Click + to add tracks, or right-click an item in the library and choose Add to Playlist.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(16)
                } else {
                    List {
                        ForEach(list.entries, id: \.id) { item in
                            row(item, in: list)
                                .listRowSeparator(.hidden)
                                .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
                        }
                        .onMove { from, to in
                            model.movePlaylistEntries(list.id, fromOffsets: from, toOffset: to)
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
        } else {
            ContentUnavailableView("Playlist not found", systemImage: "questionmark.square.dashed")
        }
    }

    private func row(_ item: PlaylistEntry, in list: Playlist) -> some View {
        let hovered = hoveredEntryID == item.id
        return HStack(spacing: 8) {

            Image(systemName: "line.3.horizontal")
                .font(.system(size: 8))
                .foregroundStyle(.tertiary)
                .opacity(hovered ? 1 : 0)
            Text(model.indexEntry(item.refId)?.name ?? item.refId)
                .font(.caption)
                .lineLimit(1)
            Spacer(minLength: 6)

            if let override = item.autoAdvanceDelaySeconds {
                Text(String(format: "⏱ %.0fs", override))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .help("This item's own Auto Advance delay — right-click to change")
            }

            Text(entryDuration(item) ?? "—")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
            Button {
                model.removePlaylistEntry(list.id, entryID: item.id)
            } label: {
                Image(systemName: "minus.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .opacity(hovered ? 1 : 0)
            .help("Remove from playlist")
        }
        .padding(.horizontal, 6)
        .frame(height: 24)
        .contentShape(Rectangle())
        .background(
            Color.primary.opacity(hovered ? 0.05 : 0),
            in: RoundedRectangle.standard(CornerStandard.element)
        )
        .onHover { inside in
            hoveredEntryID = inside ? item.id : (hoveredEntryID == item.id ? nil : hoveredEntryID)
        }
        .contextMenu {
            if (list.playlistKind ?? .audio) == .media {
                autoAdvanceOverrideMenu(item, in: list)
                Divider()
            }
            Button("Remove", role: .destructive) {
                model.removePlaylistEntry(list.id, entryID: item.id)
            }
        }
    }

    private func playbackControls(_ list: Playlist) -> some View {
        VStack(spacing: 8) {
            HStack {
                Text("Mode")
                    .font(.caption)
                Spacer()
                Picker("", selection: Binding(
                    get: { (try? model.playlist(list.id))?.playbackMode ?? .playAll },
                    set: { v in model.updatePlaylist(list.id) { $0.playbackMode = v } }
                )) {
                    Text("Play All").tag(PlaybackMode.playAll)
                    Text("Loop Playlist").tag(PlaybackMode.loopPlaylist)
                    Text("Loop Single").tag(PlaybackMode.loopSingle)
                }
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
            }
            HStack {
                Text("Shuffle")
                    .font(.caption)
                Spacer()
                Toggle("", isOn: Binding(
                    get: { (try? model.playlist(list.id))?.shuffle ?? false },
                    set: { v in model.updatePlaylist(list.id) { $0.shuffle = v } }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(.green)
                .controlSize(.mini)
            }

            let roomDefault = AudioController.storedRoomCrossfade()
            let override = (try? model.playlist(list.id))?.crossfadeSeconds
            HStack {
                Text("Crossfade")
                    .font(.caption)
                Spacer()
                Toggle("", isOn: Binding(
                    get: { override == nil },
                    set: { follows in
                        model.updatePlaylist(list.id) {
                            $0.crossfadeSeconds = follows ? nil : roomDefault
                        }
                    }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(.green)
                .controlSize(.mini)
                Text("Use default (\(PlaylistCrossfade.label(roomDefault)))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let override {
                HStack {
                    Text("This playlist")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Stepper(
                        PlaylistCrossfade.label(override),
                        value: Binding(
                            get: { (try? model.playlist(list.id))?.crossfadeSeconds ?? roomDefault },
                            set: { v in model.updatePlaylist(list.id) { $0.crossfadeSeconds = max(0, v) } }
                        ),
                        in: 0 ... PlaylistCrossfade.maximumSeconds,
                        step: 0.5
                    )
                    .font(.caption.monospacedDigit())
                    .controlSize(.small)
                }
            }

            if (list.playlistKind ?? .audio) == .media {
                HStack {
                    Text("Auto Advance")
                        .font(.caption)
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { (try? model.playlist(list.id))?.autoAdvance ?? false },
                        set: { v in model.updatePlaylist(list.id) { $0.autoAdvance = v } }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(.green)
                    .controlSize(.mini)
                }
                if list.autoAdvance ?? false {
                    HStack {
                        Text("Delay")
                            .font(.caption)
                        Spacer()
                        Stepper(
                            String(format: "%.1fs", list.autoAdvanceDelaySeconds ?? 0),
                            value: Binding(
                                get: { (try? model.playlist(list.id))?.autoAdvanceDelaySeconds ?? 0 },
                                set: { v in
                                    model.updatePlaylist(list.id) {
                                        $0.autoAdvanceDelaySeconds = max(0, v)
                                    }
                                }
                            ),
                            step: 0.5
                        )
                        .font(.caption.monospacedDigit())
                        .controlSize(.small)
                    }
                    Text("Stills hold this long; videos play to the end, then wait this long. Right-click an item for its own delay.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private static let overrideDelayChoices: [Double] = [0, 1, 2, 3, 5, 7, 10, 15, 30, 60]

    @ViewBuilder
    private func autoAdvanceOverrideMenu(_ entry: PlaylistEntry, in list: Playlist) -> some View {
        Menu("Auto Advance Delay") {
            Button(entry.autoAdvanceDelaySeconds == nil
                ? "✓ Playlist Delay" : "Playlist Delay"
            ) {
                setOverrideDelay(nil, entryID: entry.id, in: list)
            }
            Divider()
            ForEach(Self.overrideDelayChoices, id: \.self) { seconds in
                let label = String(format: "%.0fs", seconds)
                Button(entry.autoAdvanceDelaySeconds == seconds ? "✓ \(label)" : label) {
                    setOverrideDelay(seconds, entryID: entry.id, in: list)
                }
            }
        }
    }

    private func setOverrideDelay(_ seconds: Double?, entryID: String, in list: Playlist) {
        model.updatePlaylist(list.id) { playlist in
            guard let index = playlist.entries.firstIndex(where: { $0.id == entryID })
            else { return }
            playlist.entries[index].autoAdvanceDelaySeconds = seconds
        }
    }

    private func entryDuration(_ entry: PlaylistEntry) -> String? {
        let seconds: Double? = switch entry.refKind {
        case .audio: model.audio(entry.refId)?.durationSeconds
        case .media: model.media(entry.refId)?.durationSeconds
        }
        guard let seconds else { return nil }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
