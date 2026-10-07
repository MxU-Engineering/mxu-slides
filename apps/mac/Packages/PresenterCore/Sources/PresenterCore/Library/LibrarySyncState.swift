import Foundation

public struct LibrarySyncState: Sendable, Equatable {
    public static let empty = LibrarySyncState()

    public private(set) var entries: [SyncLedger.Key: SyncLedger.Entry]

    public private(set) var pendingCount: Int

    public internal(set) var teamFolders: [TeamFolder]

    public internal(set) var identity: SyncIdentity?

    public internal(set) var heldDeletes: [SyncLedger.HeldDelete]

    public init(
        entries: [SyncLedger.Key: SyncLedger.Entry] = [:], teamFolders: [TeamFolder] = [], identity: SyncIdentity? = nil,
        heldDeletes: [SyncLedger.HeldDelete] = []
    ) {
        self.entries = entries
        pendingCount = entries.values.filter(\.pending).count
        self.teamFolders = teamFolders
        self.identity = identity
        self.heldDeletes = heldDeletes
    }

    public var syncedCount: Int { entries.count }

    public func entry(kind: DocumentKind, id: String) -> SyncLedger.Entry? {
        entries[SyncLedger.Key(kind: kind, id: id)]
    }

    public var pendingKeys: [SyncLedger.Key] {
        entries.filter(\.value.pending).map(\.key).sorted { ($0.kind.rawValue, $0.id) < ($1.kind.rawValue, $1.id) }
    }

    @LibraryActor
    static func read(_ index: LibraryIndex) throws -> LibrarySyncState {
        LibrarySyncState(
            entries: try index.allSyncEntries(), teamFolders: try index.teamFolders(), identity: try index.syncIdentity(),
            heldDeletes: try index.allHeldDeletes())
    }

    mutating func hold(_ held: SyncLedger.HeldDelete) {
        if let at = heldDeletes.firstIndex(where: { $0.sameHold(as: held) }) {
            heldDeletes[at] = held
        } else {
            heldDeletes.append(held)
        }
    }

    mutating func release(_ held: SyncLedger.HeldDelete) {
        heldDeletes.removeAll { $0.sameHold(as: held) }
    }

    mutating func set(_ entry: SyncLedger.Entry, for key: SyncLedger.Key) {
        pendingCount += (entry.pending ? 1 : 0) - (entries[key]?.pending == true ? 1 : 0)
        entries[key] = entry
    }

    mutating func remove(_ key: SyncLedger.Key) {
        pendingCount -= entries[key]?.pending == true ? 1 : 0
        entries[key] = nil
    }

    mutating func removeAll(id: String) {
        for kind in DocumentKind.allCases {
            remove(SyncLedger.Key(kind: kind, id: id))
        }
    }

    mutating func resetLedger() {
        entries = [:]
        pendingCount = 0
        heldDeletes = []
    }
}
