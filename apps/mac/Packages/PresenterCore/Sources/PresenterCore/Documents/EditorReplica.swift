import Automerge
import Foundation

public final class EditorReplica<Entity: DocumentEntity> {
    let core: ReplicaCore<Entity>

    init(parts: ReplicaParts<Entity>) {
        core = ReplicaCore(document: parts.document, value: parts.value)
    }

    public var value: Entity { core.value }

    public var commitMessage: String? {
        get { core.commitMessage }
        set { core.commitMessage = newValue }
    }

    @discardableResult
    public func update(_ mutate: (inout Entity) throws -> Void) throws -> Entity {
        try core.update(mutate)
    }

    @discardableResult
    public func update<Subtree: Codable & Equatable>(
        _ keyPath: WritableKeyPath<Entity, Subtree>,
        at path: [AnyCodingKey],
        _ mutate: (inout Subtree) throws -> Void
    ) throws -> Entity {
        try core.update(keyPath, at: path, mutate)
    }

    @discardableResult
    public func moveListElement(
        listAt path: [AnyCodingKey],
        from: Int,
        before: Int?,
        settingOnMoved fields: [String: ScalarValue?] = [:],
        next: Entity
    ) throws -> Entity {
        try core.moveListElement(listAt: path, from: from, before: before, settingOnMoved: fields, next: next)
    }

    @discardableResult
    public func undo() throws -> Entity {
        try core.undo(scoped: true)
    }

    @discardableResult
    public func redo() throws -> Entity {
        try core.redo(scoped: true)
    }

    public var wholeWrite: String? { core.wholeWrite }

    public var canUndo: Bool { core.canUndo }
    public var canRedo: Bool { core.canRedo }

    public func heads() -> Set<ChangeHash> {
        core.document.heads()
    }

    public func contains(heads: Set<ChangeHash>) -> Bool {
        core.contains(heads: heads)
    }

    public func encodeChangesSince(heads: Set<ChangeHash>) throws -> Data {
        try core.document.encodeChangesSince(heads: heads)
    }

    public func applyLanded(_ bundle: EditorBundle) -> EditorLanding {
        core.applyLanded(bundle)
    }

    @discardableResult
    public func absorb(_ changes: Data) throws -> Bool {
        try core.absorb(changes)
    }

    public var history: EditorHistory { core.history }

    @discardableResult
    public func restore(history: EditorHistory) -> Bool {
        core.restore(history)
    }
}

extension EditorReplica where Entity == Presentation {

    @discardableResult
    public func updateDeck(_ mutate: (inout Presentation) throws -> Void) throws -> Presentation {
        try core.updateDeck(mutate)
    }
}

public struct EditorBundle: Sendable, Equatable {

    public let base: Set<ChangeHash>

    public let changes: Data

    public let slideScoped: Bool

    public let replaced: Bool

    public init(base: Set<ChangeHash>, changes: Data, slideScoped: Bool, replaced: Bool) {
        self.base = base
        self.changes = changes
        self.slideScoped = slideScoped
        self.replaced = replaced
    }
}

public enum EditorLanding: Sendable, Equatable {

    case applied(moved: Bool)

    case refused
}

public struct EditorHistory: Sendable, Equatable {
    public let undo: [Set<ChangeHash>]
    public let redo: [Set<ChangeHash>]
    public let heads: Set<ChangeHash>

    public init(undo: [Set<ChangeHash>], redo: [Set<ChangeHash>], heads: Set<ChangeHash>) {
        self.undo = undo
        self.redo = redo
        self.heads = heads
    }

    public var isEmpty: Bool { undo.isEmpty && redo.isEmpty }
}
