import Automerge
import Foundation

struct DeckEdit {

    enum SlideWrite: Equatable {
        case remove(Int)

        case move(from: Int, before: Int)
        case insert(Int, Slide)

        case encode(Int, Slide)
    }

    let fields: [DeckField]
    let slides: [SlideWrite]

    static func plan(from current: Presentation, to next: Presentation) -> Result<DeckEdit, Unscoped> {
        let fields = DeckField.all(writing: next).filter { $0.differs(current, next) }
        var probe = current
        for field in fields {
            field.adopt(next, &probe)
        }
        probe.slides = next.slides
        if probe != next {
            return .failure(.unnamedField)
        } else if let slides = slideWrites(from: current.slides, to: next.slides) {
            return .success(DeckEdit(fields: fields, slides: slides))
        } else {
            return .failure(.duplicateSlideIDs)
        }
    }

    enum Unscoped: String, Error {

        case unnamedField = "a deck field the scoped write does not name"

        case duplicateSlideIDs = "duplicate slide ids"

        case slideListReplaced = "no slide list or a replaced one"
    }

    static func slideWrites(from current: [Slide], to next: [Slide]) -> [SlideWrite]? {
        let currentIndex = Dictionary(current.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        let nextIDs = Set(next.map(\.id))
        if currentIndex.count == current.count, nextIDs.count == next.count {
            var writes: [SlideWrite] = []
            var work = current.map(\.id)
            for index in current.indices.reversed() where !nextIDs.contains(current[index].id) {
                writes.append(.remove(index))
                work.remove(at: index)
            }
            let keptOrder = next.map(\.id).filter { currentIndex[$0] != nil }
            let workIndex = Dictionary(uniqueKeysWithValues: work.enumerated().map { ($1, $0) })
            let inPlace = Set(longestIncreasing(keptOrder.map { workIndex[$0]! }).map { keptOrder[$0] })
            for (target, id) in keptOrder.enumerated() where !inPlace.contains(id) {
                let from = work.firstIndex(of: id)!
                let before = target == 0 ? 0 : work.firstIndex(of: keptOrder[target - 1])! + 1
                writes.append(.move(from: from, before: before))
                work.insert(id, at: before)
                work.remove(at: from >= before ? from + 1 : from)
            }
            for (index, slide) in next.enumerated() where currentIndex[slide.id] == nil {
                writes.append(.insert(index, slide))
                work.insert(slide.id, at: index)
            }
            for (index, slide) in next.enumerated() {
                if let was = currentIndex[slide.id], current[was] != slide {
                    writes.append(.encode(index, slide))
                }
            }
            return work == next.map(\.id) ? writes : nil
        } else {
            return nil
        }
    }

    static func longestIncreasing(_ values: [Int]) -> [Int] {

        var tails: [Int] = []
        var previous = Array(repeating: -1, count: values.count)
        for (index, value) in values.enumerated() {
            var low = 0
            var high = tails.count
            while low < high {
                let middle = (low + high) / 2
                if values[tails[middle]] < value { low = middle + 1 } else { high = middle }
            }
            previous[index] = low > 0 ? tails[low - 1] : -1
            if low == tails.count { tails.append(index) } else { tails[low] = index }
        }
        var run: [Int] = []
        var cursor = tails.last ?? -1
        while cursor >= 0 {
            run.append(cursor)
            cursor = previous[cursor]
        }
        return run.reversed()
    }

    func write(into document: Document, slides list: ObjId) throws {
        let encoder = AutomergeEncoder(doc: document, strategy: .createWhenNeeded, cautiousWrite: true)
        for field in fields {
            try field.write(document, encoder)
        }
        for write in slides {
            switch write {
            case let .remove(index):
                try document.delete(obj: list, index: UInt64(index))
            case let .move(from, before):
                if case let .Object(source, .Map)? = try document.get(obj: list, index: UInt64(from)) {
                    let landed = try document.insertObject(obj: list, index: UInt64(before), ty: .Map)
                    try document.deepCopy(source, type: .Map, into: landed)
                    try document.delete(obj: list, index: UInt64(from >= before ? from + 1 : from))
                } else {
                    throw TypedDocument<Presentation>.DocumentError.unexpectedShape
                }
            case let .insert(index, slide):
                _ = try document.insertObject(obj: list, index: UInt64(index), ty: .Map)
                try encoder.encode(slide, at: TypedDocument<Presentation>.slidePath(index))
            case let .encode(index, slide):
                try encoder.encode(slide, at: TypedDocument<Presentation>.slidePath(index))
            }
        }
    }
}

extension Document {

    func deepCopy(_ source: ObjId, type: ObjType, into destination: ObjId) throws {
        switch type {
        case .Map:
            for (key, value) in try mapEntries(obj: source) {
                switch value {
                case let .Scalar(scalar):
                    try put(obj: destination, key: key, value: scalar)
                case let .Object(child, childType):
                    let landed = try putObject(obj: destination, key: key, ty: childType)
                    try deepCopy(child, type: childType, into: landed)
                }
            }
        case .List:
            for (index, value) in try values(obj: source).enumerated() {
                switch value {
                case let .Scalar(scalar):
                    try insert(obj: destination, index: UInt64(index), value: scalar)
                case let .Object(child, childType):
                    let landed = try insertObject(obj: destination, index: UInt64(index), ty: childType)
                    try deepCopy(child, type: childType, into: landed)
                }
            }
        case .Text:
            try spliceText(obj: destination, start: 0, delete: 0, value: text(obj: source))
        }
    }
}

struct DeckField {
    let key: String
    let differs: (Presentation, Presentation) -> Bool

    let adopt: (Presentation, inout Presentation) -> Void

    fileprivate let writeValue: (Document, AutomergeEncoder) throws -> Void

    let read: (AutomergeDecoder, Document, inout Presentation) throws -> Void

    func write(_ document: Document, _ encoder: AutomergeEncoder) throws {
        try writeValue(document, encoder)
    }

    static func required<Field: Codable & Equatable>(_ keyPath: WritableKeyPath<Presentation, Field>, _ key: String) -> (Presentation) -> DeckField {
        { next in
            DeckField(
                key: key,
                differs: { $0[keyPath: keyPath] != $1[keyPath: keyPath] },
                adopt: { $1[keyPath: keyPath] = $0[keyPath: keyPath] },
                writeValue: { _, encoder in try encoder.encode(next[keyPath: keyPath], at: [AnyCodingKey(key)]) },
                read: { decoder, _, deck in deck[keyPath: keyPath] = try decoder.decode(Field.self, from: [AnyCodingKey(key)]) }
            )
        }
    }

    static func optional<Field: Codable & Equatable>(_ keyPath: WritableKeyPath<Presentation, Field?>, _ key: String) -> (Presentation) -> DeckField {
        { next in
            DeckField(
                key: key,
                differs: { $0[keyPath: keyPath] != $1[keyPath: keyPath] },
                adopt: { $1[keyPath: keyPath] = $0[keyPath: keyPath] },
                writeValue: { document, encoder in
                    if let value = next[keyPath: keyPath] {
                        try encoder.encode(value, at: [AnyCodingKey(key)])
                    } else {
                        try document.delete(obj: ObjId.ROOT, key: key)
                    }
                },
                read: { decoder, document, deck in
                    switch try document.get(obj: ObjId.ROOT, key: key) {
                    case nil, .Scalar(.Null)?:
                        deck[keyPath: keyPath] = nil
                    default:
                        deck[keyPath: keyPath] = try decoder.decode(Field.self, from: [AnyCodingKey(key)])
                    }
                }
            )
        }
    }

    static func all(writing next: Presentation) -> [DeckField] {
        rows.map { $0(next) }
    }

    static var all: [DeckField] {
        rows.map { $0(Presentation(id: "", name: "", presentationKind: .deck, themeId: "", slides: [])) }
    }

    private static var rows: [(Presentation) -> DeckField] {
        [
            required(\.id, "id"),
            required(\.name, "name"),
            required(\.presentationKind, "presentationKind"),
            required(\.themeId, "themeId"),
            optional(\.folder, "folder"),
            optional(\.folderId, "folderId"),
            optional(\.canvasWidth, "canvasWidth"),
            optional(\.canvasHeight, "canvasHeight"),
            optional(\.background, "background"),
            optional(\.backgroundFill, "backgroundFill"),
            optional(\.sections, "sections"),
            optional(\.arrangements, "arrangements"),
            optional(\.defaultArrangementId, "defaultArrangementId"),
            optional(\.reflowSource, "reflowSource"),
            optional(\.ccli, "ccli"),
            optional(\.chordProSource, "chordProSource"),
            optional(\.musicKey, "musicKey"),
            optional(\.autoAdvance, "autoAdvance"),
            optional(\.displayKey, "displayKey"),
            optional(\.origin, "origin"),
        ]
    }
}
