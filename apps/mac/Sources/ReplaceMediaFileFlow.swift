import AppKit
import PresenterCore
import SwiftUI

struct ReplaceMediaFileRequest: Identifiable {
    let id: String
    let name: String
    let groups: [MediaUsage.Group]

    var count: Int { groups.reduce(0) { $0 + $1.uses.count } }
}

@MainActor
enum ReplaceMediaFileFlow {

    static func start(
        model: AppModel, id: String, name: String,
        confirm: @escaping (ReplaceMediaFileRequest) -> Void
    ) {
        Task {
            let groups = MediaUsage.groups(await model.mediaUses(of: id))
            if groups.isEmpty {
                chooseFile(model: model, id: id, name: name)
            } else {
                confirm(ReplaceMediaFileRequest(id: id, name: name, groups: groups))
            }
        }
    }

    static func chooseFile(model: AppModel, id: String, name: String) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image, .movie]
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                let hash = await Task.detached(priority: .userInitiated) { try? BlobStore.sha256(of: url) }.value
                let other = hash.flatMap { model.mediaHolding(file: $0, except: id) }
                let proceed = if let other {
                    await MediaImportPrompt.confirmSharedFile(
                        model: model, otherID: other.id, otherName: other.name, itemName: name)
                } else {
                    true
                }
                if proceed, let carried = await model.replaceMediaFile(id, with: url) {
                    MediaRelinkAlerts.carriedSettingsWarning(itemName: name, carried: carried)
                }
            }
        }
    }
}

struct ReplaceMediaFileSheet: View {
    let request: ReplaceMediaFileRequest
    let onChooseFile: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label {
                Text("Replace “\(request.name)” everywhere?")
                    .font(.headline)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            Text("\(request.count == 1 ? "The new file takes this item's place in the spot below" : "The new file takes this item's place in all \(request.count) spots below"). To change one slide or object only, use Replace… in its Media section instead.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            List {
                ForEach(request.groups, id: \.kind) { group in
                    Section {
                        ForEach(group.uses, id: \.id) { use in
                            Label {
                                HStack(spacing: 4) {
                                    Text(use.name.isEmpty ? "Untitled" : use.name)
                                    if let via = use.via {
                                        Text("via \(via) theme")
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .lineLimit(1)
                            } icon: {
                                Image(systemName: group.symbol)
                            }
                        }
                    } header: {
                        Text("\(group.title) (\(group.uses.count))")
                    }
                }
            }
            .listStyle(.inset)
            .frame(minHeight: 160, maxHeight: 280)
            .clipShape(RoundedRectangle.standard(CornerStandard.element))
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Replace Everywhere…") {
                    dismiss()
                    onChooseFile()
                }
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}
