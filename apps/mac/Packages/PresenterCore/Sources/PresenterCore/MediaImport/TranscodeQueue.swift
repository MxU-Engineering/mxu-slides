import AVFoundation
import Foundation

@MainActor
public struct TranscodeQueue {
    private let client: LibraryClient
    private let blobs: BlobStore

    public init(client: LibraryClient) throws {
        self.client = client
        blobs = try BlobStore(libraryRoot: client.rootURL)
    }

    @discardableResult
    public func drain() async -> [String: MediaFileStatus] {
        var results: [String: MediaFileStatus] = [:]
        let flagged = ((try? await client.settledSnapshot())?.entries(of: .media) ?? []).map(\.id)
        let values = (try? await client.loadValues(MediaItem.self, ids: flagged))?.values ?? [:]
        for id in flagged {
            if let item = values[id], item.fileStatus == .needsTranscode {
                results[id] = await transcode(item)
            }
        }
        return results
    }

    public func transcode(itemID: String) async -> MediaFileStatus {
        if let item = try? await client.loadValue(MediaItem.self, id: itemID) {
            return await transcode(item)
        } else {
            return .transcodeFailed
        }
    }

    private func transcode(_ item: MediaItem) async -> MediaFileStatus {
        let client = client
        let id = item.id
        func finish(_ status: MediaFileStatus, detail: String, newHash: String? = nil) async -> MediaFileStatus {
            _ = await client.modify(MediaItem.self, id: id) {
                $0.fileStatus = status
                $0.statusDetail = detail
                if let newHash { $0.fileHash = newHash }
            }.result
            return status
        }

        guard let sourceURL = blobs.url(forHash: item.fileHash) else {
            return await finish(.transcodeFailed, detail: "blob missing: \(item.fileHash)")
        }
        _ = await finish(.transcoding, detail: "")

        let asset = AVURLAsset(url: sourceURL)
        let hasAlpha = await Self.carriesAlpha(asset)
        let preset = hasAlpha
            ? AVAssetExportPresetHEVCHighestQualityWithAlpha
            : AVAssetExportPresetHEVCHighestQuality
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            return await finish(.transcodeFailed, detail: "no HEVC export path for this file")
        }
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mov")
        do {
            try await session.export(to: outputURL, as: .mov)
            let newHash = try blobs.adopt(fileURL: outputURL)
            return await finish(.ready, detail: "", newHash: newHash)
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            return await finish(.transcodeFailed, detail: error.localizedDescription)
        }
    }

    private static func carriesAlpha(_ asset: AVURLAsset) async -> Bool {
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let descriptions = try? await track.load(.formatDescriptions)
        else { return false }
        return descriptions.contains { description in
            if let contains = CMFormatDescriptionGetExtension(
                description, extensionKey: kCMFormatDescriptionExtension_ContainsAlphaChannel
            ) as? Bool {
                return contains
            }
            let subType = CMFormatDescriptionGetMediaSubType(description)
            return subType == kCMVideoCodecType_AppleProRes4444
                || subType == kCMVideoCodecType_AppleProRes4444XQ
        }
    }
}
