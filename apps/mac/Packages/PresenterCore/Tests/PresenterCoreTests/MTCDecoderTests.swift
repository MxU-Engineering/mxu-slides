import Foundation
import Testing
@testable import PresenterCore

enum MTCSignal {
    static func code(_ rate: TimecodeRate) -> Int {
        switch rate {
        case .fps24: 0
        case .fps25: 1
        case .fps2997DropFrame: 2
        default: 3
        }
    }

    static func pieces(_ label: TimecodeLabel, rate: TimecodeRate) -> [UInt8] {
        let values = [
            label.frames & 0xF, label.frames >> 4, label.seconds & 0xF, label.seconds >> 4,
            label.minutes & 0xF, label.minutes >> 4, label.hours & 0xF, label.hours >> 4 | code(rate) << 1,
        ]
        return values.enumerated().map { UInt8($0.offset << 4 | $0.element) }
    }

    static func play(
        from: Int, frames count: Int, rate: TimecodeRate, start: Double = 10, reverse: Bool = false
    ) -> [(bytes: [UInt8], time: Double)] {
        var packets: [(bytes: [UInt8], time: Double)] = []
        var quarter = 0
        for pair in 0..<count / 2 {
            let number = reverse ? from - 2 * pair : from + 2 * pair
            let pieces = pieces(rate.label(frameNumber: number), rate: rate)
            for piece in reverse ? Array(pieces.reversed()) : pieces {
                packets.append(([0xF1, piece], start + Double(quarter) / 4 / rate.actual))
                quarter += 1
            }
        }
        return packets
    }

    static func fullFrame(_ label: TimecodeLabel, rate: TimecodeRate, device: UInt8 = 0x7F) -> [UInt8] {
        [0xF0, 0x7F, device, 0x01, 0x01, UInt8(code(rate) << 5 | label.hours), UInt8(label.minutes),
         UInt8(label.seconds), UInt8(label.frames), 0xF7]
    }

    static func decode(_ decoder: inout MTCDecoder, _ packets: [(bytes: [UInt8], time: Double)]) -> [TimecodeHeard] {
        packets.flatMap { decoder.receive($0.bytes, hostTime: $0.time) }
    }
}

@Suite struct MTCDecoderTests {
    @Test(arguments: [TimecodeRate.fps24, .fps25, .fps2997DropFrame, .fps30])
    func quarterFramesAssembleAtEveryRate(rate: TimecodeRate) throws {

        let start = rate.frameNumber(TimecodeLabel(hours: 1, minutes: 2, seconds: 3, frames: rate.nominal - 3))
        var decoder = MTCDecoder()
        let packets = MTCSignal.play(from: start, frames: 6, rate: rate)
        let heard = MTCSignal.decode(&decoder, packets)
        #expect(heard.count == 3)
        let first = try #require(heard.first)
        #expect(first.rate == rate)
        #expect(!first.reverse)

        #expect(first.label == rate.label(frameNumber: start + 2))

        #expect(first.hostTime == packets[7].time)
        #expect(abs(first.position - (rate.seconds(rate.label(frameNumber: start)) + 1.75 / rate.actual)) < 1e-9)
        #expect(heard[1].label == rate.label(frameNumber: start + 4))
    }

    @Test func joiningMidFrameWaitsForAWholeOne() {
        var decoder = MTCDecoder()

        let packets = Array(MTCSignal.play(from: 300, frames: 4, rate: .fps30).dropFirst(3))
        let heard = MTCSignal.decode(&decoder, packets)
        #expect(heard.map(\.label) == [TimecodeRate.fps30.label(frameNumber: 304)])
    }

    @Test func aMissingPieceDropsThatFrameOnly() {
        var decoder = MTCDecoder()
        var packets = MTCSignal.play(from: 300, frames: 6, rate: .fps30)
        packets.remove(at: 4)
        let heard = MTCSignal.decode(&decoder, packets)

        #expect(heard.map(\.label) == [302, 304].map { TimecodeRate.fps30.label(frameNumber: $0 + 2) })
    }

    @Test func backwardsPiecesAssembleReversed() throws {
        var decoder = MTCDecoder()
        let heard = MTCSignal.decode(&decoder, MTCSignal.play(from: 900, frames: 4, rate: .fps25, reverse: true))
        let first = try #require(heard.first)
        #expect(first.reverse)
        #expect(first.label == TimecodeRate.fps25.label(frameNumber: 900))
        #expect(abs(first.position - 900.0 / 25) < 1e-9)
        #expect(heard.count == 2)
    }

    @Test func fullFrameLocates() throws {
        var decoder = MTCDecoder()
        let label = TimecodeLabel(hours: 2, minutes: 0, seconds: 30, frames: 12)
        let heard = decoder.receive(MTCSignal.fullFrame(label, rate: .fps25, device: 0x00), hostTime: 5)
        let frame = try #require(heard.first)
        #expect(frame == TimecodeHeard(label: label, rate: .fps25, position: TimecodeRate.fps25.seconds(label), hostTime: 5))

        let bytes = MTCSignal.fullFrame(label, rate: .fps30)
        #expect(decoder.receive(Array(bytes[0..<4]) + [0xF8], hostTime: 6).isEmpty)
        #expect(decoder.receive(Array(bytes[4...]), hostTime: 6).first?.rate == .fps30)

        #expect(decoder.receive([0xF0, 0x7E, 0x7F, 0x06, 0x01, 0xF7], hostTime: 7).isEmpty)
    }

    @Test func notesAndClockInTheSamePacketsLeaveBothReadersAlone() {
        var decoder = MTCDecoder()
        var heard: [TimecodeHeard] = []
        var notes: [MIDIParse.ChannelMessage] = []
        for (index, packet) in MTCSignal.play(from: 60, frames: 2, rate: .fps30).enumerated() {

            let bytes = [0x90, 19, UInt8(index + 1), 0xF8] + packet.bytes
            heard += decoder.receive(bytes, hostTime: packet.time)
            notes += MIDIParse.channelMessages(in: bytes)
        }
        #expect(heard.count == 1)
        #expect(notes.count == 8)
        #expect(notes.allSatisfy { $0.status == 0x90 && $0.data1 == 19 })
    }

    @Test func aQuarterFrameSplitAcrossPacketsStillCounts() {
        var decoder = MTCDecoder()
        var heard: [TimecodeHeard] = []
        for packet in MTCSignal.play(from: 60, frames: 2, rate: .fps30) {
            heard += decoder.receive([packet.bytes[0]], hostTime: packet.time)
            heard += decoder.receive([packet.bytes[1]], hostTime: packet.time)
        }
        #expect(heard.count == 1)
    }
}

@Suite struct MTCClockTests {
    private func clock(_ packets: [(bytes: [UInt8], time: Double)], into clock: inout TimecodeClock, decoder: inout MTCDecoder) {
        for frame in MTCSignal.decode(&decoder, packets) { clock.receive(frame) }
    }

    @Test func playingMTCLocksAndTracks() throws {
        var clock = TimecodeClock()
        var decoder = MTCDecoder()
        let packets = MTCSignal.play(from: 3000, frames: 8, rate: .fps30)
        self.clock(packets, into: &clock, decoder: &decoder)
        let end = try #require(packets.last).time
        let reading = clock.reading(at: end)
        #expect(reading.state == .locked)
        #expect(reading.live)

        #expect(abs((reading.position ?? 0) - (3006 + 1.75) / 30) < 1e-9)
        #expect(reading.label == TimecodeRate.fps30.label(frameNumber: 3008))
    }

    @Test func stoppedMTCFreewheelsThenHolds() throws {
        var clock = TimecodeClock()
        var decoder = MTCDecoder()
        let packets = MTCSignal.play(from: 3000, frames: 8, rate: .fps24)
        self.clock(packets, into: &clock, decoder: &decoder)
        let end = try #require(packets.last).time
        #expect(clock.reading(at: end + 0.3).state == .freewheel)
        #expect(!clock.reading(at: end + 0.3).live)
        #expect(clock.reading(at: end + 2).state == .stopped)
    }

    @Test func runningBackwardsHolds() throws {
        var clock = TimecodeClock()
        var decoder = MTCDecoder()
        let packets = MTCSignal.play(from: 3000, frames: 8, rate: .fps30, reverse: true)
        self.clock(packets, into: &clock, decoder: &decoder)
        let reading = clock.reading(at: try #require(packets.last).time)
        #expect(reading.reverse)
        #expect(!reading.live)
    }

    @Test func aLocateWhilePlayingIsAJumpOnceQuarterFramesFollow() throws {
        var clock = TimecodeClock()
        var decoder = MTCDecoder()
        let rate = TimecodeRate.fps30
        let before = MTCSignal.play(from: 3000, frames: 8, rate: rate)
        self.clock(before, into: &clock, decoder: &decoder)

        let at = try #require(before.last).time + 1 / 120
        for frame in decoder.receive(MTCSignal.fullFrame(rate.label(frameNumber: 9000), rate: rate), hostTime: at) {
            clock.receive(frame)
        }
        let after = MTCSignal.play(from: 9000, frames: 4, rate: rate, start: at)
        self.clock(after, into: &clock, decoder: &decoder)
        let reading = clock.reading(at: try #require(after.last).time)
        #expect(reading.state == .locked)
        #expect(abs((reading.position ?? 0) - (9002 + 1.75) / 30) < 1e-9)
    }

    @Test func mtcDrivesTheSameResolverAsLTC() throws {

        let rate = TimecodeRate.fps25
        let songs = [TimecodeFollow.Song(itemID: "a", startFrames: 108_000, length: 60)]
        var clock = TimecodeClock()
        var decoder = MTCDecoder()
        var follow = TimecodeFollow()
        var commands: [TimecodeFollow.Command] = []
        for packet in MTCSignal.play(from: 3600 * 25 - 10, frames: 40, rate: rate) {
            for frame in decoder.receive(packet.bytes, hostTime: packet.time) { clock.receive(frame) }
            if let command = follow.step(clock.reading(at: packet.time), songs: songs) { commands.append(command) }
        }

        guard case .play(let id, let from, _) = try #require(commands.first) else {
            Issue.record("expected play, got \(commands)")
            return
        }
        #expect(id == "a")
        #expect(from < 0)
        #expect(commands.dropFirst().allSatisfy { if case .play = $0 { true } else { false } })
    }
}
