import AVFoundation

public enum AudioLevel {
    public typealias Reading = (rms: Float, peak: Float)

    public static func measureSides(_ buffer: AVAudioPCMBuffer) -> (left: Reading, right: Reading) {
        guard let data = buffer.floatChannelData, buffer.frameLength > 0 else {
            return ((0, 0), (0, 0))
        }
        let frames = Int(buffer.frameLength)
        func side(_ samples: UnsafeMutablePointer<Float>) -> Reading {
            var sumSquares: Float = 0
            var peak: Float = 0
            for frame in 0 ..< frames {
                let sample = samples[frame]
                sumSquares += sample * sample
                peak = max(peak, abs(sample))
            }
            return (min((sumSquares / Float(frames)).squareRoot(), 1), min(peak, 1))
        }
        let left = side(data[0])
        return (left, buffer.format.channelCount > 1 ? side(data[1]) : left)
    }

    public static func measure(_ buffer: AVAudioPCMBuffer) -> (rms: Float, peak: Float) {
        guard let data = buffer.floatChannelData, buffer.frameLength > 0 else {
            return (0, 0)
        }
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        var sumSquares: Float = 0
        var peak: Float = 0
        for channel in 0 ..< channels {
            let samples = data[channel]
            for frame in 0 ..< frames {
                let sample = samples[frame]
                sumSquares += sample * sample
                let magnitude = abs(sample)
                if magnitude > peak { peak = magnitude }
            }
        }
        let rms = (sumSquares / Float(frames * channels)).squareRoot()
        return (min(rms, 1), min(peak, 1))
    }

    public static func decibels(_ linear: Float) -> Float {
        guard linear > 0 else { return -.infinity }
        return 20 * log10(min(linear, 1))
    }

    static let floorDecibels: Float = -60
    static let kneeDecibels: Float = -24
    static let kneeFraction: Float = 0.38
    static let basementDecibels: Float = -90
    static let basementFraction: Float = 0.06

    public static func meterFraction(_ linear: Float) -> Float {
        guard linear > 0 else { return 0 }
        return meterFraction(decibels: decibels(linear))
    }

    public static func meterFraction(decibels db: Float) -> Float {
        guard db > -.infinity else { return 0 }
        let clamped = min(db, 0)
        if clamped >= kneeDecibels {
            return kneeFraction + (clamped - kneeDecibels) / -kneeDecibels
                * (1 - kneeFraction)
        }
        if clamped >= floorDecibels {
            return basementFraction + (clamped - floorDecibels)
                / (kneeDecibels - floorDecibels) * (kneeFraction - basementFraction)
        }
        guard clamped > basementDecibels else { return 0 }
        return (clamped - basementDecibels)
            / (floorDecibels - basementDecibels) * basementFraction
    }

    static let taperKneeDecibels: Float = -30
    static let taperKneeFraction: Float = 0.4
    static let plungeFraction: Float = 0.05

    public static func faderGain(fraction: Float) -> Float {
        let f = min(max(fraction, 0), 1)
        guard f > 0 else { return 0 }
        let db: Float
        if f >= taperKneeFraction {
            db = (f - 1) / (1 - taperKneeFraction) * -taperKneeDecibels
        } else if f >= plungeFraction {
            db = taperKneeDecibels - (taperKneeFraction - f)
                / (taperKneeFraction - plungeFraction)
                * (taperKneeDecibels - floorDecibels)
        } else {
            db = floorDecibels - (plungeFraction - f) / plungeFraction
                * (floorDecibels - basementDecibels)
        }
        return pow(10, db / 20)
    }

    public static func faderFraction(gain: Float) -> Float {
        guard gain > 0 else { return 0 }
        let db = decibels(gain)
        if db >= taperKneeDecibels {
            return 1 + db / -taperKneeDecibels * (1 - taperKneeFraction)
        }
        if db >= floorDecibels {
            return taperKneeFraction - (taperKneeDecibels - db)
                / (taperKneeDecibels - floorDecibels)
                * (taperKneeFraction - plungeFraction)
        }
        guard db > basementDecibels else { return 0 }
        return plungeFraction * (db - basementDecibels) / (floorDecibels - basementDecibels)
    }

    public static func faderGain(entry: String) -> Float? {
        let cleaned = entry
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "−", with: "-")
            .replacingOccurrences(of: "+", with: "")
        guard var db = Float(cleaned) else { return nil }
        if db > 0 { db = -db }
        guard db > basementDecibels else { return 0 }
        return pow(10, db / 20)
    }

    public static func combine(
        _ held: (rms: Float, peak: Float),
        adding level: (rms: Float, peak: Float),
        gain: Float = 1
    ) -> (rms: Float, peak: Float) {
        let rms = held.rms * held.rms + level.rms * gain * level.rms * gain
        return (
            min(rms.squareRoot(), 1),
            min(max(held.peak, level.peak * gain), 1)
        )
    }

    public static func combine(_ held: [Reading], adding sides: [Reading], gain: Float = 1) -> [Reading] {
        (0 ..< max(held.count, sides.count)).map { side in
            combine(
                side < held.count ? held[side] : (0, 0),
                adding: side < sides.count ? sides[side] : (0, 0), gain: gain)
        }
    }

    public static func outputLevels(
        _ mixes: [(level: [Reading], sends: [(outputId: String, gain: Float)])]
    ) -> [String: [Reading]] {
        var levels: [String: [Reading]] = [:]
        for mix in mixes {
            for send in mix.sends {
                levels[send.outputId] = combine(levels[send.outputId] ?? [], adding: mix.level, gain: send.gain)
            }
        }
        return levels
    }

    public static func mono(_ sides: [Reading]) -> Reading {
        guard sides.count > 1 else { return sides.first ?? (0, 0) }
        return ((sides[0].rms + sides[1].rms) / 2, (sides[0].peak + sides[1].peak) / 2)
    }

    public static func louder(_ sides: [Reading]) -> Reading {
        (sides.map(\.rms).max() ?? 0, sides.map(\.peak).max() ?? 0)
    }

    public static func placed(_ sides: [Reading], gain: Float, pan: Float = 0) -> [Reading] {
        let left = sides.first ?? (0, 0)
        let right = sides.count > 1 ? sides[1] : left
        let pan = min(max(pan, -1), 1)
        let leftGain = gain * min(1, 1 - pan)
        let rightGain = gain * min(1, 1 + pan)
        return [(left.rms * leftGain, left.peak * leftGain), (right.rms * rightGain, right.peak * rightGain)]
    }

    public static func deviceChannels(_ outputs: [(sides: [Reading], channels: [Int])]) -> [Int: Reading] {
        var levels: [Int: Reading] = [:]
        for output in outputs {
            let readings = output.channels.count == 1 ? [mono(output.sides)] : output.sides
            for (channel, reading) in zip(output.channels, readings) {
                levels[channel] = combine(levels[channel] ?? (0, 0), adding: reading)
            }
        }
        return levels
    }
}

extension AudioLevel {

    public static func channelLanding(
        sides: [Reading],
        channelGain: Float,
        pan: Float = 0,
        routedMix: String?,
        sends: [String: Float],
        mixGain: (String) -> Float
    ) -> [String: [Reading]] {
        var landing: [String: [Reading]] = [:]
        guard sides.contains(where: { $0.peak > 0 }) else { return landing }
        var targets = sends
        if let routedMix { targets[routedMix] = 1 }
        for (mixId, sendGain) in targets {
            let gain = channelGain * sendGain * mixGain(mixId)
            if gain > 0 {
                landing[mixId] = placed(sides, gain: gain, pan: pan)
            }
        }
        return landing
    }
}

public struct LevelWindow: Sendable {

    public private(set) var left: (rms: Float, peak: Float) = (0, 0)
    public private(set) var right: (rms: Float, peak: Float) = (0, 0)

    public init() {}

    public var rms: Float { max(left.rms, right.rms) }
    public var peak: Float { max(left.peak, right.peak) }
    public var sides: [(rms: Float, peak: Float)] { [left, right] }

    public mutating func fold(_ level: (rms: Float, peak: Float)) {
        fold(left: level, right: level)
    }

    public mutating func fold(left newLeft: (rms: Float, peak: Float), right newRight: (rms: Float, peak: Float)) {
        left = (max(left.rms, newLeft.rms), max(left.peak, newLeft.peak))
        right = (max(right.rms, newRight.rms), max(right.peak, newRight.peak))
    }

    public mutating func take() -> (rms: Float, peak: Float) {
        defer { self = LevelWindow() }
        return (rms, peak)
    }
}

public struct PeakHold: Sendable {
    public private(set) var decibels: Float = -.infinity
    private var heldAt: TimeInterval = -.infinity
    public var holdSeconds: TimeInterval?

    public init(holdSeconds: TimeInterval? = nil) {
        self.holdSeconds = holdSeconds
    }

    public mutating func update(_ linear: Float, at time: TimeInterval = 0) {
        let db = AudioLevel.decibels(linear)
        if db >= decibels {
            decibels = db
            heldAt = time
        } else if let holdSeconds, time - heldAt > holdSeconds {
            decibels = db
            heldAt = time
        }
    }

    public mutating func reset() {
        decibels = -.infinity
        heldAt = -.infinity
    }
}

public struct MeterBallistics: Sendable, Equatable {

    public static let floor: Float = 0.0001

    public private(set) var rms: Float = 0
    public private(set) var peak: Float = 0

    public var decayDecibelsPerSecond: Float

    public init(decayDecibelsPerSecond: Float = 20) {
        self.decayDecibelsPerSecond = decayDecibelsPerSecond
    }

    public mutating func update(
        rms newRms: Float, peak newPeak: Float, elapsed: TimeInterval
    ) {

        let factor = pow(10, -decayDecibelsPerSecond * Float(max(0, elapsed)) / 20)
        rms = Self.settled(max(newRms, rms * factor))
        peak = Self.settled(max(newPeak, peak * factor))
    }

    private static func settled(_ value: Float) -> Float {
        value < floor ? 0 : value
    }
}
