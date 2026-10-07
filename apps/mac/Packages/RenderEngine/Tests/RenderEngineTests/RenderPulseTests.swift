import XCTest
@testable import RenderEngine

final class RenderPulseTests: XCTestCase {

    func testCaptureFramesCountPerSourceAndResetOnDrain() {
        let pulse = RenderPulse()
        pulse.captureFrame(source: "Elgato 4K S")
        pulse.captureFrame(source: "Elgato 4K S")
        pulse.captureFrame(source: "Aircast")
        XCTAssertEqual(pulse.drain().captureFrames, ["Elgato 4K S": 2, "Aircast": 1])
        XCTAssertTrue(pulse.drain().captureFrames.isEmpty)
    }

    func testSteeredTicksReportWhereTheySatAndHowManyNearedAnEdge() {
        let pulse = RenderPulse()
        pulse.mirrorSteered(edgeDistanceMS: 16.2, periodMS: 33.4)
        pulse.mirrorSteered(edgeDistanceMS: 2.4, periodMS: 33.4)
        pulse.mirrorSteered(edgeDistanceMS: 15.9, periodMS: 33.4)
        let snapshot = pulse.drain()
        XCTAssertEqual(snapshot.mirrorSteeredTicks, 3)
        XCTAssertEqual(snapshot.mirrorClosestEdgeMS, 2.4)
        XCTAssertEqual(snapshot.mirrorEdgeMSTotal, 34.5, accuracy: 1e-9)
        XCTAssertEqual(snapshot.mirrorNearEdgeTicks, 1)
        XCTAssertEqual(pulse.drain().mirrorSteeredTicks, 0)
    }
}
