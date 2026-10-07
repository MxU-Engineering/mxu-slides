import AppKit
import PresenterCore
import SwiftUI

struct LocateMissingMediaView: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var missing: [MediaItem] = []
    @State private var tombstones: [MediaItem] = []
    @State private var scanning = false
    @State private var scanSummary: String?

    @State private var carriedNotes: [String: [String]] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Locate Missing Media")
                .font(.title3.weight(.semibold))
            Text(
                "Scan a folder and exact copies relink automatically — matching is by file content, so names don't matter. Anything unmatched can be restored by hand with any file."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            List {
                if missing.isEmpty && tombstones.isEmpty {
                    Text("Nothing is missing.").foregroundStyle(.secondary)
                }
                if !missing.isEmpty {
                    Section("Files missing on this Mac") {
                        ForEach(missing) { row($0, tombstone: false) }
                    }
                }
                if !tombstones.isEmpty {
                    Section("Deleted items still in use") {
                        ForEach(tombstones) { row($0, tombstone: true) }
                    }
                }
            }
            HStack(spacing: 10) {
                Button("Scan Folder…") { scanFolder() }
                    .disabled(scanning || (missing.isEmpty && tombstones.isEmpty))
                if scanning { ProgressView().controlSize(.small) }
                if let scanSummary {
                    Text(scanSummary).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 580, height: 440)
        .onAppear(perform: refresh)
    }

    @ViewBuilder
    private func row(_ item: MediaItem, tombstone: Bool) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                Text(tombstone ? "\(item.fileName) — deleted, still used somewhere" : item.fileName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let carried = carriedNotes[item.id], !carried.isEmpty {
                    Text("Check \(carried.joined(separator: ", ")) — carried over from the old file.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            Spacer()
            Button("Choose File…") { chooseFile(for: item, tombstone: tombstone) }
        }
        .padding(.vertical, 2)
    }

    private func refresh() {
        Task { @MainActor in
            let targets = await model.missingMediaTargets()
            missing = targets.missing
            tombstones = targets.tombstones
        }
    }

    private func scanFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Scan"
        panel.begin { response in
            guard response == .OK, let folder = panel.url else { return }
            scanning = true
            Task { @MainActor in
                let result = await model.locateMissingMedia(in: folder)
                scanning = false
                let total = result.relinked + result.restored
                scanSummary = total == 0
                    ? "No exact matches in that folder."
                    : "Relinked \(total) item\(total == 1 ? "" : "s")."
                refresh()
            }
        }
    }

    private func chooseFile(for item: MediaItem, tombstone: Bool) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image, .movie]
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                let carried = tombstone
                    ? await model.restoreMediaTombstone(item, with: url)
                    : await model.replaceMediaFile(item.id, with: url)
                if let carried { carriedNotes[item.id] = carried }
                refresh()
            }
        }
    }
}

@MainActor
enum MediaRelinkAlerts {
    static func carriedSettingsWarning(itemName: String, carried: [String]) {
        guard !carried.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = "Settings carried over"
        alert.informativeText =
            "\u{201C}\(itemName)\u{201D} kept \(carried.joined(separator: ", ")) from the old file — worth a check against the new one."
        alert.runModal()
    }
}
