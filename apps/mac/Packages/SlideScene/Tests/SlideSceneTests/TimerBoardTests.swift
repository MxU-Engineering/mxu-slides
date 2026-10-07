import Foundation
import XCTest
@testable import SlideScene

final class TimerBoardTests: XCTestCase {
    private func makeBoard() -> (TimerBoard, folderID: String) {
        var board = TimerBoard()
        board.reconcile(with: ["a", "b", "c", "d"])
        let folderID = board.addFolder(named: "Pre-service")
        board.moveTimer(id: "c", intoFolder: folderID)
        board.moveTimer(id: "d", intoFolder: folderID)

        return (board, folderID)
    }

    private func assertExactlyOnce(_ board: TimerBoard, _ ids: [String]) {
        let all = board.allTimerIDs
        XCTAssertEqual(all.sorted(), ids.sorted(), "board lost or duplicated timers: \(all)")
        XCTAssertEqual(Set(all).count, all.count, "a timer appears twice: \(all)")
    }

    func testReconcileAppendsUnknownAndPrunesDeleted() {
        var board = TimerBoard()
        board.reconcile(with: ["a", "b"])
        XCTAssertEqual(board.allTimerIDs, ["a", "b"])

        let folderID = board.addFolder(named: "F")
        board.moveTimer(id: "b", intoFolder: folderID)
        board.reconcile(with: ["a", "b", "new"])
        XCTAssertEqual(board.allTimerIDs, ["a", "b", "new"])
        XCTAssertEqual(board.folder(id: folderID)?.timerIDs, ["b"])

        board.reconcile(with: ["a", "new"])
        XCTAssertEqual(board.folder(id: folderID)?.timerIDs, [], "deleted timer must leave the folder")
        XCTAssertNotNil(board.folder(id: folderID), "an emptied folder survives — grouping is not garbage")
        assertExactlyOnce(board, ["a", "new"])
    }

    func testMoveTimerIntoAndOutOfFolder() {
        var (board, folderID) = makeBoard()
        assertExactlyOnce(board, ["a", "b", "c", "d"])
        XCTAssertEqual(board.folder(id: folderID)?.timerIDs, ["c", "d"])
        XCTAssertEqual(board.folder(containing: "c")?.id, folderID)

        board.moveTimer(id: "c", beforeNode: "a")
        XCTAssertNil(board.folder(containing: "c"))
        XCTAssertEqual(board.nodes.first?.id, "c")
        XCTAssertEqual(board.folder(id: folderID)?.timerIDs, ["d"])
        assertExactlyOnce(board, ["a", "b", "c", "d"])

        board.moveTimer(id: "a", beforeNode: "d")
        XCTAssertEqual(board.folder(id: folderID)?.timerIDs, ["a", "d"])
        assertExactlyOnce(board, ["a", "b", "c", "d"])

        board.moveTimer(id: "b", intoFolder: folderID)
        XCTAssertEqual(board.folder(id: folderID)?.timerIDs, ["a", "d", "b"])
        assertExactlyOnce(board, ["a", "b", "c", "d"])

        board.moveTimer(id: "a", beforeNode: nil)
        XCTAssertNil(board.folder(containing: "a"))
        XCTAssertEqual(board.nodes.last?.id, "a")
        assertExactlyOnce(board, ["a", "b", "c", "d"])
    }

    func testMoveTimerBeforeTopLevelFolderInsertsAtTopLevel() {
        var (board, folderID) = makeBoard()
        board.moveTimer(id: "a", beforeNode: folderID)
        XCTAssertNil(board.folder(containing: "a"), "inserting before a folder is a top-level move")
        XCTAssertEqual(board.nodes.map(\.id), ["b", "a", folderID])
        assertExactlyOnce(board, ["a", "b", "c", "d"])
    }

    func testMoveFolderReordersTopLevelAndNeverNests() {
        var (board, folderID) = makeBoard()
        board.moveFolder(id: folderID, beforeNode: "a")
        XCTAssertEqual(board.nodes.map(\.id), [folderID, "a", "b"])

        board.moveFolder(id: folderID, beforeNode: "c")
        XCTAssertEqual(board.nodes.map(\.id), [folderID, "a", "b"])

        board.moveFolder(id: folderID, beforeNode: nil)
        XCTAssertEqual(board.nodes.map(\.id), ["a", "b", folderID])
        assertExactlyOnce(board, ["a", "b", "c", "d"])
    }

    func testRemoveFolderDissolvesInPlace() {
        var (board, folderID) = makeBoard()
        board.removeFolder(id: folderID)
        XCTAssertNil(board.folder(id: folderID))
        XCTAssertEqual(
            board.nodes.map(\.id), ["a", "b", "c", "d"],
            "members must return to the folder's position, in order"
        )
        assertExactlyOnce(board, ["a", "b", "c", "d"])
    }

    func testRenameAndCollapse() {
        var (board, folderID) = makeBoard()
        board.renameFolder(id: folderID, to: "Walk-in")
        XCTAssertEqual(board.folder(id: folderID)?.name, "Walk-in")
        board.renameFolder(id: folderID, to: "   ")
        XCTAssertEqual(board.folder(id: folderID)?.name, "Walk-in", "blank rename is a no-op")
        board.setCollapsed(id: folderID, true)
        XCTAssertEqual(board.folder(id: folderID)?.collapsed, true)
    }

    func testCodableRoundTrip() throws {
        let (board, _) = makeBoard()
        let data = try JSONEncoder().encode(board)
        let decoded = try JSONDecoder().decode(TimerBoard.self, from: data)
        XCTAssertEqual(decoded, board)
    }

    func testFeaturedPicksTheLiveTimerNearestItsEnd() {
        let now = Date(timeIntervalSinceReferenceDate: 5000)
        let far = TimerSnapshot(
            id: "far", name: "Far", mode: .countdown,
            isRunning: true, runningSince: now, durationSeconds: 600
        )
        let near = TimerSnapshot(
            id: "near", name: "Near", mode: .countdown,
            isRunning: true, runningSince: now, durationSeconds: 60
        )
        let paused = TimerSnapshot(
            id: "paused", name: "Paused", mode: .countdown, durationSeconds: 5
        )
        let unlimited = TimerSnapshot(
            id: "up", name: "Up", mode: .countUp, isRunning: true, runningSince: now
        )
        XCTAssertEqual(
            TimerBoard.featured(in: [far, near, paused, unlimited], at: now)?.id, "near",
            "featured = live timer with least remaining; paused never features"
        )
        XCTAssertEqual(
            TimerBoard.featured(in: [far, unlimited], at: now)?.id, "far",
            "an unlimited Count Up ranks behind any countdown"
        )
        XCTAssertNil(TimerBoard.featured(in: [paused], at: now))
    }

    func testRollupUrgencyTakesTheWorstMember() {
        let now = Date(timeIntervalSinceReferenceDate: 5000)
        let calm = TimerSnapshot(
            id: "calm", name: "Calm", mode: .countdown,
            isRunning: true, runningSince: now, durationSeconds: 600
        )
        let warning = TimerSnapshot(
            id: "warn", name: "Warn", mode: .countdown,
            isRunning: true, runningSince: now, durationSeconds: 20
        )
        let overrun = TimerSnapshot(
            id: "over", name: "Over", mode: .countdown,
            isRunning: true, runningSince: now.addingTimeInterval(-100), durationSeconds: 10
        )
        XCTAssertEqual(TimerBoard.rollupUrgency(of: [calm], at: now), .normal)
        XCTAssertEqual(TimerBoard.rollupUrgency(of: [calm, warning], at: now), .warning)
        XCTAssertEqual(TimerBoard.rollupUrgency(of: [calm, warning, overrun], at: now), .overrun)

        let idle = TimerSnapshot(id: "idle", name: "Idle", mode: .countdown)
        XCTAssertTrue(idle.isIdle)
        XCTAssertNil(idle.activeWarning(at: now))
        XCTAssertEqual(TimerBoard.rollupUrgency(of: [calm, idle], at: now), .normal)
        XCTAssertNil(TimerBoard.rollupWarning(of: [calm, idle], at: now))
        XCTAssertFalse(calm.isIdle)
    }
}

extension TimerBoardTests {
    func testFilterMatchesTimerAndFolderNames() {
        let (board, _) = makeBoard()
        let names = ["a": "Sermon", "b": "Countdown", "c": "Walk-in Clock", "d": "Doors"]

        XCTAssertEqual(board.filteredTimerIDs(matching: " ", name: { names[$0] }), ["a", "b", "c", "d"])
        XCTAssertEqual(board.filteredTimerIDs(matching: "SERMON", name: { names[$0] }), ["a"])

        XCTAssertEqual(board.filteredTimerIDs(matching: "pre-s", name: { names[$0] }), ["c", "d"])
        XCTAssertEqual(board.filteredTimerIDs(matching: "doors", name: { names[$0] }), ["d"])
        XCTAssertTrue(board.filteredTimerIDs(matching: "zzz", name: { names[$0] }).isEmpty)
    }
}

extension TimerBoardTests {

    func testOrderSnapshotRestoreInvertsMoves() {
        let (original, folderID) = makeBoard()
        var board = original
        let before = board.orderSnapshot

        board.moveTimer(id: "a", beforeNode: "d")
        XCTAssertEqual(board.folder(id: folderID)?.timerIDs, ["c", "a", "d"])
        board.restore(order: before)
        XCTAssertEqual(board, original, "the inverse is the move back")

        board.moveFolder(id: folderID, beforeNode: "a")
        board.restore(order: before)
        XCTAssertEqual(board, original)
    }

    func testOrderRestoreToleratesDriftAndKeepsRenames() {
        var (board, folderID) = makeBoard()
        let before = board.orderSnapshot

        board.moveTimer(id: "c", beforeNode: "a")

        board.reconcile(with: ["a", "c", "d", "e"])
        board.renameFolder(id: folderID, to: "Post-service")

        board.restore(order: before)
        XCTAssertEqual(board.folder(id: folderID)?.timerIDs, ["c", "d"])
        XCTAssertEqual(board.folder(id: folderID)?.name, "Post-service",
                       "order-only snapshots never revert a rename")
        assertExactlyOnce(board, ["a", "c", "d", "e"])
        XCTAssertEqual(board.allTimerIDs, ["a", "c", "d", "e"])
    }
}
