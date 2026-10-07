import Foundation
import os

public struct LibraryCacheLimits: Sendable, Equatable {
    public var replicasPerKind: Int
    public var valuesPerKind: Int

    public var warmPerKind: Int

    public init(replicasPerKind: Int, valuesPerKind: Int, warmPerKind: Int = 8) {
        self.replicasPerKind = max(1, replicasPerKind)
        self.valuesPerKind = max(1, valuesPerKind)
        self.warmPerKind = max(1, warmPerKind)
    }

    public static let standard = LibraryCacheLimits(replicasPerKind: 8, valuesPerKind: 64, warmPerKind: 8)
}

struct LibraryReplicaCache {
    private struct Entry {
        var document: AnyObject
        var stamp: DocumentFileStamp
    }

    let perKind: Int
    let warmPerKind: Int
    private var entries: [SyncLedger.Key: Entry] = [:]

    private var order: [DocumentKind: [String]] = [:]

    private var warm: [DocumentKind: [String]] = [:]

    private var pins: [SyncLedger.Key: Int] = [:]

    private(set) var live: Set<SyncLedger.Key> = []

    init(perKind: Int, warmPerKind: Int = LibraryCacheLimits.standard.warmPerKind) {
        self.perKind = max(1, perKind)
        self.warmPerKind = max(1, warmPerKind)
    }

    var count: Int { entries.count }

    @LibraryActor
    mutating func document<E: DocumentEntity>(_ type: E.Type, id: String, stamp: DocumentFileStamp?) -> TypedDocument<E>? {
        let key = SyncLedger.Key(kind: E.documentKind, id: id)
        if let entry = entries[key], entry.stamp == stamp, let document = entry.document as? TypedDocument<E> {
            touch(key)
            return document
        } else {
            remove(kind: E.documentKind, id: id)
            return nil
        }
    }

    func holds(_ key: SyncLedger.Key, stamp: DocumentFileStamp?) -> Bool {
        if let entry = entries[key], let stamp {
            entry.stamp == stamp
        } else {
            false
        }
    }

    @LibraryActor
    mutating func keep<E: DocumentEntity>(_ document: TypedDocument<E>, stamp: DocumentFileStamp?) {
        let key = SyncLedger.Key(kind: E.documentKind, id: document.value.id)
        if let stamp {
            entries[key] = Entry(document: document, stamp: stamp)
            touch(key)
            trim(key.kind)
        } else {
            remove(kind: key.kind, id: key.id)
        }
    }

    mutating func remove(kind: DocumentKind, id: String) {
        entries[SyncLedger.Key(kind: kind, id: id)] = nil
        order[kind]?.removeAll { $0 == id }
    }

    mutating func pin(_ key: SyncLedger.Key) {
        pins[key, default: 0] += 1
    }

    mutating func unpin(_ key: SyncLedger.Key) {
        if let count = pins[key], count > 1 {
            pins[key] = count - 1
        } else {
            pins[key] = nil
            trim(key.kind)
        }
    }

    func isPinned(_ key: SyncLedger.Key) -> Bool {
        pins[key] != nil
    }

    mutating func markWarm(_ key: SyncLedger.Key) {
        warm[key.kind, default: []].removeAll { $0 == key.id }
        warm[key.kind, default: []].append(key.id)
        if let overflow = warm[key.kind]?.dropLast(warmPerKind), !overflow.isEmpty {
            warm[key.kind]?.removeFirst(overflow.count)
            trim(key.kind)
        }
    }

    mutating func setLive(_ keys: Set<SyncLedger.Key>) {
        let left = live.subtracting(keys)
        live = keys
        for key in left.sorted(by: { $0.id < $1.id }) where entries[key] != nil {
            touch(key)
        }
        for kind in Set(left.map(\.kind)) {
            trim(kind)
        }
    }

    func isLive(_ key: SyncLedger.Key) -> Bool {
        live.contains(key)
    }

    func isWarm(_ key: SyncLedger.Key) -> Bool {
        warm[key.kind]?.contains(key.id) ?? false
    }

    func warmIDs(_ kind: DocumentKind) -> [String] {
        warm[kind] ?? []
    }

    private func isProtected(_ key: SyncLedger.Key) -> Bool {
        pins[key] != nil || isWarm(key) || live.contains(key)
    }

    private mutating func trim(_ kind: DocumentKind) {
        let unprotected = (order[kind] ?? []).filter { !isProtected(SyncLedger.Key(kind: kind, id: $0)) }
        for id in unprotected.dropLast(perKind) {
            remove(kind: kind, id: id)
        }
    }

    private mutating func touch(_ key: SyncLedger.Key) {
        order[key.kind, default: []].removeAll { $0 == key.id }
        order[key.kind, default: []].append(key.id)
    }
}

final class LibraryValueCache: Sendable {
    private struct Entry: Sendable {
        var value: any DocumentEntity
        var stamp: DocumentFileStamp
    }

    private struct State: Sendable {
        var entries: [SyncLedger.Key: Entry] = [:]

        var generations: [SyncLedger.Key: Int] = [:]

        var order: [DocumentKind: [String]] = [:]
        var hits = 0
        var fills = 0

        var documentLoads = 0
    }

    let perKind: Int
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(perKind: Int) {
        self.perKind = max(1, perKind)
    }

    var counts: (hits: Int, fills: Int) {
        state.withLock { ($0.hits, $0.fills) }
    }

    var count: Int {
        state.withLock { $0.entries.count }
    }

    var documentLoads: Int {
        state.withLock { $0.documentLoads }
    }

    func noteDocumentLoad() {
        state.withLock { $0.documentLoads += 1 }
    }

    func generation(of key: SyncLedger.Key) -> Int {
        state.withLock { $0.generations[key] ?? 0 }
    }

    func value(of key: SyncLedger.Key, stamp: DocumentFileStamp?) -> (any DocumentEntity)? {
        state.withLock { state in
            if let entry = state.entries[key], let stamp, entry.stamp == stamp {
                state.hits += 1
                Self.touch(key, in: &state)
                return entry.value
            } else {
                return nil
            }
        }
    }

    func fill(_ value: any DocumentEntity, key: SyncLedger.Key, stamp: DocumentFileStamp?, generation: Int) {
        state.withLock { state in
            if let stamp, (state.generations[key] ?? 0) == generation {
                state.fills += 1
                Self.store(Entry(value: value, stamp: stamp), key: key, perKind: perKind, in: &state)
            }
        }
    }

    func write(_ value: any DocumentEntity, key: SyncLedger.Key, stamp: DocumentFileStamp?) {
        state.withLock { state in
            state.generations[key, default: 0] += 1
            if let stamp {
                Self.store(Entry(value: value, stamp: stamp), key: key, perKind: perKind, in: &state)
            } else {
                Self.drop(key, in: &state)
            }
        }
    }

    func remove(_ key: SyncLedger.Key) {
        state.withLock { state in
            state.generations[key, default: 0] += 1
            Self.drop(key, in: &state)
        }
    }

    private static func store(_ entry: Entry, key: SyncLedger.Key, perKind: Int, in state: inout State) {
        state.entries[key] = entry
        touch(key, in: &state)
        while let oldest = state.order[key.kind]?.first, (state.order[key.kind]?.count ?? 0) > perKind {
            state.order[key.kind]?.removeFirst()
            state.entries[SyncLedger.Key(kind: key.kind, id: oldest)] = nil
        }
    }

    private static func drop(_ key: SyncLedger.Key, in state: inout State) {
        state.entries[key] = nil
        state.order[key.kind]?.removeAll { $0 == key.id }
    }

    private static func touch(_ key: SyncLedger.Key, in state: inout State) {
        state.order[key.kind, default: []].removeAll { $0 == key.id }
        state.order[key.kind, default: []].append(key.id)
    }
}
