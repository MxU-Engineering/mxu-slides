import AVFoundation
import Foundation

public enum RecordingLibrary {

    public static let defaultFolder = "Recordings"

    public static func spoolDirectory(libraryRoot: URL) -> URL {
        let url = libraryRoot.appendingPathComponent("spool", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @MainActor
    @discardableResult
    public static func adopt(
        fileURL: URL,
        client: LibraryClient,
        folder: String,
        recordedAt: Date,
        presetId: String?,
        alsoCopyTo exportFolder: URL? = nil
    ) async throws -> MediaItem {
        let blobs = try BlobStore(libraryRoot: client.rootURL)
        let probe = await MediaImporter.probeVideo(AVURLAsset(url: fileURL))
        let fileName = fileURL.lastPathComponent
        let hash = try await Task.detached(priority: .userInitiated) {
            let hash = try blobs.adopt(fileURL: fileURL)
            if let exportFolder, let blob = blobs.url(forHash: hash) {
                try? FileManager.default.createDirectory(
                    at: exportFolder, withIntermediateDirectories: true)
                try? FileManager.default.copyItem(
                    at: blob, to: exportFolder.appendingPathComponent(fileName))
            }
            return hash
        }.value
        let item = MediaItem(
            id: UUID().uuidString,
            name: fileURL.deletingPathExtension().lastPathComponent,
            mediaKind: .video,
            classification: .foreground,
            fileHash: hash,
            fileName: fileURL.lastPathComponent,
            fileStatus: probe.status,
            statusDetail: probe.detail,
            tags: [], favorite: false, collections: [], loops: false,
            inPoint: nil, outPoint: nil,
            durationSeconds: probe.duration,
            pixelWidth: probe.width,
            pixelHeight: probe.height,
            folder: folder.isEmpty ? nil : folder,
            recordedAt: recordedAt.timeIntervalSince1970,
            recordedByPresetId: presetId
        )
        _ = try await client.create(item).value
        return item
    }

    public static func latestRecording(
        in items: [MediaItem], folder: String, notBefore: Date? = nil
    ) -> MediaItem? {
        items
            .filter {
                guard let recordedAt = $0.recordedAt, $0.fileStatus == .ready,
                      inSubtree($0.folder, of: folder)
                else { return false }
                if let notBefore, recordedAt < notBefore.timeIntervalSince1970 {
                    return false
                }
                return true
            }
            .max { ($0.recordedAt ?? 0) < ($1.recordedAt ?? 0) }
    }

    static func inSubtree(_ itemFolder: String?, of folder: String) -> Bool {
        let item = itemFolder ?? ""
        if folder.isEmpty { return true }
        return item == folder || item.hasPrefix(folder + "/")
    }
}
