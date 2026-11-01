import Foundation

public enum FollowCopy {

    public static let kinds: [DocumentKind] = Library.listedKinds.filter { SyncScope.scope(for: $0) == .team || setupKinds.contains($0) }

    public static let setupKinds: Set<DocumentKind> = [.outputPreset, .streamRecordPreset, .streamDestination]

    public static func offered(_ area: LibraryArea?) -> String? {
        area == .team ? LibraryArea.team.rawValue : nil
    }

    public static func landing(_ offered: String?) -> LibraryArea {
        offered == LibraryArea.team.rawValue ? .team : .local
    }

    public static func area(_ landing: LibraryArea, here: LibraryArea?) -> LibraryArea {
        guard let here else { return landing }
        return here == .local && landing == .team ? .team : here
    }
}

extension LibraryEngine {

    public func documentBytes(kind: DocumentKind, id: String) throws -> Data? {
        try documentBytes(SyncScope.entityType(for: kind), id: id)
    }

    private func documentBytes<E: DocumentEntity>(_ type: E.Type, id: String) throws -> Data? {
        try opened().store.exists(kind: E.documentKind, id: id) ? replica(type, id: id).save() : nil
    }

    @discardableResult
    public func mergeCopy(kind: DocumentKind, id: String, bytes: Data, area: LibraryArea = .local) throws -> LibraryBatch {
        try mergeCopy(SyncScope.entityType(for: kind), id: id, bytes: bytes, area: area)
    }

    private func mergeCopy<E: DocumentEntity>(_ type: E.Type, id: String, bytes: Data, area: LibraryArea) throws -> LibraryBatch {
        let theirs = try TypedDocument<E>(data: bytes)
        guard theirs.value.id == id else { throw CocoaError(.fileReadCorruptFile) }
        let listed = Library.listedKinds.contains(E.documentKind)
        return try publishing {
            let held = try opened().store.exists(kind: E.documentKind, id: id)
            let here = held ? try opened().index.area(kind: E.documentKind, id: id) ?? .default : nil
            let landing = FollowCopy.area(area, here: here)
            if landing != here {
                try recordArea(landing, key: SyncLedger.Key(kind: E.documentKind, id: id), origin: .landed)
            }
            if held {
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
    public func mergeCopy(kind: DocumentKind, id: String, bytes: Data, area: LibraryArea = .local) -> Task<LibraryBatch, any Error> {
        enqueue(nil) { [engine] in try engine.mergeCopy(kind: kind, id: id, bytes: bytes, area: area) }
    }
}
