import Automerge
import Foundation

public typealias AnyCodingKey = Automerge.AnyCodingKey

public typealias ScalarValue = Automerge.ScalarValue

struct ReplicaParts<Entity: DocumentEntity>: Sendable {
    let document: Document
    let value: Entity

    let persisted: Data?

    static func decoding(_ data: Data) throws -> ReplicaParts<Entity> {
        #if DEBUG
        precondition(
            !Thread.isMainThread,
            "a document decoded on the main thread: decode it through the value door or on the library actor"
        )
        #endif
        let document = try Document(data)
        let value = try AutomergeDecoder(doc: document).decode(Entity.self)
        return ReplicaParts(document: document, value: value, persisted: data)
    }
}

@LibraryActor public final class TypedDocument<Entity: DocumentEntity> {
    let core: ReplicaCore<Entity>

    public var document: Document { core.document }

    var lastPersistedData: Data?

    public var commitMessage: String? {
        get { core.commitMessage }
        set { core.commitMessage = newValue }
    }

    public struct SeedIdentity: Sendable {
        public var actor: ActorId
        public var timestamp: Date

        public init(actor: ActorId, timestamp: Date = Date(timeIntervalSince1970: 0)) {
            self.actor = actor
            self.timestamp = timestamp
        }

        public init(id: String) {
            var hash = [UInt8](repeating: 0, count: 32)
            let bytes = Array(id.utf8)

            var h: UInt64 = 0xcbf29ce484222325
            for byte in bytes { h = (h ^ UInt64(byte)) &* 0x100000001b3 }
            var g: UInt64 = 0x84222325cbf29ce4
            for byte in bytes.reversed() { g = (g ^ UInt64(byte)) &* 0x100000001b3 }
            for i in 0..<8 { hash[i] = UInt8((h >> (8 * UInt64(i))) & 0xff); hash[8 + i] = UInt8((g >> (8 * UInt64(i))) & 0xff) }
            self.init(actor: ActorId(data: Data(hash.prefix(16)))!)
        }
    }

    public init(_ value: Entity, seed: SeedIdentity? = nil) throws {
        core = try ReplicaCore(value, seed: seed)
    }

    private init(core: ReplicaCore<Entity>) {
        self.core = core
    }

    public init(data: Data) throws {
        core = try ReplicaCore(data: data)
        lastPersistedData = data
    }

    init(parts: ReplicaParts<Entity>) {
        core = ReplicaCore(document: parts.document, value: parts.value)
        lastPersistedData = parts.persisted
    }

    var parts: ReplicaParts<Entity> {
        ReplicaParts(document: core.document, value: core.value, persisted: lastPersistedData)
    }

    public var value: Entity { core.value }

    public func save() -> Data {
        core.document.save()
    }

    @discardableResult
    public func update(_ mutate: (inout Entity) throws -> Void) throws -> Entity {
        try core.update(mutate)
    }

    @discardableResult
    public func update<Subtree: Codable & Equatable>(
        _ keyPath: WritableKeyPath<Entity, Subtree>,
        at path: [AnyCodingKey],
        _ mutate: (inout Subtree) throws -> Void
    ) throws -> Entity {
        try core.update(keyPath, at: path, mutate)
    }

    @discardableResult
    public func moveListElement(
        listAt path: [AnyCodingKey],
        from: Int,
        before: Int?,
        settingOnMoved fields: [String: ScalarValue?] = [:],
        next: Entity
    ) throws -> Entity {
        try core.moveListElement(listAt: path, from: from, before: before, settingOnMoved: fields, next: next)
    }

    @discardableResult
    public func insertListElements<Element: Encodable>(
        listAt path: [AnyCodingKey], at index: Int, values: [Element], next: Entity
    ) throws -> Entity {
        try core.insertListElements(listAt: path, at: index, values: values, next: next)
    }

    @discardableResult
    public func insertListElements<Element: Encodable>(
        listAt path: [AnyCodingKey], placing elements: [(index: Int, element: Element)], next: Entity
    ) throws -> Entity {
        try core.insertListElements(listAt: path, placing: elements, next: next)
    }

    @discardableResult
    public func removeListElements(
        listAt path: [AnyCodingKey], at indices: [Int], next: Entity
    ) throws -> Entity {
        try core.removeListElements(listAt: path, at: indices, next: next)
    }

    @discardableResult
    public func updateField<Field: Codable & Equatable>(
        _ keyPath: WritableKeyPath<Entity, Field?>, key: String, to value: Field?
    ) throws -> Entity {
        try core.updateField(keyPath, key: key, to: value)
    }

    public struct FieldWrite {
        fileprivate let differs: (Entity) -> Bool
        fileprivate let write: (Document, inout Entity) throws -> Void

        public init<Field: Codable & Equatable>(_ keyPath: WritableKeyPath<Entity, Field?>, key: String, to value: Field?) {
            differs = { $0[keyPath: keyPath] != value }
            write = { document, cached in
                if let value {
                    let encoder = AutomergeEncoder(doc: document, strategy: .createWhenNeeded, cautiousWrite: true)
                    try encoder.encode(value, at: [AnyCodingKey(key)])
                } else {
                    try document.delete(obj: ObjId.ROOT, key: key)
                }
                cached[keyPath: keyPath] = value
            }
        }
    }

    @discardableResult
    public func updateFields(_ fields: [FieldWrite]) throws -> Entity {
        try core.updateFields(fields)
    }

    public enum DocumentError: Error {

        case unexpectedShape
    }

    public var canUndo: Bool { core.canUndo }
    public var canRedo: Bool { core.canRedo }

    @discardableResult
    public func undo() throws -> Entity {
        try core.undo()
    }

    @discardableResult
    public func redo() throws -> Entity {
        try core.redo()
    }

    public func merge(_ other: TypedDocument<Entity>) throws {
        try core.merge(other.core)
    }

    public func fork() throws -> TypedDocument<Entity> {
        try TypedDocument(data: document.save())
    }

    func workingCopy() -> TypedDocument<Entity> {
        TypedDocument(core: ReplicaCore(document: core.document.fork(), value: core.value))
    }

    public func contains(heads: Set<ChangeHash>) -> Bool {
        core.contains(heads: heads)
    }

    public func heads() -> Set<ChangeHash> {
        core.document.heads()
    }

    public func firstChangeHash() -> ChangeHash? {
        core.document.getHistory().first
    }

    public func encodeChangesSince(heads: Set<ChangeHash>) throws -> Data {
        try core.document.encodeChangesSince(heads: heads)
    }

    @discardableResult
    public func applyEncodedChanges(_ encoded: Data) throws -> Bool {
        try core.applyEncodedChanges(encoded)
    }

    func patches(since before: Set<ChangeHash>) -> [Patch] {
        core.patches(since: before)
    }

    nonisolated static func touchedSlides(_ patches: [Patch]) -> Set<Int>? {
        var touched = Set<Int>()
        var insideSlides = true
        for patch in patches {
            if patch.path.count >= 2, patch.path[0].prop == .Key("slides"), case .Index(let index) = patch.path[1].prop {
                touched.insert(Int(index))
            } else {
                insideSlides = false
            }
        }
        return insideSlides ? touched : nil
    }
}

final class ReplicaCore<Entity: DocumentEntity> {
    let document: Document

    private(set) var undoStack: [Set<ChangeHash>] = []

    private(set) var redoStack: [Set<ChangeHash>] = []

    private var cachedValue: Entity
    var commitMessage: String?

    #if DEBUG

    struct Decodes: Equatable {
        var whole = 0
        var slides = 0
    }

    private(set) var decodes = Decodes()

    private(set) var wholeWrites = 0
    #endif

    private(set) var wholeWrite: String?

    init(_ value: Entity, seed: TypedDocument<Entity>.SeedIdentity?) throws {
        document = Document()
        if let seed { document.actor = seed.actor }
        let encoder = AutomergeEncoder(doc: document)
        try encoder.encode(value)
        document.commitWith(message: "create", timestamp: seed?.timestamp ?? Date())
        if seed != nil { document.actor = ActorId() }
        cachedValue = value
    }

    init(data: Data) throws {
        let parts = try ReplicaParts<Entity>.decoding(data)
        document = parts.document
        cachedValue = parts.value
        #if DEBUG
        decodes.whole += 1
        #endif
    }

    init(document: Document, value: Entity) {
        self.document = document
        cachedValue = value
    }

    var value: Entity { cachedValue }

    @discardableResult
    func update(_ mutate: (inout Entity) throws -> Void) throws -> Entity {
        var next = cachedValue
        try mutate(&next)
        guard next != cachedValue else { return cachedValue }
        let before = document.heads()
        try write(next)
        undoStack.append(before)
        redoStack.removeAll()
        return next
    }

    @discardableResult
    func update<Subtree: Codable & Equatable>(
        _ keyPath: WritableKeyPath<Entity, Subtree>,
        at path: [AnyCodingKey],
        _ mutate: (inout Subtree) throws -> Void
    ) throws -> Entity {
        var subtree = cachedValue[keyPath: keyPath]
        try mutate(&subtree)
        guard subtree != cachedValue[keyPath: keyPath] else { return cachedValue }
        let before = document.heads()
        let encoder = AutomergeEncoder(doc: document, strategy: .createWhenNeeded, cautiousWrite: true)
        try encoder.encode(subtree, at: path)
        document.commitWith(message: commitMessage)
        cachedValue[keyPath: keyPath] = subtree
        undoStack.append(before)
        redoStack.removeAll()
        #if DEBUG

        if ProcessInfo.processInfo.environment["MXU_VERIFY_SCOPED_WRITES"] != nil {
            assert(
                try! AutomergeDecoder(doc: document).decode(Entity.self) == cachedValue,
                "Scoped update diverged: keyPath and coding path do not address the same subtree"
            )
        }
        #endif
        return cachedValue
    }

    @discardableResult
    func moveListElement(
        listAt path: [AnyCodingKey],
        from: Int,
        before: Int?,
        settingOnMoved fields: [String: ScalarValue?],
        next: Entity
    ) throws -> Entity {
        guard next != cachedValue else { return cachedValue }
        let beforeHeads = document.heads()
        let list = try objectId(at: path)
        let length = Int(document.length(obj: list))
        let insertIndex = min(before ?? length, length)
        guard from >= 0, from < length else { return cachedValue }

        if insertIndex != from, insertIndex != from + 1 {
            guard case let .Object(source, .Map)? = try document.get(obj: list, index: UInt64(from))
            else { throw TypedDocument<Entity>.DocumentError.unexpectedShape }
            let landed = try document.insertObject(
                obj: list, index: UInt64(insertIndex), ty: .Map
            )
            try document.deepCopy(source, type: .Map, into: landed)

            let stale = from >= insertIndex ? from + 1 : from
            try document.delete(obj: list, index: UInt64(stale))
        }

        if !fields.isEmpty {
            let landedIndex = insertIndex > from ? insertIndex - 1 : insertIndex
            guard case let .Object(moved, .Map)? = try document.get(
                obj: list, index: UInt64(landedIndex))
            else { throw TypedDocument<Entity>.DocumentError.unexpectedShape }
            for (key, value) in fields {
                if let value {
                    try document.put(obj: moved, key: key, value: value)
                } else {
                    try document.delete(obj: moved, key: key)
                }
            }
        }
        document.commitWith(message: commitMessage)
        cachedValue = next
        undoStack.append(beforeHeads)
        redoStack.removeAll()
        #if DEBUG
        if ProcessInfo.processInfo.environment["MXU_VERIFY_SCOPED_WRITES"] != nil {
            assert(
                try! AutomergeDecoder(doc: document).decode(Entity.self) == cachedValue,
                "moveListElement diverged: document does not decode to the expected value"
            )
        }
        #endif
        return cachedValue
    }

    @discardableResult
    func insertListElements<Element: Encodable>(
        listAt path: [AnyCodingKey], at index: Int, values: [Element], next: Entity
    ) throws -> Entity {
        guard next != cachedValue, !values.isEmpty else { return cachedValue }
        let beforeHeads = document.heads()
        let list = try objectId(at: path)
        let start = min(max(index, 0), Int(document.length(obj: list)))
        let encoder = AutomergeEncoder(doc: document, strategy: .createWhenNeeded, cautiousWrite: true)
        for (offset, value) in values.enumerated() {
            let landing = start + offset
            _ = try document.insertObject(obj: list, index: UInt64(landing), ty: .Map)
            try encoder.encode(value, at: path + [AnyCodingKey(UInt64(landing))])
        }
        document.commitWith(message: commitMessage)
        cachedValue = next
        undoStack.append(beforeHeads)
        redoStack.removeAll()
        #if DEBUG
        if ProcessInfo.processInfo.environment["MXU_VERIFY_SCOPED_WRITES"] != nil {
            assert(
                try! AutomergeDecoder(doc: document).decode(Entity.self) == cachedValue,
                "insertListElements diverged: document does not decode to the expected value"
            )
        }
        #endif
        return cachedValue
    }

    @discardableResult
    func insertListElements<Element: Encodable>(
        listAt path: [AnyCodingKey], placing elements: [(index: Int, element: Element)], next: Entity
    ) throws -> Entity {
        if next != cachedValue, !elements.isEmpty {
            let beforeHeads = document.heads()
            let list = try objectId(at: path)
            let encoder = AutomergeEncoder(doc: document, strategy: .createWhenNeeded, cautiousWrite: true)
            for (index, element) in elements.sorted(by: { $0.index < $1.index }) {
                let landing = min(max(index, 0), Int(document.length(obj: list)))
                _ = try document.insertObject(obj: list, index: UInt64(landing), ty: .Map)
                try encoder.encode(element, at: path + [AnyCodingKey(UInt64(landing))])
            }
            document.commitWith(message: commitMessage)
            cachedValue = next
            undoStack.append(beforeHeads)
            redoStack.removeAll()
            verifyScopedWrite("insertListElements(placing:)")
        }
        return cachedValue
    }

    @discardableResult
    func removeListElements(
        listAt path: [AnyCodingKey], at indices: [Int], next: Entity
    ) throws -> Entity {
        if next != cachedValue, !indices.isEmpty {
            let beforeHeads = document.heads()
            let list = try objectId(at: path)
            let length = Int(document.length(obj: list))
            for index in Set(indices).sorted(by: >) where index >= 0 && index < length {
                try document.delete(obj: list, index: UInt64(index))
            }
            document.commitWith(message: commitMessage)
            cachedValue = next
            undoStack.append(beforeHeads)
            redoStack.removeAll()
            verifyScopedWrite("removeListElements")
        }
        return cachedValue
    }

    @discardableResult
    func updateField<Field: Codable & Equatable>(
        _ keyPath: WritableKeyPath<Entity, Field?>, key: String, to value: Field?
    ) throws -> Entity {
        if value != cachedValue[keyPath: keyPath] {
            let before = document.heads()
            if let value {
                let encoder = AutomergeEncoder(doc: document, strategy: .createWhenNeeded, cautiousWrite: true)
                try encoder.encode(value, at: [AnyCodingKey(key)])
            } else {
                try document.delete(obj: ObjId.ROOT, key: key)
            }
            document.commitWith(message: commitMessage)
            cachedValue[keyPath: keyPath] = value
            undoStack.append(before)
            redoStack.removeAll()
            verifyScopedWrite("updateField")
        }
        return cachedValue
    }

    @discardableResult
    func updateFields(_ fields: [TypedDocument<Entity>.FieldWrite]) throws -> Entity {
        let changing = fields.filter { $0.differs(cachedValue) }
        if !changing.isEmpty {
            let before = document.heads()
            for field in changing {
                try field.write(document, &cachedValue)
            }
            document.commitWith(message: commitMessage)
            undoStack.append(before)
            redoStack.removeAll()
            verifyScopedWrite("updateFields")
        }
        return cachedValue
    }

    func verifyScopedWrite(_ operation: String) {
        #if DEBUG
        if ProcessInfo.processInfo.environment["MXU_VERIFY_SCOPED_WRITES"] != nil {
            assert(
                try! AutomergeDecoder(doc: document).decode(Entity.self) == cachedValue,
                "\(operation) diverged: the document does not decode to the value it cached"
            )
        }
        #endif
    }

    private func objectId(at path: [AnyCodingKey]) throws -> ObjId {
        var current = ObjId.ROOT
        for key in path {
            let value: Value? = if let index = key.intValue {
                try document.get(obj: current, index: UInt64(index))
            } else {
                try document.get(obj: current, key: key.stringValue)
            }
            guard case let .Object(next, _)? = value else {
                throw TypedDocument<Entity>.DocumentError.unexpectedShape
            }
            current = next
        }
        return current
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    @discardableResult
    func undo(scoped: Bool = false) throws -> Entity {
        wholeWrite = nil
        if let target = undoStack.popLast() {
            redoStack.append(document.heads())
            if scoped {
                try scopedRevert(to: target)
            } else {
                try revert(to: target)
            }
        }
        return cachedValue
    }

    @discardableResult
    func redo(scoped: Bool = false) throws -> Entity {
        wholeWrite = nil
        if let target = redoStack.popLast() {
            undoStack.append(document.heads())
            if scoped {
                try scopedRevert(to: target)
            } else {
                try revert(to: target)
            }
        }
        return cachedValue
    }

    func merge(_ other: ReplicaCore<Entity>) throws {
        let before = document.heads()
        try document.merge(other: other.document)
        if document.heads() != before {
            try redecode(since: before)
        }
    }

    func contains(heads: Set<ChangeHash>) -> Bool {
        heads.allSatisfy { document.change(hash: $0) != nil }
    }

    @discardableResult
    func applyEncodedChanges(_ encoded: Data) throws -> Bool {
        let before = document.heads()
        try document.applyEncodedChanges(encoded: encoded)
        guard document.heads() != before else { return false }
        try redecode(since: before)
        return true
    }

    var history: EditorHistory {
        EditorHistory(undo: undoStack, redo: redoStack, heads: document.heads())
    }

    @discardableResult
    func restore(_ history: EditorHistory) -> Bool {
        if history.heads == document.heads() {
            undoStack = history.undo
            redoStack = history.redo
            return true
        } else {
            return false
        }
    }

    func applyLanded(_ bundle: EditorBundle) -> EditorLanding {
        if Entity.self == Presentation.self, bundle.slideScoped, !bundle.replaced, document.heads() == bundle.base {
            return landScoped(bundle.changes)
        } else {
            return .refused
        }
    }

    func absorb(_ changes: Data) throws -> Bool {
        let before = document.heads()
        let patches = changes.isEmpty ? [] : try document.applyEncodedChangesWithPatches(encoded: changes)
        let moved = document.heads() != before
        if moved {
            try redecode(patches)
            undoStack.removeAll()
            redoStack.removeAll()
        }
        return moved
    }

    private func landScoped(_ changes: Data) -> EditorLanding {
        let before = document.heads()
        do {
            let patches = changes.isEmpty ? [] : try document.applyEncodedChangesWithPatches(encoded: changes)
            let moved = document.heads() != before
            if moved {
                try redecode(patches)
                undoStack.removeAll()
                redoStack.removeAll()
            }
            return .applied(moved: moved)
        } catch {
            return .refused
        }
    }

    func patches(since before: Set<ChangeHash>) -> [Patch] {
        document.difference(from: before, to: document.heads())
    }

    private func redecode(since before: Set<ChangeHash>) throws {
        try redecode(document.difference(from: before, to: document.heads()))
    }

    private func redecode(_ patches: [Patch]) throws {
        let touched = TypedDocument<Entity>.touchedSlides(patches)
        if let touched, var deck = cachedValue as? Presentation, touched.allSatisfy({ $0 < deck.slides.count }) {
            let decoder = AutomergeDecoder(doc: document)
            for index in touched {
                deck.slides[index] = try decoder.decode(Slide.self, from: [AnyCodingKey("slides"), AnyCodingKey(UInt64(index))])
            }
            cachedValue = deck as! Entity
            #if DEBUG
            decodes.slides += touched.count
            #endif
        } else {
            cachedValue = try AutomergeDecoder(doc: document).decode(Entity.self)
            #if DEBUG
            decodes.whole += 1
            #endif
        }
    }

    private func write(_ next: Entity) throws {
        let encoder = AutomergeEncoder(doc: document, strategy: .createWhenNeeded, cautiousWrite: true)
        try encoder.encode(next)
        document.commitWith(message: commitMessage)
        cachedValue = next
    }

    private func revert(to heads: Set<ChangeHash>) throws {
        let snapshot = try document.forkAt(heads: heads)
        let old = try AutomergeDecoder(doc: snapshot).decode(Entity.self)
        #if DEBUG
        decodes.whole += 1
        #endif
        try write(old)
    }

    private func scopedRevert(to heads: Set<ChangeHash>) throws {
        let slidesBefore = slideList()
        var revert = SubtreeRevert(document: document, heads: heads)
        let rootKeys = try revert.run()
        document.commitWith(message: commitMessage)
        if !rootKeys.isEmpty {
            try adoptReverted(rootKeys: rootKeys, modified: revert.modified, slidesBefore: slidesBefore)
        }
        verifyScopedWrite("scopedRevert")
    }

    private func adoptReverted(rootKeys: Set<String>, modified: Set<ObjId>, slidesBefore: SlideList?) throws {
        let rebuilt = try (cachedValue as? Presentation).map {
            try rebuiltDeck($0, rootKeys: rootKeys, modified: modified, slidesBefore: slidesBefore)
        }
        switch rebuilt {
        case let .success(deck)?:
            cachedValue = deck as! Entity
        case let .failure(reason)?:
            try decodeWhole()
            noteWholeWrite("revert: \(reason.rawValue)")
        case nil:
            try decodeWhole()
        }
    }

    private func rebuiltDeck(
        _ current: Presentation, rootKeys: Set<String>, modified: Set<ObjId>, slidesBefore: SlideList?
    ) throws -> Result<Presentation, DeckEdit.Unscoped> {
        let fields = DeckField.all
        let named = Set(fields.map(\.key)).union(["slides"])
        let slidesNow = slideList()
        if !rootKeys.isSubset(of: named) {
            return .failure(.unnamedField)
        } else if rootKeys.contains("slides"),
                  slidesNow == nil || slidesNow?.list != slidesBefore?.list || slidesBefore?.elements.count != current.slides.count {
            return .failure(.slideListReplaced)
        } else {
            var deck = current
            let decoder = AutomergeDecoder(doc: document)
            for field in fields where rootKeys.contains(field.key) {
                try field.read(decoder, document, &deck)
            }
            if rootKeys.contains("slides"), let slidesNow, let slidesBefore {
                var kept: [ObjId: Int] = [:]
                for (index, element) in slidesBefore.elements.enumerated() {
                    if case let .Object(id, _) = element {
                        kept[id] = index
                    }
                }
                var slides: [Slide] = []
                slides.reserveCapacity(slidesNow.elements.count)
                for (index, element) in slidesNow.elements.enumerated() {
                    if case let .Object(id, _) = element, let was = kept[id], !modified.contains(id) {
                        slides.append(current.slides[was])
                    } else {
                        slides.append(try decoder.decode(Slide.self, from: TypedDocument<Presentation>.slidePath(index)))
                        #if DEBUG
                        decodes.slides += 1
                        #endif
                    }
                }
                deck.slides = slides
            }
            return .success(deck)
        }
    }

    struct SlideList {
        let list: ObjId
        let elements: [Value]
    }

    private func slideList() -> SlideList? {
        if Entity.self == Presentation.self, case let .Object(list, .List)? = try? document.get(obj: ObjId.ROOT, key: "slides") {
            return (try? document.values(obj: list)).map { SlideList(list: list, elements: $0) }
        } else {
            return nil
        }
    }

    private func decodeWhole() throws {
        cachedValue = try AutomergeDecoder(doc: document).decode(Entity.self)
        #if DEBUG
        decodes.whole += 1
        #endif
    }

    private func noteWholeWrite(_ reason: String) {
        wholeWrite = reason
        #if DEBUG
        wholeWrites += 1
        #endif
    }
}

extension TypedDocument where Entity == Presentation {

    nonisolated static func slidePath(_ index: Int) -> [AnyCodingKey] {
        [AnyCodingKey("slides"), AnyCodingKey(UInt64(index))]
    }

    @discardableResult
    public func updateSlide(at index: Int, _ mutate: (inout Slide) throws -> Void) throws -> Presentation {
        try core.updateSlide(at: index, mutate)
    }

    @discardableResult
    public func updateSlide(id: String, _ mutate: (inout Slide) throws -> Void) throws -> Presentation {
        try core.updateSlide(id: id, mutate)
    }

    @discardableResult
    public func updateSlides(_ mutate: (inout Presentation) throws -> Void) throws -> Presentation {
        try core.updateSlides(mutate)
    }

    nonisolated static func editedSlides(from current: Presentation, to next: Presentation) throws -> [Int] {
        var currentDeck = current
        currentDeck.slides = []
        var nextDeck = next
        nextDeck.slides = []
        if currentDeck == nextDeck, current.slides.map(\.id) == next.slides.map(\.id) {
            return current.slides.indices.filter { current.slides[$0] != next.slides[$0] }
        } else {
            throw DocumentError.unexpectedShape
        }
    }

    @discardableResult
    public func updateSlideList(_ change: (inout [Slide]) throws -> Void) throws -> Presentation {
        try core.updateSlideList(change)
    }

    nonisolated static func slideMove(
        from current: [Slide], to slides: [Slide]
    ) -> (from: Int, before: Int?, fields: [String: ScalarValue?])? {
        if let move = ListMove(before: current.map(\.id), after: slides.map(\.id)) {
            var expected = current
            var slide = expected.remove(at: move.from)
            let landing = move.before.map { $0 > move.from ? $0 - 1 : $0 } ?? expected.count
            let section = slides[landing].sectionId
            let fields: [String: ScalarValue?] = section == slide.sectionId
                ? [:]
                : ["sectionId": section.map { .String($0) }]
            slide.sectionId = section
            expected.insert(slide, at: landing)
            return expected == slides ? (move.from, move.before, fields) : nil
        } else {
            return nil
        }
    }
}

extension ReplicaCore where Entity == Presentation {
    @discardableResult
    func updateSlide(at index: Int, _ mutate: (inout Slide) throws -> Void) throws -> Presentation {
        try update(\.slides[index], at: TypedDocument<Presentation>.slidePath(index), mutate)
    }

    @discardableResult
    func updateSlide(id: String, _ mutate: (inout Slide) throws -> Void) throws -> Presentation {
        if let index = cachedValue.slides.firstIndex(where: { $0.id == id }) {
            return try updateSlide(at: index, mutate)
        } else {
            return cachedValue
        }
    }

    @discardableResult
    func updateSlides(_ mutate: (inout Presentation) throws -> Void) throws -> Presentation {
        var next = cachedValue
        try mutate(&next)
        let edited = try TypedDocument<Presentation>.editedSlides(from: cachedValue, to: next)
        if !edited.isEmpty {
            let before = document.heads()
            let encoder = AutomergeEncoder(doc: document, strategy: .createWhenNeeded, cautiousWrite: true)
            for index in edited {
                try encoder.encode(next.slides[index], at: TypedDocument<Presentation>.slidePath(index))
            }
            document.commitWith(message: commitMessage)
            cachedValue = next
            undoStack.append(before)
            redoStack.removeAll()
            verifyScopedWrite("updateSlides")
        }
        return cachedValue
    }

    @discardableResult
    func updateDeck(_ mutate: (inout Presentation) throws -> Void) throws -> Presentation {
        var next = cachedValue
        try mutate(&next)
        wholeWrite = nil
        if next != cachedValue {
            let before = document.heads()
            switch (DeckEdit.plan(from: cachedValue, to: next), slideList()) {
            case let (.success(plan), slides?):
                try plan.write(into: document, slides: slides.list)
                document.commitWith(message: commitMessage)
                cachedValue = next
                verifyScopedWrite("updateDeck")
            case let (.failure(reason), _):
                try write(next)
                noteWholeWrite("updateDeck: \(reason.rawValue)")
            case (.success, nil):
                try write(next)
                noteWholeWrite("updateDeck: \(DeckEdit.Unscoped.slideListReplaced.rawValue)")
            }
            undoStack.append(before)
            redoStack.removeAll()
        }
        return cachedValue
    }

    @discardableResult
    func updateSlideList(_ change: (inout [Slide]) throws -> Void) throws -> Presentation {
        let current = cachedValue.slides
        var slides = current
        try change(&slides)
        var next = cachedValue
        next.slides = slides
        let list = [AnyCodingKey("slides")]
        if let removal = ListRemoval(before: current, after: slides, id: \.id),
           current.filter({ !removal.ids.contains($0.id) }) == slides {
            try removeListElements(listAt: list, at: removal.removed.map(\.index), next: next)
        } else if let insertion = ListInsertion(before: current, after: slides, id: \.id),
                  slides.filter({ !insertion.ids.contains($0.id) }) == current {
            try insertListElements(listAt: list, placing: insertion.added, next: next)
        } else if let move = TypedDocument<Presentation>.slideMove(from: current, to: slides) {
            try moveListElement(
                listAt: list, from: move.from, before: move.before, settingOnMoved: move.fields, next: next)
        } else if current.map(\.id) == slides.map(\.id) {
            try updateSlides { $0.slides = slides }
        } else {
            try update { $0.slides = slides }
        }
        return cachedValue
    }
}
