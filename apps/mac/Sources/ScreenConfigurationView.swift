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

    private var outputs: OutputManager { render.outputs }

    private enum Selection: Hashable {
        case screen(UUID)

        case output(OutputCarry.Key)

        case screenMap

        case preset(String)
    }

    @State private var selection: Selection?

    @State private var presetSelection = ListMultiSelect.State()
    @State private var renamingPresetID: String?
    @State private var presetRenameText = ""
    @State private var showsWallSheet = false

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

        .onAppear { wake([], shownScreenIDs) }
        .onDisappear { wake(shownScreenIDs, []) }
        .onChange(of: shownScreenIDs) { old, new in wake(old, new) }
    }

    private var shownScreenIDs: [UUID] {
        switch selection {
        case .screen(let id): [id]
        case .output(let key):
            OutputCarry.screenIDs(of: OutputCarry.members(of: key, outputs: outputs), outputs: outputs)
        case .screenMap:
            outputs.placeholderScreens.filter { outputs.screenMap?.rect(for: $0.id) != nil }.map(\.id)
        case .preset where outputs.screenMap != nil:
            outputs.placeholderScreens.filter { outputs.screenMap?.rect(for: $0.id) != nil }.map(\.id)
        default: []
        }
    }

    private func wake(_ old: [UUID], _ new: [UUID]) {
        for id in old where !new.contains(id) { outputs.setCanvasWake(false, forScreen: id) }
        for id in new { outputs.setCanvasWake(true, forScreen: id) }
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
        case .output(let key) where OutputCarry.groups(outputs: outputs).contains(where: { $0.key == key }):
            return
        case .screenMap where outputs.screenMap != nil:
            return
        case .preset(let id) where presets?.preset(id) != nil:
            return
        default:
            selection = outputs.placeholderScreens.first.map { .screen($0.id) }
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

                let groups = OutputCarry.groups(outputs: outputs)
                let grouped = Set(groups.flatMap { OutputCarry.screenIDs(of: $0.members, outputs: outputs) })
                ForEach(groups, id: \.key) { group in
                    outputGroup(group.key, members: group.members)
                }
                ForEach(outputs.placeholderScreens.filter { !grouped.contains($0.id) }) { screen in
                    screenListRow(screen)
                }

                if let map = outputs.screenMap {
                    HStack {
                        sectionLabel("Screen Map")
                        Spacer()
                    }
                    .padding(.top, 12)
                    screenMapRow(map)
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
        .sheet(isPresented: $showsWallSheet) {
            NewWallSheet(render: render, outputs: outputs) { selection = .output($0) }
        }
    }

    private func screenMapRow(_ map: ScreenMap) -> some View {
        let selected = selection == .screenMap
        let bounds = map.bounds
        let audience = outputs.placeholderScreens.filter { outputs.role(forScreen: $0.id) != .confidence }
        let onMap = audience.filter { map.rect(for: $0.id) != nil }.count
        return Button {
            selection = .screenMap
        } label: {
            HStack(spacing: 8) {
                RoundedRectangle.standard(4)
                    .fill(Color.black.opacity(0.5))
                    .overlay {
                        GeometryReader { proxy in
                            ForEach(audience) { screen in
                                if let rect = map.rect(for: screen.id), bounds.width > 0, bounds.height > 0 {
                                    Rectangle()
                                        .fill(Color.cyan.opacity(0.35))
                                        .overlay(Rectangle().strokeBorder(Color.cyan, lineWidth: 0.5))
                                        .frame(width: max(rect.width / bounds.width * proxy.size.width, 2), height: max(rect.height / bounds.height * proxy.size.height, 2))
                                        .offset(x: rect.minX / bounds.width * proxy.size.width, y: rect.minY / bounds.height * proxy.size.height)
                                }
                            }
                        }
                    }
                    .frame(width: 46, height: 26)
                    .clipShape(RoundedRectangle.standard(4))
                    .overlay(RoundedRectangle.standard(4).strokeBorder(Color.separator.opacity(0.5), lineWidth: 1))
                VStack(alignment: .leading, spacing: 1) {
                    Text(map.name)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                    Text("\(String(Int(bounds.maxX)))×\(String(Int(bounds.maxY))) · \(onMap) of \(audience.count) audience screens")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
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
        .contextMenu {
            Button("Remove Screen Map", role: .destructive) {
                outputs.setScreenMap(nil)
                if selection == .screenMap { selection = nil; ensureSelection() }
            }
        }
        .help("Where every audience screen sits in the room — presets place layers against it")
    }

    private func outputGroup(_ key: OutputCarry.Key, members: [UUID]) -> some View {
        let selected = selection == .output(key)
        let frame = OutputCarry.frameSize(of: key, outputs: outputs)
        let screenIDs = OutputCarry.screenIDs(of: members, outputs: outputs)
        return VStack(alignment: .leading, spacing: 2) {
            Button {
                selection = .output(key)
            } label: {
                HStack(spacing: 8) {
                    outputThumb(members)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(OutputCarry.name(of: key, outputs: outputs))
                            .font(.caption.weight(.medium))
                            .lineLimit(1)
                        Text("\(String(frame.width))×\(String(frame.height)) · \(screenIDs.count) screens")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
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
            .help("This output carries several screens — open it to see and place them all")
            ForEach(outputs.placeholderScreens.filter { screenIDs.contains($0.id) }) { screen in
                screenListRow(screen)
                    .padding(.leading, 14)
            }
            AddScreenMenu(render: render, outputs: outputs, key: key, onAdded: { _ in selection = .output(key) }) {
                Text("+ Add a screen to this output")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .menuIndicator(.hidden)
            .padding(.leading, 20)
        }
        .padding(3)
        .overlay(
            RoundedRectangle.standard(CornerStandard.element)
                .strokeBorder(Color.separator.opacity(0.6), lineWidth: 1)
        )
    }

    private func outputThumb(_ members: [UUID]) -> some View {
        let shape = RoundedRectangle.standard(4)
        return shape.fill(Color.black.opacity(0.5))
            .overlay {
                GeometryReader { proxy in
                    ForEach(members, id: \.self) { member in
                        let rect = outputs.placement(forSlice: member)?.unitRect ?? CGRect(x: 0, y: 0, width: 1, height: 1)
                        Rectangle()
                            .fill(Color.green.opacity(0.35))
                            .overlay(Rectangle().strokeBorder(Color.green, lineWidth: 0.5))
                            .frame(width: max(rect.width * proxy.size.width, 2), height: max(rect.height * proxy.size.height, 2))
                            .offset(x: rect.minX * proxy.size.width, y: rect.minY * proxy.size.height)
                    }
                }
            }
            .frame(width: 46, height: 26)
            .clipShape(shape)
            .overlay(shape.strokeBorder(Color.separator.opacity(0.5), lineWidth: 1))
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
            Divider()
            Button("New LED Wall…") { showsWallSheet = true }
            if outputs.screenMap == nil {
                Button("Add Screen Map…") {
                    ScreenMapEditor.add(to: outputs)
                    selection = .screenMap
                }
            }
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
        .help("Add a screen — route against it now, back it with hardware at the venue. New LED Wall… puts several screens on one output.")
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

        .contextMenu {
            Button("Remove Screen", role: .destructive) {
                outputs.removePlaceholderScreen(id: screen.id)
            }
        }
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

    private var detailColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                switch selection {
                case .screen(let id):
                    if let screen = outputs.placeholderScreens.first(where: { $0.id == id }) {
                        ScreenDetail(
                            outputs: outputs, render: render, screen: screen,
                            openScreen: { selection = .screen($0) })
                    }
                case .output(let key):
                    OutputEditor(render: render, outputs: outputs, key: key, openScreen: { selection = .screen($0) })
                case .screenMap:
                    ScreenMapEditor(render: render, outputs: outputs, openScreen: { selection = .screen($0) })
                case .preset(let id):
                    if let presets, presets.preset(id) != nil {
                        PresetDetail(outputs: outputs, presets: presets, render: render, presetID: id)
                    }
                case nil:
                    ContentUnavailableView(
                        "No Screens", systemImage: "display",
                        description: Text("Add a screen.")
                    )
                }
                DiagnosticsDisclosure(outputs: outputs)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollContentBackground(.hidden)
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

    let openScreen: (UUID) -> Void

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
            OutputsSection(render: render, outputs: outputs, screen: screen, openScreen: openScreen)
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

        .task(id: "\(screen.id)|\(screen.name)|\(screen.width)|\(screen.height)") {
            name = screen.name
            widthText = "\(screen.width)"
            heightText = "\(screen.height)"
        }
    }

    private var identityBar: some View {

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                identityFacts
            }
            HStack(spacing: 10) {
                identityVerbs
            }
        }
    }

    @ViewBuilder
    private var identityFacts: some View {
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
        if outputs.role(forScreen: screen.id) == .audience {

            Picker("", selection: Binding(
                get: { outputs.scaleMode(forScreen: screen.id) },
                set: { outputs.setScaleMode($0, forScreen: screen.id) }
            )) {
                Text("Fit Slides").tag(OutputScaleMode.fit)
                Text("Fill Slides").tag(OutputScaleMode.fill)
            }
            .pickerStyle(.menu)
            .controlSize(.small)
            .fixedSize()
            .help("When a presentation is a different shape than this screen: Fit shows the whole slide with its background filling the sides; Fill covers the screen and crops the edges")
        }
        Spacer()
    }

    @ViewBuilder
    private var identityVerbs: some View {
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
        Spacer()
    }

    private func identify() { outputs.identify(screens: [screen.id]) }

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
    let sliceID: UUID

    private var backing: DisplayUUID? { outputs.placeholderDevices[sliceID] }
    private var ndiCarrying: Bool { NDIScreenOutputs.shared.isCarrying(sliceID) }
    private var deckLinkBacking: DeckLinkScreenOutputs.Backing? {
        DeckLinkScreenOutputs.shared.backing(for: sliceID)
    }
    private var carried: Bool { backing != nil || ndiCarrying || deckLinkBacking != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("On")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                onMenu
                if carried { placementBadge }
                Spacer()
            }
            if let deckLinkBacking, let device = DeckLinkDeviceCatalog.shared
                .devices.first(where: {
                    $0.persistentID == deckLinkBacking.devicePersistentID
                }) {
                deckLinkRows(deckLinkBacking, device)
            }

            Text("NDI® is a registered trademark of Vizrt NDI AB")
                .font(.system(size: 8))
                .foregroundStyle(.quaternary)
        }
        .help("Which real output carries this slice — routing set against the screen follows it")
        .task { DeckLinkDeviceCatalog.shared.refresh() }

        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)
        ) { _ in
            DeckLinkDeviceCatalog.shared.refresh()
        }
    }

    private var onMenu: some View {
        Menu {
            Section("Displays") {
                ForEach(outputs.displays) { display in displayItem(display) }
                if let backing, !outputs.displays.contains(where: { $0.uuid == backing }) {
                    Toggle(isOn: .constant(true)) {
                        Text("Disconnected: \(outputs.placeholderDeviceNames[sliceID] ?? "Display")")
                    }
                }
            }
            Section("DeckLink") {
                ForEach(DeckLinkDeviceCatalog.shared.devices) { device in deckLinkItem(device) }
                if DeckLinkDeviceCatalog.shared.hasFetched,
                   DeckLinkDeviceCatalog.shared.devices.isEmpty {

                    Text(DeckLinkDeviceCatalog.shared.runtimeTooOld
                        ? "Desktop Video \(DeckLinkDeviceCatalog.shared.runtimeVersionLabel) — 16.0 or later required"
                        : "No devices found")
                }
            }
            Section("Network") {
                Toggle(isOn: Binding(get: { ndiCarrying }, set: { _ in toggleNDI() })) {
                    Text("NDI · \(ndiCaption)")
                }
                Text("Syphon · coming soon")
            }
            Divider()
            Toggle(isOn: Binding(get: { !carried }, set: { _ in releaseAll() })) {
                Text("No output · keep routing, nothing on glass")
            }
        } label: {
            Text(currentLabel)
                .font(.callout.weight(.semibold))
        }
        .menuStyle(.button)
        .buttonStyle(.bordered)
        .controlSize(.small)
        .fixedSize()
    }

    private var currentLabel: String {
        if let backing {
            if let display = outputs.displays.first(where: { $0.uuid == backing }) {
                let size = OutputCarry.pixelSize(of: display)
                return "\(display.name) · \(size.width)×\(size.height)"
            }
            return "Disconnected: \(outputs.placeholderDeviceNames[sliceID] ?? "Display")"
        }
        if let deckLinkBacking { return deckLinkBacking.deviceName }
        if ndiCarrying { return "NDI" }
        return "No output yet"
    }

    @ViewBuilder
    private func displayItem(_ display: DisplaySnapshot) -> some View {
        let size = OutputCarry.pixelSize(of: display)
        let holders = outputs.placeholderDevices
            .filter { $0.value == display.uuid && $0.key != sliceID }.keys.sorted { $0.uuidString < $1.uuidString }
        let title = "\(display.name) · \(size.width)×\(size.height)"
        if holders.isEmpty || backing == display.uuid {
            Toggle(isOn: Binding(
                get: { backing == display.uuid },
                set: { _ in claim(display) }
            )) {
                Text(backing == display.uuid ? title : "\(title) · free")
            }
        } else {
            Menu("\(title) · \(names(holders)) is on it") {
                Button("Share it — both land in the same \(String(size.width))×\(String(size.height)), you place them") {
                    share(display, holders: holders)
                }
                Button("Take it over — \(names(holders)) loses its output") { claim(display) }
            }
        }
    }

    @ViewBuilder
    private func deckLinkItem(_ device: DeckLinkHelperDevice) -> some View {
        let carriedByThis = deckLinkBacking?.devicePersistentID == device.persistentID
        let holders = DeckLinkScreenOutputs.shared
            .members(onDevice: device.persistentID).filter { $0 != sliceID }

        let inputMapped = DeckLinkDeviceCatalog.shared
            .displayModes[device.persistentID]?.isEmpty == true
        if inputMapped, !carriedByThis {
            Text("\(device.name) · mapped as input in Desktop Video Setup")
        } else if holders.isEmpty || carriedByThis {
            Toggle(isOn: Binding(
                get: { carriedByThis },
                set: { _ in claimDeckLink(device, joining: false) }
            )) {
                Text(carriedByThis ? "\(device.name) · \(deckLinkCaption(for: device))" : "\(device.name) · free")
            }
        } else {
            Menu("\(device.name) · \(names(holders)) is on it") {
                Button("Share it — both land in the same wire, you place them") {
                    shareDeckLink(device, holders: holders)
                }
                Button("Take it over — \(names(holders)) loses its output") {
                    claimDeckLink(device, joining: false)
                }
            }
        }
    }

    private func names(_ ids: [UUID]) -> String {
        ids.map { OutputCarry.label($0, outputs: outputs) }.joined(separator: ", ")
    }

    private func releaseHelpers() {
        NDIScreenOutputs.shared.disable(screenID: sliceID)
        DeckLinkScreenOutputs.shared.disable(screenID: sliceID, render: render)
    }

    private func claim(_ display: DisplaySnapshot) {
        releaseHelpers()
        outputs.assignPlaceholderDevice(placeholderID: sliceID, displayUUID: display.uuid)
    }

    private func share(_ display: DisplaySnapshot, holders: [UUID]) {
        OutputCarry.join(sliceID, .display(display.uuid), outputs: outputs, render: render)
    }

    private func claimDeckLink(_ device: DeckLinkHelperDevice, joining: Bool) {
        DeckLinkScreenOutputs.shared.enable(
            screenID: sliceID, device: device, keying: .off, joining: joining, render: render)
    }

    private func shareDeckLink(_ device: DeckLinkHelperDevice, holders: [UUID]) {
        OutputCarry.join(sliceID, .deckLink(device.persistentID), outputs: outputs, render: render)
    }

    private func toggleNDI() {
        if ndiCarrying {
            NDIScreenOutputs.shared.disable(screenID: sliceID)
        } else {
            NDIScreenOutputs.shared.enable(screenID: sliceID, render: render)
        }
    }

    private func releaseAll() {
        releaseHelpers()
        outputs.assignPlaceholderDevice(placeholderID: sliceID, displayUUID: nil)
    }

    private var placementBadge: some View {
        let placement = outputs.placement(forSlice: sliceID)
        let siblings = OutputCarry.siblings(of: sliceID, outputs: outputs)
        var parts: [String] = []
        if let placement {
            parts.append("at \(Int(placement.x)),\(Int(placement.y))")
            if let info = outputs.sliceInfo(for: sliceID),
               Int(placement.width) == info.width, Int(placement.height) == info.height {
                parts.append("1:1")
            } else {
                parts.append("\(Int(placement.width))×\(Int(placement.height))")
            }
        } else {
            parts.append("fills it")
        }
        if !siblings.isEmpty { parts.append("shares with \(names(siblings))") }
        parts.append(liveWord)
        return Menu {
            Button("Fill the output") {
                outputs.setPlacement(nil, forSlice: sliceID)
                DeckLinkScreenOutputs.shared.refreshCarry(for: sliceID, render: render)
            }
            .disabled(placement == nil)
            Button("Place 1:1 at this screen's pixels") {
                let frame = OutputCarry.frameSize(for: sliceID, outputs: outputs)
                outputs.seedPlacement(
                    forSlice: sliceID, frameWidth: frame.width, frameHeight: frame.height,
                    siblings: siblings.compactMap { outputs.placement(forSlice: $0) })
                DeckLinkScreenOutputs.shared.refreshCarry(for: sliceID, render: render)
            }
            .disabled(placement != nil)
        } label: {
            Text(parts.joined(separator: " · "))
                .font(.caption2)
                .foregroundStyle(liveColor)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Fill = the slice is scaled to the whole output. 1:1 = its pixels land unscaled at exact coordinates inside the output, the LED-processor contract; drag it in the picture above")
    }

    private var liveWord: String {
        if backing != nil {
            return outputs.displays.contains { $0.uuid == backing } ? "live" : "disconnected"
        }
        if deckLinkBacking != nil {
            switch DeckLinkScreenOutputs.shared.status(for: sliceID) {
            case .sending: return "sending"
            case .starting: return "starting…"
            case .interrupted: return "reconnecting…"
            case .failed(let message): return message
            case .idle, nil: return "idle"
            }
        }
        switch NDIScreenOutputs.shared.status(for: sliceID) {
        case .sending(let name): return "sending as “\(name)”"
        case .starting: return "starting…"
        case .interrupted: return "helper restarting…"
        case .failed(let message): return message
        case .idle, nil: return "idle"
        }
    }

    private var liveColor: Color {
        switch liveWord {
        case "live", "sending": return .green
        case "idle": return .secondary
        default: return liveWord.hasPrefix("sending as") ? .green : .orange
        }
    }

    @ViewBuilder
    private func deckLinkRows(
        _ deckLinkBacking: DeckLinkScreenOutputs.Backing, _ device: DeckLinkHelperDevice
    ) -> some View {

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

    private func deckLinkCaption(for device: DeckLinkHelperDevice) -> String {
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
        case .sending(let name): "sending as “\(name)”"
        case .starting: "starting…"
        case .interrupted: "helper restarting…"
        case .failed(let message): message
        case .idle, nil: "network output"
        }
    }
}

private struct PresetDetail: View {
    let outputs: OutputManager
    let presets: OutputPresetsController
    let render: RenderContext?
    let presetID: String

    @State private var name = ""

    @State private var addingLayer = false
    @State private var newLayerName = ""

    var body: some View {
        let active = presets.activePresetID == presetID
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                TextField("Name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .frame(maxWidth: 220)
                    .onSubmit { presets.renamePreset(presetID, to: name) }
                Button("Add Layer") {
                    newLayerName = ""
                    addingLayer = true
                }
                .controlSize(.small)
                .help("A layer of your own on this preset — route it per screen below; move a slide's media onto it with right-click › Layer.")
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
            if let render, outputs.screenMap != nil {
                PresetPlacementsEditor(render: render, outputs: outputs, presets: presets, presetID: presetID)
            }
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
        .alert("Add Layer", isPresented: $addingLayer) {
            TextField("Name", text: $newLayerName)
            Button("Add") { presets.addLayer(presetID: presetID, name: newLayerName) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The layer stacks above the Slide layer and starts on for every screen this preset routes.")
        }
    }
}

private struct RoutingMatrix: View {
    let outputs: OutputManager
    let presets: OutputPresetsController
    let render: RenderContext?
    let presetID: String

    @State private var pickerTargetID: String?

    @State private var renamingLayerID: String?
    @State private var layerNameText = ""

    private var customLayers: [CustomLayer] {
        presets.customLayers(presetID: presetID)
    }

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
    private static let customCellWidth: CGFloat = 64

    var body: some View {
        ScrollView(.horizontal) {
            VStack(alignment: .leading, spacing: 0) {
                headerRow
                ForEach(targets) { target in
                    Divider()
                    targetRow(target)
                }
            }
            .alert("Rename Layer", isPresented: Binding(
                get: { renamingLayerID != nil },
                set: { if !$0 { renamingLayerID = nil } }
            )) {
                TextField("Name", text: $layerNameText)
                Button("Rename") {
                    if let id = renamingLayerID {
                        presets.renameLayer(presetID: presetID, layerID: id, to: layerNameText)
                    }
                    renamingLayerID = nil
                }
                Button("Cancel", role: .cancel) { renamingLayerID = nil }
            }
        }
        .scrollIndicators(.automatic)
    }

    private func customHeader(_ layer: CustomLayer) -> some View {
        Text(layer.name.uppercased())
            .font(.system(size: 8, weight: .semibold))
            .foregroundStyle(.secondary)
            .tracking(0.3)
            .lineLimit(1)
            .frame(width: Self.customCellWidth)
            .help("\(layer.name) — a layer added to this preset. Right-click to rename or remove it.")
            .contextMenu {
                Button("Rename Layer…") {
                    layerNameText = layer.name
                    renamingLayerID = layer.id
                }
                Button("Remove Layer", role: .destructive) {
                    presets.removeLayer(presetID: presetID, layerID: layer.id)
                }
            }
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
            ForEach(customLayers) { layer in
                customHeader(layer)
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
                cell(target: target, layerId: layer.rawValue, layerName: layer.displayName, enabled: enabled)
            }
            ForEach(customLayers) { layer in
                cell(target: target, layerId: layer.id, layerName: layer.name, width: Self.customCellWidth, enabled: enabled)
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

    private func cell(
        target: Target, layerId: String, layerName: String,
        width: CGFloat = RoutingMatrix.cellWidth, enabled: Set<String>?
    ) -> some View {

        let routed = enabled?.contains(layerId) ?? true
        let placed = presets.hasPlacements(presetID: presetID, layer: layerId)
        return Button {
            presets.toggleLayer(
                presetID: presetID, targetKind: target.kind,
                targetId: target.id, layer: layerId
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

            .overlay(Circle().strokeBorder(Color.yellow, lineWidth: placed ? 1.5 : 0).frame(width: 13, height: 13))
            .frame(width: width, height: 26)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(placed ? "\(layerName) → \(target.name) · placed on the Screen Map below" : "\(layerName) → \(target.name)")
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
            hideScopedBackgrounds: false,
            contentStamp: "\(model.entry(themeID)?.updatedAt.timeIntervalSince1970 ?? 0)"
        )
    }
}
