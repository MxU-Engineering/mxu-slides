import Metal
import RenderEngine
import XCTest
@testable import MediaEngine

final class ArrivalWindowTests: XCTestCase {

    func testThePeriodAveragesDeliveryJitterOut() throws {
        var window = ArrivalWindow()
        var generator = SystemRandomNumberGenerator()
        let period = 1001.0 / 30000.0
        for frame in 0..<200 {
            window.record(100 + Double(frame) * period + Double.random(in: -0.003...0.003, using: &generator))
        }
        let cadence = try XCTUnwrap(window.cadence)
        XCTAssertEqual(cadence.period, period, accuracy: period * 0.002)
        XCTAssertEqual(cadence.lastArrival, 100 + 199 * period, accuracy: 0.0031)
    }

    func testNothingIsReportedBeforeASecondOfFrames() {
        var window = ArrivalWindow()
        for frame in 0..<(ArrivalWindow.minimumCount - 1) { window.record(Double(frame) / 30) }
        XCTAssertNil(window.cadence)
    }

    func testADroppedSignalRestartsTheWindow() {
        var window = ArrivalWindow()
        for frame in 0..<60 { window.record(Double(frame) / 30) }
        window.record(10)
        XCTAssertNil(window.cadence)
    }

    func testARegisteredLiveSourceReportsItsCadence() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("no Metal device on this machine")
        }
        let engine = try MediaEngine(device: device)
        let cadence = LiveCadence(lastArrival: 7, period: 1001.0 / 30000)
        engine.registerLiveSource(id: "direct", latestFrame: { nil }, onStop: {}, cadence: { cadence })
        engine.registerLiveSource(id: "ndi", latestFrame: { nil }, onStop: {})
        XCTAssertEqual(engine.liveCadence(for: "direct"), cadence)
        XCTAssertNil(engine.liveCadence(for: "ndi"))
    }
}
