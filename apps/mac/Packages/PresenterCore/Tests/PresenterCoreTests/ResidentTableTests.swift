import Foundation
import Testing

@testable import PresenterCore

@Suite struct ResidentTableTests {
    private func makeStore() throws -> (DocumentStore, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return (try DocumentStore(rootURL: root), root)
    }

    @LibraryActor private func save(_ combo: ActionCombo, in store: DocumentStore) throws {
        try store.save(TypedDocument(combo))
    }

    private func combo(_ id: String, _ name: String) -> ActionCombo {
        ActionCombo(id: id, name: name, actions: [])
    }

    @LibraryActor @Test func aSaveChangesTheStampAndADeleteClearsIt() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        try save(combo("a", "One"), in: store)
        let url = store.url(kind: .actionCombo, id: "a")
        let first = try #require(DocumentFileStamp.of(url))
        #expect(DocumentFileStamp.of(url) == first, "an untouched file keeps its stamp")
        let edited = try store.load(ActionCombo.self, id: "a")
        try edited.update { $0.name = "Two" }
        try store.save(edited)
        #expect(DocumentFileStamp.of(url) != first, "an atomic save is a new file")
        try store.delete(kind: .actionCombo, id: "a")
        #expect(DocumentFileStamp.of(url) == nil)
    }

    @LibraryActor @Test func aFillDecodesOnlyWhatChanged() async throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        try save(combo("a", "One"), in: store)
        try save(combo("b", "Two"), in: store)

        let first = await store.fillResidentTable(ActionCombo.self, epoch: 0, known: [:])
        #expect(Set(first.decoded.keys) == ["a", "b"])
        #expect(first.unchanged.isEmpty)

        let edited = try store.load(ActionCombo.self, id: "b")
        try edited.update { $0.name = "Two, edited" }
        try store.save(edited)
        try save(combo("c", "Three"), in: store)
        try store.delete(kind: .actionCombo, id: "a")
        let known = first.decoded.compactMapValues(\.stamp)
        let second = await store.fillResidentTable(ActionCombo.self, epoch: 1, known: known)
        #expect(Set(second.decoded.keys) == ["b", "c"])
        #expect(second.decoded["b"]?.value.name == "Two, edited")
        #expect(second.unchanged.isEmpty, "a is gone and b changed")

        let third = await store.fillResidentTable(
            ActionCombo.self, epoch: 2, known: second.decoded.compactMapValues(\.stamp))
        #expect(third.decoded.isEmpty, "nothing changed: no decode")
        #expect(Set(third.unchanged.keys) == ["b", "c"])
    }

    private func filled(_ values: [ActionCombo], epoch: Int) -> ResidentTable<ActionCombo> {
        var table = ResidentTable<ActionCombo>()
        _ = table.beginFill(at: epoch)
        table.land(ResidentTableFill(
            epoch: epoch,
            decoded: Dictionary(uniqueKeysWithValues: values.map { ($0.id, .init(value: $0, stamp: nil)) })
        ))
        return table
    }

    @Test func anUnfilledTableMissesAndStartsOneFillAtATime() {
        var table = ResidentTable<ActionCombo>()
        #expect(table.value("a") == nil)
        #expect(!table.isFilled)
        #expect(table.beginFill(at: 0) != nil)
        #expect(table.beginFill(at: 0) == nil, "one fill in flight")
        #expect(table.beginFill(at: 1) == nil, "a newer epoch waits for the landing")
        table.land(ResidentTableFill(epoch: 0, decoded: ["a": .init(value: combo("a", "One"), stamp: nil)]))
        #expect(table.isCovered(at: 0))
        #expect(table.value("a")?.name == "One")
        #expect(table.beginFill(at: 0) == nil, "covered: nothing to fill")
        #expect(table.beginFill(at: 1) != nil, "behind: the next fill starts")
    }

    @Test func anOutsideBumpServesTheResidentValueButNotAsCurrent() {
        let table = filled([combo("a", "One")], epoch: 3)
        #expect(table.currentValue("a", at: 3)?.name == "One")

        #expect(table.value("a")?.name == "One")
        #expect(table.currentValue("a", at: 4) == nil)
        #expect(!table.isCovered(at: 4))
        #expect(table.isCovered(since: 3))
        #expect(!table.isCovered(since: 4))
    }

    @Test func aSingleSaveRetagsTheKindInsteadOfRefilling() {
        var table = filled([combo("a", "One"), combo("b", "Two")], epoch: 3)
        table.reseed(id: "b", value: combo("b", "Two, edited"), epoch: 4)
        #expect(table.isCovered(at: 4))
        #expect(table.currentValue("a", at: 4)?.name == "One")
        #expect(table.currentValue("b", at: 4)?.name == "Two, edited")
        #expect(table.beginFill(at: 4) == nil, "still covered: no refill")
    }

    @Test func aReseedNeverRevivesAnEntryAlreadyBehind() {
        var table = filled([combo("a", "One")], epoch: 3)

        table.reseed(id: "b", value: combo("b", "Two"), epoch: 5)
        #expect(table.currentValue("a", at: 5) == nil, "a was stale at 4 and stays stale")
        #expect(table.currentValue("b", at: 5)?.name == "Two")
        #expect(!table.isCovered(at: 5))
        #expect(table.value("a")?.name == "One", "still served to views")
    }

    @Test func aLandingKeepsWhatIsNewerThanTheFill() {
        var table = filled([combo("a", "One"), combo("b", "Two")], epoch: 3)
        let known = table.beginFill(at: 4)
        #expect(known != nil)

        table.reseed(id: "a", value: combo("a", "One, saved"), epoch: 5)
        table.land(ResidentTableFill(
            epoch: 4,
            decoded: ["a": .init(value: combo("a", "One, as the fill saw it"), stamp: nil),
                      "c": .init(value: combo("c", "Three"), stamp: nil)],
            unchanged: [:]
        ))
        #expect(table.value("a")?.name == "One, saved", "the newer save wins")
        #expect(table.value("c")?.name == "Three")
        #expect(table.value("b") == nil, "b was not on disk at the fill")
        #expect(table.isCovered(at: 4))
        #expect(!table.isCovered(at: 5), "one refill behind")
        #expect(table.beginFill(at: 5) != nil)
    }

    @Test func anUnchangedStampKeepsTheValueAndAFillOlderThanTheTableIsDropped() {
        let stamp = DocumentFileStamp(inode: 7, size: 10, modifiedNanoseconds: 1)
        var table = ResidentTable<ActionCombo>()
        _ = table.beginFill(at: 0)
        table.land(ResidentTableFill(epoch: 0, decoded: ["a": .init(value: combo("a", "One"), stamp: stamp)]))
        let known = table.beginFill(at: 1)
        #expect(known == ["a": stamp])
        table.land(ResidentTableFill(epoch: 1, unchanged: ["a": stamp]))
        #expect(table.currentValue("a", at: 1)?.name == "One")

        table.land(ResidentTableFill(epoch: 0, decoded: ["z": .init(value: combo("z", "Deleted"), stamp: nil)]))
        #expect(table.value("z") == nil)
        #expect(table.isCovered(at: 1))
    }

    @Test func aSeedNeverReplacesANewerEntry() {
        var table = filled([combo("a", "One")], epoch: 3)
        table.seed(id: "a", value: combo("a", "Decoded at 4"), epoch: 4)
        #expect(table.currentValue("a", at: 4)?.name == "Decoded at 4")
        table.seed(id: "a", value: combo("a", "Older"), epoch: 2)
        #expect(table.value("a")?.name == "Decoded at 4")
    }
}

@Suite struct ResidentDocumentsTests {
    private func makeStore() throws -> (DocumentStore, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return (try DocumentStore(rootURL: root), root)
    }

    @MainActor @Test func aColdReadMissesThenTheFillLandsAndBumpsTheFillEpoch() async throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        try await store.save(TypedDocument(ActionCombo(id: "a", name: "One", actions: [])))
        let epochs = DocumentKindVersions()
        let fills = DocumentKindVersions()
        let combos = ResidentDocuments<ActionCombo>(store: store, epochs: epochs, fills: fills)

        #expect(combos.value("a") == nil, "a miss never decodes on the caller")
        await combos.ready()
        #expect(combos.value("a")?.name == "One")
        #expect(combos.currentValue("a")?.name == "One")
        #expect(combos.isCovered)
        #expect(fills[.actionCombo] == 1)
        #expect(fills[.theme] == 0, "only its own kind")
    }

    @MainActor @Test func theFillWaitCoversAnOutsideWriteMadeBeforeIt() async throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        try await store.save(TypedDocument(ActionCombo(id: "a", name: "One", actions: [])))
        let epochs = DocumentKindVersions()
        let combos = ResidentDocuments<ActionCombo>(store: store, epochs: epochs, fills: DocumentKindVersions())
        await combos.ready()

        try await store.save(TypedDocument(ActionCombo(id: "b", name: "Two", actions: [])))
        epochs.bump(.actionCombo)
        #expect(combos.value("b") == nil)
        await combos.ready()
        #expect(combos.value("b")?.name == "Two")
        #expect(combos.values.count == 2)
    }

    @MainActor @Test func theLibraryReseedsTheSavedKindOnly() async throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let epochs = DocumentKindVersions()
        let library = ResidentLibrary(store: store, epochs: epochs, fills: DocumentKindVersions())
        library.warmAll()
        await library.ready([.actionCombo, .scheduleTrigger])
        #expect(library.actionCombos.isCovered)

        epochs.bump(.actionCombo)
        library.reseed(ActionCombo(id: "a", name: "Saved", actions: []))
        #expect(library.actionCombos.currentValue("a")?.name == "Saved")
        #expect(library.actionCombos.isCovered, "a single save keeps the kind covered")
        #expect(library.table(Presentation.self) == nil, "decks are not resident")
        library.reseed(Presentation(id: "p", name: "Deck", presentationKind: .deck, themeId: "", slides: []))
        #expect(Set(library.all.map(\.kind)).count == library.all.count, "one table per kind")
    }
}
