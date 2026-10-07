import OutputEngine
import PresenterCore
import RenderEngine
import SwiftUI

struct OutputsWindow: View {
    let render: RenderContext?
    let presets: OutputPresetsController?

    @AppStorage("app.appearance") private var appearanceRaw = AppAppearance.dark.rawValue

    var body: some View {
        Group {
            if let render {
                ScreenConfigurationView(render: render, presets: presets)
            } else {
                Text("Metal is not available on this machine.")
                    .padding(40)
            }
        }
        .frame(minWidth: 700, minHeight: 480)
        .preferredColorScheme((AppAppearance(rawValue: appearanceRaw) ?? .dark).colorScheme)
    }
}

struct OutputsPanel: View {
    var render: RenderContext
    var presets: OutputPresetsController?

    private var outputs: OutputManager { render.outputs }

    var body: some View {
        presetSection
        screensSection
        Divider()
        displaysSection
        liveWindowStats
        HStack {
            Image(systemName: outputs.sleepProofing.isActive ? "bolt.fill" : "bolt.slash")
                .foregroundStyle(outputs.sleepProofing.isActive ? .green : .secondary)
            Text(outputs.sleepProofing.isActive
                 ? "Sleep-proofing active"
                 : "Sleep-proofing idle — no live outputs")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .help("While any output is live the app holds NSProcessInfo + IOPM assertions: no App Nap, no display or system sleep")
    }

    @ViewBuilder
    private var screensSection: some View {
        HStack {
            Text("SCREENS")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .tracking(0.6)
            Spacer()
            Menu {
                Button("1080p  (1920×1080)") { addScreen(width: 1920, height: 1080) }
                Button("4K  (3840×2160)") { addScreen(width: 3840, height: 2160) }
                Button("Vertical 9:16  (1080×1920)") { addScreen(width: 1080, height: 1920) }
            } label: {
                Label("Add Screen", systemImage: "plus.rectangle")
            } primaryAction: {

                addScreen(width: 1920, height: 1080)
            }
            .fixedSize()
            .help("A screen is a routing identity — set up looks and layer routing before the gig, then pick the output that carries it")
        }
        if outputs.placeholderScreens.isEmpty {
            Text("Add a screen to set up routing before you have the hardware — back it with a display or NDI at the venue (Syphon coming soon).")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        ForEach(outputs.placeholderScreens) { screen in
            ScreenRow(outputs: outputs, render: render, screen: screen)
        }
    }

    private func addScreen(width: Int, height: Int) {
        outputs.addPlaceholderScreen(
            name: "Screen \(outputs.placeholderScreens.count + 1)",
            width: width, height: height
        )
    }

    @ViewBuilder
    private var displaysSection: some View {
        Text("SYSTEM DISPLAYS — DIRECT")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .tracking(0.6)
        ForEach(outputs.displays) { display in
            displayRow(display)
        }
        if outputs.displays.count == 1 {
            Text("Single display: Esc or double-click a live output to release it.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var presetSection: some View {
        if let presets {
            HStack {
                Picker("Output Preset", selection: Binding(
                    get: { presets.activePresetID ?? "" },
                    set: { presets.activate($0.isEmpty ? nil : $0) }
                )) {
                    Text("None — all layers everywhere").tag("")
                    ForEach(presets.presets, id: \.id) { entry in
                        Text(entry.name).tag(entry.id)
                    }
                }
                Menu {
                    Button("Empty Preset") {
                        if let id = presets.createPreset(fromBroadcastTemplate: false) {
                            presets.activate(id)
                        }
                    }
                    Button("From “Broadcast Feed” Template") {
                        if let id = presets.createPreset(fromBroadcastTemplate: true) {
                            presets.activate(id)
                        }
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("New Output Preset — Broadcast Feed routes slide + overlays only (no media layers), for keying over a switcher")
            }
            if let activeID = presets.activePresetID, presets.preset(activeID) != nil {
                ForEach(outputs.displays) { display in
                    routingRow(
                        presetID: activeID, name: display.name,
                        targetKind: .display, targetId: display.uuid
                    )
                }
                ForEach(outputs.placeholderScreens) { screen in
                    routingRow(
                        presetID: activeID, name: screen.name,
                        targetKind: .placeholderScreen, targetId: screen.id.uuidString
                    )
                }
                HStack {
                    Spacer()
                    Button("Delete Preset", role: .destructive) {
                        presets.deletePreset(activeID)
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
            }
            Divider()
        }
    }

    private func routingRow(
        presetID: String, name: String, targetKind: OutputTargetKind, targetId: String
    ) -> some View {
        let enabled = presets?.enabledLayers(presetID: presetID, targetId: targetId)
        return HStack {
            Text(name)
                .font(.caption)
            Spacer()
            Menu {
                ForEach(LayerKind.allCases, id: \.self) { layer in
                    Toggle(
                        layer.displayName,
                        isOn: Binding(
                            get: { enabled?.contains(layer.rawValue) ?? true },
                            set: { _ in
                                presets?.toggleLayer(
                                    presetID: presetID, targetKind: targetKind,
                                    targetId: targetId, layer: layer.rawValue
                                )
                            }
                        )
                    )
                }
                if enabled != nil {
                    Divider()
                    Button("All Layers (Remove Routing)") {
                        presets?.clearAssignment(presetID: presetID, targetId: targetId)
                    }
                }
            } label: {
                Text(enabled.map { "\($0.count) layers" } ?? "All layers")
                    .font(.caption)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    private func displayRow(_ display: DisplaySnapshot) -> some View {
        HStack {
            Toggle(isOn: Binding(
                get: { outputs.isLive(display.uuid) },
                set: { outputs.setLive(display.uuid, $0) }
            )) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(display.name)
                    Text(
                        "\(Int(display.frame.width))×\(Int(display.frame.height)) pt"
                        + (display.isMain ? " · main" : "")
                        + " · \(display.maximumFramesPerSecond) Hz"
                    )
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.checkbox)
            Spacer()
        }
    }

    @ViewBuilder
    private var liveWindowStats: some View {
        if !outputs.windows.isEmpty || outputs.reconfigurationCount > 0 {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                VStack(alignment: .leading, spacing: 3) {
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
            }
        }
    }

    private func statRow(_ label: String, _ value: String, emphasized: Bool = false) -> some View {
        HStack {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.caption.monospacedDigit())
                .foregroundStyle(emphasized ? .red : .primary)
        }
    }
}

private struct ScreenRow: View {
    let outputs: OutputManager
    let render: RenderContext
    let screen: PlaceholderScreen

    @State private var name = ""
    @State private var widthText = ""
    @State private var heightText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                TextField("Name", text: $name)
                    .textFieldStyle(.plain)
                    .onSubmit(commit)
                Spacer()
                TextField("W", text: $widthText)
                    .frame(width: 52)
                    .multilineTextAlignment(.trailing)
                    .onSubmit(commit)
                Text("×")
                    .foregroundStyle(.secondary)
                TextField("H", text: $heightText)
                    .frame(width: 52)
                    .multilineTextAlignment(.trailing)
                    .onSubmit(commit)
                Text("px ·")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Menu {
                    ForEach([24, 25, 30, 50, 60], id: \.self) { rate in
                        Toggle("\(rate) fps", isOn: Binding(
                            get: { screen.framesPerSecond == rate },
                            set: { _ in setFrameRate(rate) }
                        ))
                    }
                } label: {
                    Text("\(screen.framesPerSecond) fps")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Render cadence for this screen — match the venue or stream rate")
                Button {
                    outputs.removePlaceholderScreen(id: screen.id)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Remove this placeholder screen")
            }
            .textFieldStyle(.roundedBorder)
            .controlSize(.small)
            deviceRow
            if let device = outputs.placeholderDevices[screen.id] {

                HStack(spacing: 5) {
                    Circle()
                        .fill(deviceConnected(device) ? Color.green : Color.orange)
                        .frame(width: 5, height: 5)
                    Text(
                        deviceConnected(device)
                            ? "Live on \(deviceName(device))"
                            : "Waiting for device — output opens when it connects"
                    )
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
            } else {
                PlaceholderScreenPreview(screen: screen, compositor: render.compositor)
                    .aspectRatio(
                        CGFloat(screen.width) / CGFloat(screen.height),
                        contentMode: .fit
                    )
                    .frame(maxHeight: 160)
                    .clipShape(RoundedRectangle.standard(CornerStandard.element))
            }
        }
        .padding(.vertical, 2)

        .task(id: "\(screen.name)|\(screen.width)|\(screen.height)") {
            name = screen.name
            widthText = "\(screen.width)"
            heightText = "\(screen.height)"
        }
    }

    private var deviceRow: some View {
        HStack(spacing: 6) {
            Text("Output")
                .font(.caption)
                .foregroundStyle(.secondary)
            Menu {
                Toggle("Placeholder — no output yet", isOn: Binding(
                    get: { outputs.placeholderDevices[screen.id] == nil && !ndiCarrying },
                    set: { _ in assign(nil) }
                ))
                if !outputs.displays.isEmpty {
                    Section("System") {
                        ForEach(outputs.displays) { display in
                            Toggle(display.name, isOn: Binding(
                                get: { outputs.placeholderDevices[screen.id] == display.uuid },
                                set: { _ in assign(display.uuid) }
                            ))
                        }
                    }
                }
                Section("Network") {
                    Toggle("NDI", isOn: Binding(
                        get: { ndiCarrying },
                        set: { on in
                            if on {
                                NDIScreenOutputs.shared.enable(screenID: screen.id, render: render)
                            } else {
                                NDIScreenOutputs.shared.disable(screenID: screen.id)
                            }
                        }
                    ))
                    Button("Syphon — coming soon") {}
                        .disabled(true)
                }
            } label: {
                Text(deviceLabel)
                    .font(.caption)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Which real output carries this screen — routing set up against the screen follows it")
            Spacer()
        }
    }

    private var ndiCarrying: Bool { NDIScreenOutputs.shared.isCarrying(screen.id) }

    private var deviceLabel: String {
        if ndiCarrying {
            return "NDI"
        } else if let device = outputs.placeholderDevices[screen.id] {
            return deviceConnected(device)
                ? deviceName(device)
                : "Disconnected: \(deviceName(device))"
        } else {
            return "Placeholder — no output yet"
        }
    }

    private func deviceName(_ uuid: String) -> String {
        outputs.displays.first { $0.uuid == uuid }?.name
            ?? outputs.placeholderDeviceNames[screen.id]
            ?? "Display"
    }

    private func deviceConnected(_ uuid: String) -> Bool {
        outputs.displays.contains { $0.uuid == uuid }
    }

    private func assign(_ displayUUID: String?) {
        NDIScreenOutputs.shared.disable(screenID: screen.id)
        outputs.assignPlaceholderDevice(placeholderID: screen.id, displayUUID: displayUUID)
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
