import Foundation

@MainActor
public final class ImportMediaResolver {
    public struct Resolution {
        public var idMap: [String: String] = [:]

        public var audioIDs: Set<String> = []

        public var importedIDs: Set<String> = []
        public var warnings: [String] = []
        public var imported = 0

        public var withheld = 0
    }

    private let mediaImporter: MediaImporter

    private let placement: LibraryHome.Placement
    private var mediaByHash: [String: String]
    private var audioByHash: [String: String]

    public init(client: LibraryClient, placement: LibraryHome.Placement = .unplaced) async throws {
        mediaImporter = try MediaImporter(client: client)
        self.placement = placement
        let index = try await client.settledSnapshot()
        let media = index.entries(of: .media).map(\.id)
        let audio = index.entries(of: .audio).map(\.id)
        let mediaHashes = try await client.loadValues(MediaItem.self, ids: media).values.mapValues(\.fileHash)
        let audioHashes = try await client.loadValues(AudioItem.self, ids: audio).values.mapValues(\.fileHash)
        mediaByHash = Self.firstByHash(media, hashes: mediaHashes)
        audioByHash = Self.firstByHash(audio, hashes: audioHashes)
    }

    private static func firstByHash(_ ids: [String], hashes: [String: String]) -> [String: String] {
        var map: [String: String] = [:]
        for id in ids {
            if let hash = hashes[id], map[hash] == nil {
                map[hash] = id
            }
        }
        return map
    }

    public func resolve(
        _ wants: [MediaWant],
        sourceFileURL: URL,
        bundleRoot: URL? = nil,
        showDirectory: URL? = nil,
        importNew: Bool = true
    ) async -> Resolution {
        var resolution = Resolution()
        for want in wants {
            let candidates = candidates(for: want, sourceFileURL: sourceFileURL, bundleRoot: bundleRoot, showDirectory: showDirectory)
            guard let fileURL = candidates.first(where: { FileManager.default.isReadableFile(atPath: $0.path) }) else {
                if let name = (want.absolutePath ?? want.relativePath).map({ URL(fileURLWithPath: $0).lastPathComponent }) {
                    resolution.warnings.append("media not found: \(name)")
                } else {
                    resolution.warnings.append("a media reference carried no file path (web or other non-file content) and was skipped")
                }
                continue
            }

            let hash = try? await Task.detached(priority: .userInitiated) {
                try BlobStore.sha256(of: fileURL)
            }.value
            if let hash {
                if let existing = mediaByHash[hash] {
                    resolution.idMap[want.placeholderID] = existing
                    continue
                }
                if let existing = audioByHash[hash] {
                    resolution.idMap[want.placeholderID] = existing
                    resolution.audioIDs.insert(existing)
                    continue
                }
            }
            if !importNew {
                resolution.withheld += 1
                continue
            }
            let results = await mediaImporter.importFiles(at: [fileURL], placement: placement)
            if case .media(let id, _)? = results.first?.outcome {
                resolution.idMap[want.placeholderID] = id
                resolution.importedIDs.insert(id)
                resolution.imported += 1
                if let hash { mediaByHash[hash] = id }
            } else if case .audio(let id)? = results.first?.outcome {

                resolution.idMap[want.placeholderID] = id
                resolution.audioIDs.insert(id)
                resolution.importedIDs.insert(id)
                resolution.imported += 1
                if let hash { audioByHash[hash] = id }
            } else if case .skipped(let reason)? = results.first?.outcome {
                resolution.warnings.append("media skipped (\(fileURL.lastPathComponent)): \(reason)")
            }
        }
        return resolution
    }

    private func candidates(for want: MediaWant, sourceFileURL: URL, bundleRoot: URL?, showDirectory: URL?) -> [URL] {
        var candidates: [URL] = []
        if let absolute = want.absolutePath {

            if let bundleRoot {
                candidates.append(bundleRoot.appendingPathComponent(String(absolute.drop(while: { $0 == "/" }))))
            }
            candidates.append(URL(fileURLWithPath: absolute))
        }
        if let relative = want.relativePath {
            if let showDirectory {
                candidates.append(showDirectory.appendingPathComponent(relative))
            } else {

                let guess = sourceFileURL
                    .deletingLastPathComponent()
                    .deletingLastPathComponent()
                    .deletingLastPathComponent()
                candidates.append(guess.appendingPathComponent(relative))
            }
            candidates.append(sourceFileURL.deletingLastPathComponent().appendingPathComponent(relative))
        }
        return candidates
    }
}
