import Foundation

@globalActor public actor LibraryActor {
    public static let shared = LibraryActor()
}

@LibraryActor public final class LibraryEngine {
    public enum EngineError: Error, Equatable {

        case notBootstrapped
    }

    public struct Start: Sendable {
        public let snapshot: IndexSnapshot
        public let sync: LibrarySyncState
        public let batches: AsyncStream<LibraryBatch>
        public let reader: LibraryReader
    }

    public enum Tombstone: Sendable {

        case untracked

        case editWins

        case removed(LibraryBatch)
    }

    public let rootURL: URL
    public let limits: LibraryCacheLimits

    public private(set) var snapshot = IndexSnapshot.empty

    public private(set) var sync = LibrarySyncState.empty

    private var library: Library?
    private var store: DocumentStore?
    private var index: LibraryIndex?
    private var mirror = LibraryIndexMirror()

    var replicas = LibraryReplicaCache(perKind: 1)

    var editors = LibraryEditorSessions()
    private let valueCache: LibraryValueCache
    private let batches: AsyncStream<LibraryBatch>
    private let continuation: AsyncStream<LibraryBatch>.Continuation
    private(set) var sequence = 0

    private var pendingChanges: [DocumentChange] = []
    private var pendingMoves: [AreaMove] = []

    private var pendingSidecar = false

    private var author: ChangeAuthor?

    private var recordedHeads: [SyncLedger.Key: [String]] = [:]

    public nonisolated init(rootURL: URL, limits: LibraryCacheLimits = .standard) {
        self.rootURL = rootURL
        self.limits = limits
        valueCache = LibraryValueCache(perKind: limits.valuesPerKind)
        let (stream, continuation) = AsyncStream.makeStream(of: LibraryBatch.self)
        batches = stream
        self.continuation = continuation
    }

    deinit {
        continuation.finish()
    }

    @discardableResult
    public func bootstrap(preparing: (@LibraryActor @Sendable (Library) throws -> Void)? = nil) throws -> Start {
        if store == nil {
            let library = try Library(rootURL: rootURL)
            try preparing?(library)
            replicas = LibraryReplicaCache(perKind: limits.replicasPerKind, warmPerKind: limits.warmPerKind)
            mirror = try LibraryIndexMirror.read(library.index)
            sync = try LibrarySyncState.read(library.index)
            recordedHeads = try library.index.allDocumentHeads()
            snapshot = mirror.snapshot(generation: library.index.writeGeneration)
            self.library = library
            store = library.store
            index = library.index
        }
        return Start(snapshot: snapshot, sync: sync, batches: batches, reader: try reader())
    }

    public func reader() throws -> LibraryReader {
        LibraryReader(store: try opened().store, cache: valueCache)
    }

    public func setAuthor(_ author: ChangeAuthor?) {
        self.author = author
    }

    public var currentAuthor: ChangeAuthor? { author }

    @discardableResult
    public func save<E: DocumentEntity>(_ document: sending TypedDocument<E>, origin: ChangeOrigin = .local) throws -> LibraryBatch {
        try publishing {
            try persist(document, origin: origin)
        }
    }

    @discardableResult
    public func create<E: DocumentEntity>(
        _ value: E, seed: TypedDocument<E>.SeedIdentity? = nil, area: LibraryArea? = nil, origin: ChangeOrigin = .local
    ) throws -> LibraryBatch {
        try publishing {
            try persist(try made(value, seed: seed), origin: origin)
            try home(area, key: SyncLedger.Key(kind: E.documentKind, id: value.id))
        }
    }

    @discardableResult
    public func modify<E: DocumentEntity>(
        _ type: E.Type, id: String, origin: ChangeOrigin = .local, _ mutate: (inout E) throws -> Void
    ) throws -> LibraryBatch {
        try publishing {
            let document = try replica(type, id: id)
            try document.update(mutate)
            try persist(document, origin: origin)
        }
    }

    @discardableResult
    public func write(
        _ presentationID: String, origin: ChangeOrigin = .local, next: (inout [Slide]) throws -> Void
    ) throws -> LibraryBatch {
        try publishing {
            let document = try replica(Presentation.self, id: presentationID)
            try document.updateSlideList(next)
            try persist(document, origin: origin)
        }
    }

    @discardableResult
    public func commit<E: DocumentEntity>(
        _ type: E.Type, id: String, changes: Data, token: EditorToken? = nil, origin: ChangeOrigin = .local
    ) throws -> LibraryBatch {
        if editors.hasEnded(token) {
            throw EditorError.sessionEnded
        } else {
            return try publishing {
                let document = try replica(type, id: id)
                try document.applyEncodedChanges(changes)
                try persist(document, origin: origin)
            }
        }
    }

    @discardableResult
    public func delete(kind: DocumentKind, id: String, origin: ChangeOrigin = .deleted) throws -> LibraryBatch {
        try delete([SyncLedger.Key(kind: kind, id: id)], origin: origin)
    }

    @discardableResult
    public func delete(_ documents: [SyncLedger.Key], origin: ChangeOrigin = .deleted) throws -> LibraryBatch {
        try publishing {
            try removeDocuments(documents, origin: origin)
        }
    }

    @discardableResult
    public func setArea(_ area: LibraryArea, of documents: [SyncLedger.Key], origin: ChangeOrigin = .local) throws -> LibraryBatch {
        try publishing {
            for key in documents {
                try recordArea(area, key: key, origin: origin)
            }
        }
    }

    @discardableResult
    public func setAreaIfAbsent(_ area: LibraryArea, of key: SyncLedger.Key) throws -> LibraryArea {
        let standing = mirror.area(kind: key.kind, id: key.id)
        if standing == nil {
            _ = try publishing {
                try recordArea(area, key: key, origin: .landed)
            }
        }
        return standing ?? area
    }

    public func restoreFlippedAreas(_ keys: [SyncLedger.Key]) throws -> [SyncLedger.Key] {
        var restored: [SyncLedger.Key] = []
        _ = try publishing {
            for key in keys where mirror.area(kind: key.kind, id: key.id) == .station {
                try recordArea(.team, key: key, origin: .landed)
                pendingSidecar = true
                try opened().index.removeSyncEntry(kind: key.kind, id: key.id)
                sync.remove(key)
                restored.append(key)
            }
        }
        return restored
    }

    public func followMediaToTeam(_ references: [SyncLedger.Key: Set<String>]) throws -> [SyncLedger.Key] {
        let moving = SyncMediaFollow.toMove(references: references, snapshot: snapshot, sync: sync)
        if !moving.isEmpty {
            _ = try publishing {
                for key in moving {
                    let from = LibraryArea.resolve(
                        row: mirror.area(kind: key.kind, id: key.id), entry: sync.entry(kind: key.kind, id: key.id))
                    if sync.entry(kind: key.kind, id: key.id) != nil, let old = LibraryArea.namespace(kind: key.kind, area: from) {
                        let held = SyncLedger.HeldDelete(key: key, side: .local, namespace: old)
                        pendingSidecar = true
                        try opened().index.holdDelete(held)
                        sync.hold(held)
                    }
                    try recordArea(.team, key: key, origin: .local)
                    pendingSidecar = true
                    try opened().index.removeSyncEntry(kind: key.kind, id: key.id)
                    sync.remove(key)
                }
            }
        }
        return moving
    }

    @discardableResult
    public func replace<E: DocumentEntity>(_ value: E, area: LibraryArea? = nil, origin: ChangeOrigin = .local) throws -> LibraryBatch {
        try publishing {
            let key = SyncLedger.Key(kind: E.documentKind, id: value.id)
            let standing = mirror.area(kind: key.kind, id: key.id)
            try bulkWriteOne(value, replacing: true, origin: origin)
            try home(standing ?? area, key: key)
        }
    }

    private func home(_ area: LibraryArea?, key: SyncLedger.Key) throws {
        if let area, SyncScope.scope(for: key.kind) == .team {
            try recordArea(area, key: key, origin: .landed)
        }
    }

    @discardableResult

    public func modify<E: DocumentEntity>(
        _ type: E.Type, id: String, origin: ChangeOrigin = .local, orMake make: () -> E,
        seeded: Bool = false, area: LibraryArea? = nil, _ mutate: (inout E) throws -> Void
    ) throws -> LibraryBatch {
        let listed = Library.listedKinds.contains(E.documentKind)
        let key = SyncLedger.Key(kind: E.documentKind, id: id)
        return try publishing {
            if try opened().store.exists(kind: E.documentKind, id: id) {
                let document = try replica(type, id: id)
                try document.update(mutate)
                try persist(document, origin: origin, listed: listed)
            } else if seeded {
                let document = try made(make(), seed: .init(id: id))
                try document.update(mutate)
                try persist(document, origin: origin, listed: listed)
                try home(area, key: key)
            } else {
                var value = make()
                try mutate(&value)
                try persist(try made(value, seed: nil), origin: origin, listed: listed)
                try home(area, key: key)
            }
        }
    }

    @discardableResult
    public func edit<E: DocumentEntity>(
        _ type: E.Type, id: String, origin: ChangeOrigin = .local, op: @LibraryActor (TypedDocument<E>) throws -> Void
    ) throws -> LibraryBatch {
        try publishing {
            let document = try replica(type, id: id)
            do {
                try op(document)
            } catch {

                dropReplica(kind: E.documentKind, id: id)
                throw error
            }
            try persist(document, origin: origin)
        }
    }

    @discardableResult
    public func maintain(_ body: @LibraryActor (Library) throws -> Void) throws -> LibraryBatch {
        try publishing {
            let library = try openedLibrary()
            var saved: [SyncLedger.Key] = []
            var deleted: [SyncLedger.Key] = []
            library.didSave = { kind, id in saved.append(SyncLedger.Key(kind: kind, id: id)) }
            library.didDelete = { kind, id in deleted.append(SyncLedger.Key(kind: kind, id: id)) }
            defer {
                library.didSave = nil
                library.didDelete = nil
                pendingSidecar = true
                mirror = (try? LibraryIndexMirror.read(library.index)) ?? mirror
                for key in saved.reduce(into: [SyncLedger.Key](), { if !$0.contains($1) { $0.append($1) } }) {
                    if let change = Self.onDisk(SyncScope.entityType(for: key.kind), id: key.id, in: library.store) {
                        pendingChanges.append(change)
                        if let heads = change.heads { try? noteHeads(heads, key: key) }
                    }
                }
                for key in deleted {
                    forgetHeads(id: key.id)
                    replicas.remove(kind: key.kind, id: key.id)
                    valueCache.remove(key)
                    pendingChanges.append(DocumentChange(kind: key.kind, id: key.id, origin: .deleted, value: nil))
                    sync.removeAll(id: key.id)
                }
            }
            try body(library)
        }
    }

    @discardableResult
    public func rebuildIndex() throws -> LibraryBatch {
        try publishing {
            let library = try openedLibrary()
            pendingSidecar = true
            defer { mirror = (try? LibraryIndexMirror.read(library.index)) ?? mirror }
            try library.rebuildIndex()
        }
    }

    @discardableResult
    public func bulkWrite(_ documents: [any DocumentEntity], replacing: Bool = false, origin: ChangeOrigin = .local) throws -> LibraryBatch {
        try publishing {
            for value in documents {
                try bulkWriteOne(value, replacing: replacing, origin: origin)
            }
        }
    }

    @discardableResult
    public func touchUsage(id: String, at date: Date = Date()) throws -> LibraryBatch {
        try publishing {
            let stamp = LibraryIndexMirror.indexDate(date)
            try opened().index.touchUsage(id: id, at: stamp)
            mirror.touchUsage(id: id, at: stamp)
        }
    }

    @discardableResult
    public func mergeUsage(_ stamps: [String: Date]) throws -> LibraryBatch {
        try publishing {
            let rounded = stamps.mapValues(LibraryIndexMirror.indexDate)
            try opened().index.mergeUsage(rounded)
            for (id, date) in rounded {
                mirror.touchUsage(id: id, at: date)
            }
        }
    }

    @discardableResult
    public func replaceTeamFolders(_ folders: [TeamFolder]) throws -> LibraryBatch {
        try publishing {
            try opened().index.replaceTeamFolders(folders)
            sync.teamFolders = folders
            pendingSidecar = true
        }
    }

    @discardableResult
    public func setSyncIdentity(_ identity: SyncIdentity) throws -> LibraryBatch {
        try publishing {
            try opened().index.setSyncIdentity(identity)
            sync.identity = identity
            pendingSidecar = true
        }
    }

    @discardableResult
    public func resetSyncState() throws -> LibraryBatch {
        try publishing {
            pendingSidecar = true
            try opened().index.resetSyncState()
            sync.resetLedger()
        }
    }

    @discardableResult
    public func setSyncEntry(_ entry: SyncLedger.Entry, kind: DocumentKind, id: String) throws -> LibraryBatch {
        try publishing {
            try writeSyncEntry(entry, key: SyncLedger.Key(kind: kind, id: id))
        }
    }

    @discardableResult
    public func updateSyncEntry(kind: DocumentKind, id: String, _ change: (inout SyncLedger.Entry) throws -> Void) throws -> LibraryBatch {
        try publishing {
            let key = SyncLedger.Key(kind: kind, id: id)
            var entry = sync.entries[key] ?? SyncLedger.Entry()
            try change(&entry)
            try writeSyncEntry(entry, key: key)
        }
    }

    @discardableResult
    public func removeSyncEntry(kind: DocumentKind, id: String) throws -> LibraryBatch {
        try publishing {
            pendingSidecar = true
            try opened().index.removeSyncEntry(kind: kind, id: id)
            sync.remove(SyncLedger.Key(kind: kind, id: id))
        }
    }

    @discardableResult
    public func holdDelete(_ held: SyncLedger.HeldDelete) throws -> LibraryBatch {
        try publishing {
            pendingSidecar = true
            try opened().index.holdDelete(held)
            sync.hold(held)
        }
    }

    @discardableResult
    public func releaseHeldDelete(_ held: SyncLedger.HeldDelete) throws -> LibraryBatch {
        try publishing {
            pendingSidecar = true
            try opened().index.releaseHeldDelete(held)
            sync.release(held)
        }
    }

    @discardableResult
    public func quarantine(kind: DocumentKind, id: String, seq: Int, bytes: Data, error: String, at date: Date = Date()) throws -> LibraryBatch {
        try publishing {
            pendingSidecar = true
            try opened().index.quarantine(kind: kind, id: id, seq: seq, bytes: bytes, error: error, at: date)
        }
    }

    @discardableResult
    public func clearQuarantine(kind: DocumentKind, id: String) throws -> LibraryBatch {
        try publishing {
            pendingSidecar = true
            try opened().index.clearQuarantine(kind: kind, id: id)
        }
    }

    @discardableResult
    public func markBlobUploaded(_ checksum: String, at date: Date = Date()) throws -> LibraryBatch {
        try publishing {
            pendingSidecar = true
            try opened().index.markBlobUploaded(checksum, at: date)
        }
    }

    @discardableResult
    public func forgetBlobUploaded(_ checksum: String) throws -> LibraryBatch {
        try publishing {
            pendingSidecar = true
            try opened().index.forgetBlobUploaded(checksum)
        }
    }

    public func reconcileDeleted(kind: DocumentKind, id: String) throws -> Tombstone {
        let entry = sync.entry(kind: kind, id: id)
        let heads = entry == nil ? nil : try localHeads(kind: kind, id: id)

        switch SyncReconcileLogic.afterTombstone(entry: entry, localHeads: heads) {
        case .push:
            return .editWins
        case .removeLocal:
            return .removed(try publishing { try removeDocument(kind: kind, id: id, origin: .landed) })
        case .keep:
            return .untracked
        }
    }

    public func search(_ query: String) throws -> [LibraryIndex.Hit] {
        try opened().index.searchHits(query)
    }

    public func allUsage() throws -> [String: Date] {
        try opened().index.allUsage()
    }

    public func presentationMatchKeys() throws -> [LibraryIndex.MatchKey] {
        try opened().index.presentationMatchKeys()
    }

    public func folderRefs() throws -> [LibraryIndex.FolderRef] {
        try opened().index.folderRefs()
    }

    public func syncEntry(kind: DocumentKind, id: String) -> SyncLedger.Entry? {
        sync.entry(kind: kind, id: id)
    }

    public func recordedHeads(kind: DocumentKind, id: String) -> [String]? {
        recordedHeads[SyncLedger.Key(kind: kind, id: id)]
    }

    public func owedDocuments() -> [SyncLedger.Key] {
        SyncOwedLogic.owed(entries: sync.entries, recordedHeads: recordedHeads) { key in namespace(of: key) }
    }

    public func namespace(of key: SyncLedger.Key) -> SyncScope? {
        LibraryArea.namespace(
            kind: key.kind,
            area: mirror.area(kind: key.kind, id: key.id) ?? LibraryArea.resolve(row: nil, entry: sync.entries[key]))
    }

    public func quarantined(kind: DocumentKind, id: String) throws -> [SyncLedger.Quarantined] {
        try opened().index.quarantined(kind: kind, id: id)
    }

    public func isBlobUploaded(_ checksum: String) throws -> Bool {
        try opened().index.blobUploaded(checksum)
    }

    public func uploadedBlobs(among checksums: [String]) throws -> Set<String> {
        let index = try opened().index
        return try Set(checksums.filter { try index.blobUploaded($0) })
    }

    public func localHeads(kind: DocumentKind, id: String) throws -> [String]? {
        try localHeads(SyncScope.entityType(for: kind), id: id)
    }

    public func loadValue<E: DocumentEntity>(_ type: E.Type, id: String) async throws -> E {
        try await reader().loadValue(type, id: id)
    }

    public func loadValues<E: DocumentEntity>(
        _ type: E.Type, ids: [String], priority: TaskPriority? = nil
    ) async throws -> (values: [String: E], failed: Set<String>) {
        try await reader().loadValues(type, ids: ids, priority: priority)
    }

    public func deckBundle(id: String) async throws -> DeckBundle {
        try await reader().deckBundle(id: id)
    }

    func opened() throws -> (store: DocumentStore, index: LibraryIndex) {
        if let store, let index {
            return (store, index)
        } else {
            throw EngineError.notBootstrapped
        }
    }

    private func openedLibrary() throws -> Library {
        if let library {
            return library
        } else {
            throw EngineError.notBootstrapped
        }
    }

    func publishing(_ body: () throws -> Void) throws -> LibraryBatch {
        do {
            try body()
            return publish()
        } catch {
            if !pendingChanges.isEmpty || !pendingMoves.isEmpty || pendingSidecar {
                publish()
            }
            throw error
        }
    }

    @discardableResult
    private func publish() -> LibraryBatch {
        sequence += 1
        if let index, snapshot.generation != index.writeGeneration {
            snapshot = mirror.snapshot(generation: index.writeGeneration)
        }
        let batch = LibraryBatch(sequence: sequence, changes: pendingChanges, areaMoves: pendingMoves, snapshot: snapshot, sync: sync)
        pendingChanges = []
        pendingMoves = []
        pendingSidecar = false
        continuation.yield(batch)
        return batch
    }

    func replica<E: DocumentEntity>(_ type: E.Type, id: String) throws -> TypedDocument<E> {
        let store = try opened().store
        let stamp = DocumentFileStamp.of(store.url(kind: E.documentKind, id: id))
        let document = try replicas.document(type, id: id, stamp: stamp) ?? store.load(type, id: id)
        document.commitMessage = author?.message(for: E.documentKind)
        return document
    }

    private func made<E: DocumentEntity>(_ value: E, seed: TypedDocument<E>.SeedIdentity?) throws -> TypedDocument<E> {
        let document = try TypedDocument(value, seed: seed)
        document.commitMessage = author?.message(for: E.documentKind)
        return document
    }

    func persist<E: DocumentEntity>(_ document: TypedDocument<E>, origin: ChangeOrigin, listed: Bool = true) throws {
        let (store, index) = try opened()
        do {
            try store.save(document)
        } catch {
            dropReplica(kind: E.documentKind, id: document.value.id)
            throw error
        }
        let value = document.value
        let key = SyncLedger.Key(kind: E.documentKind, id: value.id)
        let stamp = DocumentFileStamp.of(store.url(kind: key.kind, id: key.id))
        let heads = SyncLedger.hex(document.heads())
        replicas.keep(document, stamp: stamp)
        valueCache.write(value, key: key, stamp: stamp)
        let bundle = editorBundle(after: document, key: key)
        pendingChanges.append(
            DocumentChange(kind: key.kind, id: key.id, origin: origin, value: value, listed: listed, heads: heads, bundle: bundle))
        try noteHeads(heads, key: key)
        if listed {
            let updatedAt = LibraryIndexMirror.indexDate(Date())
            try index.upsert(
                id: value.id, kind: key.kind, subkind: value.indexSubkind, name: value.name,
                text: value.indexText, updatedAt: updatedAt, ccli: value.indexCCLI, folderId: value.indexFolderId,
                origin: value.indexOrigin)
            mirror.upsert(
                id: value.id, kind: key.kind, subkind: value.indexSubkind, name: value.name, updatedAt: updatedAt,
                origin: value.indexOrigin)
        }
        if let service = value as? Service {
            for use in Library.usageStamps(of: service) {
                let date = LibraryIndexMirror.indexDate(use.date)
                try index.touchUsage(id: use.id, at: date)
                mirror.touchUsage(id: use.id, at: date)
            }
        }
    }

    private static func onDisk<E: DocumentEntity>(_ type: E.Type, id: String, in store: DocumentStore) -> DocumentChange? {
        (try? store.load(type, id: id)).map {
            DocumentChange(
                kind: E.documentKind, id: id, origin: .local, value: $0.value,
                listed: Library.listedKinds.contains(E.documentKind), heads: SyncLedger.hex($0.heads()))
        }
    }

    func dropFile(kind: DocumentKind, id: String) throws {
        try opened().store.delete(kind: kind, id: id)
        replicas.remove(kind: kind, id: id)
        valueCache.remove(SyncLedger.Key(kind: kind, id: id))
    }

    func removeDocument(kind: DocumentKind, id: String, origin: ChangeOrigin) throws {
        try removeDocuments([SyncLedger.Key(kind: kind, id: id)], origin: origin)
    }

    func removeDocuments(_ keys: [SyncLedger.Key], origin: ChangeOrigin) throws {
        let (store, index) = try opened()
        var removed: [String] = []
        var failure: (any Error)?
        for key in keys where failure == nil {
            let syncedUnder = origin == .deleted ? namespace(of: key) : nil
            do {
                try store.delete(kind: key.kind, id: key.id)
                replicas.remove(kind: key.kind, id: key.id)
                valueCache.remove(key)
                endEditorSessions(key)
                pendingChanges.append(DocumentChange(kind: key.kind, id: key.id, origin: origin, value: nil, syncedUnder: syncedUnder))
                removed.append(key.id)
            } catch {
                failure = error
            }
        }
        try index.remove(ids: removed)
        for id in removed {
            mirror.remove(id: id)
            sync.removeAll(id: id)
            forgetHeads(id: id)
        }
        if let failure {
            throw failure
        }
    }

    func noteHeads(_ heads: [String], key: SyncLedger.Key) throws {
        if recordedHeads[key] != heads {
            try opened().index.setDocumentHeads(heads, kind: key.kind, id: key.id)
            recordedHeads[key] = heads
        }
    }

    private func forgetHeads(id: String) {
        for kind in DocumentKind.allCases {
            recordedHeads[SyncLedger.Key(kind: kind, id: id)] = nil
        }
    }

    func dropReplica(kind: DocumentKind, id: String) {
        replicas.remove(kind: kind, id: id)
    }

    func recordArea(_ area: LibraryArea, key: SyncLedger.Key, origin: ChangeOrigin) throws {
        let row = mirror.area(kind: key.kind, id: key.id)
        let from = row ?? .default
        if row != area {
            try opened().index.setArea(area, kind: key.kind, id: key.id)
            mirror.setArea(area, kind: key.kind, id: key.id)
        }
        if from != area {
            pendingMoves.append(AreaMove(kind: key.kind, id: key.id, from: from, to: area, origin: origin))
        }
    }

    func writeSyncEntry(_ entry: SyncLedger.Entry, key: SyncLedger.Key) throws {
        var stored = entry
        stored.lastSnapshotAt = entry.lastSnapshotAt.map(LibraryIndexMirror.indexDate)
        pendingSidecar = true
        try opened().index.setSyncEntry(stored, kind: key.kind, id: key.id)
        sync.set(stored, for: key)
    }

    func writeQuarantine(_ rows: [SyncLedger.Quarantined], key: SyncLedger.Key) throws {
        let index = try opened().index
        for row in rows {
            pendingSidecar = true
            try index.quarantine(kind: key.kind, id: key.id, seq: row.seq, bytes: row.bytes, error: row.error, at: row.quarantinedAt)
        }
    }

    func localHeads<E: DocumentEntity>(_ type: E.Type, id: String) throws -> [String]? {
        if try opened().store.exists(kind: E.documentKind, id: id) {
            let heads = SyncLedger.hex(try replica(type, id: id).heads())
            try noteHeads(heads, key: SyncLedger.Key(kind: E.documentKind, id: id))
            return heads
        } else {
            return nil
        }
    }

    private func bulkWriteOne<E: DocumentEntity>(_ value: E, replacing: Bool, origin: ChangeOrigin) throws {
        let store = try opened().store
        if replacing, store.exists(kind: E.documentKind, id: value.id) {
            try removeDocument(kind: E.documentKind, id: value.id, origin: origin == .local ? .deleted : origin)
        }
        try persist(try made(value, seed: nil), origin: origin)
    }
}
