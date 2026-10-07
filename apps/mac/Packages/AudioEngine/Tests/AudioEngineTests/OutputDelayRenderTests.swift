import AVFoundation
import Foundation
import Testing
@testable import AudioEngine

private func flipToneFile(name: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("output-delay-\(name).wav")
    let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    let frames = AVAudioFrameCount(4 * 48_000)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    buffer.frameLength = frames
    for index in 0 ..< Int(frames) {
        let hertz: Double = index < 48_000 ? 440 : 330
        buffer.floatChannelData?[0][index] =
            Float(sin(2 * .pi * hertz * Double(index) / 48_000)) * 0.5
    }
    try file.write(from: buffer)
    return url
}

private func peak(_ buffer: AVAudioPCMBuffer, from start: Int, to end: Int) -> Float {
    guard let data = buffer.floatChannelData?[0] else { return -1 }
    var top: Float = 0
    for index in start ..< min(end, Int(buffer.frameLength)) { top = max(top, abs(data[index])) }
    return top
}

private func hertz(_ buffer: AVAudioPCMBuffer, from start: Int, to end: Int) -> Double {
    guard let data = buffer.floatChannelData?[0] else { return 0 }
    var crossings = 0
    for index in (start + 1) ..< min(end, Int(buffer.frameLength))
    where (data[index - 1] < 0) != (data[index] < 0) { crossings += 1 }
    return Double(crossings) / 2 * 48_000 / Double(end - start)
}

@Test func outputDelaySetBeforePlayHoldsTheProgramBack() throws {
    let engine = AudioEngine()
    try engine.enableManualRenderingForTests()
    engine.outputDelayMilliseconds = 500
    try engine.play(url: try flipToneFile(name: "a"))
    let rendered = try engine.renderOfflineForTests(frames: 96_000)
    #expect(peak(rendered, from: 0, to: 22_000) < 0.01, "opens with the delay's silence")

    #expect(abs(hertz(rendered, from: 55_000, to: 65_000) - 440) < 15)
    #expect(abs(hertz(rendered, from: 80_000, to: 96_000) - 330) < 15)
}

@Test func outputDelayChangedMidPlayShiftsTheProgram() throws {
    let engine = AudioEngine()
    try engine.enableManualRenderingForTests()
    try engine.play(url: try flipToneFile(name: "b"))
    _ = try engine.renderOfflineForTests(frames: 4_800)  
    engine.outputDelayMilliseconds = 500
    let rendered = try engine.renderOfflineForTests(frames: 96_000)  

    let before = hertz(rendered, from: 48_000, to: 62_000)
    let after = hertz(rendered, from: 75_000, to: 96_000)
    #expect(abs(before - 440) < 15, "still the first tone: the flip has been held back")
    #expect(abs(after - 330) < 15)
}
