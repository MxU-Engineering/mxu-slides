import PresenterCore
import SwiftUI

struct TrackSetList: View {
    let model: AppModel
    @Environment(\.runOnly) private var runOnly
    @State private var renaming: TrackSet?
    @State private var renameText = ""
    @State private var deleting: TrackSet?

    var body: some View {
        let sets = model.trackSets
        Group {
            if sets.isEmpty {
                Text("A song's stems show up here once they're added: open the song's timeline, then Tracks › + › Import Audio\u{2026}")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(20)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(sets) { set in
                            row(set)
                        }
                    }
                    .padding(6)
                }
            }
        }
        .alert("Rename Tracks", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText)
            Button("Rename") {
                let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                if let set = renaming, !name.isEmpty { model.updateTrackSet(set.id) { $0.name = name } }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        .alert(
            deleting.map { "Delete \u{201C}\($0.name)\u{201D}?" } ?? "",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
        ) {
            Button("Delete", role: .destructive) {
                if let set = deleting { model.deleteTrackSet(set) }
                deleting = nil
            }
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: {
            Text("Its \(deleting?.stems.count ?? 0) stems go too. Songs that use them keep their blocks, without sound.")
        }
    }

    private func row(_ set: TrackSet) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "square.stack.3d.down.right")
                .foregroundStyle(.purple)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(set.name)
                    .font(.system(size: 12))
                    .lineLimit(1)
                Text(Self.details(set))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .draggablePayload(runOnly ? nil : set.id)
        .help("Drag onto a song's Tracks area: every stem lands on its channel")
        .contextMenu {
            if !runOnly {
                Button("Rename\u{2026}") {
                    renameText = set.name
                    renaming = set
                }
                Divider()
                Button("Delete\u{2026}", role: .destructive) { deleting = set }
            }
        }
    }

    static func details(_ set: TrackSet) -> String {
        let tempo = set.tempo.map { $0.rounded() == $0 ? "\(Int($0)) bpm" : String(format: "%g bpm", $0) }
        return (["\(set.stems.count) stem\(set.stems.count == 1 ? "" : "s")", set.key, tempo, set.source].compactMap { $0 })
            .joined(separator: " \u{B7} ")
    }
}
