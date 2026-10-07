import Foundation
import Testing
@testable import PresenterCore

@Test func scheduleTriggerRoundTripsThroughJSON() throws {

    let trigger = ScheduleTrigger(
        id: "tr1", name: "Sunday pre-service",
        conditions: [
            ScheduleCondition(id: "c1", kind: .weekly, days: [1], timeOfDay: "08:45"),
            ScheduleCondition(id: "c2", kind: .oneTime, date: "2026-07-20T18:00"),
            ScheduleCondition(id: "c3", kind: .timerReaches, timerId: "t1", timerSeconds: 0),
        ],
        actions: [
            SlideAction(id: "a1", kind: .switchOutputPreset, presetId: "preset-1"),
            SlideAction(id: "a2", kind: .captureStart, capturePresetId: "capture-1"),
            SlideAction(id: "a3", kind: .captureStop),
            SlideAction(id: "a4", kind: .firePresentation, presentationId: "p1", slideIndex: 2),
        ],
        enabled: false, notes: "Booth Mac only"
    )
    let data = try JSONEncoder().encode(trigger)
    let decoded = try JSONDecoder().decode(ScheduleTrigger.self, from: data)
    #expect(decoded == trigger)
}

@Test func scheduleTriggerOptionalsStayAbsentWhenNil() throws {

    let trigger = ScheduleTrigger(id: "tr1", name: "Bare", conditions: [], actions: [])
    let data = try JSONEncoder().encode(trigger)
    let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    #expect(object?["enabled"] == nil)
    #expect(object?["notes"] == nil)
    #expect(object?["archived"] == nil)
    let decoded = try JSONDecoder().decode(ScheduleTrigger.self, from: data)
    #expect(decoded.enabled == nil)
}

private func makeBoard(triggers: [String]) -> SchedulerBoard {
    var board = SchedulerBoard(id: SchedulerBoard.wellKnownID, nodes: [], folders: [])
    board.reconcile(withTriggerIDs: triggers)
    return board
}

@Test func boardReconcileAppendsUnknownAndPrunesGone() {
    var board = makeBoard(triggers: ["a", "b"])
    #expect(board.allTriggerIDs == ["a", "b"])

    let folderID = board.addFolder(named: "Sundays")
    board.moveTrigger(id: "b", intoFolder: folderID)
    board.reconcile(withTriggerIDs: ["a", "c"])
    #expect(board.allTriggerIDs.sorted() == ["a", "c"])
    #expect(board.folder(id: folderID)?.triggerIds.isEmpty == true)

    #expect(board.folder(id: folderID) != nil)
}

@Test func boardTriggerAppearsExactlyOnceThroughMoves() {
    var board = makeBoard(triggers: ["a", "b", "c"])
    let folderID = board.addFolder(named: "F")

    board.moveTrigger(id: "a", intoFolder: folderID)
    #expect(board.allTriggerIDs.filter { $0 == "a" }.count == 1)
    #expect(board.folder(containing: "a")?.id == folderID)

    board.moveTrigger(id: "b", beforeNode: "a")
    #expect(board.folder(containing: "b")?.id == folderID)
    #expect(board.folder(id: folderID)?.triggerIds == ["b", "a"])

    board.moveTrigger(id: "a", beforeNode: "c")
    #expect(board.folder(containing: "a") == nil)
    #expect(board.nodes.prefix(2) == ["a", "c"])
    #expect(board.allTriggerIDs == ["a", "c", "b"])
    #expect(board.allTriggerIDs.filter { $0 == "a" }.count == 1)
}

@Test func boardDissolveReturnsMembersInPlace() {
    var board = makeBoard(triggers: ["a", "b", "c"])
    let folderID = board.addFolder(named: "F")
    board.moveTrigger(id: "b", intoFolder: folderID)
    board.moveFolder(id: folderID, beforeNode: "c")

    board.removeFolder(id: folderID)
    #expect(board.allTriggerIDs == ["a", "b", "c"])
    #expect(board.folders.isEmpty)
    #expect(board.nodes == ["a", "b", "c"])
}

@Test func boardFolderEnabledGatesItsMembers() {
    var board = makeBoard(triggers: ["a", "b"])
    let folderID = board.addFolder(named: "F")
    board.moveTrigger(id: "a", intoFolder: folderID)

    #expect(board.folderEnabled(forTrigger: "a"))
    #expect(board.folderEnabled(forTrigger: "b"))

    board.setFolderEnabled(id: folderID, false)
    #expect(!board.folderEnabled(forTrigger: "a"))
    #expect(board.folderEnabled(forTrigger: "b"))

    board.setFolderEnabled(id: folderID, true)
    #expect(board.folder(id: folderID)?.enabled == nil)
    #expect(board.folderEnabled(forTrigger: "a"))
}

@Test func boardPlaceTriggerLandsBesideItsSibling() {
    var board = makeBoard(triggers: ["a", "b"])

    board.placeTrigger(id: "a2", afterSibling: "a")
    #expect(board.allTriggerIDs == ["a", "a2", "b"])

    let folderID = board.addFolder(named: "F")
    board.moveTrigger(id: "b", intoFolder: folderID)
    board.placeTrigger(id: "b2", afterSibling: "b")
    #expect(board.folder(id: folderID)?.triggerIds == ["b", "b2"])

    board.placeTrigger(id: "a", afterSibling: "b")
    #expect(board.allTriggerIDs.filter { $0 == "a" }.count == 1)
    #expect(board.folder(containing: "a") == nil)
}

@Test func boardDuplicateFolderCopiesShapeAfterOriginal() throws {
    var board = makeBoard(triggers: ["a", "b"])
    let folderID = board.addFolder(named: "Sundays")
    board.moveTrigger(id: "a", intoFolder: folderID)
    board.setFolderEnabled(id: folderID, false)
    board.moveFolder(id: folderID, beforeNode: "b")

    let firstResult = board.duplicateFolder(id: folderID, memberIDs: ["a2"])
    let copyID = try #require(firstResult)
    let copy = try #require(board.folder(id: copyID))
    #expect(copy.name == "Sundays Copy")
    #expect(copy.enabled == false)
    #expect(copy.triggerIds == ["a2"])

    #expect(board.nodes == [folderID, copyID, "b"])

    let secondResult = board.duplicateFolder(id: folderID, memberIDs: ["a"])
    let secondID = try #require(secondResult)
    #expect(board.folder(id: secondID)?.triggerIds.isEmpty == true)
    #expect(board.allTriggerIDs.filter { $0 == "a" }.count == 1)

    #expect(board.duplicateFolder(id: "ghost", memberIDs: []) == nil)
}

@Test func boardRoundTripsThroughJSON() throws {
    var board = makeBoard(triggers: ["a", "b"])
    let folderID = board.addFolder(named: "Sundays")
    board.moveTrigger(id: "a", intoFolder: folderID)
    board.setFolderEnabled(id: folderID, false)

    let data = try JSONEncoder().encode(board)
    let decoded = try JSONDecoder().decode(SchedulerBoard.self, from: data)
    #expect(decoded == board)
    #expect(!decoded.folderEnabled(forTrigger: "a"))
}
