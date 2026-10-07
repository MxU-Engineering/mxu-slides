import PresenterCore
import SwiftUI

struct ConfidenceModule: View {
    let model: AppModel
    let controls: ServiceControls

    @Environment(\.confidenceMonitor) private var confidence

    @Environment(\.runOnly) private var runOnly

    @AppStorage("appMode") private var appModeRaw = AppMode.edit.rawValue
    @State private var messageDraft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {

            VStack(alignment: .leading, spacing: 6) {
                ModuleHeaderBar {
                    ModuleSectionLabel("Screens")
                } trailing: {
                }
                screensSection
            }
            stageMessageSection
        }
    }

    private var layoutEntries: [LibraryIndex.Entry] {
        model.entries(in: .confidence)
    }

    @ViewBuilder
    private var screensSection: some View {
        if let confidence, !confidence.confidenceScreens.isEmpty {

            let folderPaths = model.folders(in: .confidence)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(confidence.confidenceScreens, id: \.id) { screen in
                    screenRow(screen, folderPaths: folderPaths)
                }
                if layoutEntries.isEmpty {
                    Text("Design layouts in Edit — Confidence. Screens show the built-in layout until then.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 2)
                }
            }
        } else {
            Text("No confidence monitors. Give a screen the Confidence Monitor role in Screen Configuration.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 2)
        }
    }

    private func screenRow(_ screen: (id: UUID, name: String), folderPaths: [String]) -> some View {
        HStack(spacing: 8) {
            Text(screen.name)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
            Spacer(minLength: 8)
            if runOnly {
                Text(layoutEntries.first { $0.id == layoutBinding(screen.id).wrappedValue }?.name
                    ?? "Built-in Layout")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                layoutMenu(screen.id, folderPaths: folderPaths)
            }
        }
        .padding(.horizontal, 2)
    }

    private func layoutMenu(_ screenID: UUID, folderPaths: [String]) -> some View {
        let binding = layoutBinding(screenID)
        let selectedName = layoutEntries.first { $0.id == binding.wrappedValue }?.name
            ?? "Built-in Layout"
        return Menu {
            Toggle("Built-in Layout", isOn: Binding(
                get: { binding.wrappedValue.isEmpty },
                set: { _ in binding.wrappedValue = "" }
            ))
            if !layoutEntries.isEmpty {
                Divider()
                ForEach(layoutEntries.filter { $0.subkind.isEmpty }, id: \.id) { entry in
                    Toggle(entry.name, isOn: Binding(
                        get: { binding.wrappedValue == entry.id },
                        set: { _ in binding.wrappedValue = entry.id }
                    ))
                }
                EntryFolderMenuItems(
                    nodes: FolderTreeLogic.tree(paths: folderPaths),
                    entries: layoutEntries,
                    selectedID: binding.wrappedValue,
                    select: { binding.wrappedValue = $0 })
            }
            if !runOnly, !binding.wrappedValue.isEmpty {
                Divider()

                Button("Edit Layout in Library") {
                    model.openInEditor(entryID: binding.wrappedValue)
                    appModeRaw = AppMode.edit.rawValue
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(selectedName)
                    .font(.caption)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 7, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                Color.primary.opacity(0.06),
                in: RoundedRectangle.standard(CornerStandard.element)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private func layoutBinding(_ screenID: UUID) -> Binding<String> {
        Binding(
            get: { confidence?.assignments[screenID] ?? "" },
            set: { confidence?.setLayout($0.isEmpty ? nil : $0, forScreen: screenID) }
        )
    }

    private var stageMessageSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            ModuleSectionLabel("Stage Message")
                .padding(.horizontal, 2)
            TextField("Message to stage…", text: $messageDraft)
                .textFieldStyle(.roundedBorder)
                .onSubmit(send)
            HStack(spacing: 8) {
                Button("Send", action: send)
                    .disabled(trimmedDraft.isEmpty)
                Button("Clear") { controls.dismissAlert() }
                    .disabled(!(controls.state.liveAlert?.showsOnConfidence ?? false))
                Spacer()
            }
            if let live = controls.state.liveAlert, live.showsOnConfidence {
                Text("On stage: \(live.message)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 2)
            }
        }
    }

    private var trimmedDraft: String {
        messageDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func send() {
        guard !trimmedDraft.isEmpty else { return }
        controls.fireAlert(
            id: "stage-message", message: trimmedDraft,
            behavior: .persist, target: .confidence
        )
    }
}
