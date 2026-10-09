import Foundation

public struct MediaImportDedupe: Sendable {
    public enum Match: Equatable, Sendable {
        case sameFile(id: String)
        case sameName(id: String, name: String)
        case new
    }

    private var byHash: [DocumentKind: [String: String]] = [:]
    private var byName: [DocumentKind: [String: (id: String, name: String)]] = [:]

    public init(media: [MediaItem], audio: [AudioItem]) {
        for item in media.sorted(by: { $0.id < $1.id }) {
            note(id: item.id, hash: item.fileHash, name: item.name, kind: .media)
        }
        for item in audio.sorted(by: { $0.id < $1.id }) {
            note(id: item.id, hash: item.fileHash, name: item.name, kind: .audio)
        }
    }

    public func match(hash: String, name: String, kind: DocumentKind) -> Match {
        if let id = byHash[kind]?[hash] {
            .sameFile(id: id)
        } else if let named = byName[kind]?[Self.key(name)] {
            .sameName(id: named.id, name: named.name)
        } else {
            .new
        }
    }

    public mutating func note(id: String, hash: String, name: String, kind: DocumentKind) {
        if byHash[kind]?[hash] == nil {
            byHash[kind, default: [:]][hash] = id
        }
        if byName[kind]?[Self.key(name)] == nil {
            byName[kind, default: [:]][Self.key(name)] = (id, name)
        }
    }

    private static func key(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespaces).lowercased()
    }
}
