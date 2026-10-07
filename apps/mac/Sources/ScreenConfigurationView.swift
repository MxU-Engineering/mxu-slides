import OutputEngine
import PresenterCore
import RenderEngine
import SwiftUI

@MainActor
@Observable
final class ScreenConfigRouter {
    static let shared = ScreenConfigRouter()

    var pendingPresetID: String?
    private init() {}
}

struct ScreenConfigurationView: View {
    let render: RenderContext
    let presets: OutputPresetsController?

    @Environment(\.signage) private var signage
    @State private var renamingChannel: RenamingChannel?
    @State private var channelRenameText = ""

    private struct RenamingChannel: Identifiable {
        let id: String
    }

    private var outputs: OutputManager { render.outputs }

    private enum Selection: Hashable {
        case screen(UUID)
        case display(DisplayUUID)

        case preset(String)

        case signage(String)
    }

    @State private var selection: Selection?

    @State private var presetSelection = ListMultiSelect.State()
    @State private var renamingPresetID: String?
    @State private var presetRenameText = ""

    var body: some View {
        HStack(spacing: CornerStandard.panelInset) {
            listColumn
                .frame(width: 248)
                .floatingPanel()
            detailColumn
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .floatingPanel()
        }
        .padding(CornerStandard.panelInset)
        .background(Color.basePlane)
        .onAppear {
            consumePresetRoute()
            ensureSelection()
        }
        .onChange(of: ScreenConfigRouter.shared.pendingPresetID) { _, pending in
            if pending != nil { consumePresetRoute() }
        }
        .onChange(of: selection) { _, newValue in

            if case .preset = newValue {} else { presetSelection = .init() }
        }
        .onChange(of: outputs.placeholderScreens.map(\.id)) { ensureSelection() }
        .onChange(of: outputs.displays.map(\.uuid)) { ensureSelection() }
        .onChange(of: (signage?.channels ?? []).map(\.id)) { ensureSelection() }
    }

    private func consumePresetRoute() {
        guard let pending = ScreenConfigRouter.shared.pendingPresetID else { return }
        ScreenConfigRouter.shared.pendingPresetID = nil
        if !pending.isEmpty, presets?.presets.contains(where: { $0.id == pending }) == true {
            selection = .preset(pending)
        } else if let first = presets?.presets.first {
            selection = .preset(first.id)
        }
    }

    private func ensureSelection() {
        switch selection {
        case .screen(let id) where outputs.placeholderScreens.contains(where: { $0.id == id }):
            return
        case .display(let uuid) where outputs.displays.contains(where: { $0.uuid == uuid }):
            return
        case .preset(let id) where presets?.preset(id) != nil:
            return
        case .signage(let id) where signage?.channel(id) != nil:
            return
        default:
            selection = outputs.placeholderScreens.first.map { .screen($0.id) }
                ?? outputs.displays.first.map { .display($0.uuid) }
        }
    }

    private var listColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    sectionLabel("Screens")
                    Spacer()
                    addScreenMenu
                }
                .padding(.top, 10)
                if outputs.placeholderScreens.isEmpty {
                    Text("A screen is a routing identity — add one to set up looks and routing before you have the hardware.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 2)
                }
                ForEach(outputs.placeholderScreens) { screen in
                    screenListRow(screen)
                }
                sectionLabel("System Displays — Direct")
                    .padding(.top, 12)
                ForEach(outputs.displays) { display in
                    displayListRow(display)
                }
                if outputs.displays.count == 1 {
                    Text("Single display: Esc or double-click a live output to release it.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 2)
                }
                if let presets {
                    HStack {
                        sectionLabel("Output Presets")
                        Spacer()
                        addPresetMenu(presets)
                    }
                    .padding(.top, 12)
                    if presets.presets.isEmpty {
                        Text("A preset routes layers to audience screens, switched globally from the Live panel. No preset = every layer everywhere.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 2)
                    }
                    ForEach(presets.presets, id: \.id) { entry in
                        presetListRow(entry, presets: presets)
                    }
                }
                if let signage {
                    signageSection(signage)
                }
            }
            .padding(10)

            .alert("Rename Preset", isPresented: Binding(
                get: { renamingPresetID != nil },
                set: { if !$0 { renamingPresetID = nil } }
            )) {
                TextField("Name", text: $presetRenameText)
                Button("Rename") {
                    if let id = renamingPresetID {
                        presets?.renamePreset(id, to: presetRenameText)
                    }
                    renamingPresetID = nil
                }
                Button("Cancel", role: .cancel) { renamingPresetID = nil }
            }
        }
        .scrollContentBackground(.hidden)
        .alert("Rename Signage", isPresented: Binding(
            get: { renamingChannel != nil },
            set: { if !$0 { renamingChannel = nil } }
        )) {
            TextField("Name", text: $channelRenameText)
            Button("Rename") {
                if let target = renamingChannel {
                    signage?.renameChannel(target.id, to: channelRenameText)
                }
                renamingChannel = nil
            }
            Button("Cancel", role: .cancel) { renamingChannel = nil }
        }
    }

    @ViewBuilder
    private func signageSection(_ signage: SignageController) -> some View {
        HStack {
            sectionLabel("Digital Signage")
            Spacer()
            Button {
                signage.addChannel()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("New Digital Signage — a named destination screens can point at (Lobby, Kids Hallway…)")
        }
        .padding(.top, 12)
        if signage.channels.isEmpty {
            Text("A signage is a named loop destination — create Lobby or Café here, give it content from the Signage module, and point any screen at it.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 2)
        }
        ForEach(signage.channels, id: \.id) { channel in
            signageChannelRow(channel, signage: signage)
        }
    }

    private func signageChannelRow(
        _ channel: SignageChannel, signage: SignageController
    ) -> some View {
        let selected = selection == .signage(channel.id)
        return Button {
            selection = .signage(channel.id)
        } label: {
            signageChannelRowLabel(channel, signage: signage)
        }
        .buttonStyle(.plain)
        .background(
            selected ? Color.primary.opacity(0.08) : .clear,
            in: RoundedRectangle.standard(CornerStandard.element)
        )
        .contextMenu {
            Button("Rename…") {
                channelRenameText = channel.name
                renamingChannel = RenamingChannel(id: channel.id)
            }
            Button("Delete", role: .destructive) {
                signage.removeChannel(channel.id)
            }
        }
    }

    private func signageChannelRowLabel(
        _ channel: SignageChannel, signage: SignageController
    ) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle.standard(4)
                .fill(Color.primary.opacity(0.08))
                .overlay {
                    Image(systemName: "play.tv")
                        .font(.system(size: 9))
                        .foregroundStyle(
                            channel.playlistId == nil
                                ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Color.green))
                }
                .overlay(
                    RoundedRectangle.standard(4)
                        .strokeBorder(Color.separator.opacity(0.5), lineWidth: 1)
                )
                .frame(width: 46, height: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(channel.name)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                Text(signageContentCaption(channel, signage: signage))
                    .font(.caption2)
                    .foregroundStyle(channel.playlistId == nil ? .secondary : Color.green)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
        }
        .padding(6)
        .contentShape(RoundedRectangle.standard(CornerStandard.element))
    }

    private func signageContentCaption(
        _ channel: SignageChannel, signage: SignageController
    ) -> String {
        guard channel.playlistId != nil else { return "dark — assign content in the Signage module" }
        let screens = signage.screenNames(showing: channel.id)
        return screens.isEmpty ? "content set — no screens" : "on \(screens.joined(separator: ", "))"
    }

    private func addPresetMenu(_ presets: OutputPresetsController) -> some View {
        Menu {
            Button("New Empty Preset") {
                if let id = presets.createPreset(fromBroadcastTemplate: false) {
                    selection = .preset(id)
                }
            }
            Button("New from “Broadcast Feed” Template") {
                if let id = presets.createPreset(fromBroadcastTemplate: true) {
                    selection = .preset(id)
                }
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("New Output Preset — Broadcast Feed starts from slide + overlays only (keying over a switcher)")
    }

    private func presetListRow(
        _ entry: LibraryIndex.Entry, presets: OutputPresetsController
    ) -> some View {
        let selected = selection == .preset(entry.id)
            || presetSelection.selected.contains(entry.id)
        let active = presets.activePresetID == entry.id
        return Button {
            clickPreset(entry.id, presets: presets)
        } label: {
            HStack(spacing: 8) {
                RoundedRectangle.standard(4)
                    .fill(Color.primary.opacity(0.08))
                    .overlay {
                        Image(systemName: "switch.2")
                            .font(.system(size: 9))
                            .foregroundStyle(active ? AnyShapeStyle(Color.green) : AnyShapeStyle(.tertiary))
                    }
                    .overlay(
                        RoundedRectangle.standard(4)
                            .strokeBorder(
                                active ? Color.green.opacity(0.6) : Color.separator.opacity(0.5),
                                lineWidth: 1
                            )
                    )
                    .frame(width: 46, height: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.name)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                    Text(active ? "active" : "inactive")
                        .font(.caption2)
                        .foregroundStyle(active ? Color.green : .secondary)
                }
                Spacer(minLength: 4)
            }
            .padding(6)
            .contentShape(RoundedRectangle.standard(CornerStandard.element))
        }
        .buttonStyle(.plain)
        .background(
            selected ? Color.primary.opacity(0.08) : .clear,
            in: RoundedRectangle.standard(CornerStandard.element)
        )
        .contextMenu { presetMenu(entry, presets: presets) }
    }

    private func clickPreset(_ id: String, presets: OutputPresetsController) {
        let modifiers = NSEvent.modifierFlags
        let gesture: ListMultiSelect.Gesture =
            modifiers.contains(.command) ? .toggle
            : modifiers.contains(.shift) ? .extend
            : .replace
        presetSelection = ListMultiSelect.click(
            id, gesture: gesture, in: presets.presets.map(\.id), state: presetSelection)
        selection = .preset(id)
    }

    @ViewBuilder
    private func presetMenu(
        _ entry: LibraryIndex.Entry, presets: OutputPresetsController
    ) -> some View {
        let batch = ListMultiSelect.batch(
            clicked: entry.id, selection: presetSelection.selected,
            order: presets.presets.map(\.id))
        if batch.count == 1 {
            Button("Rename…") {
                presetRenameText = entry.name
                renamingPresetID = entry.id
            }
            Button("Duplicate") { duplicatePresets([entry.id], presets: presets) }
            Divider()
            Button("Delete", role: .destructive) {
                deletePresets([entry.id], presets: presets)
            }
        } else {
            Button("Duplicate \(batch.count) Presets") {
                duplicatePresets(batch, presets: presets)
            }
            Divider()
            Button("Delete \(batch.count) Presets", role: .destructive) {
                deletePresets(batch, presets: presets)
            }
        }
    }

    private func duplicatePresets(_ ids: [String], presets: OutputPresetsController) {
        let copies = ids.compactMap { presets.duplicatePreset($0) }
        guard let last = copies.last else { return }
        presetSelection = .init(selected: Set(copies), anchor: last)
        selection = .preset(last)
    }

    private func deletePresets(_ ids: [String], presets: OutputPresetsController) {
        for id in ids { presets.deletePreset(id) }
        presetSelection = .init()
        if case .preset(let current) = selection, ids.contains(current) {
            if let first = presets.presets.first {
                selection = .preset(first.id)
            } else {
                selection = nil
                ensureSelection()
            }
        }
    }

    private var addScreenMenu: some View {
        Menu {
            Button("1080p  (1920×1080)") { addScreen(width: 1920, height: 1080) }
            Button("4K  (3840×2160)") { addScreen(width: 3840, height: 2160) }
            Button("Vertical 9:16  (1080×1920)") { addScreen(width: 1080, height: 1920) }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        } primaryAction: {

            addScreen(width: 1920, height: 1080)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Add a screen — route against it now, back it with hardware at the venue")
    }

    private func addScreen(width: Int, height: Int) {
        outputs.addPlaceholderScreen(
            name: "Screen \(outputs.placeholderScreens.count + 1)",
            width: width, height: height
        )
        if let added = outputs.placeholderScreens.last {
            selection = .screen(added.id)
        }
    }

    private func screenListRow(_ screen: PlaceholderScreen) -> some View {
        let selected = selection == .screen(screen.id)
        let backing = outputs.placeholderDevices[screen.id]
        let connected = backing.map { uuid in outputs.displays.contains { $0.uuid == uuid } }
        let carry = carryStatus(screen)
        return Button {
            selection = .screen(screen.id)
        } label: {
            HStack(spacing: 8) {
                miniPreview(screen, deviceBacked: backing != nil)
                VStack(alignment: .leading, spacing: 1) {
                    Text(screen.name)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)

                    Text(screenStatus(
                        screen, backing: backing, connected: connected, carry: carry))
                        .font(.caption2)
                        .foregroundStyle(
                            connected == true || carry?.live == true
                                ? Color.green
                                : connected == false || carry?.live == false
                                    ? Color.orange : Color.secondary
                        )
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
            }
            .padding(6)
            .contentShape(RoundedRectangle.standard(CornerStandard.element))
        }
        .buttonStyle(.plain)
        .background(
            selected ? Color.primary.opacity(0.08) : .clear,
            in: RoundedRectangle.standard(CornerStandard.element)
        )
    }

    private func screenStatus(
        _ screen: PlaceholderScreen, backing: DisplayUUID?, connected: Bool?,
        carry: (label: String, live: Bool)?
    ) -> String {
        var size = "\(screen.width)×\(screen.height)"
        if outputs.role(forScreen: screen.id) == .confidence { size += " · confidence" }
        guard let backing else {
            if let carry { return "\(size) · \(carry.label)" }
            return "\(size) · placeholder"
        }
        let name = deviceName(backing, for: screen.id)
        return connected == true ? "\(size) · \(name)" : "\(size) · disconnected: \(name)"
    }

    private func carryStatus(_ screen: PlaceholderScreen) -> (label: String, live: Bool)? {
        if let backing = DeckLinkScreenOutputs.shared.backing(for: screen.id) {
            if case .sending = DeckLinkScreenOutputs.shared.status(for: screen.id) {
                return (backing.deviceName, true)
            }
            return (backing.deviceName, false)
        }
        switch NDIScreenOutputs.shared.status(for: screen.id) {
        case .sending(let name): return ("NDI “\(name)”", true)
        case .starting, .interrupted, .failed: return ("NDI", false)
        case .idle, nil: return nil
        }
    }

    @ViewBuilder
    private func miniPreview(_ screen: PlaceholderScreen, deviceBacked: Bool) -> some View {
        let shape = RoundedRectangle.standard(4)
        Group {
            if deviceBacked {

                shape.fill(Color.primary.opacity(0.08))
                    .overlay {
                        Image(systemName: "display")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
            } else {
                PlaceholderScreenPreview(screen: screen, compositor: render.compositor)
            }
        }
        .frame(width: 46, height: 26)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.separator.opacity(0.5), lineWidth: 1))
    }

    private func displayListRow(_ display: DisplaySnapshot) -> some View {
        let selected = selection == .display(display.uuid)
        let live = outputs.isLive(display.uuid)
        return Button {
            selection = .display(display.uuid)
        } label: {
            HStack(spacing: 8) {
                RoundedRectangle.standard(4)
                    .fill(live ? Color.green.opacity(0.18) : Color.primary.opacity(0.08))
                    .overlay {
                        Image(systemName: "display")
                            .font(.system(size: 9))
                            .foregroundStyle(live ? Color.green : Color.secondary.opacity(0.5))
                    }
                    .overlay(
                        RoundedRectangle.standard(4)
                            .strokeBorder(
                                live ? Color.green.opacity(0.6) : Color.separator.opacity(0.5),
                                lineWidth: 1
                            )
                    )
                    .frame(width: 46, height: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(display.name)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                    Text(
                        "\(Int(display.frame.width))×\(Int(display.frame.height)) pt"
                        + (display.isMain ? " · main" : "")
                    )
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                if live {
                    Text("Live")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(Color.green)
                }
            }
            .padding(6)
            .contentShape(RoundedRectangle.standard(CornerStandard.element))
        }
        .buttonStyle(.plain)
        .background(
            selected ? Color.primary.opacity(0.08) : .clear,
            in: RoundedRectangle.standard(CornerStandard.element)
        )
    }

    private var detailColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                switch selection {
                case .screen(let id):
                    if let screen = outputs.placeholderScreens.first(where: { $0.id == id }) {
                        ScreenDetail(outputs: outputs, render: render, screen: screen)
                    }
                case .display(let uuid):
                    if let display = outputs.displays.first(where: { $0.uuid == uuid }) {
                        displayDetail(display)
                    }
                case .preset(let id):
                    if let presets, presets.preset(id) != nil {
                        PresetDetail(outputs: outputs, presets: presets, render: render, presetID: id)
                    }
                case .signage(let id):
                    if let signage, let channel = signage.channel(id) {
                        SignageDetail(signage: signage, channel: channel)
                    }
                case nil:
                    ContentUnavailableView(
                        "No Screens", systemImage: "display",
                        description: Text("Add a screen or connect a display.")
                    )
                }
                DiagnosticsDisclosure(outputs: outputs)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollContentBackground(.hidden)
    }

    @ViewBuilder
    private func displayDetail(_ display: DisplaySnapshot) -> some View {
        let live = outputs.isLive(display.uuid)
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(display.name)
                    .font(.headline)
                Spacer()
                Toggle("Live", isOn: Binding(
                    get: { outputs.isLive(display.uuid) },
                    set: { outputs.setLive(display.uuid, $0) }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
                .help(live ? "Take \(display.name) offline" : "Send output to \(display.name)")
            }
            Text(
                "\(Int(display.frame.width))×\(Int(display.frame.height)) pt"
                + " · \(display.maximumFramesPerSecond) Hz"
                + (display.isMain ? " · main display" : "")
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            Text("Direct output: the display carries the full composited scene. To route layers or persist intent across unplugs, back a Screen with it instead.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func deviceName(_ uuid: DisplayUUID, for screenID: UUID) -> String {
        outputs.displays.first { $0.uuid == uuid }?.name
            ?? outputs.placeholderDeviceNames[screenID]
            ?? "Display"
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .tracking(0.6)
    }
}

private struct ScreenDetail: View {
    let outputs: OutputManager
    let render: RenderContext
    let screen: PlaceholderScreen

    @State private var name = ""
    @State private var widthText = ""
    @State private var heightText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            identityBar

            if let backing = DeckLinkScreenOutputs.shared.backing(for: screen.id),
                let mode = backing.mode {
                Text("Sent to \(backing.deviceName) as \(mode.name) — set under Format below")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            OutputsSection(render: render, outputs: outputs, screen: screen)
            OutputMaskEditor(outputs: outputs, render: render, screen: screen)
            HStack {
                Spacer()
                Button("Remove Screen", role: .destructive) {
                    outputs.removePlaceholderScreen(id: screen.id)
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .help("Remove this screen — its routing goes with it")
            }
        }

        .onAppear { outputs.setCanvasWake(true, forScreen: screen.id) }
        .onDisappear { outputs.setCanvasWake(false, forScreen: screen.id) }

        .task(id: "\(screen.id)|\(screen.name)|\(screen.width)|\(screen.height)") {
            name = screen.name
            widthText = "\(screen.width)"
            heightText = "\(screen.height)"
        }
    }

    private var identityBar: some View {
        HStack(spacing: 10) {
            TextField("Name", text: $name)
                .textFieldStyle(.plain)
                .font(.title3.weight(.semibold))
                .onSubmit(commit)
                .frame(maxWidth: 240)
                .help("The screen's name — presets and services route by it")
            TextField("W", text: $widthText)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .frame(width: 56)
                .multilineTextAlignment(.trailing)
                .font(.callout.monospacedDigit())
                .onSubmit(commit)
            Text("×").foregroundStyle(.tertiary)
            TextField("H", text: $heightText)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .frame(width: 56)
                .multilineTextAlignment(.trailing)
                .font(.callout.monospacedDigit())
                .onSubmit(commit)
            Menu {
                ForEach([24, 25, 30, 50, 60], id: \.self) { rate in
                    Toggle("\(rate) fps", isOn: Binding(
                        get: { screen.framesPerSecond == rate },
                        set: { _ in setFrameRate(rate) }
                    ))
                }
            } label: {
                Text("\(screen.framesPerSecond) fps")
                    .font(.callout)
            }
            .menuStyle(.button)
            .buttonStyle(.bordered)
            .controlSize(.small)
            .fixedSize()
            .help("Render cadence — match the venue or stream rate")
            Spacer()
            Picker("", selection: Binding(
                get: { outputs.role(forScreen: screen.id) },
                set: { outputs.setRole($0, forScreen: screen.id) }
            )) {
                Text("Audience").tag(ScreenRole.audience)
                Text("Confidence").tag(ScreenRole.confidence)
            }
            .pickerStyle(.segmented)
            .controlSize(.small)
            .fixedSize()
            .help("Audience carries the program scene through preset routing; Confidence carries the stage layout — current/next, clock, timers, alerts")
            Button("Identify") { identify() }
                .controlSize(.small)
                .help("Flash the alignment grid on this screen's outputs for a moment — which glass/wire is this?")
            Toggle("Sync Test", isOn: Binding(
                get: { outputs.syncTestScreens.contains(screen.id) },
                set: { outputs.setSyncTest($0, forScreen: screen.id) }
            ))
            .toggleStyle(.checkbox)
            .controlSize(.small)
            .help("Play the metronome sync pattern on this screen — a click and a flash every beat, the circle filling each bar — and check its picture against its sound wherever the two end up: the room, a stream, a send")
        }
    }

    private func identify() {
        let wasOn = outputs.testPatternScreens.contains(screen.id)
        outputs.setTestPattern(true, forScreen: screen.id)
        let screenID = screen.id
        Task { @MainActor [outputs] in
            try? await Task.sleep(for: .seconds(2.5))
            if !wasOn { outputs.setTestPattern(false, forScreen: screenID) }
        }
    }

    private func setFrameRate(_ rate: Int) {
        guard rate != screen.framesPerSecond else { return }
        outputs.reconfigurePlaceholderScreen(
            id: screen.id, name: screen.name, width: screen.width,
            height: screen.height, framesPerSecond: rate
        )
    }

    private func commit() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard let width = Int(widthText), let height = Int(heightText),
              width > 0, height > 0, !trimmed.isEmpty
        else {

            name = screen.name
            widthText = "\(screen.width)"
            heightText = "\(screen.height)"
            return
        }
        guard trimmed != screen.name || width != screen.width || height != screen.height
        else { return }
        outputs.reconfigurePlaceholderScreen(
            id: screen.id, name: trimmed, width: width, height: height,
            framesPerSecond: screen.framesPerSecond
        )
    }
}

struct OutputSourcePicker: View {
    let render: RenderContext
    let outputs: OutputManager
    let screen: PlaceholderScreen

    var sliceID: UUID

    init(render: RenderContext, outputs: OutputManager, screen: PlaceholderScreen,
         sliceID: UUID? = nil) {
        self.render = render
        self.outputs = outputs
        self.screen = screen
        self.sliceID = sliceID ?? screen.id
    }

    private var backing: DisplayUUID? { outputs.placeholderDevices[sliceID] }
    private var ndiCarrying: Bool { NDIScreenOutputs.shared.isCarrying(sliceID) }
    private var deckLinkBacking: DeckLinkScreenOutputs.Backing? {
        DeckLinkScreenOutputs.shared.backing(for: sliceID)
    }

    private static let columns = [GridItem(.adaptive(minimum: 108), spacing: 8)]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("OUTPUT")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .tracking(0.6)
            LazyVGrid(columns: Self.columns, alignment: .leading, spacing: 8) {
                sourceCard(
                    title: "Placeholder",
                    caption: "No output yet",
                    selected: backing == nil && !ndiCarrying && deckLinkBacking == nil,
                    disabled: false,
                    tile: { placeholderTile }
                ) {
                    NDIScreenOutputs.shared.disable(screenID: sliceID)
                    DeckLinkScreenOutputs.shared.disable(screenID: sliceID, render: render)
                    assign(nil)
                }
                ForEach(outputs.displays) { display in
                    let heldByOther = outputs.placeholderDevices
                        .contains { $0.value == display.uuid && $0.key != sliceID }
                    sourceCard(
                        title: display.name,
                        caption: "\(Int(display.frame.width))×\(Int(display.frame.height)) pt",
                        selected: backing == display.uuid,
                        disabled: false,
                        tile: { displayTile(display) }
                    ) {

                        NDIScreenOutputs.shared.disable(screenID: sliceID)
                        DeckLinkScreenOutputs.shared.disable(screenID: sliceID, render: render)
                        assign(display.uuid)
                    }

                    .contextMenu {
                        if heldByOther {
                            Button("Add Alongside — pack into this frame") {
                                NDIScreenOutputs.shared.disable(screenID: sliceID)
                                DeckLinkScreenOutputs.shared.disable(
                                    screenID: sliceID, render: render)
                                outputs.assignPlaceholderDevice(
                                    placeholderID: sliceID, displayUUID: display.uuid,
                                    displayName: display.name, exclusive: false
                                )
                            }
                        }
                    }
                }
                if let backing, !outputs.displays.contains(where: { $0.uuid == backing }) {

                    sourceCard(
                        title: "Disconnected",
                        caption: outputs.placeholderDeviceNames[sliceID] ?? "Display",
                        selected: true,
                        disabled: false,
                        tile: { disconnectedTile }
                    ) {}
                }
                sourceCard(
                    title: "NDI",
                    caption: ndiCaption,
                    selected: ndiCarrying,
                    disabled: false,
                    tile: { networkTile("dot.radiowaves.left.and.right") }
                ) {
                    if ndiCarrying {
                        NDIScreenOutputs.shared.disable(screenID: sliceID)
                    } else {
                        NDIScreenOutputs.shared.enable(screenID: sliceID, render: render)
                    }
                }

                ForEach(DeckLinkDeviceCatalog.shared.devices) { device in
                    let carriedByThis = deckLinkBacking?.devicePersistentID
                        == device.persistentID

                    let inputMapped = DeckLinkDeviceCatalog.shared
                        .displayModes[device.persistentID]?.isEmpty == true
                    sourceCard(
                        title: device.name,
                        caption: inputMapped
                            ? "Mapped as input in Desktop Video Setup"
                            : deckLinkCaption(for: device),
                        selected: carriedByThis,
                        disabled: inputMapped && !carriedByThis,
                        tile: { networkTile("cable.connector.horizontal") }
                    ) {
                        if carriedByThis {
                            DeckLinkScreenOutputs.shared.disable(screenID: sliceID, render: render)
                        } else {
                            DeckLinkScreenOutputs.shared.enable(
                                screenID: sliceID, device: device,
                                keying: .off, render: render)
                        }
                    }

                    .contextMenu {
                        if !carriedByThis,
                           !DeckLinkScreenOutputs.shared
                               .members(onDevice: device.persistentID).isEmpty {
                            Button("Add Alongside — pack into this wire") {
                                DeckLinkScreenOutputs.shared.enable(
                                    screenID: sliceID, device: device,
                                    keying: .off, joining: true, render: render)
                            }
                        }
                    }

                    .help(deckLinkCaption(for: device))
                }
                if DeckLinkDeviceCatalog.shared.hasFetched,
                    DeckLinkDeviceCatalog.shared.devices.isEmpty {

                    sourceCard(
                        title: "DeckLink",
                        caption: DeckLinkDeviceCatalog.shared.runtimeTooOld
                            ? "Desktop Video \(DeckLinkDeviceCatalog.shared.runtimeVersionLabel)"
                                + " — 16.0 or later required"
                            : "No devices found",
                        selected: false, disabled: true,
                        tile: { networkTile("cable.connector.horizontal") }
                    ) {}
                }
                sourceCard(
                    title: "Syphon", caption: "Coming soon",
                    selected: false, disabled: true,
                    tile: { networkTile("square.stack.3d.forward.dottedline") }
                ) {}
            }
            if let deckLinkBacking, let device = DeckLinkDeviceCatalog.shared
                .devices.first(where: {
                    $0.persistentID == deckLinkBacking.devicePersistentID
                }) {

                HStack(spacing: 8) {
                    Text("ALPHA KEY")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .tracking(0.6)
                    ChipPicker(
                        options: DeckLinkAlphaKey.allCases
                            .filter { keyingAvailable($0, on: device) }
                            .map { ($0, $0.label) },
                        selection: Binding(
                            get: { deckLinkBacking.keying },
                            set: { mode in
                                DeckLinkScreenOutputs.shared.setKeying(
                                    screenID: sliceID, keying: mode,
                                    render: render)
                            }
                        )
                    )
                }
                .help(
                    "Internal: the card keys this screen over video fed into "
                        + "its SDI input and outputs the composite — a "
                        + "hardware keyer, no switcher needed. External: "
                        + "fill + key on separate connectors for a switcher's "
                        + "keyer (genlock reference recommended).")
                .padding(.top, 2)

                HStack(spacing: 8) {
                    Text("FORMAT")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .tracking(0.6)
                    Menu {
                        Button("Auto (card setting)") {
                            DeckLinkScreenOutputs.shared.setMode(
                                screenID: sliceID, mode: nil, render: render)
                        }

                        ForEach(
                            (DeckLinkDeviceCatalog.shared
                                .displayModes[device.persistentID] ?? [])
                                .filter {
                                    deckLinkBacking.keying == .off
                                        || $0.supportsKeying
                                }
                        ) { mode in
                            Button(mode.name) {
                                DeckLinkScreenOutputs.shared.setMode(
                                    screenID: sliceID, mode: mode, render: render)
                            }
                        }
                    } label: {
                        Text(deckLinkBacking.mode?.name ?? "Auto")
                            .font(.caption)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()

                    let wireDetail = DeckLinkScreenOutputs.shared
                        .wireDetail(for: sliceID)
                    if !wireDetail.isEmpty {
                        Text(wireDetail)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .task { DeckLinkDeviceCatalog.shared.refreshModes(
                    devicePersistentID: device.persistentID) }
            }

            Text("NDI® is a registered trademark of Vizrt NDI AB")
                .font(.system(size: 8))
                .foregroundStyle(.quaternary)
        }
        .help("Which real output carries this screen — routing set against the screen follows it")
        .task { DeckLinkDeviceCatalog.shared.refresh() }

        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)
        ) { _ in
            DeckLinkDeviceCatalog.shared.refresh()
        }
    }

    private func deckLinkCaption(for device: DeckLinkHelperDevice) -> String {
        guard deckLinkBacking?.devicePersistentID == device.persistentID else {
            return "SDI output"
        }
        switch DeckLinkScreenOutputs.shared.status(for: sliceID) {
        case .sending:
            var parts = ["Sending"]

            let wireDetail = DeckLinkScreenOutputs.shared.wireDetail(for: sliceID)
            if !wireDetail.isEmpty { parts.append(wireDetail) }
            if let keying = deckLinkBacking?.keying, keying != .off {
                parts.append("\(keying.label) key")
            }
            return parts.joined(separator: " · ")
        case .starting: return "Starting…"
        case .interrupted: return "Reconnecting…"
        case .failed(let message): return message
        case .idle, nil: return "SDI output"
        }
    }

    private func keyingAvailable(
        _ mode: DeckLinkAlphaKey, on device: DeckLinkHelperDevice
    ) -> Bool {
        switch mode {
        case .off: true
        case .internalKey: device.supportsInternalKeying
        case .externalKey: device.supportsExternalKeying
        }
    }

    private var ndiCaption: String {
        switch NDIScreenOutputs.shared.status(for: sliceID) {
        case .sending(let name): "Sending as “\(name)”"
        case .starting: "Starting…"
        case .interrupted: "Helper restarting…"
        case .failed(let message): message
        case .idle, nil: "Network output"
        }
    }

    private func assign(_ displayUUID: DisplayUUID?) {
        outputs.assignPlaceholderDevice(placeholderID: sliceID, displayUUID: displayUUID)
    }

    private func sourceCard(
        title: String, caption: String, selected: Bool, disabled: Bool,
        @ViewBuilder tile: () -> some View, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 5) {
                tile()
                    .frame(height: 44)
                    .frame(maxWidth: .infinity)
                Text(title)
                    .font(.caption.weight(selected ? .medium : .regular))
                    .lineLimit(1)
                Text(caption)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle.standard(CornerStandard.element))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.45 : 1)
        .background(
            selected ? Color.primary.opacity(0.08) : Color.primary.opacity(0.03),
            in: RoundedRectangle.standard(CornerStandard.element)
        )
        .overlay(
            RoundedRectangle.standard(CornerStandard.element)
                .strokeBorder(
                    selected ? Color.green.opacity(0.7) : Color.separator.opacity(0.5),
                    lineWidth: 1
                )
        )
    }

    private var placeholderTile: some View {
        RoundedRectangle.standard(4)
            .strokeBorder(
                Color.secondary.opacity(0.5),
                style: StrokeStyle(lineWidth: 1, dash: [3, 2.5])
            )
            .overlay {
                Image(systemName: "rectangle.dashed")
                    .font(.system(size: 13))
                    .foregroundStyle(.tertiary)
            }
    }

    private func displayTile(_ display: DisplaySnapshot) -> some View {
        GeometryReader { geo in
            let aspect = max(0.4, min(2.4, display.frame.width / max(1, display.frame.height)))
            let height = min(geo.size.height, geo.size.width / aspect)
            RoundedRectangle.standard(3)
                .fill(Color.primary.opacity(0.12))
                .overlay {
                    VStack(spacing: 1) {
                        Image(systemName: "display")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        if display.isMain {
                            Text("main")
                                .font(.system(size: 7))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .overlay(
                    RoundedRectangle.standard(3)
                        .strokeBorder(Color.separator.opacity(0.6), lineWidth: 1)
                )
                .frame(width: height * aspect, height: height)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var disconnectedTile: some View {
        RoundedRectangle.standard(4)
            .fill(Color.orange.opacity(0.10))
            .overlay {
                Image(systemName: "display.trianglebadge.exclamationmark")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.orange)
            }
    }

    private func networkTile(_ symbol: String) -> some View {
        RoundedRectangle.standard(4)
            .fill(Color.primary.opacity(0.05))
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: 13))
                    .foregroundStyle(.tertiary)
            }
    }
}

private struct SignageDetail: View {
    let signage: SignageController
    let channel: SignageChannel

    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                TextField("Name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .frame(maxWidth: 220)
                    .onSubmit { signage.renameChannel(channel.id, to: name) }
                Spacer()
            }
            Text("A named loop destination. Give it a media playlist as content and point screens at it below — every screen showing this signage follows content changes. The Set Screen Source action flips the same routing from combos and slides.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Text("Content")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 72, alignment: .leading)
                QuietMenuChip(title: signage.playlistName(channel.playlistId) ?? "Dark — no content") {
                    Button("Dark — no content") {
                        signage.assign(playlistID: nil, toSignage: channel.id)
                    }
                    let playlists = signage.playlistChoices
                    if !playlists.isEmpty { Divider() }
                    ForEach(playlists, id: \.id) { playlist in
                        Button(playlist.id == channel.playlistId
                            ? "✓ \(playlist.name)" : playlist.name
                        ) {
                            signage.assign(playlistID: playlist.id, toSignage: channel.id)
                        }
                    }
                }
                .help("The media playlist this signage loops — also assignable from the Signage module")
            }
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("On screens")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 72, alignment: .leading)

                VStack(alignment: .leading, spacing: 4) {
                    ForEach(signage.screens, id: \.id) { screen in
                        Toggle(isOn: Binding(
                            get: { signage.screenAssignments[screen.id] == channel.id },
                            set: { showing in
                                signage.setSource(
                                    showing ? channel.id : nil, forScreen: screen.id)
                            }
                        )) {
                            Text(screen.name)
                                .font(.caption)
                                .foregroundStyle(
                                    signage.screenAssignments[screen.id] == channel.id
                                        ? Color.green : .primary)
                        }
                        .toggleStyle(.checkbox)
                        .controlSize(.small)
                    }
                    Text("This machine's screens — each machine points its own screens at a signage.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack {
                Spacer()
                Button {
                    signage.removeChannel(channel.id)
                } label: {
                    Text("Remove Signage")
                        .font(.caption)
                        .foregroundStyle(.red.opacity(0.85))
                }
                .buttonStyle(.plain)
                .help("Screens pointed here fall back to the program")
            }
        }
        .onAppear { name = channel.name }
        .onChange(of: channel.id) { name = channel.name }
    }
}

private struct PresetDetail: View {
    let outputs: OutputManager
    let presets: OutputPresetsController
    let render: RenderContext?
    let presetID: String

    @State private var name = ""

    var body: some View {
        let active = presets.activePresetID == presetID
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                TextField("Name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .frame(maxWidth: 220)
                    .onSubmit { presets.renamePreset(presetID, to: name) }
                Spacer()
                Button {
                    presets.activate(active ? nil : presetID)
                } label: {
                    Text(active ? "Active" : "Make Active")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(active ? Color.green : .secondary)
                        .padding(.horizontal, 9)
                        .frame(height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(
                    active ? Color.green.opacity(0.12) : Color.primary.opacity(0.05),
                    in: RoundedRectangle.standard(CornerStandard.element)
                )
                .overlay(
                    RoundedRectangle.standard(CornerStandard.element)
                        .strokeBorder(
                            active ? Color.green.opacity(0.6) : Color.separator.opacity(0.5),
                            lineWidth: 1
                        )
                )
                .help(
                    active
                        ? "Deactivate — every output goes back to compositing all layers"
                        : "Apply this preset's routing to every audience output"
                )
            }
            Text("Which layers each audience output composites — switched globally, live outputs pick it up on their next frame. Confidence screens composite their own layout and are not routed here. Slide Theme re-formats the Slide layer for one output: the same fired slide renders through that theme there (a lower third on the stream feed) while every other output shows the slide as designed.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            RoutingMatrix(outputs: outputs, presets: presets, render: render, presetID: presetID)
            HStack {
                Spacer()
                Button("Delete Preset", role: .destructive) {
                    presets.deletePreset(presetID)
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
        }
        .task(id: presetID) {
            name = presets.preset(presetID)?.name ?? ""
        }
    }
}

private struct RoutingMatrix: View {
    let outputs: OutputManager
    let presets: OutputPresetsController
    let render: RenderContext?
    let presetID: String

    @State private var pickerTargetID: String?

    private struct Target: Identifiable {
        let id: String
        let name: String
        let kind: OutputTargetKind
    }

    private var targets: [Target] {
        outputs.displays.map {
            Target(id: $0.uuid, name: $0.name, kind: .display)
        } + outputs.placeholderScreens
            .filter { outputs.role(forScreen: $0.id) != .confidence }
            .map {
                Target(id: $0.id.uuidString, name: $0.name, kind: .placeholderScreen)
            }
    }

    private static let nameColumnWidth: CGFloat = 118
    private static let cellWidth: CGFloat = 44
    private static let themeColumnWidth: CGFloat = 128
    private static let maskColumnWidth: CGFloat = 104

    var body: some View {
        ScrollView(.horizontal) {
            VStack(alignment: .leading, spacing: 0) {
                headerRow
                ForEach(targets) { target in
                    Divider()
                    targetRow(target)
                }
            }
        }
        .scrollIndicators(.automatic)
    }

    private var headerRow: some View {
        HStack(spacing: 0) {
            Color.clear
                .frame(width: Self.nameColumnWidth, height: 1)
            ForEach(LayerKind.allCases, id: \.self) { layer in
                Text(Self.shortName(layer))
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .tracking(0.3)
                    .lineLimit(1)
                    .frame(width: Self.cellWidth)
                    .help(layer.displayName)
            }
            Text("SLIDE THEME")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.secondary)
                .tracking(0.3)
                .lineLimit(1)
                .frame(width: Self.themeColumnWidth)
                .help("Re-format the Slide layer on this output through a theme — the same fired slide renders as that theme lays it out (a lower third for the stream) while other outputs keep the slide as designed.")
            Text("MASKS")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.secondary)
                .tracking(0.3)
                .lineLimit(1)
                .frame(width: Self.maskColumnWidth)
                .help("Masks from the screen's library this preset turns on while active — on top of the screen's Always On masks. Draw masks in the screen's detail pane.")
        }
        .padding(.bottom, 4)
    }

    private func targetRow(_ target: Target) -> some View {
        let enabled = presets.enabledLayers(presetID: presetID, targetId: target.id)
        return HStack(spacing: 0) {
            HStack(spacing: 5) {
                Text(target.name)
                    .font(.caption)
                    .lineLimit(1)
                Spacer(minLength: 2)
            }
            .frame(width: Self.nameColumnWidth)
            ForEach(LayerKind.allCases, id: \.self) { layer in
                cell(target: target, layer: layer, enabled: enabled)
            }
            themeCell(target)
            maskCell(target)
        }
        .frame(height: 26)
        .contextMenu {
            Button("All Layers On") {
                presets.clearAssignment(presetID: presetID, targetId: target.id)
            }
        }
    }

    private func cell(target: Target, layer: LayerKind, enabled: Set<String>?) -> some View {

        let routed = enabled?.contains(layer.rawValue) ?? true
        return Button {
            presets.toggleLayer(
                presetID: presetID, targetKind: target.kind,
                targetId: target.id, layer: layer.rawValue
            )
        } label: {
            Group {
                if routed {
                    Circle().fill(Color.green.opacity(0.9))
                } else {
                    Circle().strokeBorder(Color.secondary.opacity(0.4), lineWidth: 1)
                }
            }
            .frame(width: 9, height: 9)
            .frame(width: Self.cellWidth, height: 26)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(layer.displayName) → \(target.name)")
    }

    private func themeCell(_ target: Target) -> some View {
        let current = presets.slideThemeId(presetID: presetID, targetId: target.id)
        let currentFolder = presets.slideThemeFolder(presetID: presetID, targetId: target.id)
        let currentSlide = presets.slideThemeSlideId(presetID: presetID, targetId: target.id)
        let currentName = current.map { id in
            let name = presets.themes.first { $0.id == id }?.name ?? "Missing Theme"
            if let currentSlide,
               let slideName = presets.themeValue(id)?.slides?.first(where: { $0.id == currentSlide })?.name {
                return "\(name) › \(slideName)"
            }
            return currentFolder.map { "\(name) › \($0)" } ?? name
        }
        return Button {
            pickerTargetID = target.id
        } label: {
            Text(currentName ?? "As Designed")
                .font(.caption)
                .lineLimit(1)
                .foregroundStyle(current == nil ? Color.secondary : Color.primary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(width: Self.themeColumnWidth, alignment: .leading)
        .popover(
            isPresented: Binding(
                get: { pickerTargetID == target.id },
                set: { if !$0 { pickerTargetID = nil } }
            ), arrowEdge: .bottom
        ) {
            ThemeLookPicker(
                model: presets.model, render: render, presets: presets,
                current: current, currentFolder: currentFolder, currentSlide: currentSlide
            ) { themeId, folder, slideId in
                presets.setSlideTheme(
                    presetID: presetID, targetKind: target.kind, targetId: target.id,
                    themeId: themeId, folder: folder, slideId: slideId
                )
                pickerTargetID = nil
            }
        }
        .help("Slide theme for \(target.name) — the fired slide re-formats through this theme, one of its slide folders, or one pinned design on this output; other outputs are unaffected.")
    }

    @ViewBuilder
    private func maskCell(_ target: Target) -> some View {
        let screenID = target.kind == .placeholderScreen ? UUID(uuidString: target.id) : nil
        let library = screenID.map { outputs.masks(forScreen: $0) } ?? []
        let selectable = library.filter { !$0.alwaysOn }
        if selectable.isEmpty {
            Text("—")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(width: Self.maskColumnWidth, alignment: .leading)
                .help(target.kind == .placeholderScreen
                    ? "No preset-controlled masks on \(target.name) — masks marked Always On apply regardless of preset."
                    : "Masks live on Screens — back this display with a Screen to mask it.")
        } else {
            let current = presets.maskIds(presetID: presetID, targetId: target.id)
            let activeNames = selectable.filter { current.contains($0.id) }.map(\.name)
            Menu {
                ForEach(selectable) { mask in
                    Toggle(
                        mask.name,
                        isOn: Binding(
                            get: { current.contains(mask.id) },
                            set: { _ in
                                presets.toggleMask(
                                    presetID: presetID, targetKind: target.kind,
                                    targetId: target.id, maskId: mask.id
                                )
                            }
                        )
                    )
                }
            } label: {
                Text(activeNames.isEmpty ? "None" : activeNames.joined(separator: ", "))
                    .font(.caption)
                    .lineLimit(1)
                    .foregroundStyle(activeNames.isEmpty ? Color.secondary : Color.primary)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .frame(width: Self.maskColumnWidth, alignment: .leading)
            .help("Masks this preset turns on for \(target.name); Always On masks apply regardless.")
        }
    }

    private static func shortName(_ layer: LayerKind) -> String {
        switch layer {
        case .videoInput: "INPUT"
        case .loopingVideos: "LOOPS"
        case .stillGraphics: "STILLS"
        case .videos: "VIDEO"
        case .slide: "SLIDE"
        case .overlays: "OVERLAY"
        case .alerts: "ALERTS"
        }
    }
}

private struct DiagnosticsDisclosure: View {
    let outputs: OutputManager

    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                VStack(alignment: .leading, spacing: 4) {
                    statRow(
                        "Sleep-proofing",
                        outputs.sleepProofing.isActive ? "active" : "idle — no live outputs"
                    )
                    statRow("Display reconfigurations", "\(outputs.reconfigurationCount)")
                    ForEach(Array(outputs.windows.keys.sorted()), id: \.self) { uuid in
                        if let window = outputs.windows[uuid] {
                            let name = outputs.displays.first { $0.uuid == uuid }?.name ?? "Output"
                            statRow(
                                "\(name) missed ticks",
                                "\(window.sceneView.missedTickCount)",
                                emphasized: window.sceneView.missedTickCount > 0
                            )
                        }
                    }
                }
                .padding(.top, 6)
            }
        } label: {
            Text("Diagnostics")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .disclosureGroupStyle(.automatic)
        .help("Hot-plug drill evidence: reconfigurations seen and missed display-link ticks (must hold at 0); sleep-proofing holds NSProcessInfo + IOPM assertions while any output is live")
    }

    private func statRow(_ label: String, _ value: String, emphasized: Bool = false) -> some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.caption.monospacedDigit())
                .foregroundStyle(emphasized ? .red : .secondary)
        }
    }
}

private struct ThemeLookPicker: View {
    let model: AppModel
    let render: RenderContext?
    let presets: OutputPresetsController
    let current: String?
    let currentFolder: String?
    let currentSlide: String?

    let select: (String?, String?, String?) -> Void

    @State private var browsedID: String?

    var body: some View {
        let themes = presets.themes
        let browsed = browsedID ?? current ?? themes.first?.id
        HStack(spacing: 0) {
            themeList(themes, browsed: browsed)
            Divider()
            designCatalog(browsed)
        }
        .frame(width: 640, height: 420)
    }

    private func themeList(_ themes: [LibraryIndex.Entry], browsed: String?) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                listRow("As Designed", selected: current == nil, browsing: false) {
                    select(nil, nil, nil)
                }
                Divider().padding(.vertical, 4)
                ForEach(themes, id: \.id) { theme in
                    listRow(theme.name, selected: theme.id == current, browsing: theme.id == browsed) {
                        browsedID = theme.id
                    }
                }
            }
            .padding(8)
        }
        .frame(width: 176)
    }

    private func listRow(
        _ name: String, selected: Bool, browsing: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(name)
                    .font(.caption)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            browsing ? Color.primary.opacity(0.08) : Color.clear,
            in: RoundedRectangle.standard(CornerStandard.element)
        )
    }

    @ViewBuilder
    private func designCatalog(_ themeID: String?) -> some View {
        if let themeID, let theme = presets.themeValue(themeID) {
            let slides = theme.slides ?? []
            let folders = theme.slideFolders
            let unfoldered = slides.filter { ($0.folder ?? "").isEmpty }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    scopeHeader(
                        theme.name, active: themeID == current && currentFolder == nil && currentSlide == nil,
                        buttonTitle: "Use Whole Theme"
                    ) {
                        select(themeID, nil, nil)
                    }
                    ForEach(folders, id: \.self) { folder in
                        let members = slides.filter {
                            ($0.folder ?? "").caseInsensitiveCompare(folder) == .orderedSame
                        }
                        scopeHeader(
                            folder,
                            active: themeID == current && currentSlide == nil && currentFolder
                                .map { $0.caseInsensitiveCompare(folder) == .orderedSame } == true,
                            buttonTitle: "Use Folder"
                        ) {
                            select(themeID, folder, nil)
                        }
                        designGrid(themeID: themeID, theme: theme, members: members)
                    }
                    if !unfoldered.isEmpty {
                        if !folders.isEmpty {
                            Text("Slides")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        designGrid(themeID: themeID, theme: theme, members: unfoldered)
                    }
                }
                .padding(12)
            }
        } else {
            ContentUnavailableView(
                "No Theme Selected", systemImage: "paintpalette",
                description: Text("Pick a theme on the left to browse its designs.")
            )
        }
    }

    private func scopeHeader(
        _ title: String, active: Bool, buttonTitle: String, action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Button(action: action) {
                HStack(spacing: 4) {
                    if active {
                        Image(systemName: "checkmark")
                            .font(.system(size: 8, weight: .semibold))
                    }
                    Text(buttonTitle)
                        .font(.caption2.weight(.medium))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(active ? Color.white : Color.primary)
            .background(
                active ? Color.accentColor : Color.primary.opacity(0.06),
                in: Capsule()
            )
        }
    }

    private func designGrid(themeID: String, theme: Theme, members: [Slide]) -> some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 132), spacing: 10)],
            alignment: .leading, spacing: 10
        ) {
            ForEach(members, id: \.id) { slide in
                designCard(themeID: themeID, theme: theme, slide: slide)
            }
        }
    }

    private func designCard(themeID: String, theme: Theme, slide: Slide) -> some View {
        let pinned = themeID == current && currentSlide == slide.id
        return Button {
            select(themeID, slide.folder, slide.id)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                ThemeSlidePreview(model: model, render: render, themeID: themeID, slide: slide)
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .clipShape(RoundedRectangle.standard(CornerStandard.element))
                    .overlay(
                        RoundedRectangle.standard(CornerStandard.element)
                            .strokeBorder(
                                pinned ? Color.accentColor : Color.separator.opacity(0.5),
                                lineWidth: pinned ? 2 : 1
                            )
                    )
                Text(slide.name)
                    .font(.caption2)
                    .lineLimit(1)
                    .foregroundStyle(pinned ? Color.accentColor : Color.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Pin \(slide.name) — every slide routed to this output renders through this design.")
    }
}

private struct ThemeSlidePreview: View {
    let model: AppModel
    let render: RenderContext?
    let themeID: String
    let slide: Slide

    var body: some View {
        let presentation = Presentation(
            id: "\(themeID)|preview", name: slide.name, presentationKind: .deck,
            themeId: "", slides: [slide]
        )
        SlideThumbnailView(
            model: model, render: render,
            slide: slide, presentation: presentation, theme: nil,
            arrangementId: nil,
            hideScopedBackgrounds: false, legibleText: false,
            contentStamp: "\(model.entry(themeID)?.updatedAt.timeIntervalSince1970 ?? 0)"
        )
    }
}
