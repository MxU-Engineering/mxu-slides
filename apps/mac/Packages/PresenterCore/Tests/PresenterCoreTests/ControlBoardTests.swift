import Foundation
import Testing
@testable import PresenterCore

private func makeBoard(items: [String]) -> ControlBoard {
    var board = ControlBoard(id: ControlBoard.comboBoardID, nodes: [], folders: [])
    board.reconcile(withItemIDs: items)
    return board
}

@Test func controlBoardFolderLifecycle() throws {
    var board = makeBoard(items: ["a", "b"])
    #expect(board.nodes == ["a", "b"])

    let folderID = board.addFolder(named: "Sundays")
    board.moveItem(id: "b", intoFolder: folderID)
    #expect(board.folder(id: folderID)?.itemIds == ["b"])
    #expect(board.allItemIDs == ["a", "b"])

    board.reconcile(withItemIDs: ["a"])
    #expect(board.folder(id: folderID)?.itemIds.isEmpty == true)
    #expect(board.folder(id: folderID) != nil)

    board.reconcile(withItemIDs: ["a", "c"])
    board.moveItem(id: "c", intoFolder: folderID)
    board.removeFolder(id: folderID)
    #expect(board.folders.isEmpty)
    #expect(board.nodes == ["a", "c"])
}

@Test func controlBoardOrderedFoldersWalkNodeOrder() throws {

    var board = makeBoard(items: ["a", "b", "c"])
    let zulu = board.addFolder(named: "Zulu")
    let alpha = board.addFolder(named: "Alpha")
    board.moveFolder(id: alpha, beforeNode: zulu)
    #expect(board.orderedFolders.map(\.name) == ["Alpha", "Zulu"])

    board.moveItem(id: "b", intoFolder: alpha)
    board.moveFolder(id: alpha, beforeNode: "a")
    #expect(board.allItemIDs == ["b", "a", "c"])
}

@Test func controlBoardMovesKeepExactlyOnce() throws {
    var board = makeBoard(items: ["a", "b", "c"])
    let folderID = board.addFolder(named: "F")
    board.moveItem(id: "a", intoFolder: folderID)
    #expect(board.folder(containing: "a")?.id == folderID)

    board.moveItem(id: "b", beforeNode: "a")
    #expect(board.folder(containing: "b")?.id == folderID)
    #expect(board.folder(id: folderID)?.itemIds == ["b", "a"])

    board.moveItem(id: "a", beforeNode: "c")
    #expect(board.folder(containing: "a") == nil)
    #expect(board.nodes == ["a", "c", folderID])
    #expect(board.allItemIDs == ["a", "c", "b"])

    board.moveItem(id: "b", beforeNode: nil)
    #expect(board.nodes == ["a", "c", folderID, "b"])
    #expect(board.folder(id: folderID)?.itemIds.isEmpty == true)
}

@Test func controlBoardFolderReorderResolvesFolderedTargets() throws {
    var board = makeBoard(items: ["a", "b", "c"])
    let folderID = board.addFolder(named: "F")
    board.moveItem(id: "b", intoFolder: folderID)
    board.moveFolder(id: folderID, beforeNode: "a")
    #expect(board.nodes == [folderID, "a", "c"])

    board.moveFolder(id: folderID, beforeNode: "b")
    #expect(board.nodes == [folderID, "a", "c"])
    board.moveFolder(id: folderID, beforeNode: nil)
    #expect(board.nodes == ["a", "c", folderID])
}

@Test func controlBoardReconcileAppendsUnknownAndPrunesGone() throws {
    var board = makeBoard(items: ["a", "b"])
    let folderID = board.addFolder(named: "F")
    board.moveItem(id: "a", intoFolder: folderID)

    board.reconcile(withItemIDs: ["b", "c", "a"])
    #expect(board.folder(id: folderID)?.itemIds == ["a"])
    #expect(board.nodes == ["b", folderID, "c"])

    board.reconcile(withItemIDs: ["c"])
    #expect(board.allItemIDs == ["c"])
    #expect(board.folder(id: folderID)?.itemIds.isEmpty == true)
}

@Test func controlBoardOptionalsStayAbsentWhenNil() throws {

    let folder = ControlFolder(id: "f1", name: "F", itemIds: ["a"])
    let data = try JSONEncoder().encode(folder)
    let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    #expect(object?["collapsed"] == nil)
}

@Test func controlBoardFilterMatchesItemAndFolderNames() throws {
    var board = makeBoard(items: ["a", "b", "c"])
    let folderID = board.addFolder(named: "Walk-in")
    board.moveItem(id: "c", intoFolder: folderID)
    let names = ["a": "Lights Up", "b": "Lights Down", "c": "House Mix"]

    #expect(board.filteredItemIDs(matching: "", name: { names[$0] }) == ["a", "b", "c"])
    #expect(board.filteredItemIDs(matching: "  ", name: { names[$0] }) == ["a", "b", "c"])

    #expect(board.filteredItemIDs(matching: "lights", name: { names[$0] }) == ["a", "b"])

    #expect(board.filteredItemIDs(matching: "walk", name: { names[$0] }) == ["c"])
    #expect(board.filteredItemIDs(matching: "nope", name: { names[$0] }).isEmpty)
}

@Test func boardFoldersTakeCallerMintedIDs() {
    var control = makeBoard(items: ["a"])
    #expect(control.addFolder(named: "Sundays", id: "f-1") == "f-1")
    #expect(control.folder(id: "f-1")?.name == "Sundays")

    var scheduler = SchedulerBoard(id: SchedulerBoard.wellKnownID, nodes: [], folders: [])
    #expect(scheduler.addFolder(named: "Morning", id: "s-1") == "s-1")
    #expect(scheduler.duplicateFolder(id: "s-1", memberIDs: [], copyID: "s-2") == "s-2")
    #expect(scheduler.folder(id: "s-2")?.name == "Morning Copy")
}
