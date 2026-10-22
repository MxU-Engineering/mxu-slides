import AVFoundation
import XCTest
@testable import AudioEngine

final class ChannelLandingTests: XCTestCase {

    func testAChannelLandsOnItsRouteAndItsSendsThroughEachMixsGain() {
        let landing = AudioLevel.channelLanding(
            sides: [(rms: 0.5, peak: 0.8), (rms: 0.5, peak: 0.8)], channelGain: 0.5, routedMix: "main",
            sends: ["stream": 0.5, "lobby": 1, "main": 0.1],
            mixGain: { ["main": 1, "stream": 1, "lobby": 0][$0] ?? 1 })
        XCTAssertEqual(landing.keys.sorted(), ["main", "stream"])
        XCTAssertEqual(landing["main"]?[0].peak ?? 0, 0.4, accuracy: 1e-6)
        XCTAssertEqual(landing["stream"]?[1].peak ?? 0, 0.2, accuracy: 1e-6)
        XCTAssertEqual(landing["stream"]?[0].rms ?? 0, 0.125, accuracy: 1e-6)

        XCTAssertTrue(AudioLevel.channelLanding(
            sides: [(0.5, 0.8)], channelGain: 0, routedMix: "main", sends: [:], mixGain: { _ in 1 }).isEmpty)
        XCTAssertTrue(AudioLevel.channelLanding(
            sides: [(0, 0), (0, 0)], channelGain: 1, routedMix: "main", sends: [:], mixGain: { _ in 1 }).isEmpty)

        XCTAssertEqual(AudioLevel.channelLanding(
            sides: [(0.5, 0.8)], channelGain: 1, routedMix: nil, sends: ["ears": 1], mixGain: { _ in 1 }).keys.sorted(),
            ["ears"])
    }

    func testSidesLandThroughThePan() {
        let stereo = AudioLevel.channelLanding(
            sides: [(rms: 0.4, peak: 0.6), (rms: 0.2, peak: 0.3)], channelGain: 1, pan: 0, routedMix: "main",
            sends: [:], mixGain: { _ in 1 })["main"]!
        XCTAssertEqual(stereo[0].peak, 0.6, accuracy: 1e-6)
        XCTAssertEqual(stereo[1].peak, 0.3, accuracy: 1e-6)

        let hardLeft = AudioLevel.channelLanding(
            sides: [(rms: 0.4, peak: 0.6), (rms: 0.2, peak: 0.3)], channelGain: 1, pan: -1, routedMix: "main",
            sends: [:], mixGain: { _ in 1 })["main"]!
        XCTAssertEqual(hardLeft[0].peak, 0.6, accuracy: 1e-6)
        XCTAssertEqual(hardLeft[1].peak, 0, accuracy: 1e-6)

        let mono = AudioLevel.channelLanding(
            sides: [(rms: 0.4, peak: 0.8)], channelGain: 0.5, pan: 0.5, routedMix: "main",
            sends: [:], mixGain: { _ in 1 })["main"]!
        XCTAssertEqual(mono[0].peak, 0.2, accuracy: 1e-6, "half right: the left side at half")
        XCTAssertEqual(mono[1].peak, 0.4, accuracy: 1e-6, "the right side at the channel's gain")
    }

    func testTheMonoFold() {
        XCTAssertEqual(AudioLevel.mono([(0.5, 0.5), (0.5, 0.5)]).peak, 0.5, accuracy: 1e-6)
        XCTAssertEqual(AudioLevel.mono([(0.5, 0.8), (0, 0)]).peak, 0.4, accuracy: 1e-6)
        XCTAssertEqual(AudioLevel.mono([(0.3, 0.6)]).peak, 0.6, accuracy: 1e-6)
        XCTAssertEqual(AudioLevel.louder([(0.5, 0.2), (0.1, 0.7)]).peak, 0.7, accuracy: 1e-6)
    }

    func testDeviceChannelsCarryEachOutputsSides() {
        let bridge = AudioLevel.deviceChannels([
            (sides: [(rms: 0.4, peak: 0.6), (rms: 0.2, peak: 0.3)], channels: [0, 1]),
            (sides: [(rms: 0.4, peak: 0.8), (rms: 0, peak: 0)], channels: [5]),
            (sides: [(rms: 0.3, peak: 0.5), (rms: 0.3, peak: 0.5)], channels: [1]),
        ])
        XCTAssertEqual(bridge.keys.sorted(), [0, 1, 5])
        XCTAssertEqual(bridge[0]?.peak ?? 0, 0.6, accuracy: 1e-6)
        XCTAssertEqual(bridge[1]?.peak ?? 0, 0.5, accuracy: 1e-6, "the louder of the two outputs on channel 2")
        XCTAssertEqual(bridge[1]?.rms ?? 0, (0.2 * 0.2 + 0.3 * 0.3).squareRoot(), accuracy: 1e-6)
        XCTAssertEqual(bridge[5]?.peak ?? 0, 0.4, accuracy: 1e-6, "mono: (L + R) / 2")
    }

    func testMeasureSides() {
        let stereo = AVAudioPCMBuffer(
            pcmFormat: AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!, frameCapacity: 64)!
        stereo.frameLength = 64
        for frame in 0 ..< 64 {
            stereo.floatChannelData![0][frame] = 0.5
            stereo.floatChannelData![1][frame] = -0.25
        }
        let sides = AudioLevel.measureSides(stereo)
        XCTAssertEqual(sides.left.peak, 0.5, accuracy: 1e-6)
        XCTAssertEqual(sides.right.peak, 0.25, accuracy: 1e-6)
        XCTAssertEqual(sides.right.rms, 0.25, accuracy: 1e-6)

        let mono = AVAudioPCMBuffer(
            pcmFormat: AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!, frameCapacity: 64)!
        mono.frameLength = 64
        for frame in 0 ..< 64 { mono.floatChannelData![0][frame] = 0.3 }
        let doubled = AudioLevel.measureSides(mono)
        XCTAssertEqual(doubled.left.peak, 0.3, accuracy: 1e-6)
        XCTAssertEqual(doubled.right.peak, 0.3, accuracy: 1e-6)

        var window = LevelWindow()
        window.fold(left: sides.left, right: sides.right)
        window.fold(left: (0.1, 0.1), right: (0.4, 0.4))
        XCTAssertEqual(window.left.peak, 0.5, accuracy: 1e-6)
        XCTAssertEqual(window.right.peak, 0.4, accuracy: 1e-6)
        XCTAssertEqual(window.take().peak, 0.5, accuracy: 1e-6)
        XCTAssertEqual(window.right.peak, 0)
    }
}
