import AVFoundation
import Foundation
import Testing
@testable import AudioEngine

private func file(_ name: String, seconds: Double, rate: Double = 48_000, _ sample: (Int) -> Float) throws -> String {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("clip-\(name)-\(UUID().uuidString).wav")
    let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
    let output = try AVAudioFile(forWriting: url, settings: format.settings)
    let frames = AVAudioFrameCount(seconds * rate)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    buffer.frameLength = frames
    for channel in 0 ..< 2 {
        for index in 0 ..< Int(frames) { buffer.floatChannelData![channel][index] = sample(index) }
    }
    try output.write(from: buffer)
    return url.path
}

private let routing = MultitrackRouting(
    channels: [.init(id: "x", sends: ["mix": 1])], mixes: [.init(id: "mix", outputs: [.init(channels: [0])])])

private func render(_ stems: [MultitrackStem], seconds: Double) -> [Float] {
    let engine = MultitrackEngine(sampleRate: 48_000, deviceChannels: 1)
    engine.setRouting(routing)
    engine.cue(MultitrackSong(id: "song", stems: stems))
    engine.play()
    var out: [Float] = []
    let buffer = 333
    let storage = UnsafeMutablePointer<Float>.allocate(capacity: buffer)
    let pointers = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: 1)
    defer { storage.deallocate(); pointers.deallocate() }
    pointers[0] = storage
    let total = Int(seconds * 48_000)
    while out.count < total {
        engine.tickNow()
        let count = min(buffer, total - out.count)
        engine.renderer.render(frames: count, hostTime: 0, outputs: pointers)
        out += Array(UnsafeBufferPointer(start: storage, count: count))
    }
    return out
}

private func at(_ seconds: Double) -> Int { Int((seconds * 48_000).rounded()) }

private func biggestStep(_ samples: [Float]) -> Float {
    zip(samples, samples.dropFirst()).map { abs($1 - $0) }.max() ?? 0
}

@Test(arguments: ClipEnvelope.Shape.allCases)
func eachFadeShapeComesOutOnItsCurve(shape: ClipEnvelope.Shape) throws {
    let path = try file("flat-\(shape)", seconds: 3) { _ in 0.5 }
    let fadeIn = ClipEnvelope.Fade(seconds: 1, shape: shape)
    let fadeOut = ClipEnvelope.Fade(seconds: 1, shape: shape, midpoint: 0.25)
    let stem = MultitrackStem(
        path: path, channelId: "x", duration: 3, envelope: ClipEnvelope(fadeIn: fadeIn, fadeOut: fadeOut, edge: 0))
    let out = render([stem], seconds: 3)
    for x in [0.1, 0.25, 0.5, 0.75, 0.9] {
        let rising = 0.5 * fadeIn.level(x)
        #expect(abs(Double(out[at(x)]) - rising) < 0.002, "\(shape) in at \(x): \(out[at(x)]) vs \(rising)")

        let falling = 0.5 * fadeOut.level(x, out: true)
        #expect(abs(Double(out[at(3 - x)]) - falling) < 0.002, "\(shape) out at \(x): \(out[at(3 - x)]) vs \(falling)")
    }

    #expect(abs(out[at(1.5)] - 0.5) < 1e-6)
    #expect(abs(out[at(0)]) < 1e-3)
}

@Test func theShapesAreWhatTheirNamesSay() {
    #expect(ClipEnvelope.Shape.linear.rising(0.5) == 0.5)
    #expect(abs(ClipEnvelope.Shape.sCurve.rising(0.5) - 0.5) < 1e-9)
    #expect(ClipEnvelope.Shape.sCurve.rising(0.1) < 0.1)

    for x in stride(from: 0.0, through: 1, by: 0.1) {
        let fade = ClipEnvelope.Fade(seconds: 1, shape: .equalPower)
        let incoming = fade.level(x), outgoing = fade.level(1 - x, out: true)
        #expect(abs(incoming * incoming + outgoing * outgoing - 1) < 1e-9)
    }

    #expect(ClipEnvelope.Fade(seconds: 1, shape: .fast).level(0.25) > 0.25)
    #expect(ClipEnvelope.Fade(seconds: 1, shape: .fast).level(0.75, out: true) < 0.75)
    #expect(ClipEnvelope.Fade(seconds: 1, shape: .slow).level(0.25) < 0.25)

    #expect(abs(ClipEnvelope.Fade(seconds: 1, midpoint: 0.25).level(0.25) - 0.5) < 1e-9)
    #expect(abs(ClipEnvelope.Fade(seconds: 1, midpoint: 0.25).level(0.75, out: true) - 0.5) < 1e-9)
}

@Test func twoClipsOnOneChannelCrossfade() throws {

    let a = try file("a", seconds: 3) { _ in 0.5 }
    let b = try file("b", seconds: 3) { $0 == at(0.25) ? 1 : 0.5 }
    let fade = ClipEnvelope.Fade(seconds: 0.5, shape: .equalPower)
    let out = render([
        MultitrackStem(path: a, channelId: "x", duration: 2, envelope: ClipEnvelope(fadeOut: fade)),
        MultitrackStem(path: b, channelId: "x", at: 1.5, duration: 1.5, envelope: ClipEnvelope(fadeIn: fade)),
    ], seconds: 3)
    #expect(abs(out[at(1)] - 0.5) < 1e-6)

    #expect(abs(out[at(1.75) - 1] - Float(0.5 * 2 * sin(Double.pi / 4))) < 0.003)
    #expect(abs(out[at(2.25)] - 0.5) < 1e-6)

    let beat = out[at(1.75)] - out[at(1.75) - 1]
    #expect(abs(beat - Float(0.5 * sin(Double.pi / 4))) < 0.01, "beat \(beat)")
    #expect(biggestStep(Array(out[at(1.4) ..< at(1.74)])) < 0.002)
}

@Test func edgeFadesMoveNoBeat() throws {

    let path = try file("beat", seconds: 3) { $0 == at(1.25) ? 1 : 0.5 }
    let stem = MultitrackStem(path: path, channelId: "x", at: 0.5, inPoint: 0.25, duration: 1.5, envelope: ClipEnvelope())
    let out = render([stem], seconds: 2.5)
    let peak = out.indices.max { out[$0] < out[$1] }!
    #expect(peak == at(1.5))
    #expect(out[peak] == 1)
    #expect(out[at(0.5)] == 0)
    #expect(abs(out[at(0.5025)] - 0.25) < 0.005)
    #expect(abs(out[at(0.505)] - 0.5) < 1e-6)
    #expect(abs(out[at(1.9975)] - 0.25) < 0.005)
    #expect(out[at(2.0)] == 0)

    #expect(biggestStep(Array(out[0 ..< at(1.4)])) <= 0.5 / 240 + 1e-4)

    let bare = render([MultitrackStem(path: path, channelId: "x", at: 0.5, inPoint: 0.25, duration: 1.5)], seconds: 1)
    #expect(bare[at(0.5)] == 0.5)
}

@Test func shapeNamesMatchTheSchemas() {

    #expect(ClipEnvelope.Shape.allCases.map(\.rawValue) == ["linear", "sCurve", "equalPower", "fast", "slow"])
}
