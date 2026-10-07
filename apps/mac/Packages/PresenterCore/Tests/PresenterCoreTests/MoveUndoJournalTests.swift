import Foundation
import Testing
@testable import PresenterCore

@MainActor
private final class ListBox {
    var ids: [String]
    var exists = true
    init(_ ids: [String]) { self.ids = ids }

    func apply(_ order: [String]) -> Bool {
        guard exists else { return false }
        ids = order
        return true
    }
}

@Test @MainActor func journalUndoRedoRoundTrip() throws {
    let journal = MoveUndoJournal()
    let box = ListBox(["a", "b", "c"])
    box.ids = ["b", "a", "c"]
    journal.registerReorder(
        label: "move", before: ["a", "b", "c"], after: ["b", "a", "c"], apply: box.apply
    )
    #expect(journal.canUndo)
    #expect(!journal.canRedo)

    #expect(journal.undo())
    #expect(box.ids == ["a", "b", "c"])
    #expect(journal.canRedo)

    #expect(journal.redo())
    #expect(box.ids == ["b", "a", "c"])
    #expect(journal.canUndo)
}

@Test @MainActor func journalNewMoveClearsRedoTrail() throws {
    let journal = MoveUndoJournal()
    let box = ListBox(["a", "b"])
    journal.registerReorder(label: "1", before: ["a", "b"], after: ["b", "a"], apply: box.apply)
    journal.undo()
    #expect(journal.canRedo)
    journal.registerReorder(label: "2", before: ["a", "b"], after: ["b", "a"], apply: box.apply)
    #expect(!journal.canRedo)
}

@Test @MainActor func journalCapEvictsOldestEntries() throws {
    let journal = MoveUndoJournal(capacity: 2)
    let box = ListBox([])
    for _ in 0 ..< 5 {
        journal.registerMove(label: "m", undo: { box.apply([]) }, redo: { box.apply([]) })
    }
    #expect(journal.undo())
    #expect(journal.undo())
    #expect(!journal.undo(), "only `capacity` entries survive")
}

@Test @MainActor func journalDropsDeadEntriesAndKeepsWalking() throws {
    let journal = MoveUndoJournal()
    let live = ListBox(["a", "b"])
    let dead = ListBox(["x", "y"])
    live.ids = ["b", "a"]
    journal.registerReorder(label: "live", before: ["a", "b"], after: ["b", "a"], apply: live.apply)
    dead.ids = ["y", "x"]
    journal.registerReorder(label: "dead", before: ["x", "y"], after: ["y", "x"], apply: dead.apply)
    dead.exists = false

    #expect(journal.undo())
    #expect(live.ids == ["a", "b"])
    #expect(!journal.canUndo)

    #expect(journal.redo())
    #expect(live.ids == ["b", "a"])
    #expect(!journal.canRedo)
}

@Test @MainActor func journalSuppressesRegistrationDuringRestore() throws {
    let journal = MoveUndoJournal()
    let box = ListBox(["a", "b"])
    box.ids = ["b", "a"]

    journal.registerMove(
        label: "move",
        undo: {
            journal.registerMove(label: "reentrant", undo: { true }, redo: { true })
            return box.apply(["a", "b"])
        },
        redo: { box.apply(["b", "a"]) }
    )
    #expect(journal.undo())
    #expect(!journal.canUndo, "registration during restore must be suppressed")
    #expect(journal.canRedo)
}

@Test @MainActor func registerReorderIgnoresInsertsRemovesAndNoOps() throws {
    let journal = MoveUndoJournal()
    let box = ListBox([])
    journal.registerReorder(label: "insert", before: ["a"], after: ["a", "b"], apply: box.apply)
    journal.registerReorder(label: "remove", before: ["a", "b"], after: ["a"], apply: box.apply)
    journal.registerReorder(label: "same", before: ["a", "b"], after: ["a", "b"], apply: box.apply)
    journal.registerReorder(label: "swap-in", before: ["a", "b"], after: ["a", "c"], apply: box.apply)
    #expect(!journal.canUndo, "only pure permutations are moves")
}

@MainActor
private final class TextBox {
    var text: String
    var exists = true
    init(_ text: String) { self.text = text }

    func apply(_ value: String) -> Bool {
        guard exists else { return false }
        text = value
        return true
    }
}

@Test @MainActor func editCoalescesTypingBurstsIntoOneUndo() throws {
    var clock = Date(timeIntervalSinceReferenceDate: 0)
    let journal = MoveUndoJournal(now: { clock })
    let box = TextBox("Sun")

    box.text = "Sund"
    journal.registerEdit(
        key: "f", label: "edit", undo: { box.apply("Sun") }, redo: { box.apply("Sund") }
    )
    clock += 1
    box.text = "Sunday"
    journal.registerEdit(
        key: "f", label: "edit", undo: { box.apply("Sund") }, redo: { box.apply("Sunday") }
    )

    #expect(journal.undo())
    #expect(box.text == "Sun")
    #expect(!journal.canUndo, "the burst coalesced into one entry")
    #expect(journal.redo())
    #expect(box.text == "Sunday")
}

@Test @MainActor func editCoalescingBreaksOnPauseKeyChangeAndMoves() throws {
    var clock = Date(timeIntervalSinceReferenceDate: 0)
    let journal = MoveUndoJournal(coalescingWindow: 5, now: { clock })
    let box = TextBox("")
    journal.registerEdit(key: "a", label: "e", undo: { box.apply("1") }, redo: { box.apply("2") })

    clock += 6
    journal.registerEdit(key: "a", label: "e", undo: { box.apply("2") }, redo: { box.apply("3") })

    journal.registerEdit(key: "b", label: "e", undo: { box.apply("3") }, redo: { box.apply("4") })

    journal.registerMove(label: "m", undo: { box.apply("4") }, redo: { box.apply("5") })
    journal.registerEdit(key: "b", label: "e", undo: { box.apply("5") }, redo: { box.apply("6") })

    var undos = 0
    while journal.undo() { undos += 1 }
    #expect(undos == 5, "pause, key change, and interleaved moves each keep their own entry")
}

@Test @MainActor func editAfterUndoStartsFreshAndClearsRedo() throws {
    let journal = MoveUndoJournal()
    let box = TextBox("")
    journal.registerEdit(key: "a", label: "e", undo: { box.apply("old") }, redo: { box.apply("new") })
    journal.undo()
    #expect(journal.canRedo)

    journal.registerEdit(key: "a", label: "e", undo: { box.apply("old") }, redo: { box.apply("newer") })
    #expect(!journal.canRedo)
    #expect(journal.undo())
    #expect(box.text == "old")
}

@Test func listOrderAppliesTolerantly() throws {

    let restored = ListOrder.apply(
        ["c", "gone", "a", "b"], to: ["a", "new1", "b", "c", "new2"], id: { $0 }
    )
    #expect(restored == ["c", "a", "b", "new1", "new2"])
}

private func makeService(_ ids: [String]) -> Service {
    Service(
        id: "svc", name: "Sunday", serviceDate: "2026-08-16",
        items: ids.map { ServiceItem(id: $0, itemKind: .presentation, name: $0, refId: $0) }
    )
}

@Test func serviceItemMoveInverseRestoresRunOrder() throws {
    var service = makeService(["a", "b", "c", "d"])
    let before = service.items.map(\.id)

    let from = service.items.firstIndex { $0.id == "b" }!
    let item = service.items.remove(at: from)
    let insert = service.items.firstIndex { $0.id == "d" }!
    service.items.insert(item, at: insert)
    #expect(service.items.map(\.id) == ["a", "c", "b", "d"])

    service.items = ListOrder.apply(before, to: service.items, id: \.id)
    #expect(service == makeService(["a", "b", "c", "d"]), "the inverse is the move back")
}

private func makeSchedulerBoard() -> (SchedulerBoard, folderID: String) {
    var board = SchedulerBoard(id: SchedulerBoard.wellKnownID, nodes: [], folders: [])
    board.reconcile(withTriggerIDs: ["t1", "t2", "t3", "t4"])
    let folderID = board.addFolder(named: "Sundays")
    board.moveTrigger(id: "t3", intoFolder: folderID)
    board.moveTrigger(id: "t4", intoFolder: folderID)

    return (board, folderID)
}

@Test func schedulerTriggerMoveInverseRestoresBoard() throws {
    var (board, folderID) = makeSchedulerBoard()
    let original = board
    let before = board.orderSnapshot

    board.moveTrigger(id: "t1", beforeNode: "t4")
    #expect(board.folder(id: folderID)?.triggerIds == ["t3", "t1", "t4"])

    board.restore(order: before)
    #expect(board == original, "the inverse is the move back")

    board.moveFolder(id: folderID, beforeNode: "t1")
    #expect(board.nodes == [folderID, "t1", "t2"])
    board.restore(order: before)
    #expect(board == original)
}

@Test func schedulerBoardRestoreToleratesMembershipDrift() throws {
    var (board, folderID) = makeSchedulerBoard()
    let before = board.orderSnapshot

    board.moveTrigger(id: "t3", beforeNode: "t1")

    board.reconcile(withTriggerIDs: ["t1", "t3", "t4", "t5"])

    board.restore(order: before)

    #expect(board.folder(id: folderID)?.triggerIds == ["t3", "t4"])
    let all = board.allTriggerIDs
    #expect(all.sorted() == ["t1", "t3", "t4", "t5"])
    #expect(Set(all).count == all.count)

    var (renamed, renamedFolder) = makeSchedulerBoard()
    let snapshot = renamed.orderSnapshot
    renamed.moveTrigger(id: "t1", intoFolder: renamedFolder)
    renamed.renameFolder(id: renamedFolder, to: "Weekdays")
    renamed.restore(order: snapshot)
    #expect(renamed.folder(id: renamedFolder)?.name == "Weekdays")
    #expect(renamed.nodes == ["t1", "t2", renamedFolder])
}

@Test func controlBoardMoveInverseRestoresBoard() throws {
    var board = ControlBoard(id: ControlBoard.streamBoardID, nodes: [], folders: [])
    board.reconcile(withItemIDs: ["p1", "p2", "p3"])
    let folderID = board.addFolder(named: "Streams")
    board.moveItem(id: "p2", intoFolder: folderID)
    let original = board
    let before = board.orderSnapshot

    board.moveItem(id: "p1", beforeNode: "p2")
    #expect(board.folder(id: folderID)?.itemIds == ["p1", "p2"])
    board.restore(order: before)
    #expect(board == original, "the inverse is the move back")
}

@Test func slideOrderInverseHandsSectionsBack() throws {

    let slides = [
        Slide(id: "s1", name: "", objects: [], sectionId: "verse"),
        Slide(id: "s2", name: "", objects: [], sectionId: "verse"),
        Slide(id: "s3", name: "", objects: [], sectionId: "chorus"),
    ]
    let before = SlideOrder(slides: slides)

    var moved = slides
    var slide = moved.remove(at: 0)
    slide.sectionId = "chorus"
    moved.append(slide)

    let restored = before.apply(to: moved)
    #expect(restored == slides)
}

@Test func listRemovalDiffsOnlyAStrictRemoval() {
    let before = ["a", "b", "c", "d"]
    let removal = ListRemoval(before: before, after: ["a", "c"], id: { $0 })
    #expect(removal?.removed.map(\.index) == [1, 3])
    #expect(removal?.removed.map(\.element) == ["b", "d"])
    #expect(ListRemoval(before: before, after: before, id: { $0 }) == nil, "nothing gone")
    #expect(ListRemoval(before: before, after: ["a", "c", "b"], id: { $0 }) == nil, "a move is not a removal")
    #expect(ListRemoval(before: before, after: ["a", "x"], id: { $0 }) == nil, "a replacement is not a removal")
    #expect(ListRemoval(before: before, after: ["a", "b", "c", "d", "e"], id: { $0 }) == nil, "an add is not a removal")
}

@Test func listRemovalRestoresPositionsTolerantly() {
    let removal = ListRemoval(before: ["a", "b", "c", "d"], after: ["a", "c"], id: { $0 })!
    var list = ["a", "c"]
    removal.restore(into: &list)
    #expect(list == ["a", "b", "c", "d"], "each lands where it was")

    var shrunk = ["a"]
    removal.restore(into: &shrunk)
    #expect(shrunk == ["a", "b", "d"], "positions clamp when the list shrank since")

    var readded = ["a", "c", "d"]
    removal.restore(into: &readded)
    #expect(readded == ["a", "b", "c", "d"], "one already back is left alone")

    var again = ["a", "b", "c", "d", "e"]
    removal.remove(from: &again)
    #expect(again == ["a", "c", "e"])
}

@Test @MainActor func journalRemovalUndoRedoRoundTrip() throws {
    let journal = MoveUndoJournal()
    let box = ListBox(["s1", "s2", "s3"])
    let diff = ListRemoval(before: box.ids, after: ["s1", "s3"], id: { $0 })
    let removal = try #require(diff)
    box.ids = ["s1", "s3"]
    journal.registerRemoval(label: "Delete Slide", removal: removal) { change in
        guard box.exists else { return false }
        change(&box.ids)
        return true
    }
    #expect(journal.undo())
    #expect(box.ids == ["s1", "s2", "s3"])
    #expect(journal.redo())
    #expect(box.ids == ["s1", "s3"])

    box.exists = false
    #expect(!journal.undo())
    #expect(!journal.canUndo)
}

@Test func listInsertionDiffsOnlyAStrictAddition() {
    let before = ["a", "b", "c"]
    let insertion = ListInsertion(before: before, after: ["a", "x", "b", "c", "y"], id: { $0 })
    #expect(insertion?.added.map(\.index) == [1, 4])
    #expect(insertion?.added.map(\.element) == ["x", "y"])
    #expect(insertion?.ids == ["x", "y"])
    #expect(ListInsertion(before: before, after: before, id: { $0 }) == nil, "nothing new")
    #expect(ListInsertion(before: before, after: ["a", "c", "b", "x"], id: { $0 }) == nil, "a move is not an insertion")
    #expect(ListInsertion(before: before, after: ["a", "b", "x"], id: { $0 }) == nil, "a replacement is not an insertion")
    #expect(ListInsertion(before: before, after: ["a", "c"], id: { $0 }) == nil, "a removal is not an insertion")
}

@Test @MainActor func journalInsertionUndoRedoRoundTrip() throws {
    let journal = MoveUndoJournal()
    let box = ListBox(["s1", "s2"])
    let diff = ListInsertion(before: box.ids, after: ["s1", "media", "s2"], id: { $0 })
    let insertion = try #require(diff)
    box.ids = ["s1", "media", "s2"]
    journal.registerInsertion(label: "Add Slide", insertion: insertion) { change in
        guard box.exists else { return false }
        change(&box.ids)
        return true
    }
    #expect(journal.undo())
    #expect(box.ids == ["s1", "s2"], "the dropped slide is gone again")
    #expect(journal.redo())
    #expect(box.ids == ["s1", "media", "s2"], "redo lands it where it was")

    box.exists = false
    #expect(!journal.undo())
    #expect(!journal.canUndo)
}

@Test @MainActor func aLaterAnswerThatAppliedJoinsTheRedoTrail() async throws {
    let journal = MoveUndoJournal()
    var applied: [String] = []
    journal.registerEdit(
        key: "k", label: "Edit",
        undoing: { .later(Task { applied.append("undo"); return true }) },
        redoing: { .done(true) })
    #expect(journal.undo(), "the keystroke is spent on the deciding entry")
    #expect(!journal.canRedo, "not on the trail until it answered")
    for _ in 0 ..< 100 where !journal.canRedo { await Task.yield() }
    #expect(applied == ["undo"])
    #expect(journal.canRedo && !journal.canUndo)
}

@Test @MainActor func aLaterGoneAnswerTriesTheNextEntryAsASynchronousOneWould() async throws {
    let journal = MoveUndoJournal()
    let box = ListBox(["a", "b"])
    box.ids = ["b", "a"]
    journal.registerReorder(label: "move", before: ["a", "b"], after: ["b", "a"], apply: box.apply)
    journal.registerEdit(
        key: "gone", label: "Edit", undoing: { .later(Task { false }) }, redoing: { .done(false) })
    #expect(journal.undo())
    for _ in 0 ..< 100 where box.ids != ["a", "b"] { await Task.yield() }
    #expect(box.ids == ["a", "b"], "the gone entry dropped and the move under it undid")
    #expect(!journal.canUndo)
    #expect(journal.canRedo, "only the move is on the redo trail")
}

@Test @MainActor func aKeystrokeWhileAnEntryDecidesWaitsItsTurn() async throws {
    let journal = MoveUndoJournal()
    var order: [String] = []
    journal.registerMove(label: "first", undo: { order.append("first"); return true }, redo: { true })
    let gate = AsyncStream<Void>.makeStream()
    journal.registerEdit(
        key: "slow", label: "Slow",
        undoing: { .later(Task { for await _ in gate.stream { break }; order.append("slow"); return true }) },
        redoing: { .done(true) })
    #expect(journal.undo())
    #expect(journal.undo(), "pressed while the first entry decides")
    #expect(order.isEmpty, "the second keystroke waits for the first")
    gate.continuation.yield()
    for _ in 0 ..< 100 where order.count < 2 { await Task.yield() }
    #expect(order == ["slow", "first"])
}

@Test @MainActor func whileRestoringNestsAndRegistersNothing() {
    let journal = MoveUndoJournal()
    journal.whileRestoring {
        journal.whileRestoring { journal.registerMove(label: "x", undo: { true }, redo: { true }) }
        #expect(journal.isRestoring, "an inner scope leaves the outer one restoring")
        journal.registerMove(label: "y", undo: { true }, redo: { true })
    }
    #expect(!journal.isRestoring)
    #expect(!journal.canUndo, "registrations while restoring push nothing")
}
