import Foundation

public struct DocumentStore: Sendable {
    public enum StoreError: Error, Equatable {
        case documentNotFound(kind: DocumentKind, id: String)
    }

    public let rootURL: URL

    public init(rootURL: URL) throws {
        self.rootURL = rootURL
        for kind in DocumentKind.allCases {
            try FileManager.default.createDirectory(
                at: rootURL.appendingPathComponent(kind.directoryName, isDirectory: true),
                withIntermediateDirectories: true
            )
        }
    }

    public func url(kind: DocumentKind, id: String) -> URL {
        rootURL
            .appendingPathComponent(kind.directoryName, isDirectory: true)
            .appendingPathComponent(id)
            .appendingPathExtension("automerge")
    }

    public func exists(kind: DocumentKind, id: String) -> Bool {
        FileManager.default.fileExists(atPath: url(kind: kind, id: id).path)
    }

    @LibraryActor
    public func save<Entity>(_ document: TypedDocument<Entity>) throws {
        let fileURL = url(kind: Entity.documentKind, id: document.value.id)

        if let existing = try? Data(contentsOf: fileURL),
           existing != document.lastPersistedData,
           let diskReplica = try? TypedDocument<Entity>(data: existing) {
            try? document.merge(diskReplica)
        }
        let data = document.save()
        try data.write(to: fileURL, options: .atomic)
        document.lastPersistedData = data
    }

    @LibraryActor
    public func load<Entity: DocumentEntity>(_ type: Entity.Type, id: String) throws -> TypedDocument<Entity> {
        try TypedDocument<Entity>(data: bytes(Entity.documentKind, id: id))
    }

    private func bytes(_ kind: DocumentKind, id: String) throws -> Data {
        MainThreadOpenTrap.check(kind: kind, id: id)
        if let data = try? Data(contentsOf: url(kind: kind, id: id)) {
            return data
        } else {
            throw StoreError.documentNotFound(kind: kind, id: id)
        }
    }

    public func delete(kind: DocumentKind, id: String) throws {
        let fileURL = url(kind: kind, id: id)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
    }

    public func ids(of kind: DocumentKind) throws -> [String] {
        let dir = rootURL.appendingPathComponent(kind.directoryName, isDirectory: true)
        let contents = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        return contents
            .filter { $0.pathExtension == "automerge" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted()
    }
}

public extension DocumentStore {

    static let decodeWidth = 4

    @concurrent
    func loadValue<Entity: DocumentEntity>(_ type: Entity.Type, id: String) async throws -> Entity {
        try parts(type, id: id).value
    }

    @concurrent
    internal func loadReplicaParts<Entity: DocumentEntity>(_ type: Entity.Type, id: String) async throws -> ReplicaParts<Entity> {
        try parts(type, id: id)
    }

    @concurrent
    internal func loadReplicaParts<Entity: DocumentEntity>(
        _ type: Entity.Type, ids: [String], width: Int
    ) async -> [String: ReplicaParts<Entity>] {
        await withTaskGroup(of: (id: String, parts: ReplicaParts<Entity>?).self) { group in
            var loaded: [String: ReplicaParts<Entity>] = [:]
            var queue = ids.makeIterator()
            for _ in 0..<Swift.max(1, width) {
                if let id = queue.next() {
                    group.addTask { (id, try? parts(type, id: id)) }
                }
            }
            for await result in group {
                if let parts = result.parts {
                    loaded[result.id] = parts
                }
                if let id = queue.next() {
                    group.addTask { (id, try? parts(type, id: id)) }
                }
            }
            return loaded
        }
    }

    @concurrent
    func loadValues<Entity: DocumentEntity>(
        _ type: Entity.Type, ids: [String], priority: TaskPriority? = nil, width: Int = decodeWidth
    ) async -> (values: [String: Entity], failed: Set<String>) {
        await loadValues(type, ids: ids, priority: priority, width: width) { $0 }
    }

    @concurrent
    func loadValues<Entity: DocumentEntity, Projection: Sendable>(
        _ type: Entity.Type, ids: [String], priority: TaskPriority? = nil, width: Int = decodeWidth,
        project: @escaping @Sendable (Entity) -> Projection
    ) async -> (values: [String: Projection], failed: Set<String>) {
        await withTaskGroup(of: (id: String, projection: Projection?).self) { group in
            var values: [String: Projection] = [:]
            var failed = Set<String>()
            var queue = ids.makeIterator()
            for _ in 0..<Swift.max(1, width) {
                if let id = queue.next() {
                    group.addTask(priority: priority) { (id, decode(type, id: id, project)) }
                }
            }
            for await result in group {
                if let projection = result.projection {
                    values[result.id] = projection
                } else {
                    failed.insert(result.id)
                }
                if let id = queue.next() {
                    group.addTask(priority: priority) { (id, decode(type, id: id, project)) }
                }
            }
            return (values, failed)
        }
    }

    private func decode<Entity: DocumentEntity, Projection>(
        _ type: Entity.Type, id: String, _ project: (Entity) -> Projection
    ) -> Projection? {
        (try? parts(type, id: id)).map { project($0.value) }
    }

    private func parts<Entity: DocumentEntity>(_ type: Entity.Type, id: String) throws -> ReplicaParts<Entity> {
        try Library.measuringOpen(kind: Entity.documentKind, id: id) {
            try ReplicaParts<Entity>.decoding(bytes(Entity.documentKind, id: id))
        }
    }
}
