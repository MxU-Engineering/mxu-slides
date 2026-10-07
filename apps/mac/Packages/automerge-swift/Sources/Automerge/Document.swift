import class AutomergeUniffi.Doc
import protocol AutomergeUniffi.DocProtocol
import Foundation

public final class Document: @unchecked Sendable {
    private var doc: WrappedDoc

    #if !os(WASI)
    let lock = NSRecursiveLock()
    fileprivate func lock<T>(execute work: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try work()
    }
    #else
    fileprivate func lock<T>(execute work: () throws -> T) rethrows -> T {
        try work()
    }
    #endif
    
    #if canImport(Combine)
    private let objectDidChangeSubject: PassthroughSubject<(), Never> = .init()

    public lazy var objectDidChange: AnyPublisher<(), Never> = {
        objectDidChangeSubject.eraseToAnyPublisher()
    }()
    #endif

    var reportingLogLevel: LogVerbosity

    public var actor: ActorId {
        get {
            lock {
                ActorId(ffi: self.doc.wrapErrors { $0.actorId() })
            }
        }
        set {
            lock {
                self.doc.wrapErrors { $0.setActor(actor: [UInt8](newValue.data)) }
            }
        }
    }

    public var textEncoding: TextEncoding {
        lock {
            self.doc.wrapErrors { $0.textEncoding().textEncoding }
        }
    }

    public init(textEncoding: TextEncoding = .unicodeScalar, logLevel: LogVerbosity = .errorOnly) {
        doc = WrappedDoc(Doc.newWithTextEncoding(textEncoding: textEncoding.ffi_textEncoding))
        self.reportingLogLevel = logLevel
    }

    public init(_ bytes: Data, logLevel: LogVerbosity = .errorOnly) throws {
        doc = try WrappedDoc { try Doc.load(bytes: Array(bytes)) }
        self.reportingLogLevel = logLevel
    }

    private init(doc: Doc, logLevel: LogVerbosity = .errorOnly) {
        self.doc = WrappedDoc(doc)
        self.reportingLogLevel = logLevel
    }

    public func put(obj: ObjId, key: String, value: ScalarValue) throws {
        try lock {
            sendObjectWillChange()
            defer { sendObjectDidChange() }
            try self.doc.wrapErrors {
                try $0.putInMap(obj: obj.bytes, key: key, value: value.toFfi())
            }
        }
    }

    public func put(obj: ObjId, index: UInt64, value: ScalarValue) throws {
        try lock {
            sendObjectWillChange()
            defer { sendObjectDidChange() }
            try self.doc.wrapErrors {
                try $0.putInList(obj: obj.bytes, index: index, value: value.toFfi())
            }
        }
    }

    public func putObject(obj: ObjId, key: String, ty: ObjType) throws -> ObjId {
        try lock {
            sendObjectWillChange()
            defer { sendObjectDidChange() }
            return try self.doc.wrapErrors {
                try ObjId(bytes: $0.putObjectInMap(obj: obj.bytes, key: key, objType: ty.toFfi()))
            }
        }
    }

    public func putObject(obj: ObjId, index: UInt64, ty: ObjType) throws -> ObjId {
        try lock {
            sendObjectWillChange()
            defer { sendObjectDidChange() }
            return try self.doc.wrapErrors {
                try ObjId(bytes: $0.putObjectInList(obj: obj.bytes, index: index, objType: ty.toFfi()))
            }
        }
    }

    public func insert(obj: ObjId, index: UInt64, value: ScalarValue) throws {
        try lock {
            sendObjectWillChange()
            defer { sendObjectDidChange() }
            try self.doc.wrapErrors {
                try $0.insertInList(obj: obj.bytes, index: index, value: value.toFfi())
            }
        }
    }

    public func insertObject(obj: ObjId, index: UInt64, ty: ObjType) throws -> ObjId {
        try lock {
            sendObjectWillChange()
            defer { sendObjectDidChange() }
            return try self.doc.wrapErrors {
                try ObjId(bytes: $0.insertObjectInList(obj: obj.bytes, index: index, objType: ty.toFfi()))
            }
        }
    }

    public func delete(obj: ObjId, key: String) throws {
        try lock {
            sendObjectWillChange()
            defer { sendObjectDidChange() }
            try self.doc.wrapErrors {
                try $0.deleteInMap(obj: obj.bytes, key: key)
            }
        }
    }

    public func delete(obj: ObjId, index: UInt64) throws {
        try lock {
            sendObjectWillChange()
            defer { sendObjectDidChange() }
            try self.doc.wrapErrors {
                try $0.deleteInList(obj: obj.bytes, index: index)
            }
        }
    }

    public func increment(obj: ObjId, key: String, by: Int64) throws {
        try lock {
            sendObjectWillChange()
            defer { sendObjectDidChange() }
            try self.doc.wrapErrors {
                try $0.incrementInMap(obj: obj.bytes, key: key, by: by)
            }
        }
    }

    public func increment(obj: ObjId, index: UInt64, by: Int64) throws {
        try lock {
            sendObjectWillChange()
            defer { sendObjectDidChange() }
            try self.doc.wrapErrors {
                try $0.incrementInList(obj: obj.bytes, index: index, by: by)
            }
        }
    }

    public func get(obj: ObjId, key: String) throws -> Value? {
        try lock {
            let val = try self.doc.wrapErrors { try $0.getInMap(obj: obj.bytes, key: key) }
            return val.map(Value.fromFfi)
        }
    }

    public func get(obj: ObjId, index: UInt64) throws -> Value? {
        try lock {
            let val = try self.doc.wrapErrors { try $0.getInList(obj: obj.bytes, index: index) }
            return val.map(Value.fromFfi)
        }
    }

    public func getAll(obj: ObjId, key: String) throws -> Set<Value> {
        try lock {
            let vals = try self.doc.wrapErrors { try $0.getAllInMap(obj: obj.bytes, key: key) }
            return Set(vals.map { Value.fromFfi(value: $0) })
        }
    }

    public func getAll(obj: ObjId, index: UInt64) throws -> Set<Value> {
        try lock {
            let vals = try self.doc.wrapErrors { try $0.getAllInList(obj: obj.bytes, index: index) }
            return Set(vals.map { Value.fromFfi(value: $0) })
        }
    }

    public func getAt(obj: ObjId, key: String, heads: Set<ChangeHash>) throws
        -> Value?
    {
        try lock {
            let val = try self.doc.wrapErrors {
                try $0.getAtInMap(obj: obj.bytes, key: key, heads: heads.map(\.bytes))
            }
            return val.map(Value.fromFfi)
        }
    }

    public func getAt(obj: ObjId, index: UInt64, heads: Set<ChangeHash>) throws
        -> Value?
    {
        try lock {
            let val = try self.doc.wrapErrors {
                try $0.getAtInList(obj: obj.bytes, index: index, heads: heads.map(\.bytes))
            }
            return val.map(Value.fromFfi)
        }
    }

    public func getAllAt(obj: ObjId, key: String, heads: Set<ChangeHash>) throws
        -> Set<Value>
    {
        try lock {
            let vals = try self.doc.wrapErrors {
                try $0.getAllAtInMap(obj: obj.bytes, key: key, heads: heads.map(\.bytes))
            }
            return Set(vals.map { Value.fromFfi(value: $0) })
        }
    }

    public func getAllAt(obj: ObjId, index: UInt64, heads: Set<ChangeHash>)
        throws -> Set<Value>
    {
        try lock {
            let vals = try self.doc.wrapErrors {
                try $0.getAllAtInList(obj: obj.bytes, index: index, heads: heads.map(\.bytes))
            }
            return Set(vals.map { Value.fromFfi(value: $0) })
        }
    }

    public func keys(obj: ObjId) -> [String] {
        lock {
            self.doc.wrapErrors { $0.mapKeys(obj: obj.bytes) }
        }
    }

    public func keysAt(obj: ObjId, heads: Set<ChangeHash>) -> [String] {
        lock {
            self.doc.wrapErrors { $0.mapKeysAt(obj: obj.bytes, heads: heads.map(\.bytes)) }
        }
    }

    public func values(obj: ObjId) throws -> [Value] {
        try lock {
            let vals = try self.doc.wrapErrors { try $0.values(obj: obj.bytes) }
            return vals.map { Value.fromFfi(value: $0) }
        }
    }

    public func valuesAt(obj: ObjId, heads: Set<ChangeHash>) throws -> [Value] {
        try lock {
            let vals = try self.doc.wrapErrors {
                try $0.valuesAt(obj: obj.bytes, heads: heads.map(\.bytes))
            }
            return vals.map { Value.fromFfi(value: $0) }
        }
    }

    public func mapEntries(obj: ObjId) throws -> [(String, Value)] {
        try lock {
            let entries = try self.doc.wrapErrors { try $0.mapEntries(obj: obj.bytes) }
            return entries.map { ($0.key, Value.fromFfi(value: $0.value)) }
        }
    }

    public func mapEntriesAt(obj: ObjId, heads: Set<ChangeHash>) throws -> [(
        String, Value
    )] {
        try lock {
            let entries = try self.doc.wrapErrors {
                try $0.mapEntriesAt(obj: obj.bytes, heads: heads.map(\.bytes))
            }
            return entries.map { ($0.key, Value.fromFfi(value: $0.value)) }
        }
    }

    public func length(obj: ObjId) -> UInt64 {
        lock {
            self.doc.wrapErrors { $0.length(obj: obj.bytes) }
        }
    }

    public func lengthAt(obj: ObjId, heads: Set<ChangeHash>) -> UInt64 {
        lock {
            self.doc.wrapErrors { $0.lengthAt(obj: obj.bytes, heads: heads.map(\.bytes)) }
        }
    }

    public func objectType(obj: ObjId) -> ObjType {
        lock {
            self.doc.wrapErrors {
                ObjType.fromFfi(ty: $0.objectType(obj: obj.bytes))
            }
        }
    }

    public func text(obj: ObjId) throws -> String {
        try lock {
            try self.doc.wrapErrors { try $0.text(obj: obj.bytes) }
        }
    }

    public func textAt(obj: ObjId, heads: Set<ChangeHash>) throws -> String {
        try lock {
            try self.doc.wrapErrors { try $0.textAt(obj: obj.bytes, heads: heads.map(\.bytes)) }
        }
    }

    public func cursor(obj: ObjId, position: UInt64) throws -> Cursor {
        try lock {
            sendObjectWillChange()
            defer { sendObjectDidChange() }
            return try Cursor(bytes: self.doc.wrapErrors { try $0.cursor(obj: obj.bytes, position: position) })
        }
    }

    public func cursor(obj: ObjId, position: UInt64, heads: Set<ChangeHash>) throws -> Cursor {
        try lock {
            sendObjectWillChange()
            defer { sendObjectDidChange() }
            return try Cursor(bytes: self.doc.wrapErrors { try $0.cursorAt(
                obj: obj.bytes,
                position: position,
                heads: heads.map(\.bytes)
            ) })
        }
    }

    public func position(obj: ObjId, cursor: Cursor) throws -> UInt64 {
        try lock {
            try self.doc.wrapErrors {
                try $0.cursorPosition(obj: obj.bytes, cursor: cursor.bytes)
            }
        }
    }

    public func position(obj: ObjId, cursor: Cursor, heads: Set<ChangeHash>) throws -> UInt64 {
        try lock {
            try self.doc.wrapErrors {
                try $0.cursorPositionAt(obj: obj.bytes, cursor: cursor.bytes, heads: heads.map(\.bytes))
            }
        }
    }

    public func splice(obj: ObjId, start: UInt64, delete: Int64, values: [ScalarValue]) throws {
        try lock {
            sendObjectWillChange()
            defer { sendObjectDidChange() }
            try self.doc.wrapErrors {
                try $0.splice(
                    obj: obj.bytes, start: start, delete: delete, values: values.map { $0.toFfi() }
                )
            }
        }
    }

    public func spliceText(obj: ObjId, start: UInt64, delete: Int64, value: String? = nil) throws {
        try lock {
            sendObjectWillChange()
            defer { sendObjectDidChange() }
            try self.doc.wrapErrors {
                try $0.spliceText(obj: obj.bytes, start: start, delete: delete, chars: value ?? "")
            }
        }
    }

    public func updateText(obj: ObjId, value: String) throws {
        try lock {
            sendObjectWillChange()
            defer { sendObjectDidChange() }
            try self.doc.wrapErrors { doc in
                try doc.updateText(obj: obj.bytes, chars: value)
            }
        }
    }

    public func mark(
        obj: ObjId,
        start: UInt64,
        end: UInt64,
        expand: ExpandMark,
        name: String,
        value: ScalarValue
    ) throws {
        try lock {
            sendObjectWillChange()
            defer { sendObjectDidChange() }
            try self.doc.wrapErrors {
                try $0.mark(
                    obj: obj.bytes,
                    start: start,
                    end: end,
                    expand: expand.toFfi(),
                    name: name,
                    value: value.toFfi()
                )
            }
        }
    }

    public func marks(obj: ObjId) throws -> [Mark] {
        try lock {
            try self.doc.wrapErrors {
                try $0.marks(obj: obj.bytes).map(Mark.fromFfi)
            }
        }
    }

    public func marksAt(obj: ObjId, heads: Set<ChangeHash>) throws -> [Mark] {
        try lock {
            try self.doc.wrapErrors {
                try $0.marksAt(obj: obj.bytes, heads: heads.map(\.bytes)).map(Mark.fromFfi)
            }
        }
    }

    public func marksAt(obj: ObjId, position: Position, heads: Set<ChangeHash>) throws -> [Mark] {
        try lock {
            try self.doc.wrapErrors {
                try $0.marksAtPosition(
                    obj: obj.bytes,
                    position: position.toFfi(),
                    heads: heads.map(\.bytes)
                ).map(Mark.fromFfi)
            }
        }
    }

    public func marksAt(obj: ObjId, position: Position) throws -> [Mark] {
        try marksAt(obj: obj, position: position, heads: heads())
    }

    public func commitWith(message: String? = nil, timestamp: Date = Date()) {
        lock {
            sendObjectWillChange()
            defer { sendObjectDidChange() }
            self.doc.wrapErrors {
                $0.commitWith(msg: message, time: Int64(timestamp.timeIntervalSince1970))
            }
        }
    }

    public func save() -> Data {
        lock {
            sendObjectWillChange()
            defer { sendObjectDidChange() }
            return self.doc.wrapErrors {
                Data($0.save())
            }
        }
    }

    public func generateSyncMessage(state: SyncState) -> Data? {
        lock {
            self.doc.wrapErrors {
                if let tempArr = $0.generateSyncMessage(state: state.ffi_state) {
                    return Data(tempArr)
                }
                return nil
            }
        }
    }

    public func receiveSyncMessage(state: SyncState, message: Data) throws {
        try lock {
            sendObjectWillChange()
            defer { sendObjectDidChange() }
            try self.doc.wrapErrors {
                try $0.receiveSyncMessage(state: state.ffi_state, msg: Array(message))
            }
        }
    }

    public func receiveSyncMessageWithPatches(state: SyncState, message: Data) throws -> [Patch] {
        try lock {
            sendObjectWillChange()
            defer { sendObjectDidChange() }
            let patches = try self.doc.wrapErrors {
                try $0.receiveSyncMessageWithPatches(state: state.ffi_state, msg: Array(message))
            }
            return patches.map { Patch($0) }
        }
    }

    public func fork() -> Document {
        lock {
            Document(doc: self.doc.wrapErrors { $0.fork() })
        }
    }

    public func forkAt(heads: Set<ChangeHash>) throws -> Document {
        try lock {
            try self.doc.wrapErrors {
                try Document(doc: $0.forkAt(heads: heads.map(\.bytes)))
            }
        }
    }

    public func merge(other: Document) throws {
        try lock {
            sendObjectWillChange()
            defer { sendObjectDidChange() }
            try self.doc.wrapErrorsWithOther(other: other.doc) { try $0.merge(other: $1) }
        }
    }

    public func mergeWithPatches(other: Document) throws -> [Patch] {
        try lock {
            sendObjectWillChange()
            defer { sendObjectDidChange() }
            let patches = try self.doc.wrapErrorsWithOther(other: other.doc) {
                try $0.mergeWithPatches(other: $1)
            }
            return patches.map { Patch($0) }
        }
    }

    public func heads() -> Set<ChangeHash> {
        lock {
            Set(self.doc.wrapErrors { $0.heads().map { ChangeHash(bytes: $0) } })
        }
    }

    public func getHistory() -> [ChangeHash] {
        lock {
            self.doc.wrapErrors { $0.changes().map { ChangeHash(bytes: $0) } }
        }
    }

    public func change(hash: ChangeHash) -> Change? {
        lock {
            guard let change = self.doc.wrapErrors(f: { $0.changeByHash(hash: hash.bytes) }) else {
                return nil
            }
            return .init(change)
        }
    }

    public func difference(from before: Set<ChangeHash>, to after: Set<ChangeHash>) -> [Patch] {
        lock {
            let patches = self.doc.wrapErrors { doc in
                doc.difference(before: before.map(\.bytes), after: after.map(\.bytes))
            }
            return patches.map { Patch($0) }
        }
    }

    public func difference(since lhs: Set<ChangeHash>) -> [Patch] {
        difference(from: lhs, to: heads())
    }

    public func difference(to rhs: Set<ChangeHash>) -> [Patch] {
        difference(from: heads(), to: rhs)
    }

    public func path(obj: ObjId) throws -> [PathElement] {
        try lock {
            let elems = try self.doc.wrapErrors { try $0.path(obj: obj.bytes) }
            return elems.map { PathElement.fromFfi($0) }
        }
    }

    public func encodeNewChanges() -> Data {
        lock {
            self.doc.wrapErrors { Data($0.encodeNewChanges()) }
        }
    }

    public func encodeChangesSince(heads: Set<ChangeHash>) throws -> Data {
        try lock {
            try self.doc.wrapErrors {
                try Data($0.encodeChangesSince(heads: heads.map(\.bytes)))
            }
        }
    }

    public func applyEncodedChanges(encoded: Data) throws {
        try lock {
            sendObjectWillChange()
            defer { sendObjectDidChange() }
            try self.doc.wrapErrors {
                try $0.applyEncodedChanges(changes: Array(encoded))
            }
        }
    }

    public func applyEncodedChangesWithPatches(encoded: Data) throws -> [Patch] {
        try lock {
            sendObjectWillChange()
            defer { sendObjectDidChange() }
            let patches = try self.doc.wrapErrors {
                try $0.applyEncodedChangesWithPatches(changes: Array(encoded))
            }
            return patches.map { Patch($0) }
        }
    }
}

struct WrappedDoc {
    private let doc: Doc

    init(_ doc: Doc) {
        self.doc = doc
    }

    init(_ f: () throws -> Doc) throws {
        doc = try wrappedErrors { try f() }
    }

    func wrapErrors<T>(f: (Doc) throws -> T) throws -> T {
        try wrappedErrors { try f(doc) }
    }

    func wrapErrors<T>(f: (Doc) -> T) -> T {
        f(doc)
    }

    func wrapErrorsWithOther<T>(other: Self, f: (Doc, Doc) throws -> T) throws -> T {
        try wrappedErrors { try f(doc, other.doc) }
    }
}

#if canImport(Combine)
import Combine
import OSLog

extension Document: ObservableObject {
    fileprivate func sendObjectWillChange() {

        objectWillChange.send()
    }

    fileprivate func sendObjectDidChange() {
        objectDidChangeSubject.send()
    }
}
#else
fileprivate extension Document {
    func sendObjectWillChange() {}
    func sendObjectDidChange() {}
}
#endif
