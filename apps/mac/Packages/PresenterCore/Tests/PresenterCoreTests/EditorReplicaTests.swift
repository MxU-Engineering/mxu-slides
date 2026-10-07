import Automerge
import Foundation
import Testing

@testable import PresenterCore

func editorDeck(_ id: String, slides count: Int) -> Presentation {
    Presentation(
        id: id, name: "Deck \(id)", presentationKind: .deck, themeId: "",
        slides: (0..<count).map { n in
            Slide(
                id: "\(id)-s\(n)", name: "Slide \(n)",
                objects: [
                    SlideObject(
                        id: "\(id)-s\(n)-text", objectKind: .text, name: "Lyrics",
                        text: "Line \(n) of the song, sung once and then again\nA second line for slide \(n)",
                        x: 120, y: 80, width: 1680, height: 900),
                    SlideObject(
                        id: "\(id)-s\(n)-bg", objectKind: .shape, name: "Background", text: "",
                        x: 0, y: 0, width: 1920, height: 1080, fill: ObjectFill(fillKind: .solid, colorHex: "#102030")),
                ])
        })
}

@LibraryActor private func fork<E: DocumentEntity>(_ canonical: TypedDocument<E>) -> EditorReplica<E> {
    EditorReplica(parts: ReplicaParts(document: canonical.document.fork(), value: canonical.value, persisted: nil))
}

@LibraryActor private func bundle<E: DocumentEntity>(
    _ canonical: TypedDocument<E>, since base: Set<ChangeHash>, slideScoped: Bool, replaced: Bool = false
) throws -> EditorBundle {
    EditorBundle(base: base, changes: try canonical.encodeChangesSince(heads: base), slideScoped: slideScoped, replaced: replaced)
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

@Suite struct EditorReplicaTests {

    @LibraryActor @Test func aForkIsTheCanonicalValueAndSharesNoState() throws {
        let canonical = try TypedDocument(editorDeck("d", slides: 4))
        let replica = fork(canonical)
        #expect(replica.value == canonical.value)
        #expect(replica.heads() == canonical.heads())
        #if DEBUG
        #expect(replica.core.decodes == .init(), "a fork decodes nothing")
        #endif

        try replica.update(\.slides[1].objects[0].text, at: [.init("slides"), .init(UInt64(1)), .init("objects"), .init(UInt64(0)), .init("text")]) {
            $0 = "Edited in the editor"
        }
        #expect(canonical.value.slides[1].objects[0].text.hasPrefix("Line 1"), "the canonical replica never saw the editor's edit")
        try canonical.update { $0.name = "Renamed on the actor" }
        #expect(replica.value.name == "Deck d", "the editor's replica never saw the actor's edit")
        #expect(!replica.contains(heads: canonical.heads()) && !canonical.contains(heads: replica.heads()))
    }

    @LibraryActor @Test func aSlideScopedLandingRedecodesTheTouchedSlidesOnly() throws {
        let canonical = try TypedDocument(editorDeck("d", slides: 12))
        let replica = fork(canonical)
        let base = canonical.heads()
        try canonical.updateSlides {
            $0.slides[3].objects[0].text = "Edited on the grid"
            $0.slides[7].name = "Renamed on the grid"
        }

        #expect(replica.applyLanded(try bundle(canonical, since: base, slideScoped: true)) == .applied(moved: true))
        #expect(replica.value == canonical.value)
        #expect(replica.heads() == canonical.heads())
        #if DEBUG
        #expect(replica.core.decodes == .init(whole: 0, slides: 2), "the two touched slides, never the deck")
        #endif
        #expect(replica.applyLanded(try bundle(canonical, since: canonical.heads(), slideScoped: true)) == .applied(moved: false), "nothing new moves nothing")
    }

    @LibraryActor @Test func anythingButASlideScopedDeckLandingIsRefusedWithoutADecode() throws {
        let canonical = try TypedDocument(editorDeck("d", slides: 5))
        let replica = fork(canonical)
        let base = canonical.heads()
        try canonical.updateSlideList { $0.insert(Slide(id: "new", name: "", objects: []), at: 2) }
        let structural = try bundle(canonical, since: base, slideScoped: false)
        #expect(replica.applyLanded(structural) == .refused)
        #expect(replica.applyLanded(try bundle(canonical, since: base, slideScoped: true, replaced: true)) == .refused)
        #expect(replica.heads() == base && replica.value.slides.count == 5, "the replica is untouched")

        try replica.update { $0.name = "A commit of its own in flight" }
        let scoped = try bundle(canonical, since: base, slideScoped: true)
        #expect(replica.applyLanded(scoped) == .refused, "heads away from the base")

        let theme = try TypedDocument(Theme(
            id: "t", name: "Theme", fontFamily: "Helvetica", fontSize: 72, textColorHex: "#FFFFFF",
            backgroundColorHex: "#000000", slides: [Slide(id: "t-s0", name: "", objects: [])]))
        let themeReplica = fork(theme)
        let themeBase = theme.heads()
        try theme.update { $0.slides?[0].name = "Edited inside a slide" }
        #expect(themeReplica.applyLanded(try bundle(theme, since: themeBase, slideScoped: true)) == .refused, "a theme always checks out again")
        #if DEBUG
        #expect(replica.core.decodes == .init() && themeReplica.core.decodes == .init(), "no decode on any refused path")
        #endif
    }

    @LibraryActor @Test func aLandingThatMovesTheReplicaClearsUndoAndRedo() throws {
        let canonical = try TypedDocument(editorDeck("d", slides: 3))
        let replica = fork(canonical)
        try replica.update { $0.slides[0].name = "First" }
        try replica.update { $0.slides[0].name = "Second" }
        try replica.undo()
        #expect(replica.canUndo && replica.canRedo)

        try canonical.applyEncodedChanges(replica.encodeChangesSince(heads: canonical.heads()))
        let base = canonical.heads()
        try canonical.updateSlide(at: 2) { $0.name = "From the grid" }

        #expect(replica.applyLanded(try bundle(canonical, since: base, slideScoped: true)) == .applied(moved: true))
        #expect(!replica.canUndo && !replica.canRedo)
        #expect(replica.value.slides.map(\.name) == ["First", "Slide 1", "From the grid"])
    }

    @LibraryActor @Test func aSwapAbsorbsTheEditsTheForkLacks() throws {
        let canonical = try TypedDocument(editorDeck("d", slides: 6))
        let old = fork(canonical)
        try old.update { $0.slides[0].name = "Committed before the request" }
        try canonical.applyEncodedChanges(old.encodeChangesSince(heads: canonical.heads()))
        let requested = old.heads()
        let fresh = fork(canonical)
        let path: [AnyCodingKey] = [.init("slides"), .init(UInt64(2)), .init("objects"), .init(UInt64(0)), .init("text")]
        try old.update(\.slides[2].objects[0].text, at: path) { $0 = "Typed while the fork was on its way" }
        #expect(!fresh.contains(heads: old.heads()), "the fork lacks the edit")

        #expect(try fresh.absorb(old.encodeChangesSince(heads: requested)))
        #expect(fresh.value == old.value, "the value adopted at the swap holds the edit")
        #expect(fresh.value.slides[2].objects[0].text == "Typed while the fork was on its way")
        #expect(fresh.heads() == old.heads())
        #if DEBUG
        #expect(fresh.core.decodes == .init(whole: 0, slides: 1), "the touched slide, never the deck")
        #endif

        let structural = fork(canonical)
        let before = old.heads()
        try old.update { $0.slides.insert(Slide(id: "added", name: "", objects: []), at: 1) }
        #expect(try structural.absorb(old.encodeChangesSince(heads: requested)))
        #expect(structural.value == old.value && structural.heads() == old.heads())
        #expect(!structural.canUndo && !structural.canRedo)
        #if DEBUG
        #expect(structural.core.decodes == .init(whole: 1, slides: 0), "a slide added re-decodes the whole deck")
        #endif
        #expect(try old.absorb(old.encodeChangesSince(heads: before)) == false)
    }

    @LibraryActor @Test func absorbingChangesTheForkHoldsIsANoOp() throws {
        let canonical = try TypedDocument(editorDeck("d", slides: 4))
        let old = fork(canonical)
        let requested = old.heads()
        try old.update { $0.slides[1].name = "Typed" }
        try canonical.applyEncodedChanges(old.encodeChangesSince(heads: requested))
        let fresh = fork(canonical)
        let heads = fresh.heads()

        #expect(try fresh.absorb(old.encodeChangesSince(heads: requested)) == false)
        #expect(fresh.heads() == heads && fresh.value == old.value)
        #if DEBUG
        #expect(fresh.core.decodes == .init(), "nothing new decodes nothing")
        #endif
    }

    @LibraryActor @Test func historyRestoresOnlyAtItsHeads() throws {
        let canonical = try TypedDocument(editorDeck("d", slides: 2))
        let first = fork(canonical)
        try first.update { $0.name = "Edited" }
        let history = first.history
        #expect(history.undo.count == 1 && history.redo.isEmpty && history.heads == first.heads())

        try canonical.applyEncodedChanges(first.encodeChangesSince(heads: canonical.heads()))
        let second = fork(canonical)
        #expect(second.restore(history: history))
        #expect(second.canUndo)
        #expect(try second.undo().name == "Deck d")

        try canonical.update { $0.name = "Written since" }
        let third = fork(canonical)
        #expect(!third.restore(history: history), "the heads moved: nothing restored")
        #expect(!third.canUndo)
    }

    @LibraryActor @Test func forkingTheBigDeckCostsUnderAQuarterOfItsLoad() throws {
        let bytes = try TypedDocument(editorDeck("big", slides: 183)).save()
        let canonical = try TypedDocument<Presentation>(data: bytes)
        let load = try median(5) { _ = try TypedDocument<Presentation>(data: bytes) }
        let forked = median(5) { _ = fork(canonical) }
        #expect(forked * 4 < load, "fork \(forked) vs load \(load) of \(bytes.count) bytes")
    }
}
