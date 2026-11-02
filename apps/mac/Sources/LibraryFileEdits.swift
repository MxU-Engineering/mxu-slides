import Foundation
import PresenterCore

@MainActor
final class LibraryFileEdits {
    nonisolated static let settle: TimeInterval = 10
    private weak var model: AppModel?
    private var watcher: FolderEventStream?
    private var scanTask: Task<Void, Never>?
    private var scanning = false

    init(model: AppModel, blobs: BlobStore) {
        self.model = model
        watcher = FolderEventStream(folder: blobs.directory) { [weak self] in self?.schedule() }
        schedule(after: .zero)
    }

    private func schedule(after delay: Duration = .seconds(2)) {
        scanTask?.cancel()
        scanTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            if !Task.isCancelled { await self?.scan() }
        }
    }

    private func scan() async {
        guard let model, let blobs = model.blobs, !scanning else { return }
        scanning = true
        defer { scanning = false }
        let found = await Self.editedFiles(in: blobs)
        if !found.settled.isEmpty {
            await model.resident.ready([.media, .audio])
            for (hash, url) in found.settled {
                let current = await Self.sha256(of: url)
                if current == hash || current == nil {
                    await Self.stampKnown(url)
                } else if await model.adoptChangedFile(from: hash, at: url) {
                    DiagnosticsStore.shared.note("library.edit", detail: "\(url.lastPathComponent) edited, re-added as \(current ?? "")")
                } else {
                    await Self.stampKnown(url)
                }
            }
        }
        if found.settling { schedule(after: .seconds(Self.settle)) }
    }

    @concurrent
    nonisolated private static func editedFiles(in blobs: BlobStore) async -> (settled: [(hash: String, url: URL)], settling: Bool) {
        blobs.editedFiles(settle: settle)
    }

    @concurrent
    nonisolated private static func sha256(of url: URL) async -> String? {
        try? BlobStore.sha256(of: url)
    }

    @concurrent
    nonisolated private static func stampKnown(_ url: URL) async {
        BlobStore.stampKnown(url)
    }
}
