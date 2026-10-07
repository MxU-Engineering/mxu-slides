import Foundation

struct LibraryIndexMirror {
    private struct Row {
        var kind: DocumentKind
        var subkind: String
        var name: String
        var updatedAt: Date

        var sequence: Int
    }

    private var rows: [String: Row] = [:]

    private var usage: [String: Date] = [:]
    private(set) var areas: [String: LibraryArea] = [:]
    private var nextSequence = 0

    init() {}

    init(entries: [LibraryIndex.Entry], areas: [String: LibraryArea], usage: [String: Date]) {
        for entry in entries {
            rows[entry.id] = Row(
                kind: entry.kind, subkind: entry.subkind, name: entry.name,
                updatedAt: entry.updatedAt, sequence: nextSequence)
            nextSequence += 1
        }
        self.areas = areas
        self.usage = usage
    }

    @LibraryActor
    static func read(_ index: LibraryIndex) throws -> LibraryIndexMirror {
        LibraryIndexMirror(entries: try index.allEntries(), areas: try index.allAreas(), usage: try index.allUsage())
    }

    var count: Int { rows.count }

    mutating func upsert(id: String, kind: DocumentKind, subkind: String, name: String, updatedAt: Date) {
        if let existing = rows[id] {
            rows[id] = Row(kind: kind, subkind: subkind, name: name, updatedAt: updatedAt, sequence: existing.sequence)
        } else {
            rows[id] = Row(kind: kind, subkind: subkind, name: name, updatedAt: updatedAt, sequence: nextSequence)
            nextSequence += 1
        }
    }

    mutating func remove(id: String) {
        rows[id] = nil
        usage[id] = nil
        for kind in DocumentKind.allCases {
            areas[Self.areaKey(kind, id)] = nil
        }
    }

    mutating func touchUsage(id: String, at date: Date) {
        usage[id] = max(usage[id] ?? date, date)
    }

    func area(kind: DocumentKind, id: String) -> LibraryArea? {
        areas[Self.areaKey(kind, id)]
    }

    mutating func setArea(_ area: LibraryArea, kind: DocumentKind, id: String) {
        areas[Self.areaKey(kind, id)] = area
    }

    func snapshot(generation: Int) -> IndexSnapshot {
        let ordered = rows.sorted { Self.precedes($0.value, $1.value) }
        let entries = ordered.map { id, row in
            LibraryIndex.Entry(
                id: id, kind: row.kind, subkind: row.subkind, name: row.name,
                updatedAt: row.updatedAt, lastUsedAt: usage[id])
        }
        return IndexSnapshot(entries: entries, areas: areas, generation: generation)
    }

    static func indexDate(_ date: Date) -> Date {
        Date(timeIntervalSince1970: date.timeIntervalSince1970)
    }

    private static func areaKey(_ kind: DocumentKind, _ id: String) -> String {
        "\(kind.rawValue)/\(id)"
    }

    private static func precedes(_ a: Row, _ b: Row) -> Bool {
        if !a.kind.rawValue.utf8.elementsEqual(b.kind.rawValue.utf8) {
            a.kind.rawValue.utf8.lexicographicallyPrecedes(b.kind.rawValue.utf8)
        } else if !a.name.utf8.elementsEqual(b.name.utf8) {
            a.name.utf8.lexicographicallyPrecedes(b.name.utf8)
        } else {
            a.sequence < b.sequence
        }
    }
}
