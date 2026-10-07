import AVFoundation
import MediaEngine
import AudioEngine
import NDIKit
import PresenterCore
import SwiftUI

struct SettingsCategoryPane: View {
    let category: SettingsCategory
    let rows: [SettingsRowSpec]
    let model: AppModel?
    let controls: ServiceControls?

    enum Page: Equatable {
        case list
        case videoInput(String)
        case audioInput(String)
        case audioOutput(String)
        case midiDevice(String)
    }

    @State private var page: Page = .list

    var body: some View {
        VStack(spacing: 0) {
            if page != .list {
                SettingsPageHeader(backTitle: category.title, title: pageTitle) { page = .list }
                Divider()
            }
            switch page {
            case .list:
                list
            case .videoInput(let id):
                VideoInputDetail(id: id) { page = .list }
            case .audioInput(let id):
                AudioInputDetail(id: id) { page = .list }
            case .audioOutput(let id):
                AudioOutputDetail(id: id) { page = .list }
            case .midiDevice(let id):
                MIDIDeviceDetail(id: id) { page = .list }
            }
        }
        .background(Color.basePlane)
        .onChange(of: category) { _, _ in page = .list }
    }

    private var pageTitle: String {
        switch page {
        case .list: category.title
        case .videoInput(let id): VideoInputInventory.shared.entries.first { $0.id == id }?.name ?? "Video Input"
        case .audioInput(let id): AudioInputInventory.shared.entries.first { $0.id == id }?.name ?? "Audio Input"
        case .audioOutput(let id): AudioOutputInventory.shared.entries.first { $0.id == id }?.name ?? "Audio Output"
        case .midiDevice(let id): MIDIDeviceInventory.shared.items.first { $0.id == id }?.device.name ?? "MIDI Device"
        }
    }

    @ViewBuilder
    private var list: some View {
        switch category {
        case .avInputs:
            Form {
                VideoInputsSection { page = .videoInput($0) }
                AudioInputsSection { page = .audioInput($0) }
                AudioOutputsSection { page = .audioOutput($0) }
            }
            .settingsForm()
        case .midi:
            Form {
                MIDIDevicesSection { page = .midiDevice($0) }
                Section {
                    ForEach(rows.filter { $0.id == "midi.map" }) { SettingsFormRow(spec: $0) }
                } header: {
                    Text("MIDI Input Map")
                }
            }
            .settingsForm()
        case .groups:
            if let model {
                GroupsForm(model: model)
            }
        case .keyboard:
            if let model {
                KeyboardMapPane(model: model, controls: controls)
            }
        default:

            Form {
                ForEach(Self.sectioned(rows), id: \.first!.id) { run in
                    if let spec = run.first, spec.stacked {
                        Section {
                            spec.control
                        } header: {
                            Text(spec.title)
                        } footer: {
                            if let caption = spec.caption { Text(caption) }
                        }
                    } else {
                        Section {
                            ForEach(run) { SettingsFormRow(spec: $0) }
                        }
                    }
                }
            }
            .settingsForm()
        }
    }
}

extension SettingsCategoryPane {

    static func sectioned(_ rows: [SettingsRowSpec]) -> [[SettingsRowSpec]] {
        var runs: [[SettingsRowSpec]] = []
        for spec in rows {
            if !spec.stacked, let last = runs.last, let head = last.first, !head.stacked {
                runs[runs.count - 1].append(spec)
            } else {
                runs.append([spec])
            }
        }
        return runs
    }
}

extension View {

    func settingsForm() -> some View {
        formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .background(Color.basePlane)
    }
}

struct SettingsPageHeader: View {
    let backTitle: String
    let title: String
    let back: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: back) {
                HStack(spacing: 3) {
                    Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                    Text(backTitle).font(.system(size: 12))
                }
                .foregroundStyle(Color.accentColor)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Text(title).font(.system(size: 13, weight: .semibold))
            Spacer()
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
    }
}

struct SettingsFormRow: View {
    let spec: SettingsRowSpec

    var body: some View {
        LabeledContent {
            spec.control
        } label: {
            Text(spec.title)
            if let caption = spec.caption, !caption.isEmpty {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct GroupsForm: View {
    let model: AppModel
    @State private var addingGroup = false
    @State private var newGroupName = ""
    @State private var confirmingRestore = false

    var body: some View {
        Form {
            Section {
                ForEach(model.groupPalette.groups) { group in
                    GroupFormRow(model: model, group: group)
                }
                Button("Add Group\u{2026}") { newGroupName = ""; addingGroup = true }
            } header: {
                Text("Groups")
            } footer: {
                Text("Song section labels and their colors — pills in the slide grid and arrangements wear these. A section wears its named group's color wherever it appears; \u{201C}Pre-Chorus\u{201D} and \u{201C}PreChorus\u{201D} count as the same name.")
            }
            Section {
                Button("Restore Default Groups\u{2026}") { confirmingRestore = true }
            }
        }
        .settingsForm()
        .alert("Add Group", isPresented: $addingGroup) {
            TextField("Name", text: $newGroupName)
            Button("Add") {
                let trimmed = newGroupName.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { return }
                let group = GroupDefinition(id: UUID().uuidString, name: trimmed, colorHex: "#808080FF")
                model.updateGroupPalette { palette in
                    palette.groups.append(group)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Sections with this name wear its color everywhere. Pick the color on the new row.")
        }
        .confirmationDialog(
            "Replace the group list with the default groups and colors?",
            isPresented: $confirmingRestore, titleVisibility: .visible
        ) {
            Button("Restore Defaults", role: .destructive) {
                model.updateGroupPalette { $0.groups = GroupPalette.defaults.groups }
            }
        }
    }
}

private struct GroupFormRow: View {
    let model: AppModel
    let group: GroupDefinition
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 10) {
            ColorPicker("", selection: colorBinding, supportsOpacity: false)
                .labelsHidden()
            TextField("Name", text: $draft)
                .textFieldStyle(.plain)
                .focused($focused)
                .onSubmit(commit)
                .onChange(of: focused) { _, f in if !f { commit() } }
            Spacer()

            GroupHotKeyChip(model: model, group: group)
                .help("Hot key — this letter jumps the live song to this section in Present")
            Button(role: .destructive) {
                model.updateGroupPalette { $0.groups.removeAll { $0.id == group.id } }
            } label: {
                Image(systemName: "minus.circle").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Remove — sections with this name fall back to their own color, or grey")
        }
        .onAppear { draft = group.name }
        .onChange(of: group.name) { _, name in if !focused { draft = name } }
    }

    private func commit() {
        let trimmed = draft.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != group.name else { draft = group.name; return }
        model.updateGroupPalette { palette in
            if let i = palette.groups.firstIndex(where: { $0.id == group.id }) { palette.groups[i].name = trimmed }
        }
    }

    private var colorBinding: Binding<Color> {
        Binding(
            get: { GroupColor.color(group.colorHex) ?? Color(.sRGB, white: 0.5) },
            set: { color in
                guard let srgb = NSColor(color).usingColorSpace(.sRGB) else { return }
                let hex = String(
                    format: "#%02X%02X%02XFF",
                    Int((srgb.redComponent * 255).rounded()),
                    Int((srgb.greenComponent * 255).rounded()),
                    Int((srgb.blueComponent * 255).rounded()))
                guard hex != group.colorHex else { return }
                model.updateGroupPalette { palette in
                    if let i = palette.groups.firstIndex(where: { $0.id == group.id }) { palette.groups[i].colorHex = hex }
                }
            })
    }
}

private struct VideoInputsSection: View {
    let open: (String) -> Void
    @State private var inventory = VideoInputInventory.shared
    @State private var discoveredNDI: [String] = []
    @State private var ndiRuntimeAvailable = true
    @State private var addingNDI = false
    @State private var ndiName = ""

    var body: some View {
        Section {
            if inventory.entries.isEmpty {
                Text("No video inputs yet.").foregroundStyle(.secondary)
            }
            ForEach(inventory.entries) { entry in
                Button { open(entry.id) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: entry.kind == .ndi ? "network" : "video")
                            .foregroundStyle(.secondary)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(entry.name).font(.system(size: 13))
                            Text(VideoInputWords.device(entry))
                                .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Menu("Add Input\u{2026}") {
                Button("Empty Input — assign a device later") { inventory.create(name: VideoInputWords.newName(inventory)) }
                Section("Cameras") {
                    ForEach(VideoInputWords.discoverableCameras(inventory), id: \.uniqueID) { device in
                        Button(device.localizedName) {
                            inventory.create(name: device.localizedName, kind: .camera, sourceId: device.uniqueID)
                        }
                    }
                }
                Section("NDI Sources") {
                    ForEach(addableNDI, id: \.self) { name in
                        Button(name) { inventory.create(name: name, kind: .ndi, sourceId: name) }
                    }
                    if !ndiRuntimeAvailable {
                        Text("NDI unavailable — runtime missing from this build")
                    } else if addableNDI.isEmpty {
                        Text("Searching the network\u{2026}")
                    }
                }
                Divider()
                Button("NDI Source by Name\u{2026}") { addingNDI = true }
            }
            .fixedSize()
        } header: {
            Text("Video Inputs")
        }
        .task {
            while !Task.isCancelled {
                let names = await Task.detached(priority: .utility) { () -> [String]? in
                    guard let library = try? NDILibrary.load(), let finder = NDIFinder(library: library) else { return nil }
                    return finder.currentSourceNames(wait: 1500)
                }.value
                ndiRuntimeAvailable = names != nil
                discoveredNDI = names ?? []
                try? await Task.sleep(for: .seconds(4))
            }
        }
        .alert("NDI Source by Name", isPresented: $addingNDI) {
            TextField("Source name (or part of it)", text: $ndiName)
            Button("Add") {
                let trimmed = ndiName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { inventory.create(name: trimmed, kind: .ndi, sourceId: trimmed) }
                ndiName = ""
            }
            Button("Cancel", role: .cancel) { ndiName = "" }
        } message: {
            Text("The input connects to the first NDI source whose name contains this text — and keeps watching for it, so boot order never matters.")
        }
    }

    private var addableNDI: [String] {
        let fragments = inventory.entries.filter { $0.kind == .ndi }.compactMap(\.sourceId)
        return discoveredNDI.filter { name in !fragments.contains { name.localizedCaseInsensitiveContains($0) } }
    }
}

@MainActor
private enum VideoInputWords {
    static func device(_ entry: VideoInputInventory.Entry) -> String {
        guard let sourceId = entry.sourceId, !sourceId.isEmpty, let kind = entry.kind else { return "No device" }
        if kind == .ndi { return "NDI \u{B7} \(sourceId)" }
        return AVCaptureDevice(uniqueID: sourceId)?.localizedName ?? "Missing camera"
    }

    static func newName(_ inventory: VideoInputInventory) -> String {
        let existing = Set(inventory.entries.map(\.name))
        var number = inventory.entries.count + 1
        while existing.contains("Input \(number)") { number += 1 }
        return "Input \(number)"
    }

    static var allCameras: [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video, position: .unspecified
        ).devices.filter { !$0.localizedName.localizedCaseInsensitiveContains("NDI Virtual") }
    }

    static func discoverableCameras(_ inventory: VideoInputInventory) -> [AVCaptureDevice] {
        let assigned = Set(inventory.entries.filter { $0.kind == .camera }.compactMap(\.sourceId))
        return allCameras.filter { !assigned.contains($0.uniqueID) }
    }
}

private struct VideoInputDetail: View {
    let id: String
    let back: () -> Void
    @State private var inventory = VideoInputInventory.shared
    @State private var audioInventory = AudioInputInventory.shared
    @State private var discoveredNDI: [String] = []
    @State private var addingNDI = false
    @State private var ndiName = ""
    @State private var confirmRemove = false

    @State private var frameRates: [Double] = []

    var body: some View {
        if let entry = inventory.entries.first(where: { $0.id == id }) {
            Form {
                Section("Input") {
                    TextField("Name", text: Binding(get: { entry.name }, set: { inventory.rename(id: id, to: $0) }))
                    Picker("Device", selection: Binding(
                        get: { deviceTag(entry) },
                        set: { tag in
                            if tag == "" { inventory.assignDevice(id: id, kind: nil, sourceId: nil) }
                            else if tag.hasPrefix("ndi:") { inventory.assignDevice(id: id, kind: .ndi, sourceId: String(tag.dropFirst(4))) }
                            else if tag == "ndi-by-name" { addingNDI = true }
                            else { inventory.assignDevice(id: id, kind: .camera, sourceId: tag) }
                        })
                    ) {
                        Text("No device").tag("")
                        Section("Cameras") {
                            ForEach(VideoInputWords.allCameras, id: \.uniqueID) { Text($0.localizedName).tag($0.uniqueID) }
                        }
                        Section("NDI Sources") {
                            ForEach(discoveredNDI, id: \.self) { Text($0).tag("ndi:\($0)") }
                            if let sourceId = entry.sourceId, entry.kind == .ndi, !discoveredNDI.contains(sourceId) {
                                Text("NDI \u{B7} \(sourceId) (not on the network)").tag("ndi:\(sourceId)")
                            }
                            Text("NDI Source by Name\u{2026}").tag("ndi-by-name")
                        }
                    }
                    Picker("Audio input", selection: Binding(
                        get: { entry.audioInputId ?? "" },
                        set: { inventory.assignAudioInput(id: id, audioInputId: $0.isEmpty ? nil : $0) })
                    ) {
                        Text("None").tag("")
                        ForEach(audioInventory.entries) { Text($0.name).tag($0.id) }
                    }
                    if entry.kind == .camera, !frameRates.isEmpty {
                        Picker("Frame rate", selection: Binding(
                            get: { entry.frameRate ?? 0 },
                            set: { inventory.setFrameRate(id: id, rate: $0 == 0 ? nil : $0) })
                        ) {
                            Text("Auto").tag(0.0)
                            ForEach(frameRates, id: \.self) {
                                Text(String(format: "%g fps", $0)).tag($0)
                            }
                            if let rate = entry.frameRate, !frameRates.contains(rate) {
                                Text(String(format: "%g fps (not offered)", rate)).tag(rate)
                            }
                        }
                    }
                    LabeledContent("Video delay") {
                        HStack(spacing: 4) {
                            TextField("", value: Binding(
                                get: { entry.delayFrames ?? 0 },
                                set: { inventory.setDelay(id: id, frames: min(max($0, 0), LiveInputDelay.maxFrames)) }),
                                format: .number)
                                .multilineTextAlignment(.trailing).frame(width: 48)
                            Text("frames").foregroundStyle(.secondary)
                            Stepper("", value: Binding(
                                get: { entry.delayFrames ?? 0 },
                                set: { inventory.setDelay(id: id, frames: $0) }),
                                in: 0...LiveInputDelay.maxFrames).labelsHidden()
                        }
                    }
                }
                Section {
                    Button("Remove Input\u{2026}", role: .destructive) { confirmRemove = true }
                } footer: {
                    Text("Removing stops its capture; slides using it render empty. The audio input rides with it in the Mixer while live; video delay holds the picture back to match late audio. Frame rate is the capture device's mode, from the rates the device offers: Auto takes 30; pick the one nearest your source when it runs faster (60 for a 59.94 camera). Inputs on the same device share it.")
                }
            }
            .settingsForm()
            .task(id: entry.kind == .camera ? entry.sourceId : nil) {
                let sourceId = entry.kind == .camera ? entry.sourceId : nil
                frameRates = await Task.detached(priority: .utility) {
                    sourceId.flatMap { AVCaptureDevice(uniqueID: $0) }
                        .map { MediaEngine.captureFrameRates(for: $0) } ?? []
                }.value
            }
            .task {
                while !Task.isCancelled {
                    let names = await Task.detached(priority: .utility) { () -> [String]? in
                        guard let library = try? NDILibrary.load(), let finder = NDIFinder(library: library) else { return nil }
                        return finder.currentSourceNames(wait: 1500)
                    }.value
                    discoveredNDI = names ?? []
                    try? await Task.sleep(for: .seconds(4))
                }
            }
            .alert("NDI Source by Name", isPresented: $addingNDI) {
                TextField("Source name (or part of it)", text: $ndiName)
                Button("Assign") {
                    let trimmed = ndiName.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { inventory.assignDevice(id: id, kind: .ndi, sourceId: trimmed) }
                    ndiName = ""
                }
                Button("Cancel", role: .cancel) { ndiName = "" }
            }
            .alert("Remove \u{201C}\(entry.name)\u{201D}?", isPresented: $confirmRemove) {
                Button("Remove", role: .destructive) { inventory.remove(entry); back() }
                Button("Cancel", role: .cancel) {}
            }
        } else {
            ContentUnavailableView("Input not found", systemImage: "video")
        }
    }

    private func deviceTag(_ entry: VideoInputInventory.Entry) -> String {
        guard let sourceId = entry.sourceId, !sourceId.isEmpty, let kind = entry.kind else { return "" }
        return kind == .ndi ? "ndi:\(sourceId)" : sourceId
    }
}

private struct AudioInputsSection: View {
    let open: (String) -> Void
    @State private var inventory = AudioInputInventory.shared
    @State private var devices: [AudioDeviceList.AudioInputDevice] = []
    @State private var channelPickerDevice: AudioDeviceList.AudioInputDevice?

    var body: some View {
        Section {
            if inventory.entries.isEmpty {
                Text("No audio inputs yet.").foregroundStyle(.secondary)
            }
            ForEach(inventory.entries) { entry in
                Button { open(entry.id) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "mic").foregroundStyle(.secondary).frame(width: 18)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(entry.name).font(.system(size: 13))
                            Text(AudioInputWords.subtitle(entry, devices: devices))
                                .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        if entry.isAssigned, AudioDeviceList.inputDevice(uid: entry.uid ?? "") == nil {
                            Text("Not connected").font(.system(size: 11)).foregroundStyle(.orange)
                        }
                        Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Menu("Add Input\u{2026}") {
                Button("Empty Input — assign a device later") { inventory.create(name: AudioInputWords.newName(inventory)) }
                ForEach(devices, id: \.uid) { device in
                    if device.channelCount > 2 {
                        Button("\(AudioInputWords.deviceLabel(device)) — pick channels\u{2026}") { channelPickerDevice = device }
                    } else {
                        Button(AudioInputWords.deviceLabel(device)) { inventory.create(name: device.name, uid: device.uid) }
                    }
                }
                if devices.isEmpty { Text("No input devices") }
            }
            .fixedSize()
        } header: {
            Text("Audio Inputs")
        }
        .sheet(item: $channelPickerDevice) { AudioChannelPickerSheet(device: $0) }
        .task {
            while !Task.isCancelled {
                devices = AudioDeviceList.inputDevices()
                try? await Task.sleep(for: .seconds(4))
            }
        }
    }
}

@MainActor
private enum AudioInputWords {
    static func subtitle(_ entry: AudioInputInventory.Entry, devices: [AudioDeviceList.AudioInputDevice]) -> String {
        guard let uid = entry.uid, !uid.isEmpty else { return "No device" }
        guard let device = AudioDeviceList.inputDevice(uid: uid) else { return "Missing device" }
        var parts = [device.name]
        if device.channelCount > 1 { parts.append(channels(entry)) }
        if let ms = entry.delayMs, ms > 0 { parts.append("\(ms) ms delay") }
        return parts.joined(separator: " \u{B7} ")
    }

    static func channels(_ entry: AudioInputInventory.Entry) -> String {
        let numbers = switch entry.channels {
        case .stereoPair(let offset): "Stereo \(offset + 1)-\(offset + 2)"
        case .mono(let channel): "Mono \(channel + 1)"
        }
        return numbers + AudioChannelNameStore.shared.suffix(uid: entry.uid, selection: entry.channels)
    }

    static func newName(_ inventory: AudioInputInventory) -> String {
        let existing = Set(inventory.entries.map(\.name))
        var number = inventory.entries.count + 1
        while existing.contains("Audio Input \(number)") { number += 1 }
        return "Audio Input \(number)"
    }

    static func deviceLabel(_ device: AudioDeviceList.AudioInputDevice) -> String {
        device.channelCount > 2 ? "\(device.name) (\(device.channelCount) ch)" : device.name
    }
}

private struct AudioInputDetail: View {
    let id: String
    let back: () -> Void
    @State private var inventory = AudioInputInventory.shared
    @State private var devices: [AudioDeviceList.AudioInputDevice] = []
    @State private var confirmRemove = false

    var body: some View {
        if let entry = inventory.entries.first(where: { $0.id == id }) {
            let device = AudioDeviceList.inputDevice(uid: entry.uid ?? "")
            Form {
                Section("Input") {
                    TextField("Name", text: Binding(get: { entry.name }, set: { inventory.rename(id: id, to: $0) }))
                    Picker("Device", selection: Binding(
                        get: { entry.uid ?? "" },
                        set: { inventory.assignDevice(id: id, uid: $0.isEmpty ? nil : $0) })
                    ) {
                        Text("No device").tag("")
                        ForEach(devices, id: \.uid) { Text(AudioInputWords.deviceLabel($0)).tag($0.uid) }
                        if let uid = entry.uid, !uid.isEmpty, !devices.contains(where: { $0.uid == uid }) {
                            Text("Missing device (not connected)").tag(uid)
                        }
                    }
                    if let device, device.channelCount > 1 {
                        Picker("Channels", selection: Binding(
                            get: { channelTag(entry) },
                            set: { tag in
                                if tag.hasPrefix("s") { inventory.assignChannels(id: id, channelOffset: Int(tag.dropFirst()) ?? 0, monoChannel: nil) }
                                else { inventory.assignChannels(id: id, channelOffset: nil, monoChannel: Int(tag.dropFirst()) ?? 0) }
                            })
                        ) {
                            let names = AudioChannelNameStore.shared
                            ForEach(Array(stride(from: 0, to: max(2, device.channelCount) - 1, by: 2)), id: \.self) { offset in
                                Text("Stereo \(offset + 1)-\(offset + 2)" + names.suffix(uid: device.uid, selection: .stereoPair(offset: offset))).tag("s\(offset)")
                            }
                            Divider()
                            ForEach(0..<device.channelCount, id: \.self) { channel in
                                Text("Mono \(channel + 1)" + names.suffix(uid: device.uid, selection: .mono(channel: channel))).tag("m\(channel)")
                            }
                        }
                    }
                    LabeledContent("Audio delay") {
                        HStack(spacing: 4) {
                            TextField("", value: Binding(
                                get: { entry.delayMs ?? 0 },
                                set: { inventory.setDelay(id: id, milliseconds: min(max($0, 0), 2000)) }),
                                format: .number)
                                .multilineTextAlignment(.trailing).frame(width: 56)
                            Text("ms").foregroundStyle(.secondary)
                            Stepper("", value: Binding(
                                get: { entry.delayMs ?? 0 },
                                set: { inventory.setDelay(id: id, milliseconds: $0) }),
                                in: 0...2000, step: 5).labelsHidden()
                        }
                    }
                }
                Section {
                    Button("Remove Input\u{2026}", role: .destructive) { confirmRemove = true }
                } footer: {
                    Text("Removing it makes presets that used it fall back to Program Audio. Delay holds this input's audio back everywhere it feeds — playout, mixes, streams.")
                }
            }
            .settingsForm()
            .task {
                while !Task.isCancelled {
                    devices = AudioDeviceList.inputDevices()
                    try? await Task.sleep(for: .seconds(4))
                }
            }
            .alert("Remove \u{201C}\(entry.name)\u{201D}?", isPresented: $confirmRemove) {
                Button("Remove", role: .destructive) { inventory.remove(entry); back() }
                Button("Cancel", role: .cancel) {}
            }
        } else {
            ContentUnavailableView("Input not found", systemImage: "mic")
        }
    }

    private func channelTag(_ entry: AudioInputInventory.Entry) -> String {
        switch entry.channels {
        case .stereoPair(let offset): "s\(offset)"
        case .mono(let channel): "m\(channel)"
        }
    }
}

private struct AudioOutputsSection: View {
    let open: (String) -> Void
    @State private var inventory = AudioOutputInventory.shared
    @State private var devices: [AudioOutputDevice] = []

    var body: some View {
        Section {
            if inventory.entries.isEmpty {
                Text("No audio outputs yet.").foregroundStyle(.secondary)
            }
            ForEach(inventory.entries) { entry in
                Button { open(entry.id) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "speaker.wave.2").foregroundStyle(.secondary).frame(width: 18)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(entry.name).font(.system(size: 13))
                            Text(AudioOutputWords.subtitle(entry, devices: devices))
                                .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Menu("Add Output\u{2026}") {
                Button("Empty Output — assign a device later") { _ = inventory.create() }
                ForEach(devices, id: \.uid) { device in
                    Button(device.name) {
                        let entry = inventory.create(name: device.name)
                        inventory.assignDevice(id: entry.id, deviceUID: device.uid, channelOffset: 0)
                    }
                }
            }
            .fixedSize()
        } header: {
            Text("Audio Outputs")
        }
        .task {
            while !Task.isCancelled {
                devices = AudioDeviceList.outputDevices()
                try? await Task.sleep(for: .seconds(4))
            }
        }
    }
}

@MainActor
private enum AudioOutputWords {
    static func subtitle(_ entry: AudioOutputInventory.Entry, devices: [AudioOutputDevice]) -> String {
        var parts: [String] = []
        if entry.isDeviceless { parts.append("No device") }
        else if let uid = entry.deviceUID {
            if let device = devices.first(where: { $0.uid == uid }) {
                parts.append(device.channelCount > 2 ? "\(device.name) \(entry.channelOffset + 1)-\(entry.channelOffset + 2)" : device.name)
            } else { parts.append("Missing device") }
        } else { parts.append("System default") }
        if let ms = entry.delayMs, ms > 0 { parts.append("\(ms) ms delay") }
        return parts.joined(separator: " \u{B7} ")
    }
}

private struct AudioOutputDetail: View {
    let id: String
    let back: () -> Void
    @State private var inventory = AudioOutputInventory.shared
    @State private var devices: [AudioOutputDevice] = []
    @State private var confirmRemove = false

    var body: some View {
        if let entry = inventory.entries.first(where: { $0.id == id }) {
            let device = entry.deviceUID.flatMap { uid in devices.first { $0.uid == uid } }
            Form {
                Section("Output") {
                    TextField("Name", text: Binding(get: { entry.name }, set: { inventory.rename(id: id, to: $0) }))
                    Picker("Device", selection: Binding(
                        get: { entry.isDeviceless ? "none" : (entry.deviceUID ?? "") },
                        set: { tag in
                            if tag == "" { inventory.assignDevice(id: id, deviceUID: nil, channelOffset: 0) }
                            else if tag == "none" { inventory.assignDevice(id: id, deviceUID: AudioOutputInventory.noDeviceUID, channelOffset: 0) }
                            else { inventory.assignDevice(id: id, deviceUID: tag, channelOffset: 0) }
                        })
                    ) {
                        Text("System default").tag("")
                        Text("No device").tag("none")
                        ForEach(devices, id: \.uid) { Text($0.name).tag($0.uid) }
                        if let uid = entry.deviceUID, !entry.isDeviceless, !devices.contains(where: { $0.uid == uid }) {
                            Text("Missing device (not connected)").tag(uid)
                        }
                    }
                    if let device, device.channelCount > 2 {
                        Picker("Channels", selection: Binding(
                            get: { entry.channelOffset },
                            set: { inventory.assignDevice(id: id, deviceUID: device.uid, channelOffset: $0) })
                        ) {
                            ForEach(Array(stride(from: 0, to: device.channelCount - 1, by: 2)), id: \.self) { offset in
                                Text("\(offset + 1)-\(offset + 2)").tag(offset)
                            }
                        }
                    }
                    LabeledContent("Playout delay") {
                        HStack(spacing: 4) {
                            TextField("", value: Binding(
                                get: { entry.delayMs ?? 0 },
                                set: { inventory.setDelay(id: id, milliseconds: min(max($0, 0), 2000)) }),
                                format: .number)
                                .multilineTextAlignment(.trailing).frame(width: 56)
                            Text("ms").foregroundStyle(.secondary)
                            Stepper("", value: Binding(
                                get: { entry.delayMs ?? 0 },
                                set: { inventory.setDelay(id: id, milliseconds: $0) }),
                                in: 0...2000, step: 5).labelsHidden()
                        }
                    }
                }
                Section {
                    Button("Remove Output\u{2026}", role: .destructive) { confirmRemove = true }
                } footer: {
                    Text("Mixes sending here drop the send. Delay holds this output's playout back to match slower rooms or devices.")
                }
            }
            .settingsForm()
            .task {
                while !Task.isCancelled {
                    devices = AudioDeviceList.outputDevices()
                    try? await Task.sleep(for: .seconds(4))
                }
            }
            .alert("Remove \u{201C}\(entry.name)\u{201D}?", isPresented: $confirmRemove) {
                Button("Remove", role: .destructive) { inventory.remove(entry); back() }
                Button("Cancel", role: .cancel) {}
            }
        } else {
            ContentUnavailableView("Output not found", systemImage: "speaker.wave.2")
        }
    }
}

private struct MIDIDevicesSection: View {
    let open: (String) -> Void
    @State private var inventory = MIDIDeviceInventory.shared

    var body: some View {
        Section {
            if inventory.items.isEmpty {
                Text("No devices added — MIDI Out reaches every destination on this Mac.").foregroundStyle(.secondary)
            }
            ForEach(inventory.items) { item in
                Button { open(item.id) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "pianokeys").foregroundStyle(.secondary).frame(width: 18)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.device.name).font(.system(size: 13))
                                .foregroundStyle(item.isEnabled ? .primary : .secondary)
                            Text(item.effectiveDirection.displayName + (item.isEnabled ? "" : " \u{B7} Off"))
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if !item.isConnected(
                            destinations: Set(inventory.discoveredDestinations.map(\.uid)),
                            sources: Set(inventory.discoveredSources.map(\.uid))) {
                            Text("Not connected").font(.system(size: 11)).foregroundStyle(.orange)
                        }
                        Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Menu("Add Device\u{2026}") {
                ForEach(addableDevices) { device in
                    Button(device.name) { inventory.add(discovered: device) }
                }
                if addableDevices.isEmpty { Text("No other MIDI devices") }
            }
            .fixedSize()
        } header: {
            Text("MIDI Devices")
        }
        .task { inventory.reload() }
    }

    private var addableDevices: [MIDIDeviceEntry] {
        let claimedOut = Set(inventory.items.compactMap(\.destinationUID))
        let claimedIn = Set(inventory.items.compactMap(\.sourceUID))
        return inventory.discoveredDevices.filter {
            !claimedOut.contains($0.uid) && !($0.sourceUid.map(claimedIn.contains) ?? false)
        }
    }
}

private struct MIDIDeviceDetail: View {
    let id: String
    let back: () -> Void
    @State private var inventory = MIDIDeviceInventory.shared
    @State private var confirmRemove = false

    var body: some View {
        if let item = inventory.items.first(where: { $0.id == id }) {
            Form {
                Section("Device") {
                    Toggle("Enabled", isOn: Binding(get: { item.isEnabled }, set: { inventory.setEnabled(item, enabled: $0) }))
                    Picker("Direction", selection: Binding(
                        get: { item.effectiveDirection },
                        set: { inventory.setDirection(item, direction: $0) })
                    ) {
                        ForEach(MIDIDeviceItemDirection.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                }
                Section {
                    if item.wantsOutput {
                        portPicker("Out port", bound: item.destinationUID, endpoints: inventory.discoveredDestinations) {
                            inventory.setDestinationBinding(item, uid: $0)
                        }
                    }
                    if item.wantsInput {
                        portPicker("In port", bound: item.sourceUID, endpoints: inventory.discoveredSources) {
                            inventory.setSourceBinding(item, uid: $0)
                        }
                        Picker("Channel", selection: Binding(
                            get: { item.device.channel ?? 0 },
                            set: { inventory.setChannel(item, channel: $0 == 0 ? nil : $0) })
                        ) {
                            Text("Any channel").tag(0)
                            ForEach(1...16, id: \.self) { Text("Channel \($0)").tag($0) }
                        }
                    }
                } header: {
                    Text("Ports on this Mac")
                } footer: {
                    Text("Automatic matches ports by name, so an imported rig lights up wherever its ports live. Channel filters which incoming notes trigger commands.")
                }
                Section {
                    Button("Remove Device\u{2026}", role: .destructive) { confirmRemove = true }
                }
            }
            .settingsForm()
            .alert("Remove \u{201C}\(item.device.name)\u{201D}?", isPresented: $confirmRemove) {
                Button("Remove", role: .destructive) { inventory.remove(item); back() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The device is a library item — combos and imports referencing it lose their target. With none left, MIDI Out reaches every destination again.")
            }
        } else {
            ContentUnavailableView("Device not found", systemImage: "pianokeys")
        }
    }

    private func portPicker(_ label: String, bound: Int32?, endpoints: [MIDIEndpoint], pin: @escaping (Int32?) -> Void) -> some View {
        Picker(label, selection: Binding(get: { bound ?? 0 }, set: { pin($0 == 0 ? nil : $0) })) {
            Text("Automatic (match by name)").tag(Int32(0))
            ForEach(endpoints, id: \.uid) { Text($0.name).tag($0.uid) }
            if let bound, !endpoints.contains(where: { $0.uid == bound }) {
                Text("Port not present").tag(bound)
            }
        }
    }
}
