import Foundation

public enum TimecodeSource: String, Sendable {

    case ltc

    case mtc
}

public struct TimecodeHeard: Equatable, Sendable {
    public var label: TimecodeLabel
    public var rate: TimecodeRate
    public var reverse: Bool

    public var position: Double

    public var hostTime: Double

    public init(label: TimecodeLabel, rate: TimecodeRate, reverse: Bool = false, position: Double, hostTime: Double) {
        self.label = label
        self.rate = rate
        self.reverse = reverse
        self.position = position
        self.hostTime = hostTime
    }

    public init(ltc frame: LTCFrame, rate: TimecodeRate, hostTime: Double) {
        self.init(
            label: frame.label, rate: rate, reverse: frame.reverse,
            position: rate.seconds(frame.label) + (frame.reverse ? 0 : 1 / rate.actual), hostTime: hostTime)
    }

    func position(at time: Double) -> Double {
        position + (time - hostTime) * (reverse ? -1 : 1)
    }

    func continues(_ next: TimecodeHeard) -> Bool {
        next.reverse == reverse && next.rate.nominal == rate.nominal
            && abs(next.position - position(at: next.hostTime)) <= 1.5 / rate.actual
    }
}

public struct MTCDecoder: Sendable {

    private var pieces = [Int](repeating: 0, count: 8)
    private var lastPiece: Int?
    private var reverse = false

    private var run = 0

    private var quarterFramePending = false

    private var sysex: [UInt8]?

    public init() {}

    public static func rate(code: Int) -> TimecodeRate {
        switch code & 3 {
        case 0: .fps24
        case 1: .fps25
        case 2: .fps2997DropFrame
        default: .fps30
        }
    }

    public mutating func receive(_ bytes: [UInt8], hostTime: Double) -> [TimecodeHeard] {
        var heard: [TimecodeHeard] = []
        for byte in bytes {
            if byte >= 0xF8 { continue }
            if quarterFramePending {
                quarterFramePending = false
                if byte < 0x80 {
                    if let frame = quarterFrame(byte, hostTime: hostTime) { heard.append(frame) }
                    continue
                }
            }
            if var message = sysex {
                if byte == 0xF7 {
                    sysex = nil
                    if let frame = fullFrame(message, hostTime: hostTime) { heard.append(frame) }
                    continue
                }
                if byte < 0x80 {
                    message.append(byte)
                    sysex = message.count > 16 ? nil : message
                    continue
                }
                sysex = nil
            }
            switch byte {
            case 0xF0: sysex = []
            case 0xF1: quarterFramePending = true
            default: break
            }
        }
        return heard
    }

    private mutating func quarterFrame(_ data: UInt8, hostTime: Double) -> TimecodeHeard? {
        let piece = Int(data >> 4)
        pieces[piece] = Int(data & 0x0F)
        defer { lastPiece = piece }
        guard let last = lastPiece else {
            run = 1
            return nil
        }
        let forward = piece == (last + 1) % 8
        if forward || piece == (last + 7) % 8 {
            run = reverse == !forward ? run + 1 : 2
            reverse = !forward
        } else {
            run = 1
        }
        guard run >= 8, piece == (reverse ? 0 : 7) else { return nil }
        let rate = Self.rate(code: pieces[7] >> 1)
        let label = TimecodeLabel(
            hours: pieces[6] | (pieces[7] & 1) << 4, minutes: pieces[4] | (pieces[5] & 3) << 4,
            seconds: pieces[2] | (pieces[3] & 3) << 4, frames: pieces[0] | (pieces[1] & 1) << 4)
        guard Self.valid(label, rate) else { return nil }

        let quarters = reverse ? 0.0 : 7.0
        let now = reverse ? label : rate.label(frameNumber: rate.frameNumber(label) + 2)
        return TimecodeHeard(
            label: now, rate: rate, reverse: reverse,
            position: rate.seconds(label) + quarters / 4 / rate.actual, hostTime: hostTime)
    }

    private mutating func fullFrame(_ message: [UInt8], hostTime: Double) -> TimecodeHeard? {
        guard message.count == 8, message[0] == 0x7F, message[2] == 0x01, message[3] == 0x01 else { return nil }
        let rate = Self.rate(code: Int(message[4]) >> 5)
        let label = TimecodeLabel(
            hours: Int(message[4]) & 0x1F, minutes: Int(message[5]), seconds: Int(message[6]), frames: Int(message[7]))
        guard Self.valid(label, rate) else { return nil }
        lastPiece = nil
        run = 0
        return TimecodeHeard(label: label, rate: rate, position: rate.seconds(label), hostTime: hostTime)
    }

    private static func valid(_ label: TimecodeLabel, _ rate: TimecodeRate) -> Bool {
        label.hours < 24 && label.minutes < 60 && label.seconds < 60 && label.frames < rate.nominal
    }
}
