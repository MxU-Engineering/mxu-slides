import Automerge
import Foundation
import Testing

@testable import PresenterCore

private func richDeck(_ id: String, slides count: Int) -> Presentation {
    var deck = editorDeck(id, slides: count)
    deck.sections = [PresentationSection(id: "\(id)-verse", name: "Verse"), PresentationSection(id: "\(id)-chorus", name: "Chorus")]
    deck.arrangements = [Arrangement(id: "\(id)-a", name: "Main", sectionIds: ["\(id)-verse", "\(id)-chorus"])]
    deck.musicKey = "G"
    for index in deck.slides.indices {
        deck.slides[index].sectionId = index < count / 2 ? "\(id)-verse" : "\(id)-chorus"
    }
    return deck
}

@LibraryActor private func replica(of document: TypedDocument<Presentation>) -> ReplicaCore<Presentation> {
    ReplicaCore(document: document.document.fork(), value: document.value)
}

private func duplicate(_ slide: Slide, as id: String) -> Slide {
    var copy = slide
    copy.id = id
    for index in copy.objects.indices {
        copy.objects[index].id = "\(id)-o\(index)"
    }
    return copy
}

private struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

private enum Step {
    case edit(String, (inout Presentation) -> Void)
    case slideText(index: Int, text: String)
    case undo
    case redo
}

private func randomStep(_ deck: Presentation, _ rng: inout SplitMix, serial: Int) -> Step {
    let count = deck.slides.count
    let fresh = Slide(
        id: "n\(serial)", name: "New \(serial)",
        objects: [SlideObject(id: "n\(serial)-t", objectKind: .text, name: "Text", text: "Fresh \(serial)", x: 1, y: 2, width: 3, height: 4)],
        sectionId: Bool.random(using: &rng) ? deck.sections?.first?.id : nil)
    switch Int.random(in: 0..<16, using: &rng) {
    case 0, 1:
        let at = Int.random(in: 0...count, using: &rng)
        return .edit("insert") { $0.slides.insert(fresh, at: at) }
    case 2 where count > 1:
        let at = Int.random(in: 0..<count, using: &rng)
        return .edit("delete") { $0.slides.remove(at: at) }
    case 3 where count > 2:
        let ids = Set(deck.slides.shuffled(using: &rng).prefix(2).map(\.id))
        return .edit("delete two") { $0.slides.removeAll { ids.contains($0.id) } }
    case 4 where count > 0:
        let at = Int.random(in: 0..<count, using: &rng)
        return .edit("duplicate") { deck in
            deck.slides.insert(duplicate(deck.slides[at], as: "d\(serial)"), at: at + 1)
        }
    case 5, 6 where count > 1:
        let from = Int.random(in: 0..<count, using: &rng)
        let to = Int.random(in: 0..<count, using: &rng)
        let section = deck.slides[to].sectionId
        return .edit("move") { deck in
            var slide = deck.slides.remove(at: from)
            slide.sectionId = section
            deck.slides.insert(slide, at: min(to, deck.slides.count))
        }
    case 7 where count > 3:
        let order = deck.slides.indices.shuffled(using: &rng)
        return .edit("reorder many") { deck in deck.slides = order.map { deck.slides[$0] } }
    case 8 where count > 0:
        let at = Int.random(in: 0..<count, using: &rng)
        return .edit("objects") { deck in
            deck.slides[at].objects.append(SlideObject(id: "o\(serial)", objectKind: .shape, name: "Box", text: "", x: 5, y: 5, width: 9, height: 9))
            deck.slides[at].objects.swapAt(0, deck.slides[at].objects.count - 1)
        }
    case 9:
        let fill: ObjectFill? = Bool.random(using: &rng) ? ObjectFill(fillKind: .solid, colorHex: "#\(serial % 10)0A0B0") : nil
        return .edit("background fill") { $0.backgroundFill = fill }
    case 10:
        let key: String? = Bool.random(using: &rng) ? ["A", "C", "E"].randomElement(using: &rng) : nil
        return .edit("music key") { deck in
            deck.musicKey = key
            deck.displayKey = key == nil ? nil : "D"
        }
    case 11 where count > 0:
        let start = Int.random(in: 0..<count, using: &rng)
        return .edit("add section") { deck in
            let section = PresentationSection(id: "sec\(serial)", name: "Bridge \(serial)")
            deck.sections = (deck.sections ?? []) + [section]
            for index in start..<deck.slides.count {
                deck.slides[index].sectionId = section.id
            }
            deck.arrangements?[0].sectionIds.append(section.id)
        }
    case 12:
        return .edit("name and canvas") { deck in
            deck.name = "Renamed \(serial)"
            deck.canvasWidth = deck.canvasWidth == nil ? 1080 : nil
            deck.canvasHeight = deck.canvasHeight == nil ? 1920 : nil
        }
    case 13 where count > 0:
        return .slideText(index: Int.random(in: 0..<count, using: &rng), text: "Typed \(serial)")
    case 14:
        return .undo
    case 15:
        return .redo
    default:
        return .undo
    }
}

@LibraryActor private func decoded(_ core: ReplicaCore<Presentation>) throws -> Presentation {
    try TypedDocument<Presentation>(data: core.document.save()).value
}

private func median(_ runs: Int, _ work: () throws -> Void) rethrows -> Duration {
    var samples: [Duration] = []
    for _ in 0..<runs {
        let began = ContinuousClock.now
        try work()
        samples.append(began.duration(to: .now))
    }
    return samples.sorted()[runs / 2]
}

@Suite struct EditorScopedWritesTests {

    @Test(arguments: 0..<12)
    @LibraryActor func scopedEditsAndUndoMatchTheWholeValuePathOverRandomSchedules(chunk: Int) throws {
        for schedule in (chunk * 20)..<(chunk * 20 + 20) {
            var rng = SplitMix(state: UInt64(schedule) &* 7919)
            let origin = try TypedDocument(richDeck("r", slides: Int.random(in: 1...9, using: &rng)))
            let whole = replica(of: origin)
            let scoped = replica(of: origin)
            let wholePeer = replica(of: origin)
            let scopedPeer = replica(of: origin)
            var wholeSent = origin.heads()
            var scopedSent = origin.heads()
            for serial in 0..<30 {
                let step = randomStep(scoped.value, &rng, serial: serial)
                var label = ""
                switch step {
                case let .edit(name, mutate):
                    label = name
                    try whole.update(mutate)
                    try scoped.updateDeck(mutate)
                case let .slideText(index, text):
                    label = "type"
                    let path = TypedDocument<Presentation>.slidePath(index) + [AnyCodingKey("objects"), AnyCodingKey(UInt64(0)), AnyCodingKey("text")]
                    try whole.update(\.slides[index].objects[0].text, at: path) { $0 = text }
                    try scoped.update(\.slides[index].objects[0].text, at: path) { $0 = text }
                case .undo:
                    label = "undo"
                    try whole.undo()
                    try scoped.undo(scoped: true)
                case .redo:
                    label = "redo"
                    try whole.redo()
                    try scoped.redo(scoped: true)
                }
                let context = "schedule \(schedule) step \(serial) (\(label))"
                try #require(scoped.value == whole.value, "\(context): the values differ")
                try #require(scoped.undoStack.count == whole.undoStack.count && scoped.redoStack.count == whole.redoStack.count, "\(context): the stacks differ")
                try #require(scoped.wholeWrite == nil, "\(context): fell back: \(scoped.wholeWrite ?? "")")
                try #require(try decoded(scoped) == scoped.value, "\(context): the scoped document does not decode to its value")

                try wholePeer.applyEncodedChanges(whole.document.encodeChangesSince(heads: wholeSent))
                try scopedPeer.applyEncodedChanges(scoped.document.encodeChangesSince(heads: scopedSent))
                wholeSent = whole.document.heads()
                scopedSent = scoped.document.heads()
                try #require(scopedPeer.value == scoped.value && wholePeer.value == whole.value, "\(context): a peer did not converge")
            }
            #if DEBUG
            #expect(scoped.wholeWrites == 0)
            #endif
        }
    }

    @LibraryActor @Test func concurrentScopedEditsConverge() throws {
        for schedule in 0..<40 {
            var rng = SplitMix(state: UInt64(schedule) &+ 100_003)
            let origin = try TypedDocument(richDeck("c", slides: 6))
            let editor = replica(of: origin)
            let station = replica(of: origin)
            for serial in 0..<6 {
                if case let .edit(_, mutate) = randomStep(editor.value, &rng, serial: serial) {
                    try editor.updateDeck(mutate)
                }
                if case let .edit(_, mutate) = randomStep(station.value, &rng, serial: 100 + serial) {
                    try station.update(mutate)
                }
            }
            try editor.undo(scoped: true)
            try editor.redo(scoped: true)
            try editor.undo(scoped: true)
            try editor.applyEncodedChanges(station.document.save())
            try station.applyEncodedChanges(editor.document.save())
            #expect(editor.value == station.value, "schedule \(schedule)")
            #expect(try decoded(editor) == editor.value, "schedule \(schedule)")
        }
    }

    @LibraryActor @Test func editsAndTheirUndoOnTheBigDeckDecodeOnlyTouchedSlides() throws {
        #if DEBUG
        let origin = try TypedDocument(editorDeck("big", slides: 183))
        let editor = EditorReplica<Presentation>(parts: ReplicaParts(document: origin.document.fork(), value: origin.value, persisted: nil))
        let core = editor.core
        var expected = core.decodes

        func expect(_ label: String, slides: Int, _ step: () throws -> Void) throws {
            try step()
            expected.slides += slides
            #expect(core.decodes == expected, "\(label): \(core.decodes) decodes, expected \(expected)")
            #expect(editor.wholeWrite == nil && core.wholeWrites == 0, "\(label): whole write \(editor.wholeWrite ?? "")")
        }

        let textPath = TypedDocument<Presentation>.slidePath(90) + [AnyCodingKey("objects"), AnyCodingKey(UInt64(0)), AnyCodingKey("text")]
        try expect("slide field edit", slides: 0) { try editor.update(\.slides[90].objects[0].text, at: textPath) { $0 = "Edited" } }
        try expect("its undo", slides: 1) { try editor.undo() }
        try expect("its redo", slides: 1) { try editor.redo() }

        let fresh = Slide(id: "fresh", name: "Fresh", objects: [])
        try expect("insert", slides: 0) { try editor.updateDeck { $0.slides.insert(fresh, at: 40) } }
        try expect("its undo", slides: 0) { try editor.undo() }
        try expect("its redo", slides: 1) { try editor.redo() }

        try expect("delete", slides: 0) { try editor.updateDeck { $0.slides.remove(at: 120) } }
        try expect("its undo", slides: 1) { try editor.undo() }
        try expect("its redo", slides: 0) { try editor.redo() }

        try expect("move", slides: 0) {
            try editor.updateDeck { deck in
                let slide = deck.slides.remove(at: 10)
                deck.slides.insert(slide, at: 150)
            }
        }
        try expect("its undo", slides: 1) { try editor.undo() }
        try expect("its redo", slides: 1) { try editor.redo() }

        try expect("duplicate", slides: 0) { try editor.updateDeck { deck in deck.slides.insert(duplicate(deck.slides[5], as: "twin"), at: 6) } }
        try expect("its undo", slides: 0) { try editor.undo() }
        try expect("its redo", slides: 1) { try editor.redo() }

        try expect("deck field", slides: 0) { try editor.updateDeck { $0.backgroundFill = ObjectFill(fillKind: .solid, colorHex: "#FF0000") } }
        try expect("its undo", slides: 0) { try editor.undo() }
        try expect("its redo", slides: 0) { try editor.redo() }

        #expect(expected.whole == 0)
        #expect(try decoded(core) == editor.value)
        #endif
    }

    @LibraryActor @Test func undoOfAOneSlideEditOnTheBigDeckIsFarBelowAWholeDecode() throws {
        let bytes = try TypedDocument(editorDeck("big", slides: 183)).save()
        let load = try median(5) { _ = try TypedDocument<Presentation>(data: bytes) }
        let scoped = try TypedDocument<Presentation>(data: bytes).core
        let whole = try TypedDocument<Presentation>(data: bytes).core
        let path = TypedDocument<Presentation>.slidePath(90) + [AnyCodingKey("objects"), AnyCodingKey(UInt64(0)), AnyCodingKey("text")]
        var serial = 0
        var undos: [Duration] = []
        for _ in 0..<5 {
            serial += 1
            try scoped.update(\.slides[90].objects[0].text, at: path) { $0 = "Edit \(serial)" }
            let began = ContinuousClock.now
            try scoped.undo(scoped: true)
            undos.append(began.duration(to: .now))
        }
        let scopedUndo = undos.sorted()[2]
        var wholeUndos: [Duration] = []
        for _ in 0..<3 {
            serial += 1
            try whole.update(\.slides[90].objects[0].text, at: path) { $0 = "Edit \(serial)" }
            let began = ContinuousClock.now
            try whole.undo()
            wholeUndos.append(began.duration(to: .now))
        }
        let wholeUndo = wholeUndos.sorted()[1]
        let fresh = Slide(id: "timed", name: "", objects: [])
        let scopedInsert = try median(5) {
            try scoped.updateDeck { $0.slides.insert(fresh, at: 40) }
            try scoped.updateDeck { $0.slides.remove(at: 40) }
        }
        let wholeInsert = try median(3) {
            try whole.update { $0.slides.insert(fresh, at: 40) }
            try whole.update { $0.slides.remove(at: 40) }
        }
        print("P4-D big deck: load \(load); undo of a one-slide edit scoped \(scopedUndo) whole \(wholeUndo); insert and delete a slide scoped \(scopedInsert) whole \(wholeInsert)")
        #expect(scopedUndo * 4 < load, "scoped undo \(scopedUndo) vs load \(load)")
        #expect(scopedInsert * 4 < load, "scoped insert and delete \(scopedInsert) vs load \(load)")
    }

    @LibraryActor @Test func aRestoredHistoryUndoesScopedToTheWholePathsValue() throws {
        let canonical = try TypedDocument(richDeck("h", slides: 8))
        let first = replica(of: canonical)
        let base = canonical.heads()
        try first.updateDeck { $0.slides.remove(at: 2) }
        try first.updateDeck { $0.sections?.append(PresentationSection(id: "late", name: "Late")) }
        try first.updateDeck { deck in
            let slide = deck.slides.remove(at: 0)
            deck.slides.append(slide)
        }
        try canonical.applyEncodedChanges(first.document.encodeChangesSince(heads: base))
        let parked = first.history

        let scoped = replica(of: canonical)
        let whole = replica(of: canonical)
        #expect(scoped.restore(parked) && whole.restore(parked))
        for _ in 0..<3 {
            try scoped.undo(scoped: true)
            try whole.undo()
            #expect(scoped.value == whole.value)
        }
        try scoped.redo(scoped: true)
        try whole.redo()
        #expect(scoped.value == whole.value && scoped.value.slides.count == 7)
        #expect(try decoded(scoped) == scoped.value)
    }

    @LibraryActor @Test func otherHostsUndoScopedToTheWholePathsValue() throws {
        let theme = try TypedDocument(Theme(
            id: "t", name: "Theme", fontFamily: "Helvetica", fontSize: 72, textColorHex: "#FFFFFF",
            backgroundColorHex: "#000000", slides: [Slide(id: "t-s0", name: "", objects: []), Slide(id: "t-s1", name: "", objects: [])]))
        let scopedTheme = ReplicaCore(document: theme.document.fork(), value: theme.value)
        let wholeTheme = ReplicaCore(document: theme.document.fork(), value: theme.value)
        let overlay = try TypedDocument(Overlay(id: "o", name: "Overlay", objects: []))
        let scopedOverlay = ReplicaCore(document: overlay.document.fork(), value: overlay.value)
        let wholeOverlay = ReplicaCore(document: overlay.document.fork(), value: overlay.value)
        let box = SlideObject(id: "box", objectKind: .shape, name: "Box", text: "", x: 1, y: 1, width: 2, height: 2)
        for replica in [scopedTheme, wholeTheme] {
            try replica.update { $0.slides?.insert(Slide(id: "t-new", name: "New", objects: [box]), at: 1) }
            try replica.update { $0.fontSize = 60 }
            try replica.update { $0.slides?.remove(at: 0) }
        }
        for replica in [scopedOverlay, wholeOverlay] {
            try replica.update { $0.objects.append(box) }
            try replica.update { $0.objects[0].x = 40 }
        }
        for _ in 0..<3 {
            try scopedTheme.undo(scoped: true)
            try wholeTheme.undo()
            #expect(scopedTheme.value == wholeTheme.value)
        }
        try scopedTheme.redo(scoped: true)
        try wholeTheme.redo()
        #expect(scopedTheme.value == wholeTheme.value)
        for _ in 0..<2 {
            try scopedOverlay.undo(scoped: true)
            try wholeOverlay.undo()
            #expect(scopedOverlay.value == wholeOverlay.value)
        }
        #expect(scopedOverlay.value.objects.isEmpty)
        #if DEBUG
        #expect(scopedTheme.wholeWrites == 0 && scopedTheme.wholeWrite == nil, "a small document's whole decode is expected, not a fallback")
        #endif
    }

    @LibraryActor @Test func anUnscopableEditTakesTheCountedWholeWrite() throws {
        let origin = try TypedDocument(editorDeck("f", slides: 3))
        let editor = EditorReplica<Presentation>(parts: ReplicaParts(document: origin.document.fork(), value: origin.value, persisted: nil))
        let twin = editor.value.slides[0]
        try editor.updateDeck { $0.slides.append(twin) }
        #expect(editor.value.slides.map(\.id) == ["f-s0", "f-s1", "f-s2", "f-s0"])
        #expect(editor.wholeWrite == "updateDeck: duplicate slide ids")
        #if DEBUG
        #expect(editor.core.wholeWrites == 1)
        #endif
        try editor.undo()
        #expect(editor.value.slides.map(\.id) == ["f-s0", "f-s1", "f-s2"] && editor.wholeWrite == nil, "its undo is scoped")
        try editor.updateDeck { $0.name = "Scoped again" }
        #expect(editor.wholeWrite == nil, "each edit says for itself")
    }
}

@Suite struct DeckEditTests {

    @Test func deckFieldsNameEveryFieldButSlides() throws {
        let deck = Presentation(id: "i", name: "n", presentationKind: .song, themeId: "t", folder: "f", folderId: "fi", slides: [],
                                canvasWidth: 1, canvasHeight: 2, background: nil, backgroundFill: ObjectFill(fillKind: .solid, colorHex: "#000000"),
                                sections: [], arrangements: [], defaultArrangementId: "a", reflowSource: "r", ccli: nil,
                                chordProSource: "c", musicKey: "G", autoAdvance: nil, displayKey: "A")
        let labels = Set(Mirror(reflecting: deck).children.compactMap(\.label)).subtracting(["slides"])
        #expect(Set(DeckField.all.map(\.key)) == labels)
        #expect(DeckField.all.count == labels.count)
        let json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(deck)) as? [String: Any])
        #expect(Set(json.keys).subtracting(["slides"]).isSubset(of: labels), "the coding keys are the property names")
    }

    @Test func slideWritesMoveTheFewestSlides() {
        let slides = (0..<6).map { Slide(id: "s\($0)", name: "", objects: []) }
        var dragged = slides
        dragged.insert(dragged.remove(at: 0), at: 5)
        #expect(DeckEdit.slideWrites(from: slides, to: dragged) == [.move(from: 0, before: 6)])
        var back = slides
        back.insert(back.remove(at: 5), at: 0)
        #expect(DeckEdit.slideWrites(from: slides, to: back) == [.move(from: 5, before: 0)])
        let swapped = [slides[1], slides[0]] + slides[2...]
        #expect(DeckEdit.slideWrites(from: slides, to: Array(swapped))?.count == 1)
        #expect(DeckEdit.slideWrites(from: slides, to: slides + [slides[0]]) == nil, "a repeated id has no plan")
        #expect(DeckEdit.longestIncreasing([3, 1, 2, 5, 4]).map { [3, 1, 2, 5, 4][$0] } == [1, 2, 4])
    }
}
