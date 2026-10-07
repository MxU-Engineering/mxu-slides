import Foundation
import Testing
@testable import PresenterCore

private func legacyStep(_ id: String) -> AnimationStep {
    AnimationStep(id: id, kind: .in, animation: .fade, trigger: .onClick, durationSeconds: 0.5)
}

@Test func legacyAnimationKeysLiftOnNormalization() {
    var object = SlideObject(id: "o1", objectKind: .text, name: "Title", text: "Hi")
    object.builds = [legacyStep("s1")]
    object.textLink = TextLink(source: .nextSlide)
    object.textLink?.includeBuilds = true
    let normalized = SlideObjectNormalization.normalized(object)
    #expect(normalized.animationSteps?.map(\.id) == ["s1"])
    #expect(normalized.builds == nil)
    #expect(normalized.textLink?.includeSteps == true)
    #expect(normalized.textLink?.includeBuilds == nil)

    var both = object
    both.animationSteps = [legacyStep("new")]
    let kept = SlideObjectNormalization.normalized(both)
    #expect(kept.animationSteps?.map(\.id) == ["new"])
    #expect(kept.builds == nil)

    #expect(SlideObjectNormalization.normalized(normalized) == normalized)
}

@Test func slideLevelLiftMovesTheOrder() {
    var slide = Slide(id: "sl1", name: "", objects: [])
    slide.buildOrder = ["a", "b"]
    let normalized = SlideObjectNormalization.normalized(slide)
    #expect(normalized.animationOrder == ["a", "b"])
    #expect(normalized.buildOrder == nil)
}

@LibraryActor @Test func libraryMigrationRoundTripsAndRestampsTheLedger() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let library = try Library(rootURL: root)

    var object = SlideObject(id: "o1", objectKind: .text, name: "Title", text: "Hi")
    object.builds = [legacyStep("s1")]
    var slide = Slide(id: "sl1", name: "", objects: [object])
    slide.buildOrder = ["s1"]
    let presentation = Presentation(id: "p1", name: "Legacy", presentationKind: .song, themeId: "", slides: [slide])
    try library.create(presentation)

    var editedObject = SlideObject(id: "o2", objectKind: .text, name: "T", text: "B")
    editedObject.builds = [legacyStep("s2")]
    let edited = Presentation(id: "p2", name: "Edited", presentationKind: .song, themeId: "", slides: [Slide(id: "sl2", name: "", objects: [editedObject])])
    try library.create(edited)

    var ledger = ImportLedger(id: ImportLedger.wellKnownID, entries: [])
    ledger.stamp("p1", ImportFingerprint.hash(try library.open(Presentation.self, id: "p1").value)!)
    ledger.stamp("p2", "stale-hash")
    try library.store.save(TypedDocument(ledger))

    let migrated = try library.normalizeAnimationVocabulary()
    #expect(migrated == 2)

    let reopened = try library.open(Presentation.self, id: "p1")
    #expect(reopened.value.slides[0].animationOrder == ["s1"])
    #expect(reopened.value.slides[0].buildOrder == nil)
    #expect(reopened.value.slides[0].objects[0].animationSteps?.map(\.id) == ["s1"])
    #expect(reopened.value.slides[0].objects[0].builds == nil)
    #expect(try library.normalizeAnimationVocabulary() == 0)

    let stamped = try library.store.load(ImportLedger.self, id: ImportLedger.wellKnownID).value
    #expect(stamped.isUnedited(docId: "p1", currentHash: ImportFingerprint.hash(reopened.value)))
    #expect(!stamped.isUnedited(
        docId: "p2",
        currentHash: ImportFingerprint.hash(try library.open(Presentation.self, id: "p2").value)
    ))
}

@LibraryActor @Test func presetBoardMovesToItsNewIdOnce() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let library = try Library(rootURL: root)

    let legacyDir = root.appendingPathComponent("build-presets", isDirectory: true)
    try FileManager.default.createDirectory(at: legacyDir, withIntermediateDirectories: true)
    let legacyBoard = AnimationPresetBoard(id: "build-preset-board", presets: [
        AnimationPreset(id: "u1", name: "Mine", steps: [legacyStep("x")]),
    ])
    try TypedDocument(legacyBoard).save().write(
        to: legacyDir.appendingPathComponent("build-preset-board.automerge")
    )

    try library.normalizeAnimationVocabulary()

    let board = try library.store.load(
        AnimationPresetBoard.self, id: AnimationPresetBoard.wellKnownID
    ).value
    #expect(board.presets.map(\.name) == ["Mine"])
    #expect(!FileManager.default.fileExists(
        atPath: legacyDir.appendingPathComponent("build-preset-board.automerge").path
    ))

    #expect(try library.normalizeAnimationVocabulary() == 0)
}
