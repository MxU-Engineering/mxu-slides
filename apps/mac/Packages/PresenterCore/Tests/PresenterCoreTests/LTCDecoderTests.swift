import Foundation
import Testing
@testable import PresenterCore

enum LTCSignal {
    static let sampleRate = 48_000.0

    static func bits(_ label: TimecodeLabel, dropFrame: Bool = false) -> [Bool] {
        var bits = [Bool](repeating: false, count: 80)
        func put(_ value: Int, at start: Int, width: Int) {
            for i in 0..<width { bits[start + i] = (value >> i) & 1 == 1 }
        }
        put(label.frames % 10, at: 0, width: 4)
        put(label.frames / 10, at: 8, width: 2)
        bits[10] = dropFrame
        put(label.seconds % 10, at: 16, width: 4)
        put(label.seconds / 10, at: 24, width: 3)
        put(label.minutes % 10, at: 32, width: 4)
        put(label.minutes / 10, at: 40, width: 3)
        put(label.hours % 10, at: 48, width: 4)
        put(label.hours / 10, at: 56, width: 2)
        for (offset, bit) in [0, 0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 1].enumerated() {
            bits[64 + offset] = bit == 1
        }
        return bits
    }

    static func label(_ n: Int, nominal: Int) -> TimecodeLabel {
        let seconds = n / nominal
        return TimecodeLabel(hours: seconds / 3600, minutes: seconds / 60 % 60, seconds: seconds % 60, frames: n % nominal)
    }

    struct Writer {
        var fps: Double
        var amplitude: Float = 0.125
        var samples: [Float] = []
        private var level: Float = 1
        private var clock = 0.0

        init(fps: Double, amplitude: Float = 0.125) {
            self.fps = fps
            self.amplitude = amplitude
        }

        mutating func frames(_ labels: [TimecodeLabel], dropFrame: Bool = false, reverse: Bool = false) {
            for label in labels {
                var cells = LTCSignal.bits(label, dropFrame: dropFrame)
                if reverse { cells.reverse() }
                for bit in cells {
                    let cell = LTCSignal.sampleRate / (80 * fps)
                    level = -level
                    if bit {
                        write(cell / 2)
                        level = -level
                        write(cell / 2)
                    } else {
                        write(cell)
                    }
                }
            }
        }

        mutating func silence(_ seconds: Double) {
            samples += [Float](repeating: 0, count: Int(seconds * LTCSignal.sampleRate))
        }

        private mutating func write(_ duration: Double) {
            let end = clock + duration
            let count = Int(end.rounded()) - Int(clock.rounded())
            samples += [Float](repeating: level * amplitude, count: count)
            clock = end
        }
    }

    static func fixture(_ name: String) throws -> [Float] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/ltc/\(name).wav")
        let data = try Data(contentsOf: url)

        var offset = 12
        while offset + 8 <= data.count {
            let id = String(decoding: data[offset..<offset + 4], as: UTF8.self)
            let size = data[offset + 4..<offset + 8].withUnsafeBytes { Int($0.loadUnaligned(as: UInt32.self)) }
            if id == "data" {
                return data[offset + 8..<min(offset + 8 + size, data.count)].withUnsafeBytes { raw in
                    raw.bindMemory(to: Int16.self).map { Float($0) / 32768 }
                }
            }
            offset += 8 + size + size % 2
        }
        throw CocoaError(.fileReadCorruptFile)
    }

    static func decode(_ signal: [Float], chunk: Int = 1024) -> (frames: [LTCFrame], decoder: LTCDecoder) {
        let samples = signal + [Float](repeating: 0, count: 2400)
        var decoder = LTCDecoder(sampleRate: sampleRate)
        var frames: [LTCFrame] = []
        var start = 0
        while start < samples.count {
            let end = min(start + chunk, samples.count)
            frames += samples[start..<end].withUnsafeBufferPointer { decoder.decode($0) }
            start = end
        }
        return (frames, decoder)
    }
}

@Suite struct LTCDecoderTests {
    private func texts(_ frames: [LTCFrame]) -> [String] {
        frames.map { $0.label.text() }
    }

    @Test func readsLtcgenAtEveryRate() throws {
        let cases: [(String, String, String, TimecodeRate)] = [
            ("ltc-24", "10:00:00:00", "10:00:00:11", .fps24),
            ("ltc-25", "02:30:00:00", "02:30:00:11", .fps25),
            ("ltc-30", "01:00:00:00", "01:00:00:11", .fps30),
        ]
        for (name, first, last, rate) in cases {
            let (frames, decoder) = LTCSignal.decode(try LTCSignal.fixture(name))
            #expect(frames.count == 12, "\(name)")
            #expect(texts(frames).first == first, "\(name)")
            #expect(texts(frames).last == last, "\(name)")
            #expect(frames.allSatisfy { !$0.reverse && !$0.dropFrame }, "\(name)")
            #expect(decoder.rate == rate, "\(name)")
        }
    }

    @Test func readsDropFrameAcrossTheMinute() throws {
        let (frames, decoder) = LTCSignal.decode(try LTCSignal.fixture("ltc-2997df"))

        #expect(texts(frames) == [
            "00:00:59:25", "00:00:59:26", "00:00:59:27", "00:00:59:28", "00:00:59:29",
            "00:01:00:02", "00:01:00:03", "00:01:00:04", "00:01:00:05", "00:01:00:06", "00:01:00:07", "00:01:00:08",
        ])
        #expect(frames.allSatisfy { $0.dropFrame })
        #expect(decoder.rate == .fps2997DropFrame)
        let rate = TimecodeRate.fps2997DropFrame
        #expect(rate.frameNumber(frames[5].label) == rate.frameNumber(frames[4].label) + 1)
    }

    @Test func readsQuietSignalAt36dBDown() throws {
        let (frames, _) = LTCSignal.decode(try LTCSignal.fixture("ltc-30-quiet36"))
        #expect(texts(frames).first == "03:00:00:00")
        #expect(frames.count == 12)
    }

    @Test func readsReverseAndSaysSo() throws {
        let (frames, _) = LTCSignal.decode(try LTCSignal.fixture("ltc-30-reverse"))
        #expect(frames.count >= 10)
        #expect(frames.allSatisfy { $0.reverse })

        #expect(Array(texts(frames).prefix(3)) == ["01:00:10:00", "01:00:09:29", "01:00:09:28"])
    }

    @Test func chunkSizeDoesNotMatter() throws {
        let samples = try LTCSignal.fixture("ltc-25")
        #expect(texts(LTCSignal.decode(samples, chunk: 1).frames) == texts(LTCSignal.decode(samples, chunk: 4096).frames))
    }

    @Test func ownWriterMatchesTheReference() {
        var writer = LTCSignal.Writer(fps: 30)
        writer.frames((108_000..<108_012).map { LTCSignal.label($0, nominal: 30) })
        let frames = LTCSignal.decode(writer.samples).frames
        #expect(texts(frames).first == "01:00:00:00")
        #expect(frames.count == 12)

        #expect(frames[5].endSample - frames[4].endSample == 1600)
    }

    @Test func tellsThirtyFromTwentyNineNineSeven() {
        for (fps, rate) in [(30.0, TimecodeRate.fps30), (30000.0 / 1001, .fps2997)] {
            var writer = LTCSignal.Writer(fps: fps)
            writer.frames((0..<90).map { LTCSignal.label($0, nominal: 30) })
            #expect(LTCSignal.decode(writer.samples).decoder.rate == rate)
        }
    }

    @Test func survivesDropoutsAndJumps() {
        var writer = LTCSignal.Writer(fps: 30)
        writer.frames((0..<10).map { LTCSignal.label($0, nominal: 30) })
        writer.silence(0.3)
        writer.frames((10..<20).map { LTCSignal.label($0, nominal: 30) })

        writer.frames((620..<630).map { LTCSignal.label($0, nominal: 30) })
        let frames = LTCSignal.decode(writer.samples).frames
        let numbers = frames.map { TimecodeRate.fps30.frameNumber($0.label) }

        #expect(Array(numbers.prefix(10)) == Array(0..<10))
        #expect(numbers.contains(19))
        #expect(Array(numbers.suffix(10)) == Array(620..<630))
    }

    @Test func silenceAndHumBelowTheGateReadNothing() {
        var writer = LTCSignal.Writer(fps: 30, amplitude: 0.001)
        writer.frames((0..<20).map { LTCSignal.label($0, nominal: 30) })
        #expect(LTCSignal.decode(writer.samples).frames.isEmpty)
        #expect(LTCSignal.decode([Float](repeating: 0, count: 48_000)).frames.isEmpty)
    }

    @Test func noiseOnAQuietSignal() {
        var writer = LTCSignal.Writer(fps: 25, amplitude: 0.016)
        writer.frames((0..<25).map { LTCSignal.label($0, nominal: 25) })

        var seed: UInt32 = 1
        let noisy = writer.samples.map { sample -> Float in
            seed = seed &* 1_664_525 &+ 1_013_904_223
            return sample + (Float(seed >> 8) / Float(1 << 24) - 0.5) * 0.002
        }
        #expect(LTCSignal.decode(noisy).frames.count >= 24)
    }

    @Test func labelsFromFrameNumbersRoundTrip() {
        for rate in TimecodeRate.allCases {
            for n in [0, 1, 1_797, 1_798, 1_800, 17_981, 17_982, 107_892, 107_999, 2_000_000] {
                #expect(rate.frameNumber(rate.label(frameNumber: n)) == n, "\(rate) \(n)")
            }
        }

        #expect(TimecodeRate.fps2997DropFrame.label(frameNumber: 1_800).text(dropFrame: true) == "00:01:00;02")
        #expect(TimecodeRate.fps25.label(seconds: 3600.5) == TimecodeLabel(hours: 1, minutes: 0, seconds: 0, frames: 12))
    }

    @Test func secondsFromLabels() {
        let label = TimecodeLabel(hours: 1, minutes: 0, seconds: 0, frames: 15)
        #expect(TimecodeRate.fps30.seconds(label) == 3600.5)
        #expect(TimecodeRate.fps25.seconds(label) == 3600.6)

        #expect(abs(TimecodeRate.fps2997.seconds(label) - 108_015 / (30000.0 / 1001)) < 1e-9)

        let hour = TimecodeLabel(hours: 1, minutes: 0, seconds: 0, frames: 0)
        #expect(abs(TimecodeRate.fps2997DropFrame.seconds(hour) - 3600) < 0.01)

        #expect(TimecodeRate.fps25.label(startFrames: 108_015) == label.with(frames: 12))
        #expect(label.text() == "01:00:00:15")
        #expect(label.text(dropFrame: true) == "01:00:00;15")
    }
}

extension TimecodeLabel {
    func with(frames: Int) -> TimecodeLabel {
        var copy = self
        copy.frames = frames
        return copy
    }
}
