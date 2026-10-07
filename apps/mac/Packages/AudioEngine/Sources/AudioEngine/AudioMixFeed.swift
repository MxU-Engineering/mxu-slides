import AVFoundation
import Foundation
import QuartzCore

public final class AudioMixFeed: @unchecked Sendable {
    public typealias Consumer = @Sendable (AVAudioPCMBuffer, AVAudioTime, Double) -> Void

    private struct Ring {
        var left: [Float] = []
        var right: [Float] = []

        mutating func push(_ buffer: AVAudioPCMBuffer, gain: Float, pan: Float) {
            guard gain > 0, let data = buffer.floatChannelData,
                  buffer.frameLength > 0 else { return }

            let leftGain = gain * min(1, 1 - pan)
            let rightGain = gain * min(1, 1 + pan)
            let frames = Int(buffer.frameLength)
            let channels = Int(buffer.format.channelCount)
            let rightChannel = channels > 1 ? 1 : 0
            left.reserveCapacity(left.count + frames)
            right.reserveCapacity(right.count + frames)
            for frame in 0 ..< frames {
                left.append(data[0][frame] * leftGain)
                right.append(data[rightChannel][frame] * rightGain)
            }

            if left.count > AudioMixFeed.maxRingFrames {
                let overflow = left.count - AudioMixFeed.maxRingFrames
                left.removeFirst(overflow)
                right.removeFirst(overflow)
            }
        }

        mutating func drain(into leftOut: inout [Float], _ rightOut: inout [Float], frames: Int) {
            let available = min(frames, left.count)
            for frame in 0 ..< available {
                leftOut[frame] += left[frame]
                rightOut[frame] += right[frame]
            }
            left.removeFirst(available)
            right.removeFirst(available)
            trough = min(trough, left.count)
        }

        var trough = Int.max

        mutating func trimExcess(threshold: Int, target: Int) -> Int {
            defer { trough = Int.max }
            let excess = trough == Int.max || trough <= threshold ? 0 : trough - target
            if excess > 0 {
                left.removeFirst(excess)
                right.removeFirst(excess)
            }
            return excess
        }
    }

    private static let maxRingFrames = 24_000  
    private static let tickFrames = 480  
    private static let tickSeconds = 0.010

    static let maxCatchUpTicks = 25

    static let trimWindowTicks = 200
    static let trimThresholdFrames = 2_880
    static let trimTargetFrames = 960

    private let lock = NSLock()
    private var rings: [String: Ring] = [:]
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "audio-mix-feed", qos: .userInitiated)
    private let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
    private let consumer: Consumer

    public init(startsClock: Bool = true, consumer: @escaping Consumer) {
        self.consumer = consumer
        guard startsClock else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(10), leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in self?.tick() }
        self.timer = timer
        timer.resume()
    }

    deinit {
        timer?.cancel()
    }

    public func push(
        member: String, buffer: AVAudioPCMBuffer, gain: Float = 1, pan: Float = 0
    ) {
        lock.withLock {
            rings[member, default: Ring()].push(
                buffer, gain: gain, pan: min(max(pan, -1), 1))
        }
    }

    public var backlogMilliseconds: Double {
        let frames = lock.withLock { rings.values.map(\.left.count).max() ?? 0 }
        return Double(frames) / format.sampleRate * 1000
    }

    public func removeMember(_ member: String) {
        lock.withLock { _ = rings.removeValue(forKey: member) }
    }

    private var clockStart: Double?
    private var pulls = 0
    private var ticksSinceTrim = 0
    private let trimmedFrames = LockedCounter()

    public var trimmedMilliseconds: Double {
        Double(trimmedFrames.value) / format.sampleRate * 1000
    }

    func tick(now: Double = CACurrentMediaTime()) {
        let start = clockStart ?? now
        clockStart = start
        var owed = Int(((now - start) / Self.tickSeconds).rounded(.down)) + 1 - pulls
        if owed > Self.maxCatchUpTicks {
            clockStart = now
            pulls = 0
            owed = 1
        }
        for _ in 0 ..< max(owed, 0) {
            pull(mark: (clockStart ?? now) + Double(pulls) * Self.tickSeconds)
            pulls += 1
        }
    }

    private func pull(mark hostSeconds: Double) {
        let frames = Self.tickFrames
        var left = [Float](repeating: 0, count: frames)
        var right = [Float](repeating: 0, count: frames)
        ticksSinceTrim += 1
        let trimDue = ticksSinceTrim >= Self.trimWindowTicks
        if trimDue { ticksSinceTrim = 0 }
        lock.withLock {
            for key in rings.keys {
                rings[key]?.drain(into: &left, &right, frames: frames)
                if trimDue {
                    trimmedFrames.add(rings[key]?.trimExcess(
                        threshold: Self.trimThresholdFrames, target: Self.trimTargetFrames) ?? 0)
                }
            }
        }
        guard let output = AVAudioPCMBuffer(
            pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))
        else { return }
        output.frameLength = AVAudioFrameCount(frames)
        guard let data = output.floatChannelData else { return }
        for frame in 0 ..< frames {
            data[0][frame] = min(max(left[frame], -1), 1)
            data[1][frame] = min(max(right[frame], -1), 1)
        }
        let when = AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: hostSeconds))
        consumer(output, when, hostSeconds)
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func add(_ amount: Int) { lock.withLock { count += amount } }
}
