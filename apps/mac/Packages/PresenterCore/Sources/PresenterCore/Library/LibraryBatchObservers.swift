import Foundation

@MainActor public final class LibraryBatchObservers {
    public typealias Token = Int

    private var observers: [(token: Token, observe: (LibraryBatch) -> Void)] = []
    private var next = 0

    public init() {}

    public var count: Int { observers.count }

    @discardableResult
    public func add(_ observe: @escaping (LibraryBatch) -> Void) -> Token {
        next += 1
        observers.append((next, observe))
        return next
    }

    public func remove(_ token: Token) {
        observers.removeAll { $0.token == token }
    }

    public func notify(_ batch: LibraryBatch) {
        for observer in observers {
            observer.observe(batch)
        }
    }
}

public struct SyncBatchRoute: Equatable, Sendable {
    public var edited: [SyncLedger.Key] = []
    public var deleted: [SyncLedger.Key] = []

    public var deletedFrom: [SyncLedger.Key: SyncScope] = [:]
    public var landed: [SyncLedger.Key] = []
    public var moved: [AreaMove] = []

    public init(_ batch: LibraryBatch) {
        for change in batch.changes where Self.carries(change) {
            switch change.origin {
            case .local:
                edited.append(change.key)
            case .deleted:
                deleted.append(change.key)
                deletedFrom[change.key] = change.syncedUnder
            case .landed:
                if change.value != nil { landed.append(change.key) }
            }
        }
        moved = batch.areaMoves.filter { $0.origin == .local }
    }

    public static func carries(_ change: DocumentChange) -> Bool {
        SyncScope.scope(for: change.kind) != .local
    }
}
