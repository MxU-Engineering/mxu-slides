import Foundation

public enum ChangeOrigin: String, Sendable, Equatable {

    case local

    case landed

    case deleted
}

public struct DocumentChange: Sendable {
    public let kind: DocumentKind
    public let id: String
    public let origin: ChangeOrigin
    public let value: (any DocumentEntity)?

    public let listed: Bool

    public let heads: [String]?

    public let syncedUnder: SyncScope?

    public let bundle: EditorBundle?

    public init(
        kind: DocumentKind, id: String, origin: ChangeOrigin, value: (any DocumentEntity)?,
        listed: Bool = true, heads: [String]? = nil, syncedUnder: SyncScope? = nil, bundle: EditorBundle? = nil
    ) {
        self.kind = kind
        self.id = id
        self.origin = origin
        self.value = value
        self.listed = listed
        self.heads = heads
        self.syncedUnder = syncedUnder
        self.bundle = bundle
    }

    public var key: SyncLedger.Key { SyncLedger.Key(kind: kind, id: id) }

    public func value<E: DocumentEntity>(as type: E.Type) -> E? {
        value as? E
    }
}

public struct AreaMove: Sendable, Equatable {
    public let kind: DocumentKind
    public let id: String
    public let from: LibraryArea
    public let to: LibraryArea
    public let origin: ChangeOrigin

    public init(kind: DocumentKind, id: String, from: LibraryArea, to: LibraryArea, origin: ChangeOrigin) {
        self.kind = kind
        self.id = id
        self.from = from
        self.to = to
        self.origin = origin
    }
}

public struct LibraryBatch: Sendable {
    public let sequence: Int
    public let changes: [DocumentChange]
    public let areaMoves: [AreaMove]
    public let snapshot: IndexSnapshot
    public let sync: LibrarySyncState

    public init(
        sequence: Int, changes: [DocumentChange], areaMoves: [AreaMove], snapshot: IndexSnapshot,
        sync: LibrarySyncState = .empty
    ) {
        self.sequence = sequence
        self.changes = changes
        self.areaMoves = areaMoves
        self.snapshot = snapshot
        self.sync = sync
    }

    public func value<E: DocumentEntity>(_ type: E.Type, id: String) -> E? {
        changes.last { $0.kind == E.documentKind && $0.id == id }?.value(as: E.self)
    }
}
