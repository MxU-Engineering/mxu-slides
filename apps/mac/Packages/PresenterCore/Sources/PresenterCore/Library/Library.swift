import Foundation
import os

@LibraryActor public final class Library {
    public let store: DocumentStore
    public let index: LibraryIndex

    public var didSave: ((DocumentKind, String) -> Void)?
    public var didDelete: ((DocumentKind, String) -> Void)?

    public var author: ChangeAuthor?

    public init(rootURL: URL) throws {
        store = try DocumentStore(rootURL: rootURL)
        let indexURL = rootURL.appendingPathComponent("index.sqlite")
        let indexExisted = FileManager.default.fileExists(atPath: indexURL.path)
        index = try LibraryIndex(url: indexURL)
        if !indexExisted {
            try rebuildIndex()
        }
    }

    @discardableResult
    public func create<Entity: DocumentEntity>(_ value: Entity, seed: TypedDocument<Entity>.SeedIdentity? = nil) throws -> TypedDocument<Entity> {
        let document = try TypedDocument(value, seed: seed)
        document.commitMessage = author?.message(for: Entity.documentKind)
        try save(document)
        return document
    }

    public func open<Entity: DocumentEntity>(_ type: Entity.Type, id: String) throws -> TypedDocument<Entity> {
        try Self.open(type, id: id, from: store, author: author)
    }

    static func open<Entity: DocumentEntity>(
        _ type: Entity.Type, id: String, from store: DocumentStore, author: ChangeAuthor?
    ) throws -> TypedDocument<Entity> {
        let state = perfSignposter.beginInterval("open")
        let start = ContinuousClock.now
        defer {
            perfSignposter.endInterval("open", state)
            let elapsed = start.duration(to: .now)

            if elapsed > .milliseconds(8) {
                perfLog.debug(
                    "slow open \(Entity.documentKind.directoryName, privacy: .public)/\(id, privacy: .public): \(elapsed.description, privacy: .public)"
                )
            }
        }
        let document = try store.load(type, id: id)
        document.commitMessage = author?.message(for: Entity.documentKind)
        return document
    }

    public func save<Entity: DocumentEntity>(_ document: TypedDocument<Entity>) throws {
        let state = perfSignposter.beginInterval("save")
        let start = ContinuousClock.now
        defer {
            perfSignposter.endInterval("save", state)
            let elapsed = start.duration(to: .now)

            if elapsed > .milliseconds(8) {
                perfLog.debug(
                    "slow save \(Entity.documentKind.directoryName, privacy: .public)/\(document.value.id, privacy: .public): \(elapsed.description, privacy: .public)"
                )
            }
        }
        try store.save(document)
        try index.upsert(
            id: document.value.id,
            kind: Entity.documentKind,
            subkind: document.value.indexSubkind,
            name: document.value.name,
            text: document.value.indexText,
            ccli: document.value.indexCCLI,
            folderId: document.value.indexFolderId
        )
        didSave?(Entity.documentKind, document.value.id)
    }

    public func delete(kind: DocumentKind, id: String) throws {
        try store.delete(kind: kind, id: id)
        try index.remove(id: id)
        didDelete?(kind, id)
    }

    @discardableResult
    public func replace<Entity: DocumentEntity>(_ value: Entity) throws -> TypedDocument<Entity> {
        try? delete(kind: Entity.documentKind, id: value.id)
        return try create(value)
    }

    public func seedUsageFromServices(calendar: Calendar = .current) throws {
        let now = Date()
        for entry in try index.entries(of: .service) {
            let service = try store.load(Service.self, id: entry.id).value
            guard let date = ScheduleMath.parseLocalDate(
                service.serviceDate + "T12:00", calendar: calendar
            ) else { continue }
            for item in service.items where !item.refId.isEmpty {
                try index.touchUsage(id: item.refId, at: min(date, now))
            }
        }
    }

    nonisolated public static let listedKinds: [DocumentKind] = [
        .presentation, .service, .theme, .media, .audio, .playlist, .overlay, .outputPreset,
        .alertPreset, .streamRecordPreset, .streamDestination, .actionCombo, .scheduleTrigger,
        .note, .confidenceLayout, .midiDevice,
    ]

    public func rebuildIndex() throws {
        try index.removeAll()
        func reindex<Entity: DocumentEntity>(_ type: Entity.Type) throws {
            for id in try store.ids(of: Entity.documentKind) {
                let value = try store.load(type, id: id).value
                try index.upsert(
                    id: id, kind: Entity.documentKind,
                    subkind: value.indexSubkind, name: value.name,
                    text: value.indexText, ccli: value.indexCCLI, folderId: value.indexFolderId
                )
            }
        }
        for kind in Self.listedKinds {
            try reindex(SyncScope.entityType(for: kind))
        }
    }
}
