import PresenterCore
import SwiftUI

struct QuickEditView: View {

    let slide: () -> Slide?

    let write: (String, String) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Quick Edit — \(slide()?.name ?? "")")
                .font(.headline)

            if let slide = slide() {

                let textObjects = slide.objects.filter { object in
                    object.objectKind == .text
                        || (object.objectKind == .shape
                            && !object.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if textObjects.isEmpty {
                    Text("No text on this slide.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(textObjects) { object in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(object.name)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            TextField("Text", text: textBinding(for: object.id), axis: .vertical)
                                .lineLimit(1...6)
                                .textFieldStyle(.roundedBorder)
                        }
                    }
                }
            }

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 420)
    }

    private func textBinding(for objectID: String) -> Binding<String> {
        Binding(
            get: { slide()?.objects.first { $0.id == objectID }?.text ?? "" },
            set: { write(objectID, $0) }
        )
    }
}
