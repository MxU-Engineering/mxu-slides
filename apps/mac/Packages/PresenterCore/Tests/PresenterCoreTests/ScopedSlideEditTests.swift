import Foundation
import Testing
@testable import PresenterCore

private func deck(slides count: Int = 4) -> Presentation {
    Presentation(
        id: "deck", name: "Deck", presentationKind: .song, themeId: "theme-1",
        slides: (0..<count).map { n in
            Slide(
                id: "slide-\(n)", name: "Verse \(n)",
                objects: [SlideObject(id: "text-\(n)", objectKind: .text, name: "Lyrics", text: "Line \(n)")],
                sectionId: n < 2 ? "section-A" : "section-B",
                actions: [
                    SlideAction(id: "clear-\(n)", kind: .clearAll),
                    SlideAction(id: "media-\(n)", kind: .fireMedia, mediaId: "media-\(n)"),
                ]
            )
        }
    )
}

@LibraryActor private func decoded(_ document: TypedDocument<Presentation>) throws -> Presentation {
    try TypedDocument<Presentation>(data: document.save()).value
}

@LibraryActor private func plantName(_ name: String, onSlide index: Int, in document: TypedDocument<Presentation>) throws {
    let doc = document.document
    if case let .Object(slides, _)? = try doc.get(obj: .ROOT, key: "slides"),
       case let .Object(slide, _)? = try doc.get(obj: slides, index: UInt64(index)) {
        try doc.put(obj: slide, key: "name", value: .String(name))
    } else {
        Issue.record("slide \(index) not found")
    }
}

@LibraryActor @Test func updateSlideMatchesTheWholeValueEditInOneUndoStep() throws {
    let original = deck()
    let whole = try TypedDocument(original)
    try whole.update { $0.slides[2].actions = nil; $0.slides[2].notes = "Watch the key change" }

    let byIndex = try TypedDocument(original)
    try byIndex.updateSlide(at: 2) { $0.actions = nil; $0.notes = "Watch the key change" }
    let byID = try TypedDocument(original)
    try byID.updateSlide(id: "slide-2") { $0.actions = nil; $0.notes = "Watch the key change" }

    for scoped in [byIndex, byID] {
        #expect(scoped.value == whole.value)
        #expect(try decoded(scoped) == whole.value)
        #expect(try scoped.undo() == original, "one edit, one undo step")
        #expect(!scoped.canUndo)
        #expect(try decoded(scoped) == original)
    }
}

@LibraryActor @Test func updateSlideByAMissingIDWritesNothing() throws {
    let document = try TypedDocument(deck())
    let heads = document.heads()
    try document.updateSlide(id: "gone") { $0.name = "Nobody" }
    #expect(document.heads() == heads)
    #expect(!document.canUndo)
}

@LibraryActor @Test func updateSlidesEditsSeveralSlidesAsOneChange() throws {
    let original = deck()

    let removeMedia: (inout Presentation) -> Void = { presentation in
        for index in [0, 3] {
            presentation.slides[index].actions?.removeAll { $0.kind == .fireMedia }
        }
    }
    let whole = try TypedDocument(original)
    try whole.update(removeMedia)
    let scoped = try TypedDocument(original)
    try scoped.updateSlides(removeMedia)

    #expect(scoped.value == whole.value)
    #expect(try decoded(scoped) == whole.value)
    #expect(try scoped.undo() == original, "the whole selection is one undo step")
    #expect(!scoped.canUndo)
    #expect(try scoped.redo() == whole.value)

    let heads = scoped.heads()
    try scoped.updateSlides { _ in }
    #expect(scoped.heads() == heads, "a no-op writes nothing")
}

@LibraryActor @Test func updateSlidesRefusesStructuralEditsAndWritesNothing() throws {
    let document = try TypedDocument(deck())
    let heads = document.heads()
    #expect(throws: TypedDocument<Presentation>.DocumentError.self) {
        try document.updateSlides { $0.slides.remove(at: 1) }
    }
    #expect(throws: TypedDocument<Presentation>.DocumentError.self) {
        try document.updateSlides { $0.slides.swapAt(0, 1) }
    }
    #expect(throws: TypedDocument<Presentation>.DocumentError.self) {
        try document.updateSlides { $0.name = "Renamed"; $0.slides[0].name = "First" }
    }
    #expect(document.heads() == heads)
    #expect(!document.canUndo)
    #expect(document.value == deck())
}

@LibraryActor @Test func updateFieldWritesOneRootKeyAndDeletesOnNil() throws {
    let original = deck()
    let advance = AutoAdvance(delaySeconds: 4, loopToStart: true)

    let whole = try TypedDocument(original)
    try whole.update { $0.autoAdvance = advance; $0.musicKey = "G"; $0.displayKey = "A" }
    let scoped = try TypedDocument(original)
    try scoped.updateField(\.autoAdvance, key: "autoAdvance", to: advance)
    try scoped.updateField(\.musicKey, key: "musicKey", to: "G")
    try scoped.updateField(\.displayKey, key: "displayKey", to: "A")
    #expect(scoped.value == whole.value)
    #expect(try decoded(scoped) == whole.value)

    try scoped.updateField(\.autoAdvance, key: "autoAdvance", to: AutoAdvance(delaySeconds: 8))
    #expect(try decoded(scoped).autoAdvance == AutoAdvance(delaySeconds: 8))
    try scoped.updateField(\.displayKey, key: "displayKey", to: nil)
    #expect(try scoped.document.get(obj: .ROOT, key: "displayKey") == nil)
    #expect(try decoded(scoped).displayKey == nil)

    #expect(try scoped.undo().displayKey == "A")
    #expect(try scoped.undo().autoAdvance == advance)
    let heads = scoped.heads()
    try scoped.updateField(\.musicKey, key: "musicKey", to: "G")
    #expect(scoped.heads() == heads, "an unchanged value writes nothing")
}

@Test(.disabled(
    if: ProcessInfo.processInfo.environment["MXU_VERIFY_SCOPED_WRITES"] != nil,
    "diverges the document from the cache on purpose"))
@LibraryActor func scopedEditsLeaveUntouchedSlidesAlone() throws {

    let whole = try TypedDocument(deck())
    try plantName("Planted", onSlide: 3, in: whole)
    try whole.update { $0.slides[0].actions = nil }
    #expect(try decoded(whole).slides[3].name == "Verse 3", "update(_:) rewrote slide 3")

    let single = try TypedDocument(deck())
    try plantName("Planted", onSlide: 3, in: single)
    try single.updateSlide(id: "slide-0") { $0.actions = nil }
    #expect(try decoded(single).slides[3].name == "Planted")
    #expect(try decoded(single).slides[0].actions == nil)

    let bulk = try TypedDocument(deck())
    try plantName("Planted", onSlide: 3, in: bulk)
    try bulk.updateSlides { $0.slides[0].actions = nil; $0.slides[1].actions = nil }
    #expect(try decoded(bulk).slides[3].name == "Planted")

    let field = try TypedDocument(deck())
    try plantName("Planted", onSlide: 3, in: field)
    try field.updateField(\.musicKey, key: "musicKey", to: "D")
    #expect(try decoded(field).slides[3].name == "Planted")
    #expect(try decoded(field).musicKey == "D")
}

@LibraryActor @Test func scopedListRemovalWritesAFractionOfTheWholeValueChange() throws {

    let original = deck(slides: 40)
    let whole = try TypedDocument(original)
    let wholeHeads = whole.heads()
    try whole.update { $0.slides.remove(at: 1) }
    let scoped = try TypedDocument(original)
    let scopedHeads = scoped.heads()
    try scoped.updateSlideList { $0.remove(at: 1) }

    #expect(scoped.value == whole.value)
    #expect(try decoded(scoped) == whole.value)
    let wholeBytes = try whole.encodeChangesSince(heads: wholeHeads).count
    let scopedBytes = try scoped.encodeChangesSince(heads: scopedHeads).count
    #expect(scopedBytes * 4 < wholeBytes, "scoped \(scopedBytes) B vs whole \(wholeBytes) B")
}

@LibraryActor @Test func updateSlideListLandsRemovalsInsertionsAndMovesScoped() throws {
    let original = deck(slides: 6)
    var expected = original

    let removing = try TypedDocument(original)
    let diff = ListRemoval(
        before: original.slides, after: original.slides.filter { !["slide-1", "slide-4"].contains($0.id) }, id: \.id)
    let removal = try #require(diff)
    try removing.updateSlideList { removal.remove(from: &$0) }
    expected.slides = original.slides.filter { !["slide-1", "slide-4"].contains($0.id) }
    #expect(removing.value == expected)
    #expect(try decoded(removing) == expected)

    try removing.updateSlideList { removal.restore(into: &$0) }
    #expect(removing.value == original)
    #expect(try decoded(removing) == original)
    #expect(try removing.undo() == expected, "each list change is one undo step")

    let moving = try TypedDocument(original)
    var moved = original.slides
    var slide = moved.remove(at: 4)
    slide.sectionId = "section-A"
    moved.insert(slide, at: 1)
    try moving.updateSlideList { $0 = moved }
    expected.slides = moved
    #expect(moving.value == expected)
    #expect(try decoded(moving) == expected)
    #expect(try moving.undo() == original)

    let editing = try TypedDocument(original)
    try editing.updateSlideList { $0[2].name = "Bridge"; $0[5].notes = "Out" }
    expected = original
    expected.slides[2].name = "Bridge"
    expected.slides[5].notes = "Out"
    #expect(try decoded(editing) == expected)
    let reordering = try TypedDocument(original)
    try reordering.updateSlideList { $0.reverse() }
    expected = original
    expected.slides.reverse()
    #expect(try decoded(reordering) == expected)
    #expect(try reordering.undo() == original)
}

@LibraryActor @Test func removeAndPlaceListElementsDirectly() throws {
    let original = deck(slides: 5)
    var expected = original
    expected.slides.remove(at: 3)
    expected.slides.remove(at: 0)
    let document = try TypedDocument(original)
    try document.removeListElements(listAt: [AnyCodingKey("slides")], at: [3, 0, 99], next: expected)
    #expect(try decoded(document) == expected, "out-of-range indexes are nothing to delete")

    try document.insertListElements(
        listAt: [AnyCodingKey("slides")],
        placing: [(index: 3, element: original.slides[3]), (index: 0, element: original.slides[0])],
        next: original)
    #expect(try decoded(document) == original, "placed in ascending order, whatever order given")
    #expect(try document.undo() == expected)
}

@Test func slideMoveNamesOneMoveAndItsSection() throws {
    let slides = deck(slides: 4).slides
    var sameSection = slides
    sameSection.swapAt(0, 1)
    let swap = try #require(TypedDocument<Presentation>.slideMove(from: slides, to: sameSection))
    #expect(swap.fields.isEmpty)

    var adopted = slides
    var last = adopted.removeLast()
    last.sectionId = "section-A"
    adopted.insert(last, at: 0)
    let move = try #require(TypedDocument<Presentation>.slideMove(from: slides, to: adopted))
    #expect(move.from == 3 && move.before == 0)
    #expect(move.fields == ["sectionId": .String("section-A")])

    var renamed = adopted
    renamed[0].name = "Renamed too"
    #expect(TypedDocument<Presentation>.slideMove(from: slides, to: renamed) == nil, "a move plus an edit is not one move")
}

@Test func listMoveFindsTheOneElementThatMoved() {
    let ids = ["a", "b", "c", "d", "e"]
    func move(to after: [String]) -> String? {
        ListMove(before: ids, after: after).map { "\($0.from)→\($0.before.map(String.init) ?? "end")" }
    }
    #expect(move(to: ["b", "c", "d", "a", "e"]) == "0→4")
    #expect(move(to: ["b", "c", "d", "e", "a"]) == "0→end")
    #expect(move(to: ["a", "d", "b", "c", "e"]) == "3→1")
    #expect(move(to: ["b", "a", "c", "d", "e"]) == "0→2", "a swap of neighbours reads as the first moving")
    #expect(move(to: ids) == nil, "nothing moved")
    #expect(move(to: ["b", "a", "c", "e", "d"]) == nil, "two moves")
    #expect(move(to: ["a", "b", "c", "d", "x"]) == nil, "a different element")
    #expect(move(to: ["a", "b", "c", "d"]) == nil, "a removal")
}
