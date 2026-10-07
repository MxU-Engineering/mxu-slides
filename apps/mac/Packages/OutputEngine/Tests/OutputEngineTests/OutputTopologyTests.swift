import XCTest
@testable import OutputEngine

final class OutputTopologyTests: XCTestCase {
    private func display(
        _ uuid: DisplayUUID,
        frame: CGRect = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    ) -> DisplaySnapshot {
        DisplaySnapshot(
            uuid: uuid,
            displayID: 1,
            name: "Display \(uuid)",
            frame: frame,
            maximumFramesPerSecond: 60,
            isMain: false
        )
    }

    func testSurvivorUntouchedWhenNeighborUnplugs() {
        let survivorFrame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let changes = OutputTopology.reconcile(
            assigned: ["A", "B"],
            openWindows: ["A": survivorFrame, "B": CGRect(x: 1920, y: 0, width: 1280, height: 720)],
            connected: [display("A", frame: survivorFrame)] 
        )
        XCTAssertEqual(changes, [.close("B")])
    }

    func testReplugRestoresAssignedDisplay() {

        let changes = OutputTopology.reconcile(
            assigned: ["A", "B"],
            openWindows: ["A": display("A").frame],
            connected: [display("A"), display("B", frame: CGRect(x: 1920, y: 0, width: 1280, height: 720))]
        )
        XCTAssertEqual(changes, [.open("B")])
    }

    func testOriginShiftReframesWithoutRebuild() {

        let shifted = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let changes = OutputTopology.reconcile(
            assigned: ["A"],
            openWindows: ["A": CGRect(x: 2560, y: 0, width: 1920, height: 1080)],
            connected: [display("A", frame: shifted)]
        )
        XCTAssertEqual(changes, [.reframe("A", shifted)])
    }

    func testUnassignedConnectedDisplayGetsNoWindow() {
        let changes = OutputTopology.reconcile(
            assigned: [],
            openWindows: [:],
            connected: [display("A")]
        )
        XCTAssertEqual(changes, [])
    }

    func testUnassignClosesWindow() {
        let changes = OutputTopology.reconcile(
            assigned: [],
            openWindows: ["A": display("A").frame],
            connected: [display("A")]
        )
        XCTAssertEqual(changes, [.close("A")])
    }

    func testAssignedButDisconnectedIsPatientlyIgnored() {

        let changes = OutputTopology.reconcile(
            assigned: ["GONE"],
            openWindows: [:],
            connected: []
        )
        XCTAssertEqual(changes, [])
    }

    func testSteadyStateIsANoOp() {
        let changes = OutputTopology.reconcile(
            assigned: ["A", "B"],
            openWindows: [
                "A": display("A").frame,
                "B": CGRect(x: 1920, y: 0, width: 1280, height: 720),
            ],
            connected: [
                display("A"),
                display("B", frame: CGRect(x: 1920, y: 0, width: 1280, height: 720)),
            ]
        )
        XCTAssertEqual(changes, [])
    }

    func testClosesOrderedBeforeOpens() {
        let changes = OutputTopology.reconcile(
            assigned: ["B"],
            openWindows: ["A": display("A").frame],
            connected: [display("A"), display("B")]
        )
        XCTAssertEqual(changes, [.close("A"), .open("B")])
    }
}
