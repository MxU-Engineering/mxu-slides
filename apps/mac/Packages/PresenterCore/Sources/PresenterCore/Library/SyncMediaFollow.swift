import Foundation

public enum SyncMediaFollow {

    public static let referencingKinds: [DocumentKind] = [
        .presentation, .service, .overlay, .theme, .confidenceLayout, .playlist, .actionCombo,
    ]

    public static let mediaKinds: [DocumentKind] = [.media, .audio]

    public static func toMove(
        references: [SyncLedger.Key: Set<String>], snapshot: IndexSnapshot, sync: LibrarySyncState
    ) -> [SyncLedger.Key] {
        let used = references
            .filter { referencingKinds.contains($0.key.kind) && snapshot.area(kind: $0.key.kind, id: $0.key.id) == .team }
            .values.reduce(into: Set<String>()) { $0.formUnion($1) }
        return candidates(used, snapshot: snapshot, sync: sync)
    }

    public static func candidates(_ ids: Set<String>, snapshot: IndexSnapshot, sync: LibrarySyncState) -> [SyncLedger.Key] {
        held(ids, in: .station, snapshot: snapshot, sync: sync)
    }

    private static func held(_ ids: Set<String>, in wanted: LibraryArea, snapshot: IndexSnapshot, sync: LibrarySyncState) -> [SyncLedger.Key] {
        ids.sorted().compactMap { id in
            snapshot.entry(id: id).flatMap { entry in
                mediaKinds.contains(entry.kind) && area(of: SyncLedger.Key(kind: entry.kind, id: id), snapshot: snapshot, sync: sync) == wanted
                    ? SyncLedger.Key(kind: entry.kind, id: id) : nil
            }
        }
    }

    public static func toAsk(
        references: [SyncLedger.Key: Set<String>], known: [SyncLedger.Key: Set<String>], snapshot: IndexSnapshot, sync: LibrarySyncState
    ) -> (documents: [SyncLedger.Key], media: [SyncLedger.Key]) {
        var documents: [SyncLedger.Key] = []
        var media: Set<SyncLedger.Key> = []
        for (document, ids) in references.sorted(by: { ($0.key.kind.rawValue, $0.key.id) < ($1.key.kind.rawValue, $1.key.id) })
        where referencingKinds.contains(document.kind) && snapshot.area(kind: document.kind, id: document.id) == .team {
            let local = held(ids.subtracting(known[document] ?? []), in: .local, snapshot: snapshot, sync: sync)
            if !local.isEmpty {
                documents.append(document)
                media.formUnion(local)
            }
        }
        return (documents, media.sorted { ($0.kind.rawValue, $0.id) < ($1.kind.rawValue, $1.id) })
    }

    public static func area(of key: SyncLedger.Key, snapshot: IndexSnapshot, sync: LibrarySyncState) -> LibraryArea {
        LibraryArea.resolve(
            row: snapshot.area(kind: key.kind, id: key.id), entry: sync.entry(kind: key.kind, id: key.id))
    }

    @concurrent
    public static func references(of keys: [SyncLedger.Key], reader: LibraryReader) async -> [SyncLedger.Key: Set<String>] {
        var out: [SyncLedger.Key: Set<String>] = [:]
        for kind in referencingKinds {
            let ids = keys.filter { $0.kind == kind }.map(\.id)
            if !ids.isEmpty {
                out.merge(await references(SyncScope.entityType(for: kind), ids: ids, reader: reader)) { $1 }
            }
        }
        return out
    }

    public static func teamDocuments(in snapshot: IndexSnapshot) -> [SyncLedger.Key] {
        referencingKinds.flatMap { kind in
            snapshot.entries(of: kind).map { SyncLedger.Key(kind: kind, id: $0.id) }.filter { snapshot.area(kind: kind, id: $0.id) == .team }
        }
    }

    @concurrent
    private static func references<E: DocumentEntity>(_ type: E.Type, ids: [String], reader: LibraryReader) async -> [SyncLedger.Key: Set<String>] {
        let found = await reader.loadValues(type, ids: ids, priority: .utility) { MediaReferences.ids(inDocument: $0) ?? [] }
        return found.values.reduce(into: [:]) { out, pair in
            if !pair.value.isEmpty { out[SyncLedger.Key(kind: E.documentKind, id: pair.key)] = pair.value }
        }
    }

    public static func saved(in batch: LibraryBatch) -> [DocumentChange] {
        batch.changes.filter { $0.origin == .local && $0.value != nil && referencingKinds.contains($0.kind) }
    }

    @concurrent
    public static func references(in changes: [DocumentChange]) async -> [SyncLedger.Key: Set<String>] {
        changes.reduce(into: [:]) { out, change in
            if let value = change.value, let ids = MediaReferences.ids(inDocument: value), !ids.isEmpty {
                out[change.key] = ids
            }
        }
    }

    public struct Owed: Equatable, Sendable {
        public private(set) var documents: Set<SyncLedger.Key> = []

        public init() {}

        public mutating func offer(_ keys: [SyncLedger.Key], waiting: Bool) -> [SyncLedger.Key] {
            if waiting {
                documents.formUnion(keys)
                return []
            } else {
                return keys
            }
        }

        public mutating func release() -> [SyncLedger.Key] {
            let owed = documents.sorted { ($0.kind.rawValue, $0.id) < ($1.kind.rawValue, $1.id) }
            documents = []
            return owed
        }
    }
}

public enum SyncTombstoneScope {
    public static func applies(from stream: SyncScope, held: Bool, currentNamespace: SyncScope?) -> Bool {
        !held || currentNamespace == stream
    }
}

public enum SyncMoveRace {
    public static func movedSinceRead(_ key: SyncLedger.Key, movedAtRead: Set<SyncLedger.Key>, movedNow: Set<SyncLedger.Key>) -> Bool {
        movedNow.contains(key) && !movedAtRead.contains(key)
    }
}
