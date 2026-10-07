import PresenterCore
import SlideScene
import SwiftUI

struct ArrangementPopover: View {
    let model: SlideEditorModel

    @State private var selectedArrangementID: String?

    private var selectedArrangement: Arrangement? {
        guard let selectedArrangementID else { return model.arrangements.first }
        return model.arrangements.first { $0.id == selectedArrangementID }
            ?? model.arrangements.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !model.arrangements.isEmpty {
                Picker("Arrangement", selection: Binding(
                    get: { selectedArrangement?.id ?? "" },
                    set: { selectedArrangementID = $0 }
                )) {
                    ForEach(model.arrangements) { arrangement in
                        Text(arrangement.name).tag(arrangement.id)
                    }
                }
            }

            if model.sections.isEmpty {
                Text("Group slides into sections first: right-click a slide and choose Start New Section Here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let arrangement = selectedArrangement {
                arrangementEditor(arrangement)
            } else {
                Text("The slide order is the default. Create an arrangement to re-sequence sections — repeat a chorus without duplicating its slides — then pick it per service.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button("New Arrangement") {
                    if let created = model.addArrangement() {
                        selectedArrangementID = created.id
                    }
                }
                .disabled(model.sections.isEmpty)
                Spacer()
                if let arrangement = selectedArrangement {
                    Button("Delete", role: .destructive) {
                        model.deleteArrangement(arrangement.id)
                        selectedArrangementID = nil
                    }
                }
            }
            .controlSize(.small)
        }
        .padding(12)
        .frame(width: 300)
    }

    private func arrangementEditor(_ arrangement: Arrangement) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Name", text: arrangementNameBinding(arrangement))
                .textFieldStyle(.roundedBorder)
            List {
                ForEach(Array(arrangement.sectionIds.enumerated()), id: \.offset) { index, sectionId in
                    HStack {
                        Image(systemName: "line.3.horizontal")
                            .foregroundStyle(.tertiary)
                            .imageScale(.small)

                        if let fill = GroupColor.fill(
                            model.sections.first { $0.id == sectionId },
                            palette: model.appModel.groupColors
                        ) {
                            Circle().fill(fill).frame(width: 7, height: 7)
                        }
                        Text(model.sectionName(sectionId))
                        Spacer()
                        Button {
                            model.updateArrangement(arrangement.id) {
                                $0.sectionIds.remove(at: index)
                            }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Remove Block")
                    }
                }
                .onMove { offsets, target in
                    model.updateArrangement(arrangement.id) {
                        $0.sectionIds.move(fromOffsets: offsets, toOffset: target)
                    }
                }
            }
            .listStyle(.plain)
            .frame(height: 180)
            HStack {
                Menu {
                    ForEach(model.sections) { section in
                        Button(section.name) {
                            model.updateArrangement(arrangement.id) {
                                $0.sectionIds.append(section.id)
                            }
                        }
                    }
                } label: {
                    Label("Add Block", systemImage: "plus")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                Spacer()
                Text("\(model.arrangedSlideCount(arrangement.id)) slides")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func arrangementNameBinding(_ arrangement: Arrangement) -> Binding<String> {
        Binding(
            get: {
                model.arrangements.first { $0.id == arrangement.id }?.name ?? arrangement.name
            },
            set: { name in
                let trimmed = name.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { return }
                model.updateArrangement(arrangement.id) { $0.name = trimmed }
            }
        )
    }
}
