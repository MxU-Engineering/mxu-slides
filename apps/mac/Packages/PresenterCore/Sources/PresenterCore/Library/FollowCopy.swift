import Foundation

public enum FollowCopy {

    public static let kinds: [DocumentKind] = Library.listedKinds.filter { SyncScope.scope(for: $0) == .team }
}

extension LibraryEngine {

    public func documentBytes(kind: DocumentKind, id: String) throws -> Data? {
        try documentBytes(SyncScope.entityType(for: kind), id: id)
    }

    private func documentBytes<E: DocumentEntity>(_ type: E.Type, id: String) throws -> Data? {
        try opened().store.exists(kind: E.documentKind, id: id) ? replica(type, id: id).save() : nil
    }

    @discardableResult
    public func mergeCopy(kind: DocumentKind, id: String, bytes: Data) throws -> LibraryBatch {
        try mergeCopy(SyncScope.entityType(for: kind), id: id, bytes: bytes)
    }

    private func mergeCopy<E: DocumentEntity>(_ type: E.Type, id: String, bytes: Data) throws -> LibraryBatch {
        let theirs = try TypedDocument<E>(data: bytes)
        guard theirs.value.id == id else { throw CocoaError(.fileReadCorruptFile) }
        let listed = Library.listedKinds.contains(E.documentKind)
        return try publishing {
            try recordArea(.local, key: SyncLedger.Key(kind: E.documentKind, id: id), origin: .landed)
            if try opened().store.exists(kind: E.documentKind, id: id) {
                let mine = try replica(type, id: id)
                try mine.merge(theirs)
                try persist(mine, origin: .landed, listed: listed)
            } else {
                try persist(theirs, origin: .landed, listed: listed)
            }
        }
    }
}

extension LibraryClient {

    public func documentBytes(kind: DocumentKind, id: String) async throws -> Data? {
        try await afterQueued { engine in try engine.documentBytes(kind: kind, id: id) }.value
    }

    @discardableResult
    public func mergeCopy(kind: DocumentKind, id: String, bytes: Data) -> Task<LibraryBatch, any Error> {
        enqueue(nil) { [engine] in try engine.mergeCopy(kind: kind, id: id, bytes: bytes) }
    }
}
