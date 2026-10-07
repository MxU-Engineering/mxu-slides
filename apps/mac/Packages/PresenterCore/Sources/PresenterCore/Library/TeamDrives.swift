import Foundation

public struct TeamCloudItem: Equatable, Sendable, Identifiable {
    public var kind: DocumentKind
    public var id: String
    public var name: String

    public var folder: String

    public var updatedAt: Date?

    public init(kind: DocumentKind, id: String, name: String, folder: String, updatedAt: Date? = nil) {
        self.kind = kind
        self.id = id
        self.name = name
        self.folder = folder
        self.updatedAt = updatedAt
    }
}

public enum LibrarySearchRow: Equatable, Sendable, Identifiable {
    case hit(LibraryIndex.Hit)
    case cloud(TeamCloudItem)

    public var id: String {
        switch self {
        case .hit(let hit): hit.entry.id
        case .cloud(let item): item.id
        }
    }
}

public struct TeamFolder: Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var parentId: String?
    public var position: Int
    public var library: DocumentKind?

    public init(id: String, name: String, parentId: String? = nil, position: Int = 0, library: DocumentKind? = nil) {
        self.id = id
        self.name = name
        self.parentId = parentId
        self.position = position
        self.library = library
    }
}

public struct TeamFolderTree: Equatable, Sendable {
    public let folders: [TeamFolder]
    private let pathById: [String: String]

    private let foldersByPath: [String: [TeamFolder]]

    public static let empty = TeamFolderTree([])

    public init(_ folders: [TeamFolder]) {
        self.folders = folders
        let byId = Dictionary(folders.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var paths: [String: String] = [:]
        for folder in folders {

            var names = [folder.name]
            var seen: Set<String> = [folder.id]
            var parent = folder.parentId
            var whole = true
            while let id = parent, whole {
                if let next = byId[id], seen.insert(id).inserted {
                    names.insert(next.name, at: 0)
                    parent = next.parentId
                } else {
                    whole = false
                }
            }
            if whole { paths[folder.id] = names.joined(separator: "/") }
        }
        pathById = paths
        foldersByPath = Dictionary(grouping: folders.filter { paths[$0.id] != nil }) { paths[$0.id] ?? "" }
    }

    public func path(of id: String) -> String? { pathById[id] }
    public func folder(_ id: String) -> TeamFolder? { folders.first { $0.id == id } }

    public func id(ofPath path: String, library: DocumentKind) -> String? {
        let named = foldersByPath[path] ?? []
        return (named.first { $0.library == library }
            ?? (path == LibraryHome.needsSorted ? nil : named.first { $0.library == nil }))?.id
    }

    public var drives: [TeamFolder] {
        folders.filter { $0.parentId == nil }.sorted {
            $0.position != $1.position ? $0.position < $1.position
                : $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    public func drives(library: DocumentKind, listed: Set<String>) -> [TeamFolder] {
        let own = Set(drives.filter { $0.library == library }.map(\.name))
        return drives.filter { $0.library == library || ($0.library == nil && listed.contains($0.name) && !own.contains($0.name)) }
    }

    public func listedPaths(occupied: Set<String>, library: DocumentKind) -> [String] {
        folders.compactMap { folder in
            pathById[folder.id].flatMap { path in
                folder.library == library
                    || (folder.library == nil && !occupied.contains { TeamDriveLogic.isUnder($0, prefix: path) }) ? path : nil
            }
        }
    }

    public func refreshedPath(folderId: String, folder: String) -> String? {
        pathById[folderId].flatMap { $0 == folder ? nil : $0 }
    }

    public func isStale(folderId: String, for kind: DocumentKind) -> Bool {
        if let folder = folder(folderId) {
            folder.library != nil && folder.library != kind
        } else {
            !folders.isEmpty
        }
    }
}

public enum TeamDriveLogic {

    public static func driveNames(rows: [String], folders: [String]) -> [String] {
        let known = Set(rows)
        let derived = Set(folders.compactMap { OfflineSetLogic.drive(ofFolder: $0) }).subtracting(known)
        return rows + derived.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    public static func filed(folder: String, inDrive drive: String) -> String {
        if folder.isEmpty {
            drive
        } else if isUnder(folder, prefix: drive) {
            folder
        } else {
            drive + "/" + folder
        }
    }

    public static func isUnder(_ folder: String, prefix: String) -> Bool {
        prefix.isEmpty || folder == prefix || folder.hasPrefix(prefix + "/")
    }

    public static func childCounts(of folders: [String], under prefix: [String]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for folder in folders {
            let components = folder.split(separator: "/").map(String.init)
            if components.count > prefix.count, Array(components.prefix(prefix.count)) == prefix {
                counts[components[prefix.count], default: 0] += 1
            }
        }
        return counts
    }

    public static func rebased(folder: String, from: [String], into destination: [String], movedFrom: [String]? = nil) -> String {
        let fromPath = (movedFrom ?? from).joined(separator: "/")
        let newBase = (destination + from.suffix(1)).joined(separator: "/")
        return newBase + folder.dropFirst(fromPath.count)
    }

    public static func renamed(folder: String, from: [String], to name: String) -> String {
        rebased(folder: folder, from: from.dropLast() + [name], into: Array(from.dropLast()), movedFrom: from)
    }

    public static func cloudItems(_ items: [TeamCloudItem], hidden: [String]) -> [TeamCloudItem] {
        items.filter { item in !hidden.contains { !$0.isEmpty && isUnder(item.folder, prefix: $0) } }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public static func cloudMatches(_ items: [TeamCloudItem], query: String) -> [TeamCloudItem] {
        let words = searchWords(query)
        return words.isEmpty ? [] : items.filter { nameMatches($0.name, words: words) }
    }

    public static func searchRows(hits: [LibraryIndex.Hit], cloud: [TeamCloudItem], query: String) -> [LibrarySearchRow] {
        let words = searchWords(query)
        let named = hits.filter { nameMatches($0.entry.name, words: words) }
        let byText = hits.filter { !nameMatches($0.entry.name, words: words) }
        return named.map(LibrarySearchRow.hit) + cloud.map(LibrarySearchRow.cloud) + byText.map(LibrarySearchRow.hit)
    }

    private static func searchWords(_ query: String) -> [String] {
        query.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    private static func nameMatches(_ name: String, words: [String]) -> Bool {
        !words.isEmpty && words.allSatisfy { name.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }

    private static let payloadPrefix = "folder:"
    private static let areaSeparator: Character = "\u{1F}"

    public static func folderPayload(path: [String], area: LibraryArea) -> String {
        payloadPrefix + area.rawValue + String(areaSeparator) + path.joined(separator: "/")
    }

    public static func parseFolderPayload(_ payload: String, fallback: LibraryArea) -> (path: [String], area: LibraryArea)? {
        if payload.hasPrefix(payloadPrefix) {
            let body = payload.dropFirst(payloadPrefix.count)
            let parts = body.split(separator: areaSeparator, maxSplits: 1, omittingEmptySubsequences: false)
            let area = parts.count == 2 ? LibraryArea(rawValue: String(parts[0])) ?? fallback : fallback
            return ((parts.last ?? "").split(separator: "/").map(String.init), area)
        } else {
            return nil
        }
    }
}

public enum StationCleanup {

    public static let kinds: [DocumentKind] = [.presentation, .media, .audio, .overlay, .confidenceLayout, .theme, .playlist, .service]
    static let autoMade: Set<String> = ["ProPresenter Import", "PowerPoint Import", "Lyrics", "MultiViews"]

    public static func doneKey(libraryRoot: URL) -> String {
        "library.stationCleanupDone.v1." + libraryRoot.standardizedFileURL.path
    }

    public static func driveReady(_ tree: TeamFolderTree) -> Bool {
        !tree.folders.isEmpty && tree.folders.allSatisfy { $0.library != nil }
    }

    public static func folder(for kind: DocumentKind, path: String, station: String) -> String? {
        let names = path.split(separator: "/").map(String.init)
        if !TeamFoldered.kinds.contains(kind) {
            return nil
        } else if kind == .media, names.first == RecordingLibrary.defaultFolder {
            return path
        } else {
            return ([station] + names.filter { !autoMade.contains($0) && $0 != station }).joined(separator: "/")
        }
    }
}
