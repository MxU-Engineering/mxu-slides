import XCTest
@testable import AudioEngine

final class MonitorTakeoverTests: XCTestCase {
    private let outputs: [(id: String, deviceUID: String?)] = [
        (id: "main", deviceUID: nil), (id: "booth", deviceUID: "usb-interface"),
        (id: "lobby", deviceUID: "dante"), (id: "parked", deviceUID: "none"),
    ]

    func testAMonitorOnSystemDefaultSilencesTheOutputsThatFollowIt() {
        XCTAssertEqual(
            MonitorTakeover.silencedOutputs(
                outputs: outputs, monitorDeviceUID: nil, systemDefaultUID: "usb-interface", silentUID: "none"),
            ["main", "booth"])
    }

    func testAMonitorOnANamedDeviceLeavesTheRestPlaying() {
        XCTAssertEqual(
            MonitorTakeover.silencedOutputs(
                outputs: outputs, monitorDeviceUID: "dante", systemDefaultUID: "speakers", silentUID: "none"),
            ["lobby"])
        XCTAssertTrue(MonitorTakeover.silencedOutputs(
            outputs: outputs, monitorDeviceUID: "headphones", systemDefaultUID: "speakers", silentUID: "none").isEmpty)
    }
}
