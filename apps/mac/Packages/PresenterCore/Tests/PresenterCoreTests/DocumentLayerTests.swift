import Foundation
import Testing
@testable import PresenterCore

private func sampleSong(id: String = "song-1", name: String = "Amazing Grace") -> Presentation {
    Presentation(
        id: id,
        name: name,
        presentationKind: .song,
        themeId: "theme-1",
        slides: (1...3).map { n in
            Slide(
                id: "\(id)-slide-\(n)",
                name: "Verse \(n)",
                objects: [
                    SlideObject(id: "\(id)-s\(n)-text", objectKind: .text, name: "Lyrics", text: "Line \(n)"),
                    SlideObject(id: "\(id)-s\(n)-bg", objectKind: .media, name: "Background", text: ""),
                ]
            )
        }
    )
}

@LibraryActor @Test func presentationRoundTripsThroughAutomerge() throws {
    let song = sampleSong()
    let document = try TypedDocument(song)
    #expect(document.value == song)

    let reloaded = try TypedDocument<Presentation>(data: document.save())
    #expect(reloaded.value == song)
}

@LibraryActor @Test func updateAppliesAndPersists() throws {
    let document = try TypedDocument(sampleSong())
    try document.update { $0.slides[1].objects[0].text = "How sweet the sound" }
    #expect(document.value.slides[1].objects[0].text == "How sweet the sound")

    let reloaded = try TypedDocument<Presentation>(data: document.save())
    #expect(reloaded.value == document.value)
}

@LibraryActor @Test func noOpUpdateProducesNoChange() throws {
    let document = try TypedDocument(sampleSong())
    let heads = document.document.heads()
    try document.update { _ in }
    #expect(document.document.heads() == heads)
    #expect(!document.canUndo)
}

@LibraryActor @Test func scopedUpdateEditsOneSubtreeAndStaysConsistent() throws {
    let document = try TypedDocument(sampleSong())
    let path = [
        AnyCodingKey("slides"), AnyCodingKey(UInt64(1)),
        AnyCodingKey("objects"), AnyCodingKey(UInt64(0)),
    ]
    let before = document.value
    try document.update(\.slides[1].objects[0], at: path) { $0.text = "How sweet the sound" }

    #expect(document.value.slides[1].objects[0].text == "How sweet the sound")
    let reloaded = try TypedDocument<Presentation>(data: document.save())
    #expect(reloaded.value == document.value)

    #expect(document.canUndo)
    #expect(try document.undo() == before)

    try document.update(\.slides[0].objects[0], at: [
        AnyCodingKey("slides"), AnyCodingKey(UInt64(0)),
        AnyCodingKey("objects"), AnyCodingKey(UInt64(0)),
    ]) { _ in }
    #expect(!document.canUndo)
}

private func fullyStyledObject(id: String = "obj-full") -> SlideObject {
    SlideObject(
        id: id, objectKind: .text, name: "Lyrics", text: "Amazing grace\nHow sweet the sound",
        x: 160, y: 640, width: 1600, height: 360, rotationDegrees: -2.5,
        opacity: 0.9, blendMode: .screen, groupId: "group-1",
        textStyle: TextStyle(
            fontName: "HelveticaNeue-Bold", fontSize: 96, colorHex: "#FFFFFFFF",
            tracking: 1.5, lineHeightMultiple: 1.1,
            horizontalAlignment: .center, verticalAlignment: .bottom,
            textTransform: .uppercase, tabularFigures: false,
            autoShrink: true, minFontSize: 40,
            outline: ObjectStroke(colorHex: "#000000FF", width: 2),
            shadow: ObjectShadow(colorHex: "#00000080", blurRadius: 12, offsetX: 0, offsetY: 4),
            lineStyles: [
                LineStyleOverride(
                    lineIndex: 1, fontSize: 64, colorHex: "#FFD24DFF",
                    firstLineIndent: -60, leftIndent: 60, rightIndent: 30
                ),
            ],
            insetTop: 12, insetLeft: 16, insetBottom: 8, insetRight: 20,
            firstLineIndent: -30, leftIndent: 60, rightIndent: 40, paragraphSpacing: 24
        ),
        shapeKind: .roundedRectangle, cornerRadius: 24,
        fill: ObjectFill(
            fillKind: .linearGradient, gradientAngleDegrees: 90,
            gradientStops: [
                GradientStop(colorHex: "#101828FF", position: 0),
                GradientStop(colorHex: "#1D2939FF", position: 1),
            ]
        ),
        stroke: ObjectStroke(colorHex: "#FFFFFF33", width: 1),
        shadow: ObjectShadow(colorHex: "#000000AA", blurRadius: 30, offsetX: 0, offsetY: 10),
        mediaId: "media-1", mediaScaleMode: .fit
    )
}

@LibraryActor @Test func fullyStyledObjectRoundTripsThroughAutomerge() throws {
    var song = sampleSong()
    song.slides[0].objects.append(fullyStyledObject())
    let document = try TypedDocument(song)
    let reloaded = try TypedDocument<Presentation>(data: document.save())
    #expect(reloaded.value == song)
}

@LibraryActor @Test func v3EraDocumentDecodesWithStyleFieldsAbsent() throws {

    let document = try TypedDocument(sampleSong())
    let reloaded = try TypedDocument<Presentation>(data: document.save())
    let object = reloaded.value.slides[0].objects[0]
    #expect(object.textStyle == nil)
    #expect(object.x == nil && object.opacity == nil && object.blendMode == nil)
}

@LibraryActor @Test func scopedUpdateReachesNestedTextStyle() throws {
    var song = sampleSong()
    song.slides[0].objects[0] = fullyStyledObject(id: "song-1-s1-text")
    let document = try TypedDocument(song)
    let path = [
        AnyCodingKey("slides"), AnyCodingKey(UInt64(0)),
        AnyCodingKey("objects"), AnyCodingKey(UInt64(0)),
    ]
    try document.update(\.slides[0].objects[0], at: path) {
        $0.text = "Amazing grace\nThat saved a wretch like me"
        $0.textStyle?.fontSize = 88
        $0.textStyle?.lineStyles?[0].colorHex = "#FF0000FF"
    }
    let reloaded = try TypedDocument<Presentation>(data: document.save())
    #expect(reloaded.value == document.value)
    #expect(reloaded.value.slides[0].objects[0].textStyle?.fontSize == 88)
    #expect(reloaded.value.slides[0].objects[0].textStyle?.lineStyles?[0].colorHex == "#FF0000FF")
}

@LibraryActor @Test func undoRedoWalkEditHistory() throws {
    let document = try TypedDocument(sampleSong())
    let v0 = document.value
    try document.update { $0.name = "Amazing Grace (My Chains Are Gone)" }
    let v1 = document.value
    try document.update { $0.slides.remove(at: 2) }
    let v2 = document.value

    #expect(try document.undo() == v1)
    #expect(try document.undo() == v0)
    #expect(!document.canUndo)
    #expect(try document.redo() == v1)
    #expect(try document.redo() == v2)
    #expect(!document.canRedo)
}

@LibraryActor @Test func undoIsANewChangeNotHistoryRewrite() throws {
    let document = try TypedDocument(sampleSong())
    try document.update { $0.name = "Renamed" }
    let historyBefore = document.document.getHistory().count
    try document.undo()

    #expect(document.document.getHistory().count > historyBefore)
}

@LibraryActor @Test func newEditClearsRedo() throws {
    let document = try TypedDocument(sampleSong())
    try document.update { $0.name = "A" }
    try document.undo()
    #expect(document.canRedo)
    try document.update { $0.name = "B" }
    #expect(!document.canRedo)
}

@LibraryActor @Test func divergentReplicasConverge() throws {
    let ours = try TypedDocument(sampleSong())
    let theirs = try ours.fork()

    try ours.update { $0.slides[0].objects[0].text = "Edited on machine A" }
    try theirs.update {
        $0.slides.append(Slide(id: "new-slide", name: "Bridge", objects: []))
    }

    try ours.merge(theirs)
    try theirs.merge(ours)

    #expect(ours.value == theirs.value)
    #expect(ours.value.slides[0].objects[0].text == "Edited on machine A")
    #expect(ours.value.slides.contains { $0.id == "new-slide" })
}

@LibraryActor @Test func alternatingSavesFromTwoLiveDocumentsStillConverge() throws {

    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try DocumentStore(rootURL: root)

    let editor = try TypedDocument(sampleSong(id: "shared"))
    try store.save(editor)
    let present = try store.load(Presentation.self, id: "shared")

    try editor.update { $0.slides[0].objects[0].text = "Editor edit" }
    try store.save(editor) 
    try present.update { $0.name = "Present rename" }
    try store.save(present) 
    try editor.update { $0.slides[0].name = "Verse 1" }
    try store.save(editor) 

    let converged = try store.load(Presentation.self, id: "shared").value
    #expect(converged.slides[0].objects[0].text == "Editor edit")
    #expect(converged.name == "Present rename")
    #expect(converged.slides[0].name == "Verse 1")
    #expect(editor.value == converged)
}

@LibraryActor @Test func documentStoreRoundTripsAndLists() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try DocumentStore(rootURL: root)

    let song = sampleSong(id: "abc", name: "Cornerstone")
    try store.save(TypedDocument(song))
    let theme = Theme(
        id: "theme-1", name: "Default", fontFamily: "Helvetica Neue",
        fontSize: 96, textColorHex: "#FFFFFF", backgroundColorHex: "#000000"
    )
    try store.save(TypedDocument(theme))

    #expect(try store.load(Presentation.self, id: "abc").value == song)
    #expect(try store.ids(of: .presentation) == ["abc"])
    #expect(try store.ids(of: .theme) == ["theme-1"])
    #expect(try store.ids(of: .service).isEmpty)

    try store.delete(kind: .presentation, id: "abc")
    #expect(try store.ids(of: .presentation).isEmpty)
    #expect(throws: DocumentStore.StoreError.documentNotFound(kind: .presentation, id: "abc")) {
        try store.load(Presentation.self, id: "abc")
    }
}

@LibraryActor @Test func themeSlidesRideTheSameScopedUpdatePaths() throws {

    let theme = Theme(
        id: "theme-1", name: "Modern", fontFamily: "Helvetica Neue",
        fontSize: 96, textColorHex: "#FFFFFF", backgroundColorHex: "#000000",
        slides: Theme.defaultSlides()
    )
    let document = try TypedDocument(theme)

    let path = [
        AnyCodingKey("slides"), AnyCodingKey(UInt64(0)),
        AnyCodingKey("objects"), AnyCodingKey(UInt64(0)),
    ]
    let updated = try document.update(\.slides![0].objects[0], at: path) {
        $0.textStyle = TextStyle(fontName: "Georgia-Bold", fontSize: 120)
        $0.x = 200
    }
    #expect(updated.slides?[0].objects[0].textStyle?.fontName == "Georgia-Bold")

    let reloaded = try TypedDocument<Theme>(data: document.save())
    #expect(reloaded.value == updated)

    let reverted = try document.undo()
    #expect(reverted.slides?[0].objects[0].textStyle == nil)
}

private func movedSong(
    _ song: Presentation, from: Int, before: Int?, sectionId: String? = nil
) -> Presentation {
    var next = song
    var slide = next.slides.remove(at: from)
    let target = before.map { $0 > from ? $0 - 1 : $0 } ?? next.slides.count
    if let sectionId { slide.sectionId = sectionId }
    next.slides.insert(slide, at: min(target, next.slides.count))
    return next
}

@LibraryActor @Test func moveListElementReordersForwardBackwardAndToEnd() throws {

    var document = try TypedDocument(sampleSong())
    var expected = movedSong(document.value, from: 0, before: 2)
    try document.moveListElement(
        listAt: [AnyCodingKey("slides")], from: 0, before: 2, next: expected)
    #expect(document.value == expected)
    #expect(try TypedDocument<Presentation>(data: document.save()).value == expected)

    document = try TypedDocument(sampleSong())
    expected = movedSong(document.value, from: 2, before: 0)
    try document.moveListElement(
        listAt: [AnyCodingKey("slides")], from: 2, before: 0, next: expected)
    #expect(document.value == expected)
    #expect(try TypedDocument<Presentation>(data: document.save()).value == expected)

    document = try TypedDocument(sampleSong())
    expected = movedSong(document.value, from: 0, before: nil)
    try document.moveListElement(
        listAt: [AnyCodingKey("slides")], from: 0, before: nil, next: expected)
    #expect(document.value == expected)
    #expect(try TypedDocument<Presentation>(data: document.save()).value == expected)
}

@LibraryActor @Test func insertListElementsLandsDeepSubtreesAtTheIndexAndUndoes() throws {
    let document = try TypedDocument(sampleSong())
    let original = document.value
    var arriving = sampleSong(id: "song-2").slides[0]
    arriving.sectionId = "section-A"
    arriving.objects[0].styleRuns = [
        TextStyleRun(line: 0, column: 0, length: 4, fontName: "Georgia", fontSize: 44)
    ]
    arriving.transition = Transition(transitionKind: .dissolve, durationSeconds: 0.4)
    var second = sampleSong(id: "song-3").slides[1]
    second.sectionId = "section-A"
    var expected = original
    expected.slides.insert(contentsOf: [arriving, second], at: 1)

    try document.insertListElements(
        listAt: [AnyCodingKey("slides")], at: 1, values: [arriving, second], next: expected)
    #expect(document.value == expected)

    let reloaded = try TypedDocument<Presentation>(data: document.save())
    #expect(reloaded.value == expected)
    #expect(reloaded.value.slides[1].objects[0].styleRuns?.first?.fontName == "Georgia")
    #expect(reloaded.value.slides.map(\.id) == ["song-1-slide-1", "song-2-slide-1", "song-3-slide-2", "song-1-slide-2", "song-1-slide-3"])

    #expect(try document.undo() == original)
    #expect(try TypedDocument<Presentation>(data: document.save()).value == original)
}

@LibraryActor @Test func insertListElementsClampsPastTheEnd() throws {
    let document = try TypedDocument(sampleSong())
    let arriving = sampleSong(id: "song-2").slides[2]
    var expected = document.value
    expected.slides.append(arriving)
    try document.insertListElements(
        listAt: [AnyCodingKey("slides")], at: 99, values: [arriving], next: expected)
    #expect(try TypedDocument<Presentation>(data: document.save()).value == expected)
}

@LibraryActor @Test func moveListElementCopiesDeepSubtrees() throws {

    var song = sampleSong()
    song.slides[0].objects[0].styleRuns = [
        TextStyleRun(line: 0, column: 0, length: 4, fontName: "Georgia", fontSize: 44)
    ]
    song.slides[0].objects[0].textStyle = TextStyle(fontName: "Helvetica", fontSize: 96)
    song.slides[0].transition = Transition(transitionKind: .dissolve, durationSeconds: 0.4)
    let document = try TypedDocument(song)

    let expected = movedSong(document.value, from: 0, before: nil)
    try document.moveListElement(
        listAt: [AnyCodingKey("slides")], from: 0, before: nil, next: expected)
    #expect(document.value == expected)

    let reloaded = try TypedDocument<Presentation>(data: document.save())
    #expect(reloaded.value.slides.last?.objects[0].styleRuns?.first?.fontName == "Georgia")
    #expect(reloaded.value == expected)
}

@LibraryActor @Test func moveListElementAppliesMovedFieldsAndUndoes() throws {
    let document = try TypedDocument(sampleSong())
    let original = document.value
    let expected = movedSong(original, from: 2, before: 0, sectionId: "section-A")
    try document.moveListElement(
        listAt: [AnyCodingKey("slides")], from: 2, before: 0,
        settingOnMoved: ["sectionId": .String("section-A")], next: expected)
    #expect(document.value == expected)
    let reloaded = try TypedDocument<Presentation>(data: document.save())
    #expect(reloaded.value.slides[0].sectionId == "section-A")

    let reverted = try document.undo()
    #expect(reverted == original)
    let redone = try document.redo()
    #expect(redone == expected)
}

@LibraryActor @Test func moveListElementNoOpMovesLeaveHistoryUntouched() throws {
    let document = try TypedDocument(sampleSong())
    let heads = document.document.heads()

    try document.moveListElement(
        listAt: [AnyCodingKey("slides")], from: 1, before: 1, next: document.value)
    try document.moveListElement(
        listAt: [AnyCodingKey("slides")], from: 1, before: 2, next: document.value)
    #expect(document.document.heads() == heads)
    #expect(!document.canUndo)
}

@LibraryActor @Test func anEditInsideOneSlideRedecodesOnlyThatSlide() throws {
    let open = try TypedDocument(sampleSong())
    let other = try open.fork()
    _ = try other.update(\.slides[1], at: [AnyCodingKey("slides"), AnyCodingKey(UInt64(1))]) { $0.notes = "Watch the key change" }
    let before = open.heads()
    try open.merge(other)
    #expect(TypedDocument<Presentation>.touchedSlides(open.patches(since: before)) == [1])
    #expect(open.value == other.value, "the spliced value is what a full decode reads")

    let structural = try open.fork()
    _ = try structural.update { $0.slides.remove(at: 0); $0.name = "Renamed" }
    let beforeStructural = open.heads()
    try open.merge(structural)
    #expect(TypedDocument<Presentation>.touchedSlides(open.patches(since: beforeStructural)) == nil, "a removed slide or a deck field decodes the whole deck")
    #expect(open.value == structural.value)
}
