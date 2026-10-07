import AudioEngine
import PresenterCore
import SwiftUI

struct StreamRecordPane: View {
    let model: AppModel
    let controls: ServiceControls

    enum Tab: String, CaseIterable, Identifiable {
        case destinations, presets
        var id: String { rawValue }
        var title: String {
            switch self {
            case .destinations: "Destinations"
            case .presets: "Presets"
            }
        }
    }

    enum Page: Equatable {
        case list
        case destination(String)
        case preset(String)
    }

    @State private var tab: Tab = .presets
    @State private var page: Page = .list
    @State private var router = SettingsRouter.shared

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            switch page {
            case .list:
                switch tab {
                case .destinations:
                    DestinationsList(model: model) { page = .destination($0) }
                case .presets:
                    PresetsList(model: model) { page = .preset($0) }
                }
            case .destination(let id):
                DestinationDetail(model: model, controls: controls, id: id) { page = .list }
            case .preset(let id):
                PresetDetail(model: model, controls: controls, id: id) { page = .list }
            }
        }

        .background(Color.basePlane)
        .onAppear(perform: consumeRoute)
        .onChange(of: router.pendingStreamTab) { _, _ in consumeRoute() }
        .onChange(of: router.pendingStreamPresetID) { _, _ in consumeRoute() }
    }

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 8) {
            switch page {
            case .list:
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 220)
                Spacer()
            case .destination(let id):
                backButton(tab.title)
                Text(destinationTitle(id)).font(.system(size: 13, weight: .semibold))
                Spacer()
            case .preset(let id):
                backButton(tab.title)
                Text((try? model.streamPreset(id))?.name ?? "Preset").font(.system(size: 13, weight: .semibold))
                Spacer()
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
    }

    private func backButton(_ title: String) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.15)) { page = .list }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                Text(title).font(.system(size: 12))
            }
            .foregroundStyle(Color.accentColor)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func destinationTitle(_ id: String) -> String {
        model.resolvedStreamDestination(id).map(StreamDestinationLibrary.displayName) ?? "Destination"
    }

    private func consumeRoute() {
        if let pending = router.pendingStreamTab {
            tab = pending
            page = .list
            router.pendingStreamTab = nil
        }
        if let presetID = router.pendingStreamPresetID {
            tab = .presets
            page = .preset(presetID)
            router.pendingStreamPresetID = nil
        }
    }
}

struct TransportMark: View {
    let transport: StreamTransport
    var size: CGFloat = 20

    var body: some View {
        Text(transport.rawValue.uppercased())
            .font(.system(size: size * 0.36, weight: .bold))
            .foregroundStyle(.secondary)
            .frame(width: size * 1.35, height: size)
            .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
}

private struct ReadinessBadge: View {
    let text: String
    let color: Color
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text).font(.system(size: 11)).foregroundStyle(color == .green ? .secondary : color)
        }
    }
}

private struct Chevron: View {
    var body: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.tertiary)
    }
}

private struct DestinationsList: View {
    let model: AppModel
    let open: (String) -> Void

    @State private var addingCustom = false

    private struct Row: Identifiable {
        var id: String
        var destination: StreamDestination
    }

    private var customRows: [Row] {
        model.allStreamDestinations
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .map { Row(id: $0.id, destination: $0) }
    }

    var body: some View {
        Form {
            Section {
                let rows = customRows
                if rows.isEmpty {
                    Text("RTMP, RTMPS, SRT, or HLS endpoints — Resi, a campus decoder, a CDN.")
                        .foregroundStyle(.secondary)
                }
                ForEach(rows) { row in destinationRow(row) }
                Button("Add Custom Destination\u{2026}") { addingCustom = true }
            } header: {
                Text("Destinations")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(Color.basePlane)
        .sheet(isPresented: $addingCustom) {
            AddCustomDestinationSheet(model: model) { id in open(id) }
        }
    }

    private func destinationRow(_ row: Row) -> some View {
        let usedBy = model.presetsUsingStreamDestination(row.id).count
        let d = row.destination
        return Button { open(row.id) } label: {
            HStack(spacing: 10) {
                TransportMark(transport: d.transport, size: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(StreamDestinationLibrary.displayName(d))
                        .font(.system(size: 13))
                    Text(subtitle(d))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                ReadinessBadge(text: "Ready", color: .green)
                Text(usedBy == 0 ? "Unused" : "\(usedBy) preset\(usedBy == 1 ? "" : "s")")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .frame(width: 64, alignment: .trailing)
                Chevron()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func subtitle(_ d: StreamDestination) -> String {
        var parts = ["\(d.transport.rawValue.uppercased()) \u{B7} \(d.url)"]
        if let cap = d.maxHeight { parts.append("\(cap)p cap") }
        return parts.joined(separator: " \u{B7} ")
    }
}

private struct DestinationDetail: View {
    let model: AppModel
    let controls: ServiceControls
    let id: String
    let back: () -> Void

    @State private var confirmDelete = false
    @State private var confirmHDR = false

    var body: some View {
        if let destination = model.resolvedStreamDestination(id) {
            Form {
                Section {
                    TextField("Name", text: binding(\.name), prompt: Text("Name"))
                    Picker("Transport", selection: binding(\.transport)) {
                        ForEach(StreamTransport.allCases, id: \.self) { Text($0.rawValue.uppercased()).tag($0) }
                    }
                    TextField("Server URL", text: binding(\.url), prompt: Text("rtmps://host/app"))
                    if destination.transport != .srt {
                        SecureField("Stream key", text: binding(\.streamKey, default: "", nilFor: ""))
                    }
                } header: {
                    Text("Destination")
                }

                Section("Advanced") {
                    if destination.transport == .hls {
                        Picker("Codec", selection: Binding(
                            get: { destination.videoCodec == .hevc ? "hevc" : "h264" },
                            set: { v in update { $0.videoCodec = v == "hevc" ? .hevc : .h264; if v != "hevc" { $0.hdr = nil } } })
                        ) {
                            Text("HEVC").tag("hevc")
                            Text("H.264").tag("h264")
                        }
                        Toggle("HDR (HLG)", isOn: Binding(
                            get: { destination.hdr == true },
                            set: { on in if on { confirmHDR = true } else { update { $0.hdr = nil } } }))
                            .disabled(destination.videoCodec != .hevc)
                    }

                    Picker("Max resolution", selection: Binding(
                        get: { destination.maxHeight ?? 0 },
                        set: { v in update { $0.maxHeight = v == 0 ? nil : v } })
                    ) {
                        Text("Full canvas").tag(0)
                        Text("2160p").tag(2160)
                        Text("1440p").tag(1440)
                        Text("1080p").tag(1080)
                        Text("720p").tag(720)
                    }
                    Picker("Canvas", selection: Binding(
                        get: { destination.canvasScreenId ?? "" },
                        set: { v in update { $0.canvasScreenId = v.isEmpty ? nil : v } })
                    ) {
                        Text("Inherit preset").tag("")
                        ForEach(PreviewTargets.screens(controls.render), id: \.id) { screen in
                            Text(screen.name).tag(screen.id)
                        }
                    }
                    Picker("Quality", selection: Binding(
                        get: { qualityTag(destination) },
                        set: { v in update { apply(qualityTag: v, to: &$0) } })
                    ) {
                        Text("Inherit preset").tag("")
                        ForEach(StreamQualityRung.rungs) { rung in
                            Text(rung.label).tag(rung.id)
                        }
                        Text("Vertical 1080\u{D7}1920 \u{B7} 30 fps").tag("1080x1920@30")
                    }
                }

                Section {
                    Button("Delete Destination\u{2026}", role: .destructive) { confirmDelete = true }
                }
            }
            .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(Color.basePlane)
            .alert("Delete this destination?", isPresented: $confirmDelete) {
                Button("Delete", role: .destructive) {
                    model.deleteStreamDestination(id)
                    back()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                let count = model.presetsUsingStreamDestination(id).count
                Text(count == 0 ? "No preset uses it." : "\(count) preset\(count == 1 ? "" : "s") stream to it — they'll stop including it.")
            }
            .alert("Stream in HDR?", isPresented: $confirmHDR) {
                Button("Use HDR") { update { $0.hdr = true } }
                Button("Keep SDR", role: .cancel) {}
            } message: {
                Text("HDR only looks right when every source is HDR — cameras, media, and graphics. SDR content gains nothing in HDR and can look wrong to viewers.")
            }
        } else {
            ContentUnavailableView("Destination not found", systemImage: "antenna.radiowaves.left.and.right")
        }
    }

    private func update(_ mutate: (inout StreamDestination) -> Void) {
        guard var destination = model.resolvedStreamDestination(id) else { return }
        mutate(&destination)
        model.saveStreamDestination(destination)
    }

    private func binding<V>(_ keyPath: WritableKeyPath<StreamDestination, V>) -> Binding<V> {
        Binding(
            get: { model.resolvedStreamDestination(id)![keyPath: keyPath] },
            set: { v in update { $0[keyPath: keyPath] = v } })
    }

    private func binding(_ keyPath: WritableKeyPath<StreamDestination, String?>, default fallback: String, nilFor: String) -> Binding<String> {
        Binding(
            get: { model.resolvedStreamDestination(id)?[keyPath: keyPath] ?? fallback },
            set: { v in update { $0[keyPath: keyPath] = v == nilFor ? nil : v } })
    }

    private func qualityTag(_ d: StreamDestination) -> String {
        guard let w = d.width, let h = d.height else { return "" }
        return "\(w)x\(h)@\(d.frameRate ?? 30)"
    }

    private func apply(qualityTag tag: String, to d: inout StreamDestination) {
        guard !tag.isEmpty else { d.width = nil; d.height = nil; d.frameRate = nil; return }
        let parts = tag.replacingOccurrences(of: "@", with: "x").split(separator: "x").compactMap { Int($0) }
        guard parts.count == 3 else { return }
        d.width = parts[0]; d.height = parts[1]; d.frameRate = parts[2]
    }
}

private struct AddCustomDestinationSheet: View {
    let model: AppModel
    let onAdd: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var transport: StreamTransport = .rtmps
    @State private var url = ""
    @State private var key = ""
    @State private var name = ""

    private var candidate: StreamDestination {
        StreamDestination(
            id: UUID().uuidString,
            name: name.trimmingCharacters(in: .whitespaces),
            transport: transport,
            url: url.trimmingCharacters(in: .whitespaces),
            streamKey: transport == .srt || key.isEmpty ? nil : key)
    }

    private var isValid: Bool {
        let c = candidate
        let probe = StreamPresetDestination(
            id: c.id, name: c.name.isEmpty ? "x" : c.name, transport: c.transport, url: c.url, streamKey: c.streamKey)
        return !c.name.isEmpty && StreamDestinationReadiness.isReady(probe)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Picker("Transport", selection: $transport) {
                    ForEach(StreamTransport.allCases, id: \.self) { Text($0.rawValue.uppercased()).tag($0) }
                }
                TextField("Server URL", text: $url, prompt: Text("rtmps://host/app"))
                if transport != .srt {
                    SecureField("Stream key", text: $key)
                }
                TextField("Name", text: $name, prompt: Text("Resi, North Campus Decoder\u{2026}"))
            }
            .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(Color.basePlane)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Add") {
                    let destination = candidate
                    model.saveStreamDestination(destination)
                    dismiss()
                    onAdd(destination.id)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid)
            }
            .padding(16)
        }
        .frame(width: 440, height: 260)
    }
}

private struct PresetsList: View {
    let model: AppModel
    let open: (String) -> Void

    @State private var renamingFolderID: String?
    @State private var folderName = ""

    var body: some View {
        let board = model.streamBoard
        Form {

            let topLevel = board.nodes.filter { board.folder(id: $0) == nil }
            Section {
                ForEach(topLevel, id: \.self) { presetRow($0, folderID: nil) }
                if topLevel.isEmpty && board.orderedFolders.isEmpty {
                    Text("No presets yet.").foregroundStyle(.secondary)
                }
                Button("New Preset\u{2026}") {
                    if let id = model.createStreamPreset(name: "New Preset") { open(id) }
                }
                Button("New Folder\u{2026}") {
                    let newID = UUID().uuidString
                    model.updateStreamBoard { $0.addFolder(named: "New Folder", id: newID) }
                    renamingFolderID = newID
                    folderName = "New Folder"
                }
            } header: {
                Text("Presets")
            } footer: {
                Text("A preset says which destinations, what streams, and what records. Capture from Preset in the header chip goes live on one; the Scheduler fires them.")
            }
            ForEach(board.orderedFolders, id: \.id) { folder in
                Section {
                    ForEach(folder.itemIds, id: \.self) { presetRow($0, folderID: folder.id) }
                    if folder.itemIds.isEmpty {
                        Text("Empty folder — move presets here from their \u{2026} menu.").foregroundStyle(.secondary)
                    }
                } header: {
                    HStack {
                        Text(folder.name)
                        Spacer()
                        Menu {
                            Button("Rename Folder\u{2026}") { renamingFolderID = folder.id; folderName = folder.name }
                            Button("Remove Folder", role: .destructive) {
                                model.updateStreamBoard { $0.removeFolder(id: folder.id) }
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(Color.basePlane)
        .alert("Folder Name", isPresented: Binding(
            get: { renamingFolderID != nil }, set: { if !$0 { renamingFolderID = nil } })
        ) {
            TextField("Name", text: $folderName)
            Button("Save") {
                if let id = renamingFolderID {
                    let name = folderName.trimmingCharacters(in: .whitespaces)
                    if !name.isEmpty { model.updateStreamBoard { $0.renameFolder(id: id, to: name) } }
                }
                renamingFolderID = nil
            }
            Button("Cancel", role: .cancel) { renamingFolderID = nil }
        }
    }

    @ViewBuilder
    private func presetRow(_ id: String, folderID: String?) -> some View {
        if let preset = try? model.streamPreset(id) {
            let board = model.streamBoard
            Button { open(id) } label: {
                HStack(spacing: 10) {
                    Image(systemName: preset.isRecordOnly ? "record.circle" : "dot.radiowaves.left.and.right")
                        .foregroundStyle(.secondary)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(preset.name).font(.system(size: 13))
                        Text(caption(preset))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Menu {
                        Menu("Move to") {
                            Button("Top level") { model.updateStreamBoard { $0.moveItem(id: id, beforeNode: nil) } }
                                .disabled(folderID == nil)
                            ForEach(board.orderedFolders, id: \.id) { folder in
                                Button(folder.name) { model.updateStreamBoard { $0.moveItem(id: id, intoFolder: folder.id) } }
                                    .disabled(folder.id == folderID)
                            }
                        }
                        Button("Duplicate") {
                            if let entry = model.entry(id) { model.duplicate(entry) }
                        }
                        Divider()
                        Button("Delete Preset", role: .destructive) { model.deleteStreamPreset(id) }
                    } label: {
                        Image(systemName: "ellipsis.circle").foregroundStyle(.secondary)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    Chevron()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private func caption(_ preset: StreamRecordPreset) -> String {
        if preset.isRecordOnly { return "Record only" }
        let names = (preset.destinationIds ?? []).compactMap { id in
            model.resolvedStreamDestination(id).map(StreamDestinationLibrary.displayName)
        }
        return names.isEmpty ? "No destinations selected" : names.joined(separator: ", ")
    }
}

private struct PresetDetail: View {
    let model: AppModel
    let controls: ServiceControls
    let id: String
    let back: () -> Void

    @State private var showingQuality = false
    @State private var checkingSync = false
    @State private var pickingMedia = false
    @State private var confirmDelete = false

    var body: some View {
        if let preset = try? model.streamPreset(id) {
            let sourceKind = preset.sourceKind ?? .screen
            Form {
                Section("Preset") {
                    TextField("Name", text: Binding(
                        get: { preset.name },
                        set: { v in model.updateStreamPreset(id) { $0.name = v } }))

                    Picker("Type", selection: Binding(
                        get: { preset.resolvedKind },
                        set: { kind in model.updateStreamPreset(id) { $0.presetKind = kind } })
                    ) {
                        Text("Stream & Record").tag(StreamPresetKind.stream)
                        Text("Record Only").tag(StreamPresetKind.recordOnly)
                    }
                    .pickerStyle(.segmented)
                }

                if !preset.isRecordOnly {
                    Section {
                        let rows = checklistRows()
                        if rows.isEmpty {
                            Text("No destinations yet — add an endpoint in Destinations.")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(rows) { row in
                            Toggle(isOn: checkedBinding(row.id)) {
                                HStack(spacing: 8) {
                                    TransportMark(transport: row.transport, size: 16)
                                    Text(row.name)
                                    Text(row.detail).foregroundStyle(.secondary)
                                }
                            }
                        }
                    } header: {
                        Text("Stream to")
                    } footer: {
                        if (preset.destinationIds ?? []).isEmpty {
                            Text("Nothing selected — this preset won't go live.").foregroundStyle(.orange)
                        }
                    }
                }

                Section("Source") {

                    let mediaFolders = model.folders(in: .media)
                    LabeledContent("Video Source") {
                        Menu {
                            Menu("Screen") {
                                Button("Automatic (first screen)") {
                                    model.updateStreamPreset(id) { $0.sourceKind = nil; $0.canvasScreenId = nil }
                                }
                                ForEach(PreviewTargets.screens(controls.render), id: \.id) { screen in
                                    Button(screen.name) {
                                        model.updateStreamPreset(id) { $0.sourceKind = nil; $0.canvasScreenId = screen.id }
                                    }
                                }
                            }
                            Menu("Media file") {
                                Button("Choose\u{2026}") {
                                    model.updateStreamPreset(id) { $0.sourceKind = .mediaItem }
                                    pickingMedia = true
                                }
                            }
                            Menu("Latest recording in") {
                                Button("\(RecordingLibrary.defaultFolder) (default)") {
                                    model.updateStreamPreset(id) { $0.sourceKind = .latestRecording; $0.sourceFolder = nil }
                                }
                                if !mediaFolders.isEmpty {
                                    Divider()
                                    FolderScopeMenuItems(
                                        nodes: FolderTreeLogic.tree(paths: mediaFolders),
                                        isActive: { preset.sourceFolder == $0 },
                                        select: { folder in
                                            model.updateStreamPreset(id) { $0.sourceKind = .latestRecording; $0.sourceFolder = folder }
                                        })
                                }
                            }
                        } label: {
                            Text(videoSourceTitle(preset))
                        }
                        .fixedSize()
                    }
                    if sourceKind == .latestRecording {
                        Picker("Newer than", selection: Binding(
                            get: { preset.sourceMaxAgeHours ?? 0 },
                            set: { v in model.updateStreamPreset(id) { $0.sourceMaxAgeHours = v == 0 ? nil : v } })
                        ) {
                            Text("Any age").tag(0)
                            ForEach([6, 12, 24, 48, 168], id: \.self) { Text(Self.maxAgeLabel($0)).tag($0) }
                        }
                    }
                    if sourceKind == .screen {
                        LabeledContent("Audio Source") {
                            Menu {
                                AudioSourceMenuItems { source in
                                    model.updateStreamPreset(id) {
                                        source.apply(to: &$0, includingProgram: $0.audioIncludesProgram == true)
                                    }
                                }
                            } label: {
                                Text(AudioSourceMenuItems.title(preset))
                            }
                            .fixedSize()
                        }
                        if preset.audioMixId != nil || preset.audioInputId != nil || preset.audioInputUid != nil {
                            Toggle("Add Program Audio", isOn: Binding(
                                get: { preset.audioIncludesProgram == true },
                                set: { on in model.updateStreamPreset(id) { $0.audioIncludesProgram = on ? true : nil } }))
                        }
                        LabeledContent("Audio delay") {
                            HStack(spacing: 4) {
                                TextField("", value: Binding(
                                    get: { preset.audioDelayMs ?? 0 },
                                    set: { v in model.updateStreamPreset(id) { $0.audioDelayMs = v == 0 ? nil : min(max(v, 0), 2000) } }),
                                    format: .number)
                                    .multilineTextAlignment(.trailing)
                                    .frame(width: 56)
                                Text("ms").foregroundStyle(.secondary)
                                Stepper("", value: Binding(
                                    get: { preset.audioDelayMs ?? 0 },
                                    set: { v in model.updateStreamPreset(id) { $0.audioDelayMs = v == 0 ? nil : v } }),
                                    in: 0...2000, step: 5)
                                    .labelsHidden()
                            }
                        }
                        if sourceKind == .screen {
                            LabeledContent("Picture and sound") {
                                Button("Check Sync\u{2026}") { checkingSync = true }
                            }
                        }
                    }
                }

                Section {
                    LabeledContent("Quality") {
                        Button(qualitySummary(preset)) { showingQuality = true }
                            .popover(isPresented: $showingQuality, arrowEdge: .bottom) {
                                StreamQualityPopover(model: model, presetID: id)
                            }
                    }
                } header: {
                    Text("Encoder")
                }

                if sourceKind == .screen {
                    Section {
                        if !preset.isRecordOnly {
                            Toggle("Record while streaming", isOn: Binding(
                                get: { preset.recordWhileStreaming == true },
                                set: { on in model.updateStreamPreset(id) { $0.recordWhileStreaming = on ? true : nil } }))
                        }
                        Picker("Save to", selection: Binding(
                            get: { preset.recordLibraryFolder ?? "" },
                            set: { v in model.updateStreamPreset(id) { $0.recordLibraryFolder = v.isEmpty ? nil : v } })
                        ) {
                            Text("\(RecordingLibrary.defaultFolder) (default)").tag("")
                            ForEach(model.folders(in: .media), id: \.self) { Text($0).tag($0) }
                        }
                        LabeledContent("Also copy to") {
                            HStack(spacing: 8) {
                                if let folder = preset.recordExportFolder, !folder.isEmpty {
                                    Text((folder as NSString).abbreviatingWithTildeInPath)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                        .frame(maxWidth: 220, alignment: .trailing)
                                    Button("Change\u{2026}") { chooseExportFolder() }
                                    Button("None") { model.updateStreamPreset(id) { $0.recordExportFolder = nil } }
                                } else {
                                    Button("Choose Folder\u{2026}") { chooseExportFolder() }
                                }
                            }
                        }
                    } header: {
                        Text("Recording")
                    } footer: {
                        Text("Recordings land in the media library; a copy can also go to a watched folder like Dropbox.")
                    }
                }

                Section {
                    Button("Delete Preset\u{2026}", role: .destructive) { confirmDelete = true }
                }
            }
            .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(Color.basePlane)
            .sheet(isPresented: $checkingSync) {
                SyncMonitorSheet(model: model, controls: controls, presetID: id)
            }
            .sheet(isPresented: $pickingMedia) {
                LibraryPickerSheet(appModel: model) { entry in
                    model.updateStreamPreset(id) { $0.sourceMediaId = entry.id }
                    pickingMedia = false
                }
            }
            .alert("Delete \u{201C}\(preset.name)\u{201D}?", isPresented: $confirmDelete) {
                Button("Delete", role: .destructive) {
                    model.deleteStreamPreset(id)
                    back()
                }
                Button("Cancel", role: .cancel) {}
            }
        } else {
            ContentUnavailableView("Preset not found", systemImage: "record.circle")
        }
    }

    private struct ChecklistRow: Identifiable {
        var id: String
        var name: String
        var detail: String
        var transport: StreamTransport
    }

    private func checklistRows() -> [ChecklistRow] {
        model.allStreamDestinations.map { record in
            ChecklistRow(
                id: record.id,
                name: StreamDestinationLibrary.displayName(record),
                detail: record.transport.rawValue.uppercased(),
                transport: record.transport)
        }
    }

    private func checkedBinding(_ destinationID: String) -> Binding<Bool> {
        Binding(
            get: { (try? model.streamPreset(id))?.destinationIds?.contains(destinationID) == true },
            set: { on in
                model.updateStreamPreset(id) { preset in
                    var ids = preset.destinationIds ?? []
                    if on { if !ids.contains(destinationID) { ids.append(destinationID) } } else { ids.removeAll { $0 == destinationID } }
                    preset.destinationIds = ids
                }
            })
    }

    private func videoSourceTitle(_ preset: StreamRecordPreset) -> String {
        switch preset.sourceKind ?? .screen {
        case .screen:
            let screen = preset.canvasScreenId.flatMap { sid in
                PreviewTargets.screens(controls.render).first { $0.id == sid }?.name
            } ?? "Automatic"
            return "Screen \u{B7} \(screen)"
        case .mediaItem:
            return "Media file \u{B7} " + (preset.sourceMediaId.flatMap { model.entry($0)?.name } ?? "Choose\u{2026}")
        case .latestRecording:
            return "Latest recording \u{B7} \(preset.sourceFolder ?? RecordingLibrary.defaultFolder)"
        }
    }

    private func qualitySummary(_ preset: StreamRecordPreset) -> String {
        let width = preset.width ?? 1920, height = preset.height ?? 1080
        var parts = ["\(min(width, height))p", "\(preset.frameRate ?? 30) fps"]
        let kbps = preset.videoBitrateKbps ?? 4500
        parts.append(kbps >= 1000 ? String(format: "%.1f Mbps", Double(kbps) / 1000) : "\(kbps) kbps")
        if StreamQualityRung.presetWantsHDR(preset, in: model) { parts.append("HDR") }
        return parts.joined(separator: " \u{B7} ")
    }

    private static func maxAgeLabel(_ hours: Int) -> String {
        switch hours {
        case ..<24: "\(hours) hours"
        case 24: "24 hours"
        default: "\(hours / 24) days"
        }
    }

    private func chooseExportFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Use Folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.updateStreamPreset(id) { $0.recordExportFolder = url.path }
    }
}
