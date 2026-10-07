import Foundation

public enum LibrarySort: String, CaseIterable, Sendable {
    case name, dateModified, recentlyUsed

    public var title: String {
        switch self {
        case .name: "Name"
        case .dateModified: "Date Modified"
        case .recentlyUsed: "Recently Used"
        }
    }

    public static func defaultsKey(section: String) -> String {
        "library.sort." + section
    }

    public func ordered(_ entries: [LibraryIndex.Entry]) -> [LibraryIndex.Entry] {
        switch self {
        case .name:
            entries
        case .dateModified:
            entries.enumerated().sorted { ($0.element.updatedAt, $1.offset) > ($1.element.updatedAt, $0.offset) }.map(\.element)
        case .recentlyUsed:
            entries.enumerated().sorted {
                let (a, b) = ($0.element.lastUsedAt ?? .distantPast, $1.element.lastUsedAt ?? .distantPast)
                return a == b ? $0.offset < $1.offset : a > b
            }.map(\.element)
        }
    }
}

public enum LibraryBrowserRow: Equatable, Sendable, Identifiable {
    case held(LibraryIndex.Entry)
    case cloud(TeamCloudItem)

    public var id: String {
        switch self {
        case .held(let entry): entry.id
        case .cloud(let item): item.id
        }
    }
}

extension LibrarySort {

    public func merged(_ held: [LibraryIndex.Entry], cloud: [TeamCloudItem]) -> [LibraryBrowserRow] {
        let cloudKeys = cloud.map { RowKey(name: $0.name, updated: $0.updatedAt ?? .distantPast, used: .distantPast) }
        let sortedCloud = zip(cloud, cloudKeys).enumerated()
            .sorted { precedes($0.element.1, $1.element.1) || (!precedes($1.element.1, $0.element.1) && $0.offset < $1.offset) }
            .map(\.element)
        var rows: [LibraryBrowserRow] = []
        rows.reserveCapacity(held.count + cloud.count)
        var next = 0
        for entry in held {
            let key = RowKey(name: entry.name, updated: entry.updatedAt, used: entry.lastUsedAt ?? .distantPast)
            while next < sortedCloud.count, precedes(sortedCloud[next].1, key) {
                rows.append(.cloud(sortedCloud[next].0))
                next += 1
            }
            rows.append(.held(entry))
        }
        rows.append(contentsOf: sortedCloud[next...].map { .cloud($0.0) })
        return rows
    }

    private struct RowKey {
        var name: String
        var updated: Date
        var used: Date
    }

    private func precedes(_ a: RowKey, _ b: RowKey) -> Bool {
        let byName = !a.name.utf8.elementsEqual(b.name.utf8) && a.name.utf8.lexicographicallyPrecedes(b.name.utf8)
        return switch self {
        case .name: byName
        case .dateModified: a.updated == b.updated ? byName : a.updated > b.updated
        case .recentlyUsed: a.used == b.used ? byName : a.used > b.used
        }
    }
}

public enum UpcomingUse {

    public static let kinds: Set<DocumentKind> = [.service, .presentation, .media, .audio]

    public static func services(_ entries: [LibraryIndex.Entry], today: Date, calendar: Calendar = .current) -> [String] {
        let start = calendar.startOfDay(for: today)
        return entries.filter { entry in
            ServiceMenuLogic.parseISODate(entry.subkind, calendar: calendar).map { $0 >= start } ?? false
        }.map(\.id)
    }

    public static func references(of service: Service) -> Set<String> {
        Set(ServiceVersions.allItems(service).flatMap { [$0.refId, $0.mxuMessageNotesDeckDocId].compactMap(\.self) }).subtracting([""])
    }
}
