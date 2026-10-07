import Foundation

public struct LibraryReader: Sendable {
    let store: DocumentStore
    let cache: LibraryValueCache

    init(store: DocumentStore, cache: LibraryValueCache) {
        self.store = store
        self.cache = cache
    }

    @concurrent
    public func loadValue<E: DocumentEntity>(_ type: E.Type, id: String) async throws -> E {
        let probe = probe(type, id: id)
        if let hit = cache.value(of: probe.key, stamp: probe.stamp) as? E {
            return hit
        } else {
            let decoded = try await store.loadValue(type, id: id)
            cache.fill(decoded, key: probe.key, stamp: probe.stamp, generation: probe.generation)
            return decoded
        }
    }

    @concurrent
    public func loadValues<E: DocumentEntity>(
        _ type: E.Type, ids: [String], priority: TaskPriority? = nil, width: Int = DocumentStore.decodeWidth
    ) async -> (values: [String: E], failed: Set<String>) {
        let loaded = await loadStampedValues(type, ids: ids, priority: priority, width: width)
        return (loaded.values.mapValues(\.value), loaded.failed)
    }

    @concurrent
    public func loadStampedValues<E: DocumentEntity>(
        _ type: E.Type, ids: [String], priority: TaskPriority? = nil, width: Int = DocumentStore.decodeWidth
    ) async -> (values: [String: ResidentTableFill<E>.Decoded], failed: Set<String>) {
        var values: [String: ResidentTableFill<E>.Decoded] = [:]
        var misses: [String: Probe] = [:]
        for id in Set(ids) {
            let probe = probe(type, id: id)
            if let hit = cache.value(of: probe.key, stamp: probe.stamp) as? E {
                values[id] = .init(value: hit, stamp: probe.stamp)
            } else {
                misses[id] = probe
            }
        }
        let decoded = await store.loadValues(type, ids: Array(misses.keys), priority: priority, width: width)
        for (id, value) in decoded.values {
            if let probe = misses[id] {
                cache.fill(value, key: probe.key, stamp: probe.stamp, generation: probe.generation)
            }
            values[id] = .init(value: value, stamp: misses[id]?.stamp)
        }
        return (values, decoded.failed)
    }

    @concurrent
    func loadReplicaParts<E: DocumentEntity>(_ type: E.Type, id: String) async throws -> ReplicaParts<E> {
        let parts = try await store.loadReplicaParts(type, id: id)
        cache.noteDocumentLoad()
        return parts
    }

    @concurrent
    func loadReplicaParts<E: DocumentEntity>(_ type: E.Type, ids: [String], width: Int) async -> [String: ReplicaParts<E>] {
        let loaded = await store.loadReplicaParts(type, ids: ids, width: width)
        for _ in loaded {
            cache.noteDocumentLoad()
        }
        return loaded
    }

    @concurrent
    public func exists(kind: DocumentKind, id: String) async -> Bool {
        store.exists(kind: kind, id: id)
    }

    @concurrent
    public func ids(of kind: DocumentKind) async throws -> [String] {
        try store.ids(of: kind)
    }

    @concurrent
    public func loadValues<E: DocumentEntity, Projection: Sendable>(
        _ type: E.Type, ids: [String], priority: TaskPriority? = nil, width: Int = DocumentStore.decodeWidth,
        project: @escaping @Sendable (E) -> Projection
    ) async -> (values: [String: Projection], failed: Set<String>) {
        await store.loadValues(type, ids: ids, priority: priority, width: width, project: project)
    }

    public func idsNow(of kind: DocumentKind) throws -> [String] {
        try store.ids(of: kind)
    }

    public func existsNow(kind: DocumentKind, id: String) -> Bool {
        store.exists(kind: kind, id: id)
    }

    struct Probe {
        var key: SyncLedger.Key
        var generation: Int
        var stamp: DocumentFileStamp?
    }

    private func probe<E: DocumentEntity>(_ type: E.Type, id: String) -> Probe {
        let key = SyncLedger.Key(kind: E.documentKind, id: id)
        let generation = cache.generation(of: key)
        return Probe(key: key, generation: generation, stamp: DocumentFileStamp.of(store.url(kind: key.kind, id: id)))
    }
}

extension LibraryReader: ResidentFillSource {
    @concurrent
    public func fillResidentTable<Entity: DocumentEntity>(
        _ type: Entity.Type, epoch: Int, known: [String: DocumentFileStamp]
    ) async -> ResidentTableFill<Entity> {
        await store.fillResidentTable(type, epoch: epoch, known: known)
    }
}
