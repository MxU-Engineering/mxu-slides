import Foundation

public enum TimecodeRate: String, CaseIterable, Sendable {
    case fps24, fps25, fps2997, fps2997DropFrame, fps30

    public var nominal: Int {
        switch self {
        case .fps24: 24
        case .fps25: 25
        case .fps2997, .fps2997DropFrame, .fps30: 30
        }
    }

    public var actual: Double {
        switch self {
        case .fps2997, .fps2997DropFrame: 30000.0 / 1001.0
        default: Double(nominal)
        }
    }

    public var title: String {
        switch self {
        case .fps24: "24 fps"
        case .fps25: "25 fps"
        case .fps2997: "29.97 fps"
        case .fps2997DropFrame: "29.97 fps drop-frame"
        case .fps30: "30 fps"
        }
    }

    public func frameNumber(_ label: TimecodeLabel) -> Int {
        let labelled = ((label.hours * 60 + label.minutes) * 60 + label.seconds) * nominal + label.frames
        guard self == .fps2997DropFrame else { return labelled }
        let minutes = label.hours * 60 + label.minutes
        return labelled - 2 * (minutes - minutes / 10)
    }

    public func label(frameNumber: Int) -> TimecodeLabel {
        var n = max(frameNumber, 0)
        if self == .fps2997DropFrame {
            let tens = n / 17_982, rest = n % 17_982
            n += 18 * tens + (rest < 2 ? 0 : 2 * ((rest - 2) / 1_798))
        }
        let seconds = n / nominal
        return TimecodeLabel(
            hours: seconds / 3600 % 24, minutes: seconds / 60 % 60, seconds: seconds % 60, frames: n % nominal)
    }

    public func label(seconds: Double) -> TimecodeLabel {
        label(frameNumber: Int((seconds * actual + 1e-6).rounded(.down)))
    }

    public func seconds(_ label: TimecodeLabel) -> Double {
        Double(frameNumber(label)) / actual
    }

    public func label(startFrames: Int) -> TimecodeLabel {
        let fps = PresentationTimelines.framesPerSecond
        let total = max(startFrames, 0)
        let seconds = total / fps
        return TimecodeLabel(
            hours: seconds / 3600, minutes: seconds / 60 % 60, seconds: seconds % 60,
            frames: total % fps * nominal / fps)
    }
}

public struct TimecodeLabel: Equatable, Hashable, Sendable {
    public var hours: Int
    public var minutes: Int
    public var seconds: Int
    public var frames: Int

    public init(hours: Int, minutes: Int, seconds: Int, frames: Int) {
        self.hours = hours
        self.minutes = minutes
        self.seconds = seconds
        self.frames = frames
    }

    public func text(dropFrame: Bool = false) -> String {
        String(format: "%02d:%02d:%02d%@%02d", hours, minutes, seconds, dropFrame ? ";" : ":", frames)
    }
}

public struct LTCFrame: Equatable, Sendable {
    public var label: TimecodeLabel

    public var dropFrame: Bool

    public var reverse: Bool

    public var endSample: Int

    public init(label: TimecodeLabel, dropFrame: Bool = false, reverse: Bool = false, endSample: Int = 0) {
        self.label = label
        self.dropFrame = dropFrame
        self.reverse = reverse
        self.endSample = endSample
    }
}

public struct LTCDecoder: Sendable {
    public let sampleRate: Double

    private var dc: Float = 0
    private var envelope: Float = 0
    private var high = false

    private var idle = true

    static let gate: Float = 0.003

    private var sinceEdge = 0

    private var period: Double
    private let minPeriod: Double
    private let maxPeriod: Double
    private var halfBit = false

    private var cellOpen = false

    private var older: UInt64 = 0
    private var newer: UInt16 = 0
    private var bitCount = 0

    public private(set) var sampleCount = 0

    private var lastForward: LTCFrame?
    private var samplesPerFrame: Double = 0
    private var measuredFrames = 0
    private var highestFrameLabel = 0

    public private(set) var rate: TimecodeRate?

    static let forwardSync: UInt16 = 0xBFFC
    static let reverseSync: UInt64 = 0x3FFD

    public init(sampleRate: Double) {
        self.sampleRate = sampleRate

        period = sampleRate / (80 * 27)
        minPeriod = sampleRate / (80 * 40)
        maxPeriod = sampleRate / (80 * 18)
    }

    public mutating func decode(_ samples: UnsafeBufferPointer<Float>) -> [LTCFrame] {
        var frames: [LTCFrame] = []

        let decay: Float = Float(pow(0.5, 1 / (0.02 * sampleRate)))
        let dcRate: Float = Float(1 / (0.05 * sampleRate))
        for sample in samples {
            sampleCount += 1
            sinceEdge += 1

            if cellOpen, Double(sinceEdge) > period * 1.5 {
                cellOpen = false
                idle = true
                let bit: UInt16 = halfBit ? 1 : 0
                halfBit = false
                if let frame = push(bit) { frames.append(frame) }
            }
            dc += (sample - dc) * dcRate
            let value = sample - dc
            if abs(value) > envelope * 4, abs(value) > Self.gate * 4 {

                idle = true
                cellOpen = false
                halfBit = false
            }
            envelope = max(abs(value), envelope * decay)
            guard envelope > Self.gate else {
                halfBit = false
                idle = true
                continue
            }

            let threshold = envelope * 0.33
            if high, value < -threshold {
                high = false
            } else if !high, value > threshold {
                high = true
            } else if idle, abs(value) > threshold {

                high = value > 0
            } else {
                continue
            }
            idle = false

            if cellOpen, Double(sinceEdge) < period * 0.3 { continue }
            if let frame = edge(after: sinceEdge) { frames.append(frame) }
            sinceEdge = 0
        }
        return frames
    }

    private mutating func edge(after interval: Int) -> LTCFrame? {
        let gap = Double(interval)

        defer { cellOpen = true }

        guard cellOpen, gap < period * 2.5 else {
            halfBit = false
            return nil
        }
        if gap > period * 0.75 {

            halfBit = false
            period = min(max((period * 3 + gap) / 4, minPeriod), maxPeriod)
            return push(0)
        }
        period = min(max((period * 3 + gap * 2) / 4, minPeriod), maxPeriod)
        if halfBit {
            halfBit = false
            return push(1)
        }
        halfBit = true
        return nil
    }

    private mutating func push(_ bit: UInt16) -> LTCFrame? {
        older = (older >> 1) | (UInt64(newer & 1) << 63)
        newer = (newer >> 1) | (bit << 15)
        bitCount += 1
        guard bitCount >= 80 else { return nil }
        if newer == Self.forwardSync {
            return frame(data: older, reverse: false)
        }
        if older & 0xFFFF == Self.reverseSync {

            var data: UInt64 = 0
            for bit in 0..<64 where registerBit(79 - bit) {
                data |= 1 << UInt64(bit)
            }
            return frame(data: data, reverse: true)
        }
        return nil
    }

    private func registerBit(_ index: Int) -> Bool {
        index < 64 ? (older >> UInt64(index)) & 1 == 1 : (newer >> UInt16(index - 64)) & 1 == 1
    }

    private mutating func frame(data: UInt64, reverse: Bool) -> LTCFrame? {
        func field(_ start: Int, _ width: Int) -> Int {
            Int((data >> UInt64(start)) & ((1 << UInt64(width)) - 1))
        }
        let units = [field(0, 4), field(16, 4), field(32, 4), field(48, 4)]
        guard units.allSatisfy({ $0 <= 9 }) else { return nil }
        let label = TimecodeLabel(
            hours: field(56, 2) * 10 + units[3], minutes: field(40, 3) * 10 + units[2],
            seconds: field(24, 3) * 10 + units[1], frames: field(8, 2) * 10 + units[0])
        guard label.hours < 24, label.minutes < 60, label.seconds < 60, label.frames < 30 else { return nil }
        bitCount = 0
        let decoded = LTCFrame(label: label, dropFrame: field(10, 1) == 1, reverse: reverse, endSample: sampleCount)
        detectRate(decoded)
        return decoded
    }

    private mutating func detectRate(_ frame: LTCFrame) {
        defer { lastForward = frame.reverse ? nil : frame }
        highestFrameLabel = max(highestFrameLabel, frame.label.frames)
        if let last = lastForward, !frame.reverse {
            let samples = Double(frame.endSample - last.endSample)

            if samples > period * 60, samples < period * 100 {
                measuredFrames += 1
                let weight = 1 / Double(min(measuredFrames, 128))
                samplesPerFrame += (samples - samplesPerFrame) * weight
            }
        }
        if frame.dropFrame {
            rate = .fps2997DropFrame
        } else if measuredFrames >= 8 {
            let fps = sampleRate / samplesPerFrame

            rate = fps < 24.5 ? .fps24 : fps < 27.5 ? .fps25 : measuredFrames >= 60 && fps < 29.985 ? .fps2997 : .fps30
        } else {
            rate = highestFrameLabel >= 25 ? .fps30 : highestFrameLabel == 24 ? .fps25 : rate ?? .fps30
        }
    }
}
