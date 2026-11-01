import Foundation
import LocalAPI
import PresenterCore

@MainActor
enum FollowFileCopy {

    static let copiedKey = "follow.copiedItems"

    static func offered(_ model: AppModel) async throws -> FollowFiles.List {
        let snapshot = try await model.client.settledSnapshot()
        let blobs = model.blobs
        var items: [FollowFiles.Item] = []
        for kind in FollowCopy.kinds {
            let ids = snapshot.entries(of: kind).map(\.id).filter { snapshot.area(kind: kind, id: $0) == .local }
            guard !ids.isEmpty else { continue }
            let files: [String: String] = switch kind {
            case .media: (try? await model.client.loadValues(MediaItem.self, ids: ids).values.mapValues(\.fileHash)) ?? [:]
            case .audio: (try? await model.client.loadValues(AudioItem.self, ids: ids).values.mapValues(\.fileHash)) ?? [:]
            default: [:]
            }
            for id in ids {
                guard let heads = try await model.client.localHeads(kind: kind, id: id) else { continue }
                let file = files[id].flatMap { FollowFiles.isHash($0) ? $0 : nil }
                let ext = file.flatMap { blobs?.url(forHash: $0)?.pathExtension }
                items.append(FollowFiles.Item(kind: kind.rawValue, id: id, heads: heads, file: ext == nil ? nil : file, ext: ext))
            }
        }
        return FollowFiles.List(items: items)
    }

    static func document(_ model: AppModel, kind: String, id: String) async throws -> FollowFiles.Document {
        guard let kind = DocumentKind(rawValue: kind), FollowCopy.kinds.contains(kind),
              (try await model.client.settledSnapshot()).area(kind: kind, id: id) == .local,
              let bytes = try await model.client.documentBytes(kind: kind, id: id) else {
            throw APIError.notFound("Not a This Mac only item here.")
        }
        return FollowFiles.Document(bytes: bytes)
    }

    static func copy(from endpoint: LocalAPIClient.Endpoint, model: AppModel) async throws -> Int {
        let list = try await get(FollowFiles.List.self, "/v1/follow/files", endpoint)
        var heads: [String: [String]] = [:]
        for item in list.items {
            if let kind = DocumentKind(rawValue: item.kind), let held = try? await model.client.localHeads(kind: kind, id: item.id) {
                heads["\(item.kind)/\(item.id)"] = held
            }
        }
        guard let blobs = model.blobs else { return 0 }
        let hashes = list.items.compactMap(\.file)
        let here = await Task.detached(priority: .utility) { blobs.presence(forHashes: hashes) }.value
        let wanted = FollowFiles.wanted(list.items, heads: heads, filesHere: here)
        let exts = Dictionary(list.items.compactMap { item in item.file.map { ($0, item.ext ?? "") } }, uniquingKeysWith: { first, _ in first })

        for hash in wanted.files {
            try await download(hash, ext: exts[hash] ?? "", from: endpoint, into: blobs)
            model.noteBlobsChanged(arrived: hash)
        }
        for item in wanted.documents {
            guard let kind = DocumentKind(rawValue: item.kind), FollowCopy.kinds.contains(kind) else { continue }
            let document = try await get(FollowFiles.Document.self, "/v1/follow/files/\(item.kind)/\(item.id)", endpoint)
            try await model.client.mergeCopy(kind: kind, id: item.id, bytes: document.bytes).value
        }

        let copied = Set(UserDefaults.standard.stringArray(forKey: copiedKey) ?? [])
        let snapshot = try await model.client.settledSnapshot()
        let gone: [SyncLedger.Key] = FollowFiles.gone(copied: copied, booth: list.items).compactMap { key in
            let parts = key.split(separator: "/", maxSplits: 1).map(String.init)
            guard parts.count == 2, let kind = DocumentKind(rawValue: parts[0]), snapshot.area(kind: kind, id: parts[1]) == .local else { return nil }
            return SyncLedger.Key(kind: kind, id: parts[1])
        }
        if !gone.isEmpty { _ = try await model.client.delete(gone, origin: .landed).value }

        let held = list.items.map { "\($0.kind)/\($0.id)" }
        if Set(held) != copied { UserDefaults.standard.set(held, forKey: copiedKey) }
        if !wanted.documents.isEmpty || !wanted.files.isEmpty || !gone.isEmpty {
            DiagnosticsStore.shared.note("follow.copied", detail: "\(wanted.documents.count) items, \(wanted.files.count) files, \(gone.count) removed")
        }
        return wanted.documents.count
    }

    private nonisolated static func download(_ hash: String, ext: String, from endpoint: LocalAPIClient.Endpoint, into blobs: BlobStore) async throws {
        let (temp, response) = try await URLSession.shared.download(for: request("/v1/follow/blobs/\(hash)", endpoint))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }

        try await Task.detached(priority: .utility) {
            let named = temp.deletingLastPathComponent().appendingPathComponent(ext.isEmpty ? hash : "\(hash).\(ext)")
            try? FileManager.default.removeItem(at: named)
            try FileManager.default.moveItem(at: temp, to: named)
            guard try BlobStore.sha256(of: named) == hash else {
                try? FileManager.default.removeItem(at: named)
                throw CocoaError(.fileReadCorruptFile)
            }
            _ = try blobs.adopt(fileURL: named)
        }.value
    }

    private nonisolated static func get<T: Decodable>(_ type: T.Type, _ path: String, _ endpoint: LocalAPIClient.Endpoint) async throws -> T {
        let (data, response) = try await URLSession.shared.data(for: request(path, endpoint))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(type, from: data)
    }

    private nonisolated static func request(_ path: String, _ endpoint: LocalAPIClient.Endpoint) -> URLRequest {
        var request = URLRequest(url: URL(string: "http://\(endpoint.host):\(endpoint.port)\(path)")!, timeoutInterval: 30)
        request.setValue("Bearer \(endpoint.token)", forHTTPHeaderField: "Authorization")
        return request
    }
}
