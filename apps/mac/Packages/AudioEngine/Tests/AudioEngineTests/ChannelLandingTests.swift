import XCTest
@testable import AudioEngine

final class ChannelLandingTests: XCTestCase {

    func testAChannelLandsOnItsRouteAndItsSendsThroughEachMixsGain() {
        let landing = AudioLevel.channelLanding(
            level: (rms: 0.5, peak: 0.8), channelGain: 0.5, routedMix: "main",
            sends: ["stream": 0.5, "lobby": 1, "main": 0.1],
            mixGain: { ["main": 1, "stream": 1, "lobby": 0][$0] ?? 1 })
        XCTAssertEqual(landing.keys.sorted(), ["main", "stream"])
        XCTAssertEqual(landing["main"]?.peak ?? 0, 0.4, accuracy: 1e-6)
        XCTAssertEqual(landing["stream"]?.peak ?? 0, 0.2, accuracy: 1e-6)
        XCTAssertEqual(landing["stream"]?.rms ?? 0, 0.125, accuracy: 1e-6)

        XCTAssertTrue(AudioLevel.channelLanding(
            level: (0.5, 0.8), channelGain: 0, routedMix: "main", sends: [:], mixGain: { _ in 1 }).isEmpty)
        XCTAssertTrue(AudioLevel.channelLanding(
            level: (0, 0), channelGain: 1, routedMix: "main", sends: [:], mixGain: { _ in 1 }).isEmpty)
    }
}
