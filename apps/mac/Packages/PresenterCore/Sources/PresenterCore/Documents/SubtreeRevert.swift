import Automerge
import Foundation

struct SubtreeRevert {
    let document: Document

    let heads: Set<ChangeHash>

    let touched: Set<ObjId>

    private(set) var modified: Set<ObjId> = []

    init(document: Document, heads: Set<ChangeHash>) {
        self.document = document
        self.heads = heads
        touched = Self.touchedObjects(document.difference(from: document.heads(), to: heads))
    }

    mutating func run() throws -> Set<String> {
        try revertMap(ObjId.ROOT)
    }

    static func touchedObjects(_ patches: [Patch]) -> Set<ObjId> {
        var touched: Set<ObjId> = [ObjId.ROOT]
        for patch in patches {
            for element in patch.path {
                touched.insert(element.obj)
            }
            touched.insert(target(of: patch.action))
        }
        return touched
    }

    private static func target(of action: PatchAction) -> ObjId {
        switch action {
        case let .Put(obj, _, _): obj
        case let .Insert(obj, _, _): obj
        case let .SpliceText(obj, _, _, _): obj
        case let .Increment(obj, _, _): obj
        case let .DeleteMap(obj, _): obj
        case let .DeleteSeq(delete): delete.obj
        case let .Marks(obj, _): obj
        case let .Conflict(obj, _): obj
        }
    }

    private mutating func revert(_ obj: ObjId, type: ObjType) throws -> Bool {
        switch type {
        case .Map: try !revertMap(obj).isEmpty
        case .List: try revertList(obj)
        case .Text: try revertText(obj)
        }
    }

    private mutating func revertMap(_ obj: ObjId) throws -> Set<String> {
        let past = try document.mapEntriesAt(obj: obj, heads: heads)
        var now: [String: Value] = [:]
        for (key, value) in try document.mapEntries(obj: obj) {
            now[key] = value
        }
        var changed = Set<String>()
        let pastKeys = Set(past.map(\.0))
        for key in now.keys.sorted() where !pastKeys.contains(key) {
            try document.delete(obj: obj, key: key)
            changed.insert(key)
        }
        for (key, value) in past {
            let current = now[key]
            if value == current {
                if case let .Object(child, type) = value, touched.contains(child), try revert(child, type: type) {
                    modified.insert(child)
                    changed.insert(key)
                }
            } else {
                switch value {
                case let .Scalar(scalar):
                    try document.put(obj: obj, key: key, value: scalar)
                case let .Object(child, type):
                    let landed = try document.putObject(obj: obj, key: key, ty: type)
                    try copy(child, type: type, into: landed)
                }
                changed.insert(key)
            }
        }
        return changed
    }

    private mutating func revertList(_ obj: ObjId) throws -> Bool {
        let past = try document.valuesAt(obj: obj, heads: heads)
        let now = try document.values(obj: obj)
        let shared = Self.commonSubsequence(now, past)
        let keptNow = Set(shared.map(\.now))
        let keptPast = Set(shared.map(\.past))
        var changed = false
        for index in now.indices.reversed() where !keptNow.contains(index) {
            try document.delete(obj: obj, index: UInt64(index))
            changed = true
        }
        for (index, value) in past.enumerated() {
            if keptPast.contains(index) {
                if case let .Object(child, type) = value, touched.contains(child), try revert(child, type: type) {
                    modified.insert(child)
                    changed = true
                }
            } else {
                switch value {
                case let .Scalar(scalar):
                    try document.insert(obj: obj, index: UInt64(index), value: scalar)
                case let .Object(child, type):
                    let landed = try document.insertObject(obj: obj, index: UInt64(index), ty: type)
                    try copy(child, type: type, into: landed)
                }
                changed = true
            }
        }
        return changed
    }

    private func revertText(_ obj: ObjId) throws -> Bool {
        let past = try document.textAt(obj: obj, heads: heads)
        let differs = try past != document.text(obj: obj)
        if differs {
            try document.updateText(obj: obj, value: past)
        }
        return differs
    }

    private func copy(_ source: ObjId, type: ObjType, into destination: ObjId) throws {
        switch type {
        case .Map:
            for (key, value) in try document.mapEntriesAt(obj: source, heads: heads) {
                switch value {
                case let .Scalar(scalar):
                    try document.put(obj: destination, key: key, value: scalar)
                case let .Object(child, childType):
                    let landed = try document.putObject(obj: destination, key: key, ty: childType)
                    try copy(child, type: childType, into: landed)
                }
            }
        case .List:
            for (index, value) in try document.valuesAt(obj: source, heads: heads).enumerated() {
                switch value {
                case let .Scalar(scalar):
                    try document.insert(obj: destination, index: UInt64(index), value: scalar)
                case let .Object(child, childType):
                    let landed = try document.insertObject(obj: destination, index: UInt64(index), ty: childType)
                    try copy(child, type: childType, into: landed)
                }
            }
        case .Text:
            try document.spliceText(obj: destination, start: 0, delete: 0, value: document.textAt(obj: source, heads: heads))
        }
    }

    static func commonSubsequence(_ now: [Value], _ past: [Value]) -> [(now: Int, past: Int)] {
        var prefix = 0
        while prefix < now.count, prefix < past.count, now[prefix] == past[prefix] {
            prefix += 1
        }
        var suffix = 0
        while suffix < now.count - prefix, suffix < past.count - prefix,
              now[now.count - 1 - suffix] == past[past.count - 1 - suffix] {
            suffix += 1
        }
        let middleNow = Array(now[prefix..<(now.count - suffix)])
        let middlePast = Array(past[prefix..<(past.count - suffix)])
        var pairs = (0..<prefix).map { (now: $0, past: $0) }
        pairs += longestCommon(middleNow, middlePast).map { (now: $0.now + prefix, past: $0.past + prefix) }
        pairs += (0..<suffix).map { (now: now.count - suffix + $0, past: past.count - suffix + $0) }
        return pairs
    }

    private static func longestCommon(_ a: [Value], _ b: [Value]) -> [(now: Int, past: Int)] {
        var pairs: [(now: Int, past: Int)] = []
        if !a.isEmpty, !b.isEmpty {

            var lengths = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
            for i in a.indices.reversed() {
                for j in b.indices.reversed() {
                    lengths[i][j] = a[i] == b[j] ? lengths[i + 1][j + 1] + 1 : max(lengths[i + 1][j], lengths[i][j + 1])
                }
            }
            var i = 0
            var j = 0
            while i < a.count, j < b.count {
                if a[i] == b[j] {
                    pairs.append((now: i, past: j))
                    i += 1
                    j += 1
                } else if lengths[i + 1][j] >= lengths[i][j + 1] {
                    i += 1
                } else {
                    j += 1
                }
            }
        }
        return pairs
    }
}
