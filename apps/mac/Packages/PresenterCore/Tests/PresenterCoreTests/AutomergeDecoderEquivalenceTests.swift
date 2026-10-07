import Automerge
import Foundation
import Testing
@testable import PresenterCore

@Suite struct AutomergeDecoderEquivalenceTests {
    private static func richDeck() -> Presentation {
        let styled = SlideObject(
            id: "title", objectKind: .text, name: "Title", text: "Amazing grace",
            x: 120, y: 80.5, width: 1680, height: 240, hidden: false, opacity: 0.5, blendMode: .multiply,
            effects: [Effect(effectKind: .blur, radius: 4)],
            textStyle: TextStyle(
                fontName: "Georgia", fontSize: 72,
                fill: ObjectFill(fillKind: .solid, colorHex: "#FFFFFFFF"), horizontalAlignment: .center
            )
        )
        let shape = SlideObject(
            id: "plate", objectKind: .shape, name: "Plate", text: "",
            shapeKind: .roundedRectangle, cornerRadius: 12,
            fill: ObjectFill(fillKind: .linearGradient, gradientAngleDegrees: 90)
        )
        let bare = SlideObject(id: "bg", objectKind: .media, name: "Background", text: "")
        return Presentation(
            id: "rich", name: "Rich", presentationKind: .deck, themeId: "theme-1", folder: "Songs",
            slides: [
                Slide(id: "s1", name: "One", objects: [styled, bare], notes: "Speaker notes\nline two"),
                Slide(id: "s2", name: "Two", objects: [shape], keepWords: true),
                Slide(id: "s3", name: "Three", objects: []),
            ],
            canvasWidth: 1920, canvasHeight: 1080
        )
    }

    private static func note() -> NoteDocument {
        NoteDocument(
            id: "note-1", name: "Sermon notes", origin: "local",
            body: NoteBody(
                blocks: [
                    NoteBlock(type: .heading, level: 2, runs: [NoteRun(text: "Grace", bold: true)]),
                    NoteBlock(type: .paragraph, runs: [NoteRun(text: "Saved a wretch like me")]),
                ],
                plainText: "Grace\nSaved a wretch like me"
            )
        )
    }

    private func encodeThenDecode<T: Codable & Equatable>(_ value: T) throws {
        let document = Document()
        try AutomergeEncoder(doc: document).encode(value)
        #expect(try AutomergeDecoder(doc: document).decode(T.self) == value)
    }

    @LibraryActor private func roundTrip<T: DocumentEntity>(_ value: T) throws {
        let saved = try TypedDocument(value).save()
        #expect(try TypedDocument<T>(data: saved).value == value)
    }

    @Test func everyFixtureDecodesToTheValueItWasEncodedFrom() throws {
        let decks = [Self.richDeck(), WelcomeDeck.makePresentation()]
        for deck in decks { try encodeThenDecode(deck) }
        for pack in StarterPack.allCases { try encodeThenDecode(pack.makeTheme()) }
        for overlay in StarterPack.boldBlocks.makeOverlays() { try encodeThenDecode(overlay) }
        try encodeThenDecode(WelcomeDeck.makeService(serviceDate: "2026-09-22"))
        try encodeThenDecode(Self.note())
    }

    @LibraryActor @Test func everyFixtureRoundTripsThroughTypedDocument() throws {
        try roundTrip(Self.richDeck())
        try roundTrip(WelcomeDeck.makePresentation())
        for pack in StarterPack.allCases { try roundTrip(pack.makeTheme()) }
        for overlay in StarterPack.digital.makeOverlays() { try roundTrip(overlay) }
        try roundTrip(WelcomeDeck.makeService(serviceDate: "2026-09-22"))
        try roundTrip(Self.note())
    }

    @LibraryActor @Test func subtreeDecodesMatchTheWholeDocument() throws {
        let deck = Self.richDeck()
        let document = try TypedDocument(deck).document
        let decoder = AutomergeDecoder(doc: document)
        for (index, slide) in deck.slides.enumerated() {
            let path = [AnyCodingKey("slides"), AnyCodingKey(UInt64(index))]
            #expect(try decoder.decode(Slide.self, from: path) == slide)
            for (objectIndex, object) in slide.objects.enumerated() {
                let objectPath = path + [AnyCodingKey("objects"), AnyCodingKey(UInt64(objectIndex))]
                #expect(try decoder.decode(SlideObject.self, from: objectPath) == object)
            }
        }
        #expect(try decoder.decode(TextStyle.self, from: AnyCodingKey.parsePath("slides.[0].objects.[0].textStyle"))
            == deck.slides[0].objects[0].textStyle)
    }

    private struct Inner: Codable, Equatable {
        var label: String
        var weight: Double?
    }

    private enum Tone: String, Codable, Equatable { case warm, cool }

    private struct Optionals: Codable, Equatable {
        var bool: Bool?
        var string: String?
        var double: Double?
        var float: Float?
        var int: Int?
        var int8: Int8?
        var int16: Int16?
        var int32: Int32?
        var int64: Int64?
        var uint: UInt?
        var uint8: UInt8?
        var uint16: UInt16?
        var uint32: UInt32?
        var uint64: UInt64?
        var date: Date?
        var data: Data?
        var url: URL?
        var tone: Tone?
        var inner: Inner?
        var list: [Inner]?
        var strings: [String]?
        var table: [String: Inner]?
    }

    private static let full = Optionals(
        bool: true, string: "grace", double: 0.1, float: 0.1, int: -42, int8: -8, int16: -16, int32: -32,
        int64: -64, uint: 42, uint8: 8, uint16: 16, uint32: 32, uint64: 64,
        date: Date(timeIntervalSince1970: 1_790_000_000), data: Data([0, 1, 2, 255]),
        url: URL(string: "https://example.com/a?b=c"), tone: .cool,
        inner: Inner(label: "inner", weight: 2.5), list: [Inner(label: "a"), Inner(label: "b", weight: 1)],
        strings: ["x", "y"], table: ["k": Inner(label: "v")]
    )

    @Test func optionalsDecodeTheSameWhenPresentAbsentOrNull() throws {
        try encodeThenDecode(Self.full)
        try encodeThenDecode(Optionals())
        try encodeThenDecode(["items": [Self.full, Optionals(), Self.full]])
        try encodeThenDecode(["nested": Self.full])

        let document = Document()
        try AutomergeEncoder(doc: document).encode(Self.full)
        for key in ["bool", "string", "double", "int", "uint64", "date", "data", "url", "tone", "inner", "list", "table"] {
            try document.put(obj: ObjId.ROOT, key: key, value: .Null)
        }
        var expected = Self.full
        expected.bool = nil; expected.string = nil; expected.double = nil; expected.int = nil; expected.uint64 = nil
        expected.date = nil; expected.data = nil; expected.url = nil; expected.tone = nil; expected.inner = nil
        expected.list = nil; expected.table = nil
        #expect(try AutomergeDecoder(doc: document).decode(Optionals.self) == expected)
    }

    private struct Bound: Codable {
        var counter: Counter?
        var text: AutomergeText?
        var requiredText: AutomergeText
        var requiredCounter: Counter
    }

    @Test func counterAndTextDecodeWhetherOptionalOrRequired() throws {
        let document = Document()
        try AutomergeEncoder(doc: document).encode(
            Bound(counter: Counter(3), text: AutomergeText("hello"), requiredText: AutomergeText("world"), requiredCounter: Counter(7))
        )
        let decoded = try AutomergeDecoder(doc: document).decode(Bound.self)
        #expect(decoded.counter?.value == 3)
        #expect(decoded.text?.value == "hello")
        #expect(decoded.requiredText.value == "world")
        #expect(decoded.requiredCounter.value == 7)

        let empty = Document()
        try AutomergeEncoder(doc: empty).encode(Bound(requiredText: AutomergeText(""), requiredCounter: Counter()))
        let bare = try AutomergeDecoder(doc: empty).decode(Bound.self)
        #expect(bare.counter == nil)
        #expect(bare.text == nil)
    }

    private struct KeyProbe: Decodable {
        var keys: [String]
        var hasString: Bool
        var hasMissing: Bool

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: AnyCodingKey.self)
            keys = container.allKeys.map(\.stringValue).sorted()
            hasString = container.contains(AnyCodingKey("string"))
            hasMissing = container.contains(AnyCodingKey("missing"))
        }
    }

    @Test func containsAndAllKeysSeeEveryStoredKey() throws {
        let document = Document()
        try AutomergeEncoder(doc: document).encode(Optionals(string: "grace", inner: Inner(label: "x")))
        let probe = try AutomergeDecoder(doc: document).decode(KeyProbe.self)
        #expect(probe.keys == ["inner", "string"])
        #expect(probe.hasString)
        #expect(!probe.hasMissing)
    }

    private struct Labelled: Decodable { var label: String }

    @Test func batchReadsAgreeWithGetUnderConflicts() throws {
        for round in 0..<16 {
            let base = Document()
            let list = try base.putObject(obj: ObjId.ROOT, key: "list", ty: .List)
            for index in 0..<3 { try base.insert(obj: list, index: UInt64(index), value: .Int(Int64(index))) }
            try base.put(obj: ObjId.ROOT, key: "counter", value: .Counter(1))
            let left = base.fork()
            let right = base.fork()
            try left.put(obj: ObjId.ROOT, key: "label", value: .String("left \(round)"))
            try right.put(obj: ObjId.ROOT, key: "label", value: .String("right \(round)"))
            try left.put(obj: ObjId.ROOT, key: "weight", value: .F64(1))
            _ = try right.putObject(obj: ObjId.ROOT, key: "weight", ty: .Map)
            try left.put(obj: list, index: 1, value: .String("left"))
            _ = try right.putObject(obj: list, index: 1, ty: .Map)
            try left.increment(obj: ObjId.ROOT, key: "counter", by: 2)
            try right.increment(obj: ObjId.ROOT, key: "counter", by: 3)
            try left.merge(other: right)

            let entries = try left.mapEntries(obj: ObjId.ROOT)
            #expect(entries.map(\.0) == left.keys(obj: ObjId.ROOT))
            for (key, value) in entries {
                #expect(try left.get(obj: ObjId.ROOT, key: key) == value, "\(key)")
            }
            let values = try left.values(obj: list)
            #expect(values.count == Int(left.length(obj: list)))
            for (index, value) in values.enumerated() {
                #expect(try left.get(obj: list, index: UInt64(index)) == value, "[\(index)]")
            }
            let winner = try left.get(obj: ObjId.ROOT, key: "label")
            #expect(try Value.Scalar(.String(AutomergeDecoder(doc: left).decode(Labelled.self).label)) == winner)
        }
    }

    private struct NeedsInt: Codable { var count: Int? }
    private struct NeedsName: Codable { var name: String }
    private struct NeedsInner: Codable { var inner: Inner? }

    @Test func mismatchesAndMissingKeysStillThrow() throws {
        let document = Document()
        try AutomergeEncoder(doc: document).encode(["count": "three", "inner": "flat"])
        #expect {
            try AutomergeDecoder(doc: document).decode(NeedsInt.self)
        } throws: { error in
            guard case let DecodingError.typeMismatch(_, context)? = error as? DecodingError else { return false }
            return context.codingPath.map(\.stringValue) == ["count"]
        }
        #expect(throws: (any Error).self) { try AutomergeDecoder(doc: document).decode(NeedsInner.self) }
        let listed = Document()
        try AutomergeEncoder(doc: listed).encode(["inner": ["a", "b"]])
        #expect(throws: (any Error).self) { try AutomergeDecoder(doc: listed).decode(NeedsInner.self) }
        #expect {
            try AutomergeDecoder(doc: document).decode(NeedsName.self)
        } throws: { error in
            guard case DecodingError.keyNotFound? = error as? DecodingError else { return false }
            return true
        }
    }
}
