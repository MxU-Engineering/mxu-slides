import Foundation

@MainActor public protocol LibraryReadSide: AnyObject {

    func currentValue(_ kind: DocumentKind, id: String) -> (any DocumentEntity)?

    func applyOptimistic(_ change: DocumentChange)

    func optimisticWriteFailed(_ change: DocumentChange, error: any Error)

    func apply(_ batch: LibraryBatch)
}

@MainActor public final class LibraryClient {
    public enum ClientError: Error, Equatable {

        case notStarted
    }

    public static let bulkChunkSize = 50

    public let engine: LibraryEngine

    public let rootURL: URL

    public private(set) var snapshot = IndexSnapshot.empty

    public private(set) var sync = LibrarySyncState.empty

    public private(set) var isReady = false
    public private(set) var lastAppliedSequence = 0
    public weak var readSide: (any LibraryReadSide)?

    private var reader: LibraryReader?
    private var starting: Task<Void, any Error>?
    private var listener: Task<Void, Never>?

    private var tail: (@Sendable () async -> Void)?

    private var liveAsked = 0

    public init(engine: LibraryEngine) {
        self.engine = engine
        rootURL = engine.rootURL
    }

    public convenience init(rootURL: URL) {
        self.init(engine: LibraryEngine(rootURL: rootURL))
    }

    @discardableResult
    public func start(preparing: (@LibraryActor @Sendable (Library) throws -> Void)? = nil) -> Task<Void, any Error> {
        if let starting {
            return starting
        } else {
            let previous = tail
            let opening = Task { @LibraryActor [engine] in
                await previous?()
                return try engine.bootstrap(preparing: preparing)
            }
            tail = { _ = await opening.result }
            let started = Task { [weak self] in
                do {
                    self?.begin(try await opening.value)
                } catch {
                    self?.starting = nil
                    throw error
                }
            }
            starting = started
            return started
        }
    }

    private func begin(_ start: LibraryEngine.Start) {
        reader = start.reader
        snapshot = start.snapshot
        sync = start.sync
        isReady = true
        listener = Task { [weak self] in
            for await batch in start.batches {
                self?.apply(batch)
            }
        }
    }

    public func apply(_ batch: LibraryBatch) {
        if batch.sequence > lastAppliedSequence {
            snapshot = batch.snapshot
            sync = batch.sync
            lastAppliedSequence = batch.sequence
            readSide?.apply(batch)
        }
    }

    @discardableResult
    public func create<E: DocumentEntity>(
        _ value: E, seed: TypedDocument<E>.SeedIdentity? = nil, area: LibraryArea? = nil
    ) -> Task<LibraryBatch, any Error> {
        let change = DocumentChange(kind: E.documentKind, id: value.id, origin: .local, value: value)
        readSide?.applyOptimistic(change)
        return enqueue(change) { [engine] in try engine.create(value, seed: seed, area: area) }
    }

    @discardableResult
    public func modify<E: DocumentEntity>(
        _ type: E.Type, id: String, _ mutate: @escaping @Sendable (inout E) throws -> Void
    ) -> Task<LibraryBatch, any Error> {
        let change = optimistic(type, id: id, mutate)
        return enqueue(change) { [engine] in try engine.modify(type, id: id, mutate) }
    }

    @discardableResult
    public func write(
        _ presentationID: String, next: @escaping @Sendable (inout [Slide]) throws -> Void
    ) -> Task<LibraryBatch, any Error> {
        let change = optimistic(Presentation.self, id: presentationID) { try next(&$0.slides) }
        return enqueue(change) { [engine] in try engine.write(presentationID, next: next) }
    }

    @discardableResult
    public func edit<E: DocumentEntity>(
        _ type: E.Type, id: String,
        value: @escaping @Sendable (inout E) throws -> Void,
        op: @escaping @LibraryActor @Sendable (TypedDocument<E>) throws -> Void
    ) -> Task<LibraryBatch, any Error> {
        let change = optimistic(type, id: id, value)
        return enqueue(change) { [engine] in try engine.edit(type, id: id, op: op) }
    }

    @discardableResult
    public func commit<E: DocumentEntity>(
        _ type: E.Type, id: String, changes: Data, token: EditorToken? = nil
    ) -> Task<LibraryBatch, any Error> {
        enqueue(nil) { [engine] in try engine.commit(type, id: id, changes: changes, token: token) }
    }

    @discardableResult
    public func delete(kind: DocumentKind, id: String, origin: ChangeOrigin = .deleted) -> Task<LibraryBatch, any Error> {
        delete([SyncLedger.Key(kind: kind, id: id)], origin: origin)
    }

    @discardableResult
    public func delete(_ documents: [SyncLedger.Key], origin: ChangeOrigin = .deleted) -> Task<LibraryBatch, any Error> {
        let changes = documents.map { DocumentChange(kind: $0.kind, id: $0.id, origin: origin, value: nil) }
        for change in changes {
            readSide?.applyOptimistic(change)
        }
        return enqueue(changes) { [engine] in try engine.delete(documents, origin: origin) }
    }

    @discardableResult
    public func setArea(
        _ area: LibraryArea, of documents: [SyncLedger.Key], origin: ChangeOrigin = .local
    ) -> Task<LibraryBatch, any Error> {
        enqueue(nil) { [engine] in try engine.setArea(area, of: documents, origin: origin) }
    }

    @discardableResult
    public func setAreaIfAbsent(_ area: LibraryArea, of key: SyncLedger.Key) -> Task<LibraryArea, any Error> {
        enqueue(nil) { [engine] in try engine.setAreaIfAbsent(area, of: key) }
    }

    @discardableResult
    public func restoreFlippedAreas(_ keys: [SyncLedger.Key]) -> Task<[SyncLedger.Key], any Error> {
        enqueue(nil) { [engine] in try engine.restoreFlippedAreas(keys) }
    }

    @discardableResult
    public func followMediaToTeam(_ references: [SyncLedger.Key: Set<String>]) -> Task<[SyncLedger.Key], any Error> {
        enqueue(nil) { [engine] in try engine.followMediaToTeam(references) }
    }

    public func resolveArea(kind: DocumentKind, id: String) -> LibraryArea? {
        let key = SyncLedger.Key(kind: kind, id: id)
        switch SyncAreaGuess.answer(for: key, isReady: isReady, snapshot: snapshot, sync: sync) {
        case .unknown:
            return nil
        case .known(let area):
            return area
        case .guess(let area):
            setAreaIfAbsent(area, of: key)
            return area
        }
    }

    public func standingArea(kind: DocumentKind, id: String) async -> LibraryArea? {
        let key = SyncLedger.Key(kind: kind, id: id)
        switch SyncAreaGuess.answer(for: key, isReady: isReady, snapshot: snapshot, sync: sync) {
        case .unknown:
            return nil
        case .known(let area):
            return area
        case .guess(let area):
            return try? await setAreaIfAbsent(area, of: key).value
        }
    }

    @discardableResult
    public func replace<E: DocumentEntity>(_ value: E, area: LibraryArea? = nil) -> Task<LibraryBatch, any Error> {
        let change = DocumentChange(kind: E.documentKind, id: value.id, origin: .local, value: value)
        readSide?.applyOptimistic(change)
        return enqueue(change) { [engine] in try engine.replace(value, area: area) }
    }

    @discardableResult
    public func modify<E: DocumentEntity>(
        _ type: E.Type, id: String, orMake make: @escaping @Sendable () -> E,
        seeded: Bool = false, area: LibraryArea? = nil, _ mutate: @escaping @Sendable (inout E) throws -> Void
    ) -> Task<LibraryBatch, any Error> {
        let change = optimistic(type, id: id, mutate)
        return enqueue(change) { [engine] in try engine.modify(type, id: id, orMake: make, seeded: seeded, area: area, mutate) }
    }

    @discardableResult
    public func rebuildIndex() -> Task<LibraryBatch, any Error> {
        enqueue(nil) { [engine] in try engine.rebuildIndex() }
    }

    @discardableResult
    public func maintain(_ body: @escaping @LibraryActor @Sendable (Library) throws -> Void) -> Task<LibraryBatch, any Error> {
        enqueue(nil) { [engine] in try engine.maintain(body) }
    }

    public func setAuthor(_ author: ChangeAuthor?) {
        _ = enqueue(nil) { [engine] in engine.setAuthor(author) }
    }

    @discardableResult
    public func touchUsage(id: String, at date: Date = Date()) -> Task<LibraryBatch, any Error> {
        enqueue(nil) { [engine] in try engine.touchUsage(id: id, at: date) }
    }

    @discardableResult
    public func mergeUsage(_ stamps: [String: Date]) -> Task<LibraryBatch, any Error> {
        enqueue(nil) { [engine] in try engine.mergeUsage(stamps) }
    }

    @discardableResult
    public func replaceTeamFolders(_ folders: [TeamFolder]) -> Task<LibraryBatch, any Error> {
        enqueue(nil) { [engine] in try engine.replaceTeamFolders(folders) }
    }

    @discardableResult
    public func setSyncIdentity(_ identity: SyncIdentity) -> Task<LibraryBatch, any Error> {
        enqueue(nil) { [engine] in try engine.setSyncIdentity(identity) }
    }

    @discardableResult
    public func resetSyncState() -> Task<LibraryBatch, any Error> {
        enqueue(nil) { [engine] in try engine.resetSyncState() }
    }

    @discardableResult
    public func setSyncEntry(_ entry: SyncLedger.Entry, kind: DocumentKind, id: String) -> Task<LibraryBatch, any Error> {
        enqueue(nil) { [engine] in try engine.setSyncEntry(entry, kind: kind, id: id) }
    }

    @discardableResult
    public func updateSyncEntry(
        kind: DocumentKind, id: String, _ change: @escaping @Sendable (inout SyncLedger.Entry) -> Void
    ) -> Task<LibraryBatch, any Error> {
        enqueue(nil) { [engine] in try engine.updateSyncEntry(kind: kind, id: id, change) }
    }

    @discardableResult
    public func removeSyncEntry(kind: DocumentKind, id: String) -> Task<LibraryBatch, any Error> {
        enqueue(nil) { [engine] in try engine.removeSyncEntry(kind: kind, id: id) }
    }

    @discardableResult
    public func quarantine(
        kind: DocumentKind, id: String, seq: Int, bytes: Data, error: String
    ) -> Task<LibraryBatch, any Error> {
        enqueue(nil) { [engine] in try engine.quarantine(kind: kind, id: id, seq: seq, bytes: bytes, error: error) }
    }

    @discardableResult
    public func clearQuarantine(kind: DocumentKind, id: String) -> Task<LibraryBatch, any Error> {
        enqueue(nil) { [engine] in try engine.clearQuarantine(kind: kind, id: id) }
    }

    @discardableResult
    public func markBlobUploaded(_ checksum: String) -> Task<LibraryBatch, any Error> {
        enqueue(nil) { [engine] in try engine.markBlobUploaded(checksum) }
    }

    @discardableResult
    public func forgetBlobUploaded(_ checksum: String) -> Task<LibraryBatch, any Error> {
        enqueue(nil) { [engine] in try engine.forgetBlobUploaded(checksum) }
    }

    @discardableResult
    public func holdDelete(_ held: SyncLedger.HeldDelete) -> Task<LibraryBatch, any Error> {
        enqueue(nil) { [engine] in try engine.holdDelete(held) }
    }

    @discardableResult
    public func releaseHeldDelete(_ held: SyncLedger.HeldDelete) -> Task<LibraryBatch, any Error> {
        enqueue(nil) { [engine] in try engine.releaseHeldDelete(held) }
    }

    @discardableResult
    public func reconcileDeleted(kind: DocumentKind, id: String) -> Task<LibraryEngine.Tombstone, any Error> {
        enqueue(nil) { [engine] in try engine.reconcileDeleted(kind: kind, id: id) }
    }

    @discardableResult
    public func bulkWrite(
        _ documents: [any DocumentEntity], replacing: Bool = false, chunkSize: Int = LibraryClient.bulkChunkSize
    ) -> Task<[LibraryBatch], any Error> {
        let size = max(1, chunkSize)
        let chunks = stride(from: 0, to: documents.count, by: size).map {
            Array(documents[$0..<min($0 + size, documents.count)])
        }
        let engine = engine
        return Task.detached {
            var batches: [LibraryBatch] = []
            for chunk in chunks {
                batches.append(try await engine.bulkWrite(chunk, replacing: replacing))
            }
            return batches
        }
    }

    public func loadValue<E: DocumentEntity>(_ type: E.Type, id: String) async throws -> E {
        try await startedReader().loadValue(type, id: id)
    }

    public func loadValues<E: DocumentEntity>(
        _ type: E.Type, ids: [String], priority: TaskPriority? = nil
    ) async throws -> (values: [String: E], failed: Set<String>) {
        try await startedReader().loadValues(type, ids: ids, priority: priority)
    }

    public func deckBundles(ids: [String], priority: TaskPriority? = nil) async throws -> DeckBundles {
        try await startedReader().deckBundles(ids: ids, priority: priority)
    }

    public func settled() async {
        _ = await afterQueued { _ in () }.result
    }

    public func settledSnapshot() async throws -> IndexSnapshot {
        try await afterQueued { engine in engine.snapshot }.value
    }

    public func settledSync() async throws -> LibrarySyncState {
        try await afterQueued { engine in engine.sync }.value
    }

    public func search(_ query: String) async throws -> [LibraryIndex.Hit] {
        try await afterQueued { engine in try engine.search(query) }.value
    }

    public func allUsage() async throws -> [String: Date] {
        try await afterQueued { engine in try engine.allUsage() }.value
    }

    public func presentationMatchKeys() async throws -> [LibraryIndex.MatchKey] {
        try await afterQueued { engine in try engine.presentationMatchKeys() }.value
    }

    public func folderRefs() async throws -> [LibraryIndex.FolderRef] {
        try await afterQueued { engine in try engine.folderRefs() }.value
    }

    public func quarantined(kind: DocumentKind, id: String) async throws -> [SyncLedger.Quarantined] {
        try await afterQueued { engine in try engine.quarantined(kind: kind, id: id) }.value
    }

    public func isBlobUploaded(_ checksum: String) async throws -> Bool {
        try await afterQueued { engine in try engine.isBlobUploaded(checksum) }.value
    }

    public func uploadedBlobs(among checksums: [String]) async throws -> Set<String> {
        try await afterQueued { engine in try engine.uploadedBlobs(among: checksums) }.value
    }

    public func localHeads(kind: DocumentKind, id: String) async throws -> [String]? {
        try await afterQueued { engine in try engine.localHeads(kind: kind, id: id) }.value
    }

    public func owedDocuments() async throws -> [SyncLedger.Key] {
        try await afterQueued { engine in engine.owedDocuments() }.value
    }

    public func exists(kind: DocumentKind, id: String) async throws -> Bool {
        try await startedReader().exists(kind: kind, id: id)
    }

    public func ids(of kind: DocumentKind) async throws -> [String] {
        try await startedReader().ids(of: kind)
    }

    public func checkout<E: DocumentEntity>(
        _ type: E.Type, id: String, history: EditorHistoryUse = .parked
    ) async throws -> sending EditorCheckout<E> {
        let previous = tail
        await previous?()
        return try await engine.checkout(type, id: id, history: history)
    }

    @discardableResult
    public func release(token: EditorToken, history: EditorHistory? = nil) -> Task<Void, any Error> {
        afterQueued { engine in engine.release(token: token, history: history) }
    }

    @discardableResult
    public func warm<E: DocumentEntity>(_ type: E.Type, ids: [String]) -> Task<Void, Never> {
        let starting = starting
        let engine = engine
        return Task(priority: .utility) {
            _ = await starting?.result
            await engine.warm(type, ids: ids)
        }
    }

    @discardableResult
    public func warmLive(_ ids: Set<String>) -> Task<Void, Never> {
        liveAsked += 1
        let asked = liveAsked
        let starting = starting
        let engine = engine
        return Task(priority: .utility) {
            _ = await starting?.result
            await engine.warmLive(ids: ids, asked: asked)
        }
    }

    public var readerNow: LibraryReader? { reader }

    public func reader() async throws -> LibraryReader {
        try await startedReader()
    }

    public var residentFillSource: any ResidentFillSource {
        LibraryClientFillSource { [weak self] in
            if let self {
                try await self.reader()
            } else {
                throw ClientError.notStarted
            }
        }
    }

    public var deckBundleSource: any DeckBundleSource {
        LibraryClientFillSource { [weak self] in
            if let self {
                try await self.reader()
            } else {
                throw ClientError.notStarted
            }
        }
    }

    public func author() async -> ChangeAuthor? {
        (try? await afterQueued { engine in engine.currentAuthor }.value) ?? nil
    }

    private func startedReader() async throws -> LibraryReader {
        try await starting?.value
        if let reader {
            return reader
        } else {
            throw ClientError.notStarted
        }
    }

    private func optimistic<E: DocumentEntity>(
        _ type: E.Type, id: String, _ mutate: (inout E) throws -> Void
    ) -> DocumentChange? {
        if var value = readSide?.currentValue(E.documentKind, id: id) as? E, (try? mutate(&value)) != nil {
            let change = DocumentChange(kind: E.documentKind, id: id, origin: .local, value: value)
            readSide?.applyOptimistic(change)
            return change
        } else {
            return nil
        }
    }

    private func afterQueued<T: Sendable>(
        _ work: @escaping @Sendable @LibraryActor (LibraryEngine) async throws -> T
    ) -> Task<T, any Error> {
        let previous = tail
        let engine = engine
        return Task { @LibraryActor in
            await previous?()
            return try await work(engine)
        }
    }

    func enqueue<T: Sendable>(
        _ change: DocumentChange?, _ work: @escaping @Sendable @LibraryActor () throws -> T
    ) -> Task<T, any Error> {
        enqueue(change.map { [$0] } ?? [], work)
    }

    func enqueue<T: Sendable>(
        _ changes: [DocumentChange], _ work: @escaping @Sendable @LibraryActor () throws -> T
    ) -> Task<T, any Error> {
        let previous = tail
        let command = Task { @LibraryActor in
            await previous?()
            return try work()
        }
        tail = { _ = await command.result }
        if !changes.isEmpty {
            Task { [weak self] in
                if case let .failure(error) = await command.result {
                    for change in changes {
                        self?.readSide?.optimisticWriteFailed(change, error: error)
                    }
                }
            }
        }
        return command
    }
}

public struct LibraryClientFillSource: ResidentFillSource {
    let reader: @Sendable () async throws -> LibraryReader

    @concurrent
    public func fillResidentTable<Entity: DocumentEntity>(
        _ type: Entity.Type, epoch: Int, known: [String: DocumentFileStamp]
    ) async -> ResidentTableFill<Entity> {
        if let reader = try? await reader() {
            await reader.fillResidentTable(type, epoch: epoch, known: known)
        } else {
            ResidentTableFill(epoch: epoch)
        }
    }
}
