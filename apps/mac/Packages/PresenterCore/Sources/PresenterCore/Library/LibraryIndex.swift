import Foundation
import SQLite3

@LibraryActor public final class LibraryIndex {
    public struct Entry: Equatable, Sendable {
        public let id: String
        public let kind: DocumentKind

        public let subkind: String
        public let name: String
        public let updatedAt: Date

        public let lastUsedAt: Date?

        public let origin: String

        public init(id: String, kind: DocumentKind, subkind: String, name: String, updatedAt: Date, lastUsedAt: Date?, origin: String = "") {
            self.id = id
            self.kind = kind
            self.subkind = subkind
            self.name = name
            self.updatedAt = updatedAt
            self.lastUsedAt = lastUsedAt
            self.origin = origin
        }

        public init<E: DocumentEntity>(pending value: E, at date: Date = Date()) {
            self.init(
                id: value.id, kind: E.documentKind, subkind: value.indexSubkind, name: value.name,
                updatedAt: date, lastUsedAt: nil, origin: value.indexOrigin)
        }
    }

    public enum IndexError: Error {
        case sqlite(code: Int32, message: String)
    }

    private struct Connection: ~Copyable {
        let handle: OpaquePointer?

        deinit {
            sqlite3_close(handle)
        }
    }

    private let connection: Connection
    private var db: OpaquePointer? { connection.handle }

    public private(set) var writeGeneration = 0

    public init(url: URL) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, flags, nil) == SQLITE_OK else {
            defer { sqlite3_close(db) }
            throw Self.lastError(db)
        }
        connection = Connection(handle: db)
        try exec("PRAGMA journal_mode = WAL")
        try exec("PRAGMA synchronous = NORMAL")
        try exec("""
            CREATE TABLE IF NOT EXISTS entities (
                id TEXT PRIMARY KEY,
                kind TEXT NOT NULL,
                subkind TEXT NOT NULL DEFAULT '',
                name TEXT NOT NULL,
                updated_at REAL NOT NULL
            )
            """)

        try addColumn("entities", "subkind", "TEXT NOT NULL DEFAULT ''")

        try addColumn("entities", "ccli_number", "INTEGER")
        try addColumn("entities", "ccli_title", "TEXT")

        try addColumn("entities", "folder_id", "TEXT NOT NULL DEFAULT ''")
        try addColumn("entities", "origin", "TEXT NOT NULL DEFAULT ''")
        try exec("CREATE INDEX IF NOT EXISTS entities_kind_name ON entities(kind, name)")

        if try scalarInt("PRAGMA user_version") < 2 {
            try exec("DROP TABLE IF EXISTS entities_fts")
            try exec("""
                CREATE VIRTUAL TABLE entities_fts
                USING fts5(name, content, id UNINDEXED, tokenize = 'unicode61')
                """)
            try exec("INSERT INTO entities_fts (name, content, id) SELECT name, '', id FROM entities")
            try exec("PRAGMA user_version = 2")
        }
        try exec("""
            CREATE VIRTUAL TABLE IF NOT EXISTS entities_fts
            USING fts5(name, content, id UNINDEXED, tokenize = 'unicode61')
            """)

        try exec("""
            CREATE TABLE IF NOT EXISTS usage (
                id TEXT PRIMARY KEY,
                last_used_at REAL NOT NULL
            )
            """)

        try exec("""
            CREATE TABLE IF NOT EXISTS sync_ledger (
                kind TEXT NOT NULL,
                id TEXT NOT NULL,
                last_pushed_heads TEXT NOT NULL DEFAULT '[]',
                applied_seq INTEGER NOT NULL DEFAULT 0,
                remote_seq INTEGER NOT NULL DEFAULT 0,
                pending INTEGER NOT NULL DEFAULT 0,
                last_snapshot_at REAL,
                PRIMARY KEY (kind, id)
            )
            """)
        try exec("""
            CREATE TABLE IF NOT EXISTS sync_identity (
                id INTEGER PRIMARY KEY CHECK (id = 1),
                server_host TEXT NOT NULL,
                team_hex_id TEXT,
                team_name TEXT NOT NULL DEFAULT ''
            )
            """)
        try exec("""
            CREATE TABLE IF NOT EXISTS library_area (
                kind TEXT NOT NULL,
                id TEXT NOT NULL,
                area TEXT NOT NULL,
                PRIMARY KEY (kind, id)
            )
            """)
        try exec("""
            CREATE TABLE IF NOT EXISTS team_folders (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                parent_id TEXT,
                position INTEGER NOT NULL DEFAULT 0,
                library TEXT
            )
            """)

        if try scalarInt("PRAGMA user_version") < 3 {
            try addColumn("team_folders", "library", "TEXT")
            try exec("PRAGMA user_version = 3")
        }
        try exec("""
            CREATE TABLE IF NOT EXISTS blob_sync (
                checksum TEXT PRIMARY KEY,
                uploaded_at REAL NOT NULL
            )
            """)
        try exec("""
            CREATE TABLE IF NOT EXISTS pending_changes (
                kind TEXT NOT NULL,
                id TEXT NOT NULL,
                seq INTEGER NOT NULL,
                bytes BLOB NOT NULL,
                error TEXT NOT NULL DEFAULT '',
                quarantined_at REAL NOT NULL,
                PRIMARY KEY (kind, id, seq)
            )
            """)

        try exec("""
            CREATE TABLE IF NOT EXISTS document_heads (
                kind TEXT NOT NULL,
                id TEXT NOT NULL,
                heads TEXT NOT NULL DEFAULT '[]',
                PRIMARY KEY (kind, id)
            )
            """)

        try exec("""
            CREATE TABLE IF NOT EXISTS held_deletes (
                kind TEXT NOT NULL,
                id TEXT NOT NULL,
                side TEXT NOT NULL,
                namespace TEXT NOT NULL,
                held_at REAL NOT NULL,
                PRIMARY KEY (kind, id, side, namespace)
            )
            """)
    }

    public func syncIdentity() throws -> SyncIdentity? {
        let stmt = try prepare("SELECT server_host, team_hex_id, team_name FROM sync_identity WHERE id = 1", binds: [])
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW, let host = sqlite3_column_text(stmt, 0) else { return nil }
        return SyncIdentity(
            serverHost: String(cString: host),
            teamHexId: sqlite3_column_type(stmt, 1) == SQLITE_NULL ? nil : sqlite3_column_text(stmt, 1).map { String(cString: $0) },
            teamName: sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? "")
    }

    public func setSyncIdentity(_ identity: SyncIdentity) throws {
        try run(
            "INSERT INTO sync_identity (id, server_host, team_hex_id, team_name) VALUES (1, ?, ?, ?) " +
                "ON CONFLICT(id) DO UPDATE SET server_host = excluded.server_host, team_hex_id = excluded.team_hex_id, team_name = excluded.team_name",
            binds: [.text(identity.serverHost), identity.teamHexId.map(Bind.text) ?? .null, .text(identity.teamName)])
    }

    public func resetSyncState() throws {
        try exec("DELETE FROM sync_ledger")
        try exec("DELETE FROM pending_changes")
        try exec("DELETE FROM blob_sync")
        try exec("DELETE FROM held_deletes")
    }

    public func area(kind: DocumentKind, id: String) throws -> LibraryArea? {
        let stmt = try prepare("SELECT area FROM library_area WHERE kind = ? AND id = ?", binds: [.text(kind.rawValue), .text(id)])
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW, let text = sqlite3_column_text(stmt, 0) else { return nil }
        return LibraryArea(rawValue: String(cString: text))
    }

    public func setArea(_ area: LibraryArea, kind: DocumentKind, id: String) throws {
        writeGeneration += 1
        try run(
            "INSERT INTO library_area (kind, id, area) VALUES (?, ?, ?) ON CONFLICT(kind, id) DO UPDATE SET area = excluded.area",
            binds: [.text(kind.rawValue), .text(id), .text(area.rawValue)])
    }

    public func allAreas() throws -> [String: LibraryArea] {
        let stmt = try prepare("SELECT kind, id, area FROM library_area", binds: [])
        defer { sqlite3_finalize(stmt) }
        var areas: [String: LibraryArea] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let kind = sqlite3_column_text(stmt, 0), let id = sqlite3_column_text(stmt, 1), let area = sqlite3_column_text(stmt, 2),
                  let value = LibraryArea(rawValue: String(cString: area)) else { continue }
            areas["\(String(cString: kind))/\(String(cString: id))"] = value
        }
        return areas
    }

    public func teamFolders() throws -> [TeamFolder] {
        let stmt = try prepare("SELECT id, name, parent_id, position, library FROM team_folders", binds: [])
        defer { sqlite3_finalize(stmt) }
        var folders: [TeamFolder] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let id = sqlite3_column_text(stmt, 0), let name = sqlite3_column_text(stmt, 1) {
                folders.append(TeamFolder(
                    id: String(cString: id), name: String(cString: name),
                    parentId: sqlite3_column_text(stmt, 2).map { String(cString: $0) },
                    position: Int(sqlite3_column_int64(stmt, 3)),
                    library: sqlite3_column_text(stmt, 4).flatMap { DocumentKind(rawValue: String(cString: $0)) }))
            }
        }
        return folders
    }

    public func replaceTeamFolders(_ folders: [TeamFolder]) throws {
        try exec("BEGIN IMMEDIATE")
        do {
            try exec("DELETE FROM team_folders")
            for folder in folders {
                try run(
                    "INSERT INTO team_folders (id, name, parent_id, position, library) VALUES (?, ?, ?, ?, ?)",
                    binds: [.text(folder.id), .text(folder.name), folder.parentId.map { .text($0) } ?? .null, .int(folder.position),
                            folder.library.map { .text($0.rawValue) } ?? .null])
            }
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    public struct FolderRef: Equatable, Sendable {
        public var kind: DocumentKind
        public var id: String
        public var folderId: String
        public var folder: String
    }

    public func folderRefs() throws -> [FolderRef] {
        let stmt = try prepare("SELECT kind, id, folder_id, subkind FROM entities WHERE folder_id != ''", binds: [])
        defer { sqlite3_finalize(stmt) }
        var refs: [FolderRef] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let kindText = sqlite3_column_text(stmt, 0), let kind = DocumentKind(rawValue: String(cString: kindText)),
               let id = sqlite3_column_text(stmt, 1), let folderId = sqlite3_column_text(stmt, 2), let folder = sqlite3_column_text(stmt, 3) {
                refs.append(FolderRef(kind: kind, id: String(cString: id), folderId: String(cString: folderId), folder: String(cString: folder)))
            }
        }
        return refs
    }

    public func blobUploaded(_ checksum: String) throws -> Bool {
        let stmt = try prepare("SELECT 1 FROM blob_sync WHERE checksum = ?", binds: [.text(checksum)])
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    public func markBlobUploaded(_ checksum: String, at date: Date = Date()) throws {
        try run(
            "INSERT INTO blob_sync (checksum, uploaded_at) VALUES (?, ?) ON CONFLICT(checksum) DO UPDATE SET uploaded_at = excluded.uploaded_at",
            binds: [.text(checksum), .real(date.timeIntervalSince1970)])
    }

    public func forgetBlobUploaded(_ checksum: String) throws {
        try run("DELETE FROM blob_sync WHERE checksum = ?", binds: [.text(checksum)])
    }

    public func syncEntry(kind: DocumentKind, id: String) throws -> SyncLedger.Entry? {
        let stmt = try prepare(
            "SELECT last_pushed_heads, applied_seq, remote_seq, pending, last_snapshot_at FROM sync_ledger WHERE kind = ? AND id = ?",
            binds: [.text(kind.rawValue), .text(id)])
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return Self.syncEntry(stmt)
    }

    public func setSyncEntry(_ entry: SyncLedger.Entry, kind: DocumentKind, id: String) throws {
        let heads = String(decoding: (try? JSONEncoder().encode(entry.lastPushedHeads)) ?? Data("[]".utf8), as: UTF8.self)
        try run(
            "INSERT INTO sync_ledger (kind, id, last_pushed_heads, applied_seq, remote_seq, pending, last_snapshot_at) " +
                "VALUES (?, ?, ?, ?, ?, ?, ?) " +
                "ON CONFLICT(kind, id) DO UPDATE SET last_pushed_heads = excluded.last_pushed_heads, " +
                "applied_seq = excluded.applied_seq, remote_seq = excluded.remote_seq, pending = excluded.pending, " +
                "last_snapshot_at = excluded.last_snapshot_at",
            binds: [
                .text(kind.rawValue), .text(id), .text(heads), .int(entry.appliedSeq), .int(entry.remoteSeq),
                .int(entry.pending ? 1 : 0), entry.lastSnapshotAt.map { .real($0.timeIntervalSince1970) } ?? .null,
            ])
    }

    public func removeSyncEntry(kind: DocumentKind, id: String) throws {
        try run("DELETE FROM sync_ledger WHERE kind = ? AND id = ?", binds: [.text(kind.rawValue), .text(id)])
        try run("DELETE FROM pending_changes WHERE kind = ? AND id = ?", binds: [.text(kind.rawValue), .text(id)])
    }

    public func allSyncEntries() throws -> [SyncLedger.Key: SyncLedger.Entry] {
        let stmt = try prepare(
            "SELECT last_pushed_heads, applied_seq, remote_seq, pending, last_snapshot_at, kind, id FROM sync_ledger", binds: [])
        defer { sqlite3_finalize(stmt) }
        var entries: [SyncLedger.Key: SyncLedger.Entry] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let kindText = sqlite3_column_text(stmt, 5), let idText = sqlite3_column_text(stmt, 6),
                  let kind = DocumentKind(rawValue: String(cString: kindText)) else { continue }
            entries[SyncLedger.Key(kind: kind, id: String(cString: idText))] = Self.syncEntry(stmt)
        }
        return entries
    }

    private static func syncEntry(_ stmt: OpaquePointer) -> SyncLedger.Entry {
        let headsText = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? "[]"
        return SyncLedger.Entry(
            lastPushedHeads: (try? JSONDecoder().decode([String].self, from: Data(headsText.utf8))) ?? [],
            appliedSeq: Int(sqlite3_column_int64(stmt, 1)),
            remoteSeq: Int(sqlite3_column_int64(stmt, 2)),
            pending: sqlite3_column_int64(stmt, 3) != 0,
            lastSnapshotAt: sqlite3_column_type(stmt, 4) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(stmt, 4)))
    }

    public func quarantine(kind: DocumentKind, id: String, seq: Int, bytes: Data, error: String, at date: Date = Date()) throws {
        try run(
            "INSERT OR REPLACE INTO pending_changes (kind, id, seq, bytes, error, quarantined_at) VALUES (?, ?, ?, ?, ?, ?)",
            binds: [.text(kind.rawValue), .text(id), .int(seq), .blob(bytes), .text(error), .real(date.timeIntervalSince1970)])
    }

    public func quarantined(kind: DocumentKind, id: String) throws -> [SyncLedger.Quarantined] {
        let stmt = try prepare(
            "SELECT seq, bytes, error, quarantined_at FROM pending_changes WHERE kind = ? AND id = ? ORDER BY seq",
            binds: [.text(kind.rawValue), .text(id)])
        defer { sqlite3_finalize(stmt) }
        var rows: [SyncLedger.Quarantined] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let length = Int(sqlite3_column_bytes(stmt, 1))
            let bytes = sqlite3_column_blob(stmt, 1).map { Data(bytes: $0, count: length) } ?? Data()
            rows.append(SyncLedger.Quarantined(
                seq: Int(sqlite3_column_int64(stmt, 0)), bytes: bytes,
                error: sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? "",
                quarantinedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3))))
        }
        return rows
    }

    public func clearQuarantine(kind: DocumentKind, id: String) throws {
        try run("DELETE FROM pending_changes WHERE kind = ? AND id = ?", binds: [.text(kind.rawValue), .text(id)])
    }

    public func setDocumentHeads(_ heads: [String], kind: DocumentKind, id: String) throws {
        let text = String(decoding: (try? JSONEncoder().encode(heads)) ?? Data("[]".utf8), as: UTF8.self)
        try run(
            "INSERT INTO document_heads (kind, id, heads) VALUES (?, ?, ?) ON CONFLICT(kind, id) DO UPDATE SET heads = excluded.heads",
            binds: [.text(kind.rawValue), .text(id), .text(text)])
    }

    public func allDocumentHeads() throws -> [SyncLedger.Key: [String]] {
        let stmt = try prepare("SELECT kind, id, heads FROM document_heads", binds: [])
        defer { sqlite3_finalize(stmt) }
        var heads: [SyncLedger.Key: [String]] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let kindText = sqlite3_column_text(stmt, 0), let idText = sqlite3_column_text(stmt, 1),
               let kind = DocumentKind(rawValue: String(cString: kindText)) {
                let text = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? "[]"
                heads[SyncLedger.Key(kind: kind, id: String(cString: idText))] = (try? JSONDecoder().decode([String].self, from: Data(text.utf8))) ?? []
            }
        }
        return heads
    }

    public func holdDelete(_ held: SyncLedger.HeldDelete) throws {
        try run(
            "INSERT OR REPLACE INTO held_deletes (kind, id, side, namespace, held_at) VALUES (?, ?, ?, ?, ?)",
            binds: [
                .text(held.key.kind.rawValue), .text(held.key.id), .text(held.side.rawValue), .text(held.namespace.rawValue),
                .real(held.heldAt.timeIntervalSince1970),
            ])
    }

    public func releaseHeldDelete(_ held: SyncLedger.HeldDelete) throws {
        try run(
            "DELETE FROM held_deletes WHERE kind = ? AND id = ? AND side = ? AND namespace = ?",
            binds: [.text(held.key.kind.rawValue), .text(held.key.id), .text(held.side.rawValue), .text(held.namespace.rawValue)])
    }

    public func allHeldDeletes() throws -> [SyncLedger.HeldDelete] {
        let stmt = try prepare("SELECT kind, id, side, namespace, held_at FROM held_deletes ORDER BY held_at, kind, id", binds: [])
        defer { sqlite3_finalize(stmt) }
        var rows: [SyncLedger.HeldDelete] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let kindText = sqlite3_column_text(stmt, 0), let idText = sqlite3_column_text(stmt, 1),
               let sideText = sqlite3_column_text(stmt, 2), let namespaceText = sqlite3_column_text(stmt, 3),
               let kind = DocumentKind(rawValue: String(cString: kindText)),
               let side = SyncLedger.HeldDelete.Side(rawValue: String(cString: sideText)),
               let namespace = SyncScope(rawValue: String(cString: namespaceText)) {
                rows.append(SyncLedger.HeldDelete(
                    key: SyncLedger.Key(kind: kind, id: String(cString: idText)), side: side, namespace: namespace,
                    heldAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 4))))
            }
        }
        return rows
    }

    public func upsert(
        id: String, kind: DocumentKind, subkind: String = "", name: String,
        text: String = "", updatedAt: Date = Date(), ccli: IndexCCLI = .none, folderId: String = "",
        origin: String = ""
    ) throws {
        writeGeneration += 1
        try exec("BEGIN IMMEDIATE")
        do {
            try run(
                "INSERT INTO entities (id, kind, subkind, name, updated_at, ccli_number, ccli_title, folder_id, origin) " +
                    "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?) " +
                    "ON CONFLICT(id) DO UPDATE SET kind = excluded.kind, subkind = excluded.subkind, " +
                    "name = excluded.name, updated_at = excluded.updated_at, " +
                    "ccli_number = excluded.ccli_number, ccli_title = excluded.ccli_title, folder_id = excluded.folder_id, " +
                    "origin = excluded.origin",
                binds: [
                    .text(id), .text(kind.rawValue), .text(subkind), .text(name),
                    .real(updatedAt.timeIntervalSince1970),
                    ccli.number.map(Bind.int) ?? .null,
                    ccli.title.map(Bind.text) ?? .null,
                    .text(folderId),
                    .text(origin),
                ]
            )
            try run("DELETE FROM entities_fts WHERE id = ?", binds: [.text(id)])
            try run(
                "INSERT INTO entities_fts (name, content, id) VALUES (?, ?, ?)",
                binds: [.text(name), .text(text), .text(id)]
            )
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    public func remove(id: String) throws {
        try remove(ids: [id])
    }

    public func remove(ids: [String]) throws {
        writeGeneration += 1
        try exec("BEGIN IMMEDIATE")
        do {
            for id in ids {
                try run("DELETE FROM entities WHERE id = ?", binds: [.text(id)])
                try run("DELETE FROM entities_fts WHERE id = ?", binds: [.text(id)])
                try run("DELETE FROM usage WHERE id = ?", binds: [.text(id)])
                try run("DELETE FROM library_area WHERE id = ?", binds: [.text(id)])
                try run("DELETE FROM sync_ledger WHERE id = ?", binds: [.text(id)])
                try run("DELETE FROM pending_changes WHERE id = ?", binds: [.text(id)])
                try run("DELETE FROM document_heads WHERE id = ?", binds: [.text(id)])
            }
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    public func removeAll() throws {
        writeGeneration += 1
        try exec("DELETE FROM entities")
        try exec("DELETE FROM entities_fts")
    }

    public func touchUsage(id: String, at date: Date = Date()) throws {
        writeGeneration += 1
        try run(
            "INSERT INTO usage (id, last_used_at) VALUES (?, ?) " +
                "ON CONFLICT(id) DO UPDATE SET last_used_at = max(last_used_at, excluded.last_used_at)",
            binds: [.text(id), .real(date.timeIntervalSince1970)]
        )
    }

    public func mergeUsage(_ stamps: [String: Date]) throws {
        try exec("BEGIN IMMEDIATE")
        do {
            for (id, date) in stamps {
                try touchUsage(id: id, at: date)
            }
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    public func allUsage() throws -> [String: Date] {
        let stmt = try prepare("SELECT id, last_used_at FROM usage", binds: [])
        defer { sqlite3_finalize(stmt) }
        var stamps: [String: Date] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let id = sqlite3_column_text(stmt, 0) {
                stamps[String(cString: id)] = Date(
                    timeIntervalSince1970: sqlite3_column_double(stmt, 1))
            }
        }
        return stamps
    }

    public var count: Int {
        (try? scalarInt("SELECT COUNT(*) FROM entities")) ?? 0
    }

    private static let entryColumns =
        "e.id, e.kind, e.subkind, e.name, e.updated_at, u.last_used_at, e.origin"
    private static let entryFrom = "FROM entities e LEFT JOIN usage u ON u.id = e.id"

    public struct MatchKey: Equatable, Sendable {
        public var id: String
        public var name: String
        public var ccliNumber: Int?
        public var ccliTitle: String?
    }

    public func presentationMatchKeys() throws -> [MatchKey] {
        let stmt = try prepare(
            "SELECT id, name, ccli_number, ccli_title FROM entities WHERE kind = ?",
            binds: [.text(DocumentKind.presentation.rawValue)])
        defer { sqlite3_finalize(stmt) }
        var results: [MatchKey] = []
        while true {
            switch sqlite3_step(stmt) {
            case SQLITE_ROW:
                guard let idText = sqlite3_column_text(stmt, 0),
                      let nameText = sqlite3_column_text(stmt, 1)
                else { continue }
                results.append(MatchKey(
                    id: String(cString: idText),
                    name: String(cString: nameText),
                    ccliNumber: sqlite3_column_type(stmt, 2) == SQLITE_NULL
                        ? nil : Int(sqlite3_column_int64(stmt, 2)),
                    ccliTitle: sqlite3_column_type(stmt, 3) == SQLITE_NULL
                        ? nil : sqlite3_column_text(stmt, 3).map { String(cString: $0) }
                ))
            case SQLITE_DONE:
                return results
            default:
                throw Self.lastError(db)
            }
        }
    }

    public func entries(of kind: DocumentKind, subkind: String? = nil) throws -> [Entry] {
        if let subkind {
            return try queryEntries(
                "SELECT \(Self.entryColumns) \(Self.entryFrom) WHERE kind = ? AND subkind = ? ORDER BY name",
                binds: [.text(kind.rawValue), .text(subkind)]
            )
        }
        return try queryEntries(
            "SELECT \(Self.entryColumns) \(Self.entryFrom) WHERE kind = ? ORDER BY name",
            binds: [.text(kind.rawValue)]
        )
    }

    public func allEntries() throws -> [Entry] {
        try queryEntries(
            "SELECT \(Self.entryColumns) \(Self.entryFrom) ORDER BY e.kind, e.name, e.rowid",
            binds: []
        )
    }

    public func entry(id: String) throws -> Entry? {
        try queryEntries(
            "SELECT \(Self.entryColumns) \(Self.entryFrom) WHERE e.id = ?",
            binds: [.text(id)]
        ).first
    }

    public struct Hit: Equatable, Sendable {
        public let entry: Entry
        public let snippet: String?

        public init(entry: Entry, snippet: String?) {
            self.entry = entry
            self.snippet = snippet
        }
    }

    public func search(_ query: String) throws -> [Entry] {
        try searchHits(query).map(\.entry)
    }

    public func searchHits(_ query: String) throws -> [Hit] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let match = trimmed
            .split(separator: " ")
            .map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"*" }
            .joined(separator: " ")
        let sql =
            "SELECT \(Self.entryColumns), " +
            "snippet(entities_fts, 1, '', '', '…', 8) " +
            "FROM entities_fts f JOIN entities e ON e.id = f.id " +
            "LEFT JOIN usage u ON u.id = e.id " +
            "WHERE entities_fts MATCH ? ORDER BY bm25(entities_fts, 10.0, 1.0) LIMIT 100"
        let stmt = try prepare(sql, binds: [.text(match)])
        defer { sqlite3_finalize(stmt) }
        var hits: [Hit] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard
                let idText = sqlite3_column_text(stmt, 0),
                let kindText = sqlite3_column_text(stmt, 1),
                let subkindText = sqlite3_column_text(stmt, 2),
                let nameText = sqlite3_column_text(stmt, 3),
                let kind = DocumentKind(rawValue: String(cString: kindText))
            else { continue }
            let snippetText = sqlite3_column_text(stmt, 7).map { String(cString: $0) } ?? ""
            hits.append(Hit(
                entry: Entry(
                    id: String(cString: idText),
                    kind: kind,
                    subkind: String(cString: subkindText),
                    name: String(cString: nameText),
                    updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 4)),
                    lastUsedAt: sqlite3_column_type(stmt, 5) == SQLITE_NULL
                        ? nil : Date(timeIntervalSince1970: sqlite3_column_double(stmt, 5)),
                    origin: sqlite3_column_text(stmt, 6).map { String(cString: $0) } ?? ""
                ),
                snippet: snippetText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? nil : snippetText
            ))
        }

        let lowered = trimmed.lowercased()
        return hits.sorted { a, b in
            func tier(_ hit: Hit) -> Int {
                let name = hit.entry.name.lowercased()
                if name == lowered { return 0 }
                if name.hasPrefix(lowered) { return 1 }
                return 2
            }
            let (ta, tb) = (tier(a), tier(b))
            if ta != tb { return ta < tb }
            switch (a.entry.lastUsedAt, b.entry.lastUsedAt) {
            case let (usedA?, usedB?): return usedA > usedB
            case (.some, nil): return true
            default: return false
            }
        }
    }

    private enum Bind {
        case text(String)
        case real(Double)
        case int(Int)
        case blob(Data)
        case null
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func exec(_ sql: String) throws {
        Self.countStatement()
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw Self.lastError(db) }
    }

    private func addColumn(_ table: String, _ column: String, _ type: String) throws {
        let stmt = try prepare("SELECT 1 FROM pragma_table_info(?) WHERE name = ?", binds: [.text(table), .text(column)])
        let exists = sqlite3_step(stmt) == SQLITE_ROW
        sqlite3_finalize(stmt)
        if !exists { try exec("ALTER TABLE \(table) ADD COLUMN \(column) \(type)") }
    }

    private func prepare(_ sql: String, binds: [Bind]) throws -> OpaquePointer {
        Self.countStatement()
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw Self.lastError(db)
        }
        for (i, bind) in binds.enumerated() {
            let idx = Int32(i + 1)
            let code = switch bind {
            case .text(let s): sqlite3_bind_text(stmt, idx, s, -1, Self.transient)
            case .real(let d): sqlite3_bind_double(stmt, idx, d)
            case .int(let n): sqlite3_bind_int64(stmt, idx, Int64(n))
            case .blob(let data): data.withUnsafeBytes { sqlite3_bind_blob(stmt, idx, $0.baseAddress, Int32(data.count), Self.transient) }
            case .null: sqlite3_bind_null(stmt, idx)
            }
            guard code == SQLITE_OK else {
                sqlite3_finalize(stmt)
                throw Self.lastError(db)
            }
        }
        return stmt
    }

    private func run(_ sql: String, binds: [Bind]) throws {
        let stmt = try prepare(sql, binds: binds)
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw Self.lastError(db) }
    }

    private func queryEntries(_ sql: String, binds: [Bind]) throws -> [Entry] {
        let stmt = try prepare(sql, binds: binds)
        defer { sqlite3_finalize(stmt) }
        var results: [Entry] = []
        while true {
            switch sqlite3_step(stmt) {
            case SQLITE_ROW:
                guard
                    let idText = sqlite3_column_text(stmt, 0),
                    let kindText = sqlite3_column_text(stmt, 1),
                    let subkindText = sqlite3_column_text(stmt, 2),
                    let nameText = sqlite3_column_text(stmt, 3),
                    let kind = DocumentKind(rawValue: String(cString: kindText))
                else { continue }
                results.append(Entry(
                    id: String(cString: idText),
                    kind: kind,
                    subkind: String(cString: subkindText),
                    name: String(cString: nameText),
                    updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 4)),
                    lastUsedAt: sqlite3_column_type(stmt, 5) == SQLITE_NULL
                        ? nil : Date(timeIntervalSince1970: sqlite3_column_double(stmt, 5)),
                    origin: sqlite3_column_text(stmt, 6).map { String(cString: $0) } ?? ""
                ))
            case SQLITE_DONE:
                return results
            default:
                throw Self.lastError(db)
            }
        }
    }

    private func scalarInt(_ sql: String) throws -> Int {
        let stmt = try prepare(sql, binds: [])
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { throw Self.lastError(db) }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    private static func lastError(_ db: OpaquePointer?) -> IndexError {
        IndexError(
            code: sqlite3_errcode(db),
            message: String(cString: sqlite3_errmsg(db))
        )
    }
}

private extension LibraryIndex.IndexError {
    init(code: Int32, message: String) {
        self = .sqlite(code: code, message: message)
    }
}
