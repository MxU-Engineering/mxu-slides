import OutputEngine
import RenderEngine
import SwiftUI

struct OutputEditor: View {
    let render: RenderContext
    let outputs: OutputManager
    let key: OutputCarry.Key
    let openScreen: (UUID) -> Void

    @State private var selected: UUID?
    @State private var mode: OutputPicture.Mode = .grid
    @State private var snap = true

    private var members: [UUID] { OutputCarry.members(of: key, outputs: outputs) }
    private var screenIDs: [UUID] { OutputCarry.screenIDs(of: members, outputs: outputs) }
    private var current: UUID? {
        if let selected, members.contains(selected) { return selected }
        return members.first
    }
    private var name: String { OutputCarry.name(of: key, outputs: outputs) }

    var body: some View {
        let frame = OutputCarry.frameSize(of: key, outputs: outputs)
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text(name)
                    .font(.title3.weight(.semibold))
                Text("\(OutputCarry.kindWord(key)) · \(String(frame.width)) × \(String(frame.height))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Identify") { outputs.identify(screens: screenIDs) }
                    .controlSize(.small)
                    .help("Flash the alignment grid on this output for a moment — which wire is this?")
                Toggle("Alignment Grid", isOn: Binding(
                    get: { !screenIDs.isEmpty && screenIDs.allSatisfy { outputs.testPatternScreens.contains($0) } },
                    set: { on in for id in screenIDs { outputs.setTestPattern(on, forScreen: id) } }
                ))
                .toggleStyle(.checkbox)
                .controlSize(.small)
                .help("Show the rigging grid on every screen of this output while aligning")
            }
            HStack(spacing: 10) {
                Picker("", selection: $mode) {
                    Text("Content").tag(OutputPicture.Mode.content)
                    Text("Grid").tag(OutputPicture.Mode.grid)
                }
                .pickerStyle(.segmented)
                .controlSize(.small)
                .fixedSize()
                .help("Content: each screen's live canvas. Grid: a named test card per screen — the picture is legible with nothing live")
                Toggle("Snap 8 px", isOn: $snap)
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                    .help("Drags land on 8-pixel blocks — LED cabinets are built in them")
                Spacer()
                Text(screenIDs.count == 1 ? "1 screen" : "\(screenIDs.count) screens")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                AddScreenMenu(render: render, outputs: outputs, key: key, onAdded: { selected = $0 }) {
                    Label("Add Screen", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            if let current {
                OutputPicture(
                    render: render, outputs: outputs, sliceID: current,
                    selectSlice: { selected = $0 }, mode: mode, snapOn: snap, showsHeader: false)
                inspector(current)
            }
            Text("Drag a screen to move it · drag its corner to resize · click another screen to edit it · the fields nudge by 8 px")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private func inspector(_ slice: UUID) -> some View {
        let frame = OutputCarry.frameSize(of: key, outputs: outputs)
        let info = outputs.sliceInfo(for: slice)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text(OutputCarry.label(slice, outputs: outputs))
                    .font(.caption.weight(.semibold))
                PlacementFields(render: render, outputs: outputs, sliceID: slice)
                Spacer()
                Button("Top-left 1:1") { place(slice, x: 0, y: 0, size: nil) }
                    .help("Its own pixels, unscaled, at the output's origin")
                Button("Center 1:1") {
                    guard let info else { return }
                    place(slice, x: Double(frame.width - info.width) / 2, y: Double(frame.height - info.height) / 2, size: nil)
                }
                .help("Its own pixels, unscaled, centered in the output")
                Button("Fill") { place(slice, x: 0, y: 0, size: (frame.width, frame.height)) }
                    .help("Scaled to the whole output — it covers the other screens")
            }
            .controlSize(.small)
            HStack(spacing: 14) {
                if let info {
                    Button("Open \(outputs.placeholderScreens.first { $0.id == info.screenID }?.name ?? "screen") →") {
                        openScreen(info.screenID)
                    }
                    .buttonStyle(.link)
                    .controlSize(.small)
                }
                Button("Take off this output", role: .destructive) { takeOff(slice) }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .help("Release this output's claim on the screen; the screen keeps its routing and goes back to no output")
                Spacer()
            }
            .font(.caption)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle.standard(CornerStandard.element).fill(Color.primary.opacity(0.03)))
    }

    private func place(_ slice: UUID, x: Double, y: Double, size: (Int, Int)?) {
        let frame = OutputCarry.frameSize(of: key, outputs: outputs)
        guard let info = outputs.sliceInfo(for: slice) else { return }
        let width = Double(size?.0 ?? min(info.width, frame.width))
        let height = Double(size?.1 ?? min(info.height, frame.height))
        outputs.setPlacement(
            OutputPlacement(
                frameWidth: frame.width, frameHeight: frame.height,
                x: max(0, min(x, Double(frame.width) - width)).rounded(),
                y: max(0, min(y, Double(frame.height) - height)).rounded(),
                width: width, height: height),
            forSlice: slice)
        DeckLinkScreenOutputs.shared.refreshCarry(for: slice, render: render)
    }

    private func takeOff(_ slice: UUID) {
        let screenID = outputs.sliceInfo(for: slice)?.screenID
        OutputCarry.release(slice, outputs: outputs, render: render)
        let left = OutputCarry.screenIDs(of: OutputCarry.members(of: key, outputs: outputs), outputs: outputs)
        if left.count < 2, let stay = left.first ?? screenID { openScreen(stay) }
    }
}

struct AddScreenMenu<Label: View>: View {
    let render: RenderContext
    let outputs: OutputManager
    let key: OutputCarry.Key
    let onAdded: (UUID) -> Void
    @ViewBuilder let label: () -> Label

    var body: some View {
        let here = Set(OutputCarry.screenIDs(of: OutputCarry.members(of: key, outputs: outputs), outputs: outputs))
        let others = outputs.placeholderScreens.filter { !here.contains($0.id) }
        let name = OutputCarry.name(of: key, outputs: outputs)
        Menu {
            if !others.isEmpty {
                Section("Move a screen here") {
                    ForEach(others) { screen in
                        Button("\(screen.name) · \(String(screen.width))×\(String(screen.height)) · \(whereabouts(screen))") {
                            OutputCarry.join(screen.id, key, outputs: outputs, render: render)
                            onAdded(screen.id)
                        }
                    }
                }
            }
            Button("New Screen on \(name)") {
                let frame = OutputCarry.frameSize(of: key, outputs: outputs)
                guard let screen = outputs.addPlaceholderScreen(
                    name: "Screen \(outputs.placeholderScreens.count + 1)",
                    width: min(1920, frame.width), height: min(1080, frame.height))
                else { return }
                OutputCarry.join(screen.id, key, outputs: outputs, render: render)
                onAdded(screen.id)
            }
            Divider()
            Text("New arrivals land 1:1 below the others; size a new screen on its own page.")
        } label: {
            label()
        }
        .menuStyle(.button)
        .fixedSize()
        .help("Put another screen on \(name) — it lands at its own pixels beside the others")
    }

    private func whereabouts(_ screen: PlaceholderScreen) -> String {
        if let key = OutputCarry.key(of: screen.id, outputs: outputs) {
            return "from \(OutputCarry.name(of: key, outputs: outputs))"
        }
        if NDIScreenOutputs.shared.isCarrying(screen.id) { return "from NDI" }
        return "no output yet"
    }
}

struct NewWallSheet: View {
    let render: RenderContext
    let outputs: OutputManager
    let created: (OutputCarry.Key) -> Void

    private struct Row: Identifiable {
        let id = UUID()
        var name: String
        var width: String
        var height: String
    }

    @Environment(\.dismiss) private var dismiss
    @State private var key: OutputCarry.Key?
    @State private var rows = [Row(name: "Wall", width: "1920", height: "1080")]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("New LED Wall")
                    .font(.title3.weight(.semibold))
                Text("Several screens on one output. The processor reads the output; each screen lands at its own pixels. They start stacked top-left — place them in the output's picture after.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            sectionLabel("1 · Output the processor is on")
            Picker("", selection: $key) {
                ForEach(outputs.displays) { display in
                    let size = OutputCarry.pixelSize(of: display)
                    Text("\(display.name) · \(String(size.width))×\(String(size.height)) · \(holders(.display(display.uuid)))")
                        .tag(Optional(OutputCarry.Key.display(display.uuid)))
                }
                ForEach(DeckLinkDeviceCatalog.shared.devices) { device in
                    Text("\(device.name) · DeckLink · \(holders(.deckLink(device.persistentID)))")
                        .tag(Optional(OutputCarry.Key.deckLink(device.persistentID)))
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            sectionLabel("2 · Screens on it")
            ForEach($rows) { $row in
                HStack(spacing: 6) {
                    TextField("Name", text: $row.name)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 160)
                    TextField("W", text: $row.width)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 56)
                        .multilineTextAlignment(.trailing)
                    Text("×").foregroundStyle(.tertiary)
                    TextField("H", text: $row.height)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 56)
                        .multilineTextAlignment(.trailing)
                    Text("px")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button {
                        rows.removeAll { $0.id == row.id }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .disabled(rows.count == 1)
                }
                .controlSize(.small)
            }
            Button("Add Screen") {
                rows.append(Row(name: "Wall \(rows.count + 1)", width: "1920", height: "192"))
            }
            .controlSize(.small)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create Wall") { create() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(key == nil || rows.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520)
        .task { DeckLinkDeviceCatalog.shared.refresh() }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .tracking(0.6)
    }

    private func holders(_ key: OutputCarry.Key) -> String {
        let names = OutputCarry.screenIDs(of: OutputCarry.members(of: key, outputs: outputs), outputs: outputs)
            .compactMap { id in outputs.placeholderScreens.first { $0.id == id }?.name }
        return names.isEmpty ? "free" : "\(names.joined(separator: ", ")) is on it"
    }

    private func create() {
        guard let key else { return }
        for row in rows {
            let name = row.name.trimmingCharacters(in: .whitespaces)
            guard let width = Int(row.width), let height = Int(row.height), width > 0, height > 0,
                  let screen = outputs.addPlaceholderScreen(
                    name: name.isEmpty ? "Wall" : name, width: width, height: height)
            else { continue }
            OutputCarry.join(screen.id, key, outputs: outputs, render: render)
        }
        dismiss()
        created(key)
    }
}
