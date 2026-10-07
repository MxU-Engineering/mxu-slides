import PresenterCore
import SwiftUI

struct MIDIMapManager: View {
    @State private var store = MIDICommandMapStore.shared
    @State private var editing = false

    var body: some View {
        HStack(spacing: 8) {
            Picker("", selection: Binding(
                get: { store.map.channel ?? 0 },
                set: { store.map.channel = $0 == 0 ? nil : $0 })
            ) {
                Text("Any channel").tag(0)
                ForEach(1...16, id: \.self) { Text("Channel \($0)").tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            .help("Global filter — only this channel's notes trigger commands. Each device can also pin its own channel in MIDI devices.")
            Button("Edit Map\u{2026}") { editing.toggle() }
                .popover(isPresented: $editing, arrowEdge: .bottom) {
                    MIDIMapEditor(store: store)
                }
        }
    }
}

private struct MIDIMapEditor: View {
    @Bindable var store: MIDICommandMapStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {

            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 10) {
                    groupSection(.clears)
                    groupSection(.video)
                    groupSection(.presentation)
                }
                .frame(width: 280)
                VStack(alignment: .leading, spacing: 10) {
                    groupSection(.selectByIndex)
                    Text("Velocity picks which one: 1–127 is the item's position in its list (A→Z, as the Library lists them). A Select command aims the matching Trigger until the next Select.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .frame(width: 280)
            }
            HStack {
                Spacer()
                Button("Reset to Defaults") { store.map.notes = [:] }
                    
                    .disabled(store.map.notes.isEmpty)
            }
        }
        .padding(14)
    }

    private func groupSection(_ group: MIDICommandGroup) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(group.displayName)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(commands(in: group), id: \.self) { command in
                commandRow(command)
            }
        }
    }

    private func commands(in group: MIDICommandGroup) -> [MIDICommand] {
        MIDICommand.allCases.filter { $0.group == group }
    }

    private func commandRow(_ command: MIDICommand) -> some View {
        HStack(spacing: 6) {
            Text(command.displayName)
                .font(.caption)
            Spacer(minLength: 8)
            TextField("", value: Binding(
                get: { store.map.note(for: command) },
                set: { store.map.setNote($0, for: command) }
            ), format: .number)
            .textFieldStyle(.roundedBorder)
            .controlSize(.small)
            .multilineTextAlignment(.trailing)
            .frame(width: 44)
            Text(MIDICommandMap.noteName(store.map.note(for: command)))
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
                .frame(width: 30, alignment: .leading)
        }
    }
}
