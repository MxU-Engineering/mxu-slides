import SwiftUI

struct FolderNameSheet: View {
    let title: String
    let confirm: String
    var initial = ""
    var error: String?
    let submit: (String) async -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var working = false
    @State private var failed = false

    private var trimmed: String { name.trimmingCharacters(in: .whitespaces) }
    private var valid: Bool { !trimmed.isEmpty && !trimmed.contains("/") && trimmed != initial && !working }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)
            Text(failed ? (error ?? "That didn't work") : "A name can't contain a slash.")
                .font(.caption)
                .foregroundStyle(failed ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button(confirm, action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!valid)
            }
        }
        .padding(16)
        .frame(width: 380)
        .onAppear { name = initial }
    }

    private func save() {
        if valid {
            working = true
            Task {
                let done = await submit(trimmed)
                working = false
                failed = !done
                if done { dismiss() }
            }
        }
    }
}
