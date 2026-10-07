import RenderEngine
import SwiftUI

struct OutputsModule: View {
    let model: AppModel
    let controls: ServiceControls
    let presets: OutputPresetsController?

    @Environment(\.openWindow) private var openWindow
    @Environment(\.runOnly) private var runOnly

    var body: some View {
        let outputs = controls.render.outputs
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionLabel("Screens")
                Spacer()
                if let presets, !runOnly {

                    OutputPresetMenu(presets: presets)
                    Button {
                        openWindow(id: "outputs")
                    } label: {
                        Image(systemName: "gearshape")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Manage outputs — presets, layer routing, placeholder screens")
                }
            }
            ForEach(outputs.displays) { display in
                let isLive = outputs.isLive(display.uuid)

                Button {
                    outputs.setLive(display.uuid, !isLive)
                } label: {
                    HStack(spacing: 6) {
                        Text(display.name)
                            .font(.caption)
                            .foregroundStyle(isLive ? Color.green : .secondary)
                            .lineLimit(1)
                        Spacer(minLength: 6)
                        Text(isLive ? "Live" : "Off")
                            .font(.caption2)
                            .foregroundStyle(isLive ? Color.green : Color.secondary.opacity(0.7))
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 26)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(runOnly)
                .background(
                    isLive ? Color.green.opacity(0.10) : Color.primary.opacity(0.03),
                    in: RoundedRectangle.standard(CornerStandard.element)
                )
                .help(isLive ? "Take \(display.name) offline" : "Send output to \(display.name)")
            }
            ForEach(outputs.placeholderScreens) { screen in
                HStack(spacing: 6) {
                    Text(screen.name)
                        .font(.caption)
                        .foregroundStyle(Color.green)
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    Text("\(screen.width)×\(screen.height)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 8)
                .frame(height: 26)
                .background(
                    Color.primary.opacity(0.03),
                    in: RoundedRectangle.standard(CornerStandard.element)
                )
            }
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .tracking(0.6)
    }
}

struct OutputPresetMenu: View {
    let presets: OutputPresetsController

    var body: some View {
        Menu {
            ForEach(Self.choices(presets), id: \.id) { choice in
                Toggle(choice.name, isOn: Binding(
                    get: { (presets.activePresetID ?? "") == choice.id },
                    set: { _ in
                        presets.activate(choice.id.isEmpty ? nil : choice.id)
                    }
                ))
            }
        } label: {
            HStack(spacing: 4) {
                Text(Self.activeName(presets))
                    .font(.caption)
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .semibold))
            }
            .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Output Preset — which layers reach the glass")
    }

    struct Choice: Identifiable {
        let id: String
        let name: String
    }

    static func choices(_ presets: OutputPresetsController) -> [Choice] {
        [Choice(id: "", name: "Default — All Layers")]
            + presets.presets.map { Choice(id: $0.id, name: $0.name) }
    }

    static func activeName(_ presets: OutputPresetsController) -> String {
        guard let id = presets.activePresetID,
              let active = presets.presets.first(where: { $0.id == id })
        else { return "Default — All Layers" }
        return active.name
    }
}
