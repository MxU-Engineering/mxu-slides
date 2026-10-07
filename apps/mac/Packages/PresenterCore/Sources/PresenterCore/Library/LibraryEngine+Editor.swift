import Automerge
import Foundation

public struct EditorToken: Hashable, Sendable {
    public let kind: DocumentKind
    public let id: String
    let serial: Int
}

public enum EditorHistoryUse: Sendable, Equatable {

    case parked

    case fresh
}

public struct EditorCheckout<Entity: DocumentEntity> {
    public let replica: EditorReplica<Entity>
    public let token: EditorToken
    public let sequence: Int
}

struct LibraryEditorSessions {
    struct Session {
        let key: SyncLedger.Key

        var ended = false
    }

    private(set) var sessions: [EditorToken: Session] = [:]

    var bases: [SyncLedger.Key: Set<ChangeHash>] = [:]

    var parked: [SyncLedger.Key: EditorHistory] = [:]

    var warming: Set<SyncLedger.Key> = []

    var decoding: Set<SyncLedger.Key> = []

    var liveApplied = 0
    private var serial = 0

    mutating func open(_ key: SyncLedger.Key, base: Set<ChangeHash>) -> EditorToken {
        serial += 1
        let token = EditorToken(kind: key.kind, id: key.id, serial: serial)
        sessions[token] = Session(key: key)
        if bases[key] == nil {
            bases[key] = base
        }
        return token
    }

    mutating func close(_ token: EditorToken) -> Session? {
        let session = sessions.removeValue(forKey: token)
        if let session, !hasSession(session.key) {
            bases[session.key] = nil
        }
        return session
    }

    func hasSession(_ key: SyncLedger.Key) -> Bool {
        sessions.values.contains { $0.key == key }
    }

    func hasEnded(_ token: EditorToken?) -> Bool {
        if let token, let session = sessions[token] {
            session.ended
        } else {
            false
        }
    }

    mutating func end(_ key: SyncLedger.Key) {
        for (token, session) in sessions where session.key == key {
            sessions[token]?.ended = true
        }
        parked[key] = nil
    }
}

extension LibraryEngine {
    public enum EditorError: Error, Equatable, Sendable {

        case sessionEnded
    }

    static let warmWidth = 2

    static let coldAttempts = 3

    public func checkout<E: DocumentEntity>(
        _ type: E.Type, id: String, history: EditorHistoryUse = .parked
    ) async throws -> sending EditorCheckout<E> {
        let key = SyncLedger.Key(kind: E.documentKind, id: id)
        try await installForEditor(type, id: id)
        let canonical = try replica(type, id: id)
        replicas.keep(canonical, stamp: DocumentFileStamp.of(try opened().store.url(kind: key.kind, id: id)))
        let fork = EditorReplica(parts: ReplicaParts(document: canonical.document.fork(), value: canonical.value, persisted: nil))
        fork.commitMessage = currentAuthor?.message(for: E.documentKind)
        if history == .parked, let parked = editors.parked[key] {
            fork.restore(history: parked)
        }
        editors.parked[key] = nil
        replicas.pin(key)
        let token = editors.open(key, base: canonical.heads())
        return EditorCheckout(replica: fork, token: token, sequence: sequence)
    }

    public func release(token: EditorToken, history: EditorHistory? = nil) {
        if let session = editors.close(token) {
            replicas.unpin(session.key)
            if !session.ended {
                replicas.markWarm(session.key)
                if let history, session.key.kind == .presentation, !history.isEmpty {
                    editors.parked[session.key] = history
                }
            }
        }
    }

    public func warm<E: DocumentEntity>(_ type: E.Type, ids: [String]) async {
        await decodeForEditor(type, ids: ids, markingWarm: true)
    }

    public func warmLive(ids: Set<String>) async {
        await warmLive(ids: ids, asked: editors.liveApplied + 1)
    }

    func warmLive(ids: Set<String>, asked: Int) async {
        if asked > editors.liveApplied {
            editors.liveApplied = asked
            replicas.setLive(Set(ids.map { SyncLedger.Key(kind: .presentation, id: $0) }))
            await decodeForEditor(Presentation.self, ids: ids.sorted(), markingWarm: false)
        }
    }

    private func decodeForEditor<E: DocumentEntity>(_ type: E.Type, ids: [String], markingWarm: Bool) async {
        if let store = try? opened().store {
            var wanted: [(id: String, stamp: DocumentFileStamp)] = []
            for id in ids.reduce(into: [String](), { if !$0.contains($1) { $0.append($1) } }) {
                let key = SyncLedger.Key(kind: E.documentKind, id: id)
                let stamp = DocumentFileStamp.of(store.url(kind: key.kind, id: id))
                if replicas.holds(key, stamp: stamp) {
                    if markingWarm {
                        replicas.markWarm(key)
                    }
                } else if let stamp, !editors.warming.contains(key), !editors.decoding.contains(key) {
                    editors.warming.insert(key)
                    wanted.append((id, stamp))
                }
            }
            if !wanted.isEmpty {
                let loaded = if let reader = try? reader() {
                    await reader.loadReplicaParts(type, ids: wanted.map(\.id), width: Self.warmWidth)
                } else {
                    [String: ReplicaParts<E>]()
                }
                for (id, stamp) in wanted {
                    let key = SyncLedger.Key(kind: E.documentKind, id: id)
                    editors.warming.remove(key)
                    if let parts = loaded[id], DocumentFileStamp.of(store.url(kind: key.kind, id: id)) == stamp,
                       !replicas.holds(key, stamp: stamp) {
                        if markingWarm {
                            replicas.markWarm(key)
                        }
                        replicas.keep(TypedDocument(parts: parts), stamp: stamp)
                    }
                }
            }
        }
    }

    private func installForEditor<E: DocumentEntity>(_ type: E.Type, id: String) async throws {
        let store = try opened().store
        let key = SyncLedger.Key(kind: E.documentKind, id: id)
        let url = store.url(kind: key.kind, id: id)
        var stamp = DocumentFileStamp.of(url)
        var attempts = 0
        while let before = stamp, !replicas.holds(key, stamp: before), attempts < Self.coldAttempts {
            attempts += 1
            editors.decoding.insert(key)
            let parts = try? await reader().loadReplicaParts(type, id: id)
            editors.decoding.remove(key)
            stamp = DocumentFileStamp.of(url)
            if let parts, stamp == before, !replicas.holds(key, stamp: before) {
                replicas.keep(TypedDocument(parts: parts), stamp: before)
            }
        }
    }

    func editorBundle<E: DocumentEntity>(after document: TypedDocument<E>, key: SyncLedger.Key) -> EditorBundle? {
        editors.parked[key] = nil
        if let base = editors.bases[key] {
            editors.bases[key] = document.heads()
            if document.contains(heads: base), let changes = try? document.encodeChangesSince(heads: base) {
                let slideScoped = E.self == Presentation.self && TypedDocument<E>.touchedSlides(document.patches(since: base)) != nil
                return EditorBundle(base: base, changes: changes, slideScoped: slideScoped, replaced: false)
            } else {
                return EditorBundle(base: base, changes: Data(), slideScoped: false, replaced: true)
            }
        } else {
            return nil
        }
    }

    func endEditorSessions(_ key: SyncLedger.Key) {
        editors.end(key)
    }
}
