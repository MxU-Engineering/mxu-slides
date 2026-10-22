import SwiftUI

struct OutputPresetChip: View {
    let presets: OutputPresetsController

    var showName = true

    @Environment(\.runOnly) private var runOnly
    @Environment(\.openWindow) private var openWindow

    private var displayName: String {
        let name = OutputPresetMenu.activeName(presets)
        guard name.count > 13 else { return name }
        return name.prefix(13).trimmingCharacters(in: .whitespaces) + "…"
    }

    var body: some View {
        if !runOnly {
            Menu {
                ForEach(OutputPresetMenu.choices(presets), id: \.id) { choice in
                    Toggle(choice.name, isOn: Binding(
                        get: { (presets.activePresetID ?? "") == choice.id },
                        set: { _ in
                            presets.activate(choice.id.isEmpty ? nil : choice.id)
                        }
                    ))
                }
                Divider()

                Button("Edit Output Presets\u{2026}") {
                    ScreenConfigRouter.shared.pendingPresetID = presets.activePresetID ?? ""
                    openWindow(id: "outputs")
                }
            } label: {

                HStack(spacing: 5) {
                    Glyph(kind: .screens, size: 12)
                    if showName {
                        Text(displayName)
                            .font(.system(size: 10, weight: .medium))
                            .lineLimit(1)
                            .fixedSize()
                    }
                    Image(systemName: "chevron.down")
                        .font(.system(size: 7, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .foregroundStyle(.secondary)
                .headerItemLabel()
            }

            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .headerItemBackground()

            .help("Output Preset: \(OutputPresetMenu.activeName(presets)) — which layers reach the glass")
        }
    }
}
