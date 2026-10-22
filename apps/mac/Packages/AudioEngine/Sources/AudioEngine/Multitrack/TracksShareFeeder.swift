import AVFoundation
import Foundation

public final class TracksShareFeeder: @unchecked Sendable {
    public typealias Sink = @Sendable (_ slot: Int, _ buffer: AVAudioPCMBuffer) -> Void

    static let maxLagSeconds = 0.04
    static let keepSeconds = 0.01
    private let share: TracksShare
    private let sink: Sink
    private let queue = DispatchQueue(label: "io.prodcontrol.tracks-share", qos: .userInitiated)
    private var timer: DispatchSourceTimer?

    private var positions: [Int: Int64] = [:]
    private var converters: [Int: AVAudioConverter] = [:]
    private var rate: Double = 0
    private let output = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!

    public private(set) var droppedFrames: Int64 = 0

    public init(share: TracksShare, startsClock: Bool = true, sink: @escaping Sink) {
        self.share = share
        self.sink = sink
        guard startsClock else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(10), leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in self?.drain() }
        timer.resume()
        self.timer = timer
    }

    deinit { timer?.cancel() }

    public func stop() {
        queue.sync {
            timer?.cancel()
            timer = nil
        }
    }

    func drainNow() { queue.sync { drain() } }

    private func drain() {
        let rate = share.sampleRate
        guard rate > 0 else { return }
        if rate != self.rate {
            self.rate = rate
            converters = [:]
        }
        let lag = Int64(Self.maxLagSeconds * rate)
        let keep = Int64(Self.keepSeconds * rate)
        for slot in 0 ..< TracksShare.slots {
            let written = share.writtenFrames(slot: slot)

            var from = positions[slot].map { $0 > written ? written : $0 } ?? max(0, written - keep)
            if written - from > lag {
                droppedFrames += written - keep - from
                from = written - keep
            }
            positions[slot] = written
            let count = Int(written - from)
            guard count > 0, let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2),
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
                  let data = buffer.floatChannelData
            else { continue }
            buffer.frameLength = AVAudioFrameCount(count)
            share.read(slot: slot, from: from, count: count, left: data[0], right: data[1])

            guard share.writtenFrames(slot: slot) - from <= Int64(TracksShare.slotFrames) else { continue }
            if let converted = convert(buffer, slot: slot) { sink(slot, converted) }
        }
    }

    private func convert(_ buffer: AVAudioPCMBuffer, slot: Int) -> AVAudioPCMBuffer? {
        guard buffer.format.sampleRate != output.sampleRate else { return buffer }
        let converter = converters[slot] ?? AVAudioConverter(from: buffer.format, to: output)
        guard let converter else { return nil }
        converters[slot] = converter
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * output.sampleRate / buffer.format.sampleRate).rounded(.up)) + 64
        guard let converted = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity) else { return nil }
        var given = false
        var error: NSError?

        converter.convert(to: converted, error: &error) { _, status in
            if given {
                status.pointee = .noDataNow
                return nil
            }
            given = true
            status.pointee = .haveData
            return buffer
        }
        return error == nil && converted.frameLength > 0 ? converted : nil
    }
}
