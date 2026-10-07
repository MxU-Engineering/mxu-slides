import Foundation

public enum SyncAreaGuess {
    public enum Answer: Equatable, Sendable {

        case unknown

        case known(LibraryArea)

        case guess(LibraryArea)
    }

    public static func answer(
        for key: SyncLedger.Key, isReady: Bool, snapshot: IndexSnapshot, sync: LibrarySyncState
    ) -> Answer {
        if SyncScope.scope(for: key.kind) != .team {
            .known(.station)
        } else if !isReady {
            .unknown
        } else if let row = snapshot.area(kind: key.kind, id: key.id) {
            .known(row)
        } else {
            .guess(LibraryArea.resolve(row: nil, entry: sync.entry(kind: key.kind, id: key.id)))
        }
    }
}
