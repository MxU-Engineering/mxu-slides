import Foundation

public struct IndexSnapshot: Sendable, Equatable {

    public let generation: Int
    private let byKind: [DocumentKind: [LibraryIndex.Entry]]
    private let byId: [String: LibraryIndex.Entry]

    private let teamByKind: [DocumentKind: [LibraryIndex.Entry]]
    private let stationByKind: [DocumentKind: [LibraryIndex.Entry]]

    private let areas: [String: LibraryArea]

    public static let unread = -1
    public static let empty = IndexSnapshot(entries: [], areas: [:], generation: unread)

    public init(entries: [LibraryIndex.Entry], areas: [String: LibraryArea], generation: Int) {
        self.generation = generation
        self.areas = areas
        let byKind = Dictionary(grouping: entries, by: \.kind)
        self.byKind = byKind
        byId = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var team: [DocumentKind: [LibraryIndex.Entry]] = [:]
        var station: [DocumentKind: [LibraryIndex.Entry]] = [:]
        for (kind, rows) in byKind where SyncScope.scope(for: kind) == .team {
            let inTeam = rows.filter { areas["\(kind.rawValue)/\($0.id)"] == .team }
            team[kind] = inTeam
            station[kind] = inTeam.isEmpty ? rows : rows.filter { areas["\(kind.rawValue)/\($0.id)"] != .team }
        }
        teamByKind = team
        stationByKind = station
    }

    @LibraryActor
    public static func read(_ index: LibraryIndex) throws -> IndexSnapshot {
        let generation = index.writeGeneration
        return IndexSnapshot(entries: try index.allEntries(), areas: try index.allAreas(), generation: generation)
    }

    public var count: Int { byId.count }

    public func listsLike(_ other: IndexSnapshot) -> Bool {
        areas == other.areas && byKind.count == other.byKind.count
            && byKind.allSatisfy { kind, rows in
                guard let theirs = other.byKind[kind], theirs.count == rows.count else { return false }
                return zip(rows, theirs).allSatisfy { mine, theirs in
                    mine.id == theirs.id && mine.subkind == theirs.subkind && mine.name == theirs.name
                        && mine.lastUsedAt == theirs.lastUsedAt
                }
            }
    }

    public func entries(of kind: DocumentKind) -> [LibraryIndex.Entry] {
        byKind[kind] ?? []
    }

    public func entries(of kind: DocumentKind, subkind: String) -> [LibraryIndex.Entry] {
        entries(of: kind).filter { $0.subkind == subkind }
    }

    public func entry(id: String) -> LibraryIndex.Entry? {
        byId[id]
    }

    public func area(kind: DocumentKind, id: String) -> LibraryArea? {
        areas["\(kind.rawValue)/\(id)"]
    }

    public func browserEntries(of kind: DocumentKind, showing area: LibraryArea) -> [LibraryIndex.Entry] {
        if SyncScope.scope(for: kind) == .team {
            (area == .team ? teamByKind[kind] : stationByKind[kind]) ?? []
        } else {
            entries(of: kind)
        }
    }
}

public enum LibraryBrowseLogic {

    public static func folders(items: [LibraryIndex.Entry], cloudFolders: [String], empties: [String]) -> [String] {
        Set(items.map(\.subkind))
            .union(cloudFolders)
            .subtracting([""])
            .union(empties)
            .sorted()
    }

    public static func childFolders(folders: [String], held: [String], under prefix: [String]) -> [(name: String, count: Int)] {
        var counts = TeamDriveLogic.childCounts(of: folders, under: prefix).mapValues { _ in 0 }
        counts.merge(TeamDriveLogic.childCounts(of: held, under: prefix)) { $0 + $1 }
        return counts.sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
            .map { (name: $0.key, count: $0.value) }
    }

    public static func drives(rows: [String], children: [(name: String, count: Int)]) -> [(name: String, count: Int)] {
        let counts = Dictionary(children.map { ($0.name, $0.count) }, uniquingKeysWith: { first, _ in first })
        return TeamDriveLogic.driveNames(rows: rows, folders: Array(counts.keys))
            .map { (name: $0, count: counts[$0] ?? 0) }
    }

    public static func occupiedTeamFolders(
        in snapshot: IndexSnapshot, kinds: [DocumentKind], cloudFolders: [String]
    ) -> Set<String> {
        var occupied = Set(cloudFolders)
        for kind in kinds where SyncScope.scope(for: kind) == .team {
            occupied.formUnion(snapshot.browserEntries(of: kind, showing: .team).map(\.subkind))
        }
        return occupied.subtracting([""])
    }
}
