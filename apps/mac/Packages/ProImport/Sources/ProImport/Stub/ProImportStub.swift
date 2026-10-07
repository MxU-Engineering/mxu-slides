import Foundation
import PresenterCore

let proImportUnavailable =
    "ProPresenter import isn't available in this build — run apps/mac/scripts/generate-propresenter-proto.sh and rebuild."

@MainActor
public struct ProPresenterImporter {
    public init(client: LibraryClient, placement: LibraryHome.Placement = .unplaced) throws {}

    public func importItems(
        at urls: [URL], folder: String? = "ProPresenter Import",
        policy: ImportConflictPolicy = .updateUnedited,
        onDocument: ((URL) -> Void)? = nil
    ) async -> [DocumentSummary] {
        urls.map {
            DocumentSummary(
                sourceURL: $0, presentationID: nil, name: $0.lastPathComponent,
                warnings: [proImportUnavailable], mediaImported: 0
            )
        }
    }

    public func importPlaylistBundle(at url: URL, folder: String? = "ProPresenter Import") async -> PlaylistBundleSummary {
        var summary = PlaylistBundleSummary()
        summary.failureReason = proImportUnavailable
        return summary
    }

    public func importTheme(at url: URL, policy: ImportConflictPolicy = .updateUnedited) async -> ProThemeImportSummary {
        ProThemeImportSummary(
            sourceURL: url, themeID: nil, name: url.deletingPathExtension().lastPathComponent,
            warnings: [proImportUnavailable], mediaImported: 0
        )
    }
}

@MainActor
public struct ProWorkspaceImporter {
    public init(client: LibraryClient) async throws {}

    public func scan(showDirectory: URL) -> WorkspaceScan { WorkspaceScan() }

    public func importWorkspace(
        showDirectory: URL,
        existingTimers: [ProTimerSeed] = [],
        existingInputs: [ProInputSeed] = [],
        options: WorkspaceImportOptions = WorkspaceImportOptions(),
        progress: ProImportProgressHandler? = nil
    ) async -> Result {
        var result = Result()
        result.warnings = [proImportUnavailable]
        return result
    }
}
