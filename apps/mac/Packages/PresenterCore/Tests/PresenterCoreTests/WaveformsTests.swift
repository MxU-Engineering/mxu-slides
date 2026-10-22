import Foundation
import Testing
@testable import PresenterCore

@Test func bucketsHoldEachStretchsLowestAndHighestSampleAcrossChannelsAndBuffers() {

    var bucketer = WaveformBucketer(sampleRate: 400, bucketsPerSecond: 100)
    let left: [Float] = [0.1, -0.2, 0.3, 0, 0.5, 0, 0, 0, -0.9]
    let right: [Float] = [0, 0, 0, 0.4, 0, -0.6, 0, 0, 0]
    for start in stride(from: 0, to: left.count, by: 3) {
        left[start..<start + 3].withUnsafeBufferPointer { l in
            right[start..<start + 3].withUnsafeBufferPointer { r in
                bucketer.add([l, r], frameCount: 3)
            }
        }
    }
    let wave = bucketer.finished()
    #expect(wave.maxs == [0.4, 0.5, 0])
    #expect(wave.mins == [-0.2, -0.6, -0.9])
    #expect(wave.seconds == 0.03)
}

@Test func theCacheFileReadsBackAndRejectsTornBytes() {
    let wave = Waveform(mins: [-0.5, -0.25], maxs: [0.5, 1])
    #expect(Waveform(encoded: wave.encoded) == wave)
    #expect(Waveform(encoded: wave.encoded.dropLast()) == nil)
    #expect(Waveform(encoded: Data("nope".utf8)) == nil)
}

@Test func fillScalesTheLoudestPeakToTheEdges() {
    #expect(Waveform(mins: [-0.5, -0.1], maxs: [0.2, 0.25]).fillScale == 2)
    #expect(Waveform(mins: [0], maxs: [0]).fillScale == 0)
}

@Test func stemsCombineAtTheirPlacesAndTrims() {
    let ones = Waveform(bucketsPerSecond: 10, mins: Array(repeating: -1, count: 20), maxs: Array(repeating: 1, count: 20))
    let song = Waveforms.combined([
        WaveformPart(waveform: ones, at: 0),
        WaveformPart(waveform: ones, at: 1, inPoint: 0.5, duration: 0.5),
    ], from: 0, length: 3)
    #expect(song.count == 30)
    #expect(song.maxs[5] == 1)
    #expect(song.maxs[12] == Float(2).squareRoot())
    #expect(song.maxs[16] == 1)
    #expect(song.mins[12] == -Float(2).squareRoot())
    #expect(song.maxs[25] == 0)

    let card = Waveforms.combined([WaveformPart(waveform: ones, at: 1, inPoint: 0.5)], from: 1, length: 1.5)
    #expect(card.count == 15)
    #expect(card.maxs.allSatisfy { $0 == 1 })
}

@Test func aZoomDrawsTheCoarsestLevelWithABucketAPoint() {
    let base = Waveform(mins: Array(repeating: -0.5, count: 1000), maxs: (0..<1000).map { Float($0) / 1000 })
    let levels = WaveformLevels(base)
    #expect(levels.levels.map(\.bucketsPerSecond) == [100, 50, 25, 12.5, 6.25, 3.125, 1.5625])
    #expect(levels.level(forPointsPerSecond: 120).bucketsPerSecond == 100)
    #expect(levels.level(forPointsPerSecond: 40).bucketsPerSecond == 50)
    #expect(levels.level(forPointsPerSecond: 2).bucketsPerSecond == 3.125)
    #expect(levels.levels[1].maxs[0] == 0.001)
    #expect(abs(levels.fillScale - 1 / 0.999) < 1e-5)
}

@Test func aScrolledLaneRedrawsInHalfViewSteps() {
    let window = Waveforms.drawnWindow(visibleMinX: 1250, visibleWidth: 1000)
    #expect(window == 0...3000)
    #expect(Waveforms.drawnWindow(visibleMinX: 1499, visibleWidth: 1000) == window)
    #expect(window.contains(1250) && window.contains(2250))
}
