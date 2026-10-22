import Accelerate
import CAudioAtomics
import Foundation

final class MultitrackSession: @unchecked Sendable {
    let rings: [StemRing]
    let stemChannels: [String]

    let startFrame: Int64

    let anchor: (frame: Int64, hostTime: UInt64)?

    let meters: UnsafeMutablePointer<mxu_atomic_i64>
    static let meterSlots = 5

    let lastSamples: UnsafeMutablePointer<Float>

    init(rings: [StemRing], stemChannels: [String], startFrame: Int64, anchor: (frame: Int64, hostTime: UInt64)? = nil) {
        self.rings = rings
        self.stemChannels = stemChannels
        self.startFrame = startFrame
        self.anchor = anchor
        meters = .allocate(capacity: max(1, rings.count * Self.meterSlots))
        for index in 0 ..< max(1, rings.count * Self.meterSlots) { mxu_store_i64(meters + index, 0) }
        lastSamples = .allocate(capacity: max(1, rings.count * 2))
        lastSamples.initialize(repeating: 0, count: max(1, rings.count * 2))
    }

    deinit { meters.deallocate(); lastSamples.deallocate() }
}

final class MultitrackProgram: @unchecked Sendable {
    let session: MultitrackSession
    let matrix: MultitrackMatrix
    let gains: UnsafeMutablePointer<Float>

    let delays: MultitrackDelays?

    init(session: MultitrackSession, matrix: MultitrackMatrix, delays: MultitrackDelays? = nil) {
        self.session = session
        self.matrix = matrix
        self.delays = delays
        let table = UnsafeMutablePointer<Float>.allocate(capacity: max(1, matrix.gains.count))
        table.initialize(repeating: 0, count: max(1, matrix.gains.count))
        matrix.gains.withUnsafeBufferPointer { if let base = $0.baseAddress { table.update(from: base, count: $0.count) } }
        gains = table
    }

    deinit { gains.deallocate() }
}

final class MultitrackDelays: @unchecked Sendable {

    let frames: [Int]
    private let lines: UnsafeMutablePointer<UnsafeMutablePointer<Float>?>
    private let heads: UnsafeMutablePointer<Int>

    init(frames: [Int]) {
        self.frames = frames
        lines = .allocate(capacity: max(1, frames.count))
        heads = .allocate(capacity: max(1, frames.count))
        for (channel, delay) in frames.enumerated() {
            heads[channel] = 0
            if delay > 0 {
                let line = UnsafeMutablePointer<Float>.allocate(capacity: delay)
                line.initialize(repeating: 0, count: delay)
                lines[channel] = line
            } else {
                lines[channel] = nil
            }
        }
    }

    deinit {
        for channel in frames.indices { lines[channel]?.deallocate() }
        lines.deallocate(); heads.deallocate()
    }

    func process(_ outputs: UnsafeMutablePointer<UnsafeMutablePointer<Float>>, channels: Int, count: Int) {
        for channel in 0 ..< min(channels, frames.count) {
            guard let line = lines[channel] else { continue }
            let delay = frames[channel]
            let samples = outputs[channel]
            var head = heads[channel]
            for frame in 0 ..< count {
                let delayed = line[head]
                line[head] = samples[frame]
                samples[frame] = delayed
                head += 1
                if head == delay { head = 0 }
            }
            heads[channel] = head
        }
    }
}

final class MultitrackRenderer: @unchecked Sendable {
    let maxFrames: Int
    let deviceChannels: Int
    let sampleRate: Double

    let fadeFrames: Int

    private let wanted = UnsafeMutablePointer<mxu_atomic_ptr>.allocate(capacity: 1)
    private let playRequest = UnsafeMutablePointer<mxu_atomic_i64>.allocate(capacity: 1)
    private let playHostTime = UnsafeMutablePointer<mxu_atomic_i64>.allocate(capacity: 1)
    private let stopRequest = UnsafeMutablePointer<mxu_atomic_i64>.allocate(capacity: 1)

    private let slipRequest = UnsafeMutablePointer<mxu_atomic_i64>.allocate(capacity: 1)
    private let slipsMade = UnsafeMutablePointer<mxu_atomic_i64>.allocate(capacity: 1)

    private let usingCurrent = UnsafeMutablePointer<mxu_atomic_ptr>.allocate(capacity: 1)
    private let usingOutgoing = UnsafeMutablePointer<mxu_atomic_ptr>.allocate(capacity: 1)
    private let publishedFrame = UnsafeMutablePointer<mxu_atomic_i64>.allocate(capacity: 1)
    private let publishedHostTime = UnsafeMutablePointer<mxu_atomic_i64>.allocate(capacity: 1)
    private let publishedPlaying = UnsafeMutablePointer<mxu_atomic_i64>.allocate(capacity: 1)

    private var current: Unmanaged<MultitrackProgram>?
    private var outgoing: Unmanaged<MultitrackProgram>?

    private var rampFrom: Unmanaged<MultitrackProgram>?
    private var outgoingFrame: Int64 = 0
    private var crossfadeLeft = 0
    private var frame: Int64 = 0
    private var playing = false
    private var envelope: Float = 0
    private var envelopeTarget: Float = 0
    private var seenPlay: Int64 = 0
    private var seenStop: Int64 = 0
    private var slipsDone: Int64 = 0
    private let scratchLeft: UnsafeMutablePointer<Float>
    private let scratchRight: UnsafeMutablePointer<Float>
    private let feedScratch: UnsafeMutablePointer<Float>
    private static let maxFeeds = TracksShare.slots
    private let nanosPerTick: Double

    let share: TracksShare?

    init(
        maxFrames: Int = 4096, deviceChannels: Int, sampleRate: Double, fadeSeconds: Double = 0.01,
        share: TracksShare? = nil
    ) {
        self.share = share
        self.maxFrames = maxFrames
        self.deviceChannels = deviceChannels
        self.sampleRate = sampleRate
        fadeFrames = max(1, Int(sampleRate * fadeSeconds))

        scratchLeft = .allocate(capacity: maxFrames + 1)
        scratchRight = .allocate(capacity: maxFrames + 1)
        feedScratch = .allocate(capacity: maxFrames * 2 * Self.maxFeeds)
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        nanosPerTick = Double(timebase.numer) / Double(timebase.denom)
        mxu_store_ptr(wanted, nil)
        mxu_store_ptr(usingCurrent, nil)
        mxu_store_ptr(usingOutgoing, nil)
        for counter in [playRequest, playHostTime, stopRequest, slipRequest, slipsMade, publishedFrame, publishedHostTime, publishedPlaying] {
            mxu_store_i64(counter, 0)
        }
    }

    deinit {
        scratchLeft.deallocate(); scratchRight.deallocate(); feedScratch.deallocate()
        wanted.deallocate(); playRequest.deallocate(); playHostTime.deallocate(); stopRequest.deallocate()
        slipRequest.deallocate(); slipsMade.deallocate()
        usingCurrent.deallocate(); usingOutgoing.deallocate()
        publishedFrame.deallocate(); publishedHostTime.deallocate(); publishedPlaying.deallocate()
    }

    func publish(_ program: MultitrackProgram?) {
        mxu_store_ptr(wanted, program.map { Unmanaged.passUnretained($0).toOpaque() })
    }

    func play(atHostTime hostTime: UInt64 = 0) {
        mxu_store_i64(playHostTime, Int64(bitPattern: hostTime))
        mxu_store_i64(playRequest, mxu_load_i64(playRequest) + 1)
    }

    func stop() {
        mxu_store_i64(stopRequest, mxu_load_i64(stopRequest) + 1)
    }

    func requestSlips(_ count: Int) {
        mxu_store_i64(slipRequest, mxu_load_i64(slipRequest) + Int64(count))
    }

    var slipsTotal: Int64 { mxu_load_i64(slipsMade) }

    var pendingSlips: Int64 { mxu_load_i64(slipRequest) - mxu_load_i64(slipsMade) }

    func isHolding(_ program: MultitrackProgram) -> Bool {
        let pointer = Unmanaged.passUnretained(program).toOpaque()
        return mxu_load_ptr(usingCurrent) == pointer || mxu_load_ptr(usingOutgoing) == pointer
            || mxu_load_ptr(wanted) == pointer
    }

    func isCurrent(_ program: MultitrackProgram) -> Bool {
        mxu_load_ptr(usingCurrent) == Unmanaged.passUnretained(program).toOpaque()
    }

    var published: (frame: Int64, hostTime: UInt64, playing: Bool) {
        (mxu_load_i64(publishedFrame), UInt64(bitPattern: mxu_load_i64(publishedHostTime)),
         mxu_load_i64(publishedPlaying) != 0)
    }

    func position(atHostTime hostTime: UInt64) -> Double {
        let state = published
        var seconds = Double(state.frame) / sampleRate
        if state.playing, state.hostTime > 0 {
            seconds += (Double(Int64(bitPattern: hostTime &- state.hostTime)) * nanosPerTick) / 1e9
        }
        return seconds
    }

    func render(frames total: Int, hostTime: UInt64, outputs: UnsafeMutablePointer<UnsafeMutablePointer<Float>>) {
        for channel in 0 ..< deviceChannels {
            outputs[channel].update(repeating: 0, count: total)
        }
        adoptWanted(hostTime: hostTime)
        var offset = 0
        let playAsked = mxu_load_i64(playRequest)
        if playAsked != seenPlay {
            let start = UInt64(bitPattern: mxu_load_i64(playHostTime))
            let wait = start == 0 || hostTime == 0 ? 0
                : Int(((Double(Int64(bitPattern: start &- hostTime)) * nanosPerTick) / 1e9 * sampleRate).rounded())
            if wait < total {
                seenPlay = playAsked
                if !playing || envelopeTarget == 0 {

                    offset = playing ? 0 : max(0, wait)
                    playing = true
                    envelopeTarget = 1

                    envelope = frame <= 0 && envelope == 0 ? 1 : envelope
                }
            }
        }
        let stopAsked = mxu_load_i64(stopRequest)
        if stopAsked != seenStop {
            seenStop = stopAsked
            if playing { envelopeTarget = 0 }
        }
        mxu_store_i64(publishedFrame, frame - Int64(playing ? offset : 0))
        mxu_store_i64(publishedHostTime, Int64(bitPattern: hostTime))
        mxu_store_i64(publishedPlaying, playing && envelopeTarget > 0 ? 1 : 0)

        defer { rampFrom = nil }
        guard let program = current?.takeUnretainedValue() else { return }
        if playing {

            if offset > 0 {
                for slot in program.matrix.feedSlots.prefix(Self.maxFeeds) {
                    share?.write(slot: slot, left: nil, right: nil, count: offset)
                }
            }
            var done = offset
            while done < total {
                let count = min(maxFrames, total - done)
                renderSlice(program, count: count, at: done, outputs: outputs)
                done += count
            }
        }

        program.delays?.process(outputs, channels: deviceChannels, count: total)
    }

    private func adoptWanted(hostTime: UInt64) {
        let pointer = mxu_load_ptr(wanted)
        guard pointer != current.map({ $0.toOpaque() }) else { return }
        let next = pointer.map { Unmanaged<MultitrackProgram>.fromOpaque($0) }
        let previous = current?.takeUnretainedValue()
        guard let program = next?.takeUnretainedValue() else {
            current = nil
            mxu_store_ptr(usingCurrent, nil)
            playing = false
            return
        }
        if previous?.session !== program.session {
            let crossfading = playing && envelopeTarget > 0 && previous != nil
            if crossfading, let previous {

                outgoing = Unmanaged.passUnretained(previous)
                outgoingFrame = frame
                crossfadeLeft = fadeFrames
                mxu_store_ptr(usingOutgoing, Unmanaged.passUnretained(previous).toOpaque())
            }
            frame = program.session.startFrame

            if let anchor = program.session.anchor, hostTime > 0, anchor.hostTime > 0 {
                let since = (Double(Int64(bitPattern: hostTime &- anchor.hostTime)) * nanosPerTick) / 1e9
                let target = anchor.frame + Int64((since * sampleRate).rounded())
                if target > frame {
                    for ring in program.session.rings { ring.skip(Int(target - frame)) }
                    frame = target
                }
            }

            if !crossfading { envelope = frame <= 0 ? 1 : 0 }
        } else if let previous {
            rampFrom = Unmanaged.passUnretained(previous)
        }
        current = next
        mxu_store_ptr(usingCurrent, pointer)
    }

    private func renderSlice(
        _ program: MultitrackProgram, count: Int, at offset: Int,
        outputs: UnsafeMutablePointer<UnsafeMutablePointer<Float>>
    ) {
        let feeds = program.matrix.feedSlots.count
        let feedFrames = feedScratch
        if feeds > 0 { feedFrames.update(repeating: 0, count: count * 2 * min(feeds, Self.maxFeeds)) }

        let startGain = envelope
        let step = 1 / Float(fadeFrames)
        let endGain = envelopeTarget > envelope
            ? min(envelopeTarget, envelope + step * Float(count))
            : max(envelopeTarget, envelope - step * Float(count))
        var fadeIn: Float = 1
        var fadeInEnd: Float = 1
        if let old = outgoing?.takeUnretainedValue() {
            fadeIn = 1 - Float(crossfadeLeft) / Float(fadeFrames)
            let left = max(0, crossfadeLeft - count)
            fadeInEnd = 1 - Float(left) / Float(fadeFrames)
            mix(old, count: count, offset: offset, envelope: (startGain * (1 - fadeIn), endGain * (1 - fadeInEnd)),
                outputs: outputs, feedFrames: feedFrames, readFrom: &outgoingFrame, writesFeeds: false)
            crossfadeLeft = left
            if left == 0 {
                outgoing = nil
                mxu_store_ptr(usingOutgoing, nil)
            }
        }

        var slip = 0
        let asked = mxu_load_i64(slipRequest)
        if asked != slipsDone, outgoing == nil, envelopeTarget > 0, envelope == 1, count >= 32 {
            slip = asked > slipsDone ? 1 : -1
            slipsDone += Int64(slip)
            mxu_store_i64(slipsMade, slipsDone)
        }
        mix(program, count: count, offset: offset, envelope: (startGain * fadeIn, endGain * fadeInEnd),
            outputs: outputs, feedFrames: feedFrames, readFrom: &frame, writesFeeds: true,
            rampFrom: rampFrom?.takeUnretainedValue(), slip: slip)
        rampFrom = nil
        envelope = endGain
        if envelopeTarget == 0, envelope == 0 {
            playing = false
            outgoing = nil
            mxu_store_ptr(usingOutgoing, nil)
        }
    }

    private func mix(
        _ program: MultitrackProgram, count: Int, offset: Int, envelope: (Float, Float),
        outputs: UnsafeMutablePointer<UnsafeMutablePointer<Float>>,
        feedFrames: UnsafeMutablePointer<Float>, readFrom position: inout Int64, writesFeeds: Bool,
        rampFrom: MultitrackProgram? = nil, slip: Int = 0
    ) {

        let from = rampFrom.flatMap { $0.matrix.destinations == program.matrix.destinations
            && $0.matrix.stems == program.matrix.stems ? $0 : nil }
        let session = program.session
        let matrix = program.matrix
        let destinations = matrix.destinations
        let feeds = min(program.matrix.feedSlots.count, Self.maxFeeds)
        for (stem, ring) in session.rings.enumerated() {
            let last = session.lastSamples + stem * 2
            if slip == 0 {
                ring.read(into: scratchLeft, scratchRight, count: count)
            } else {
                Self.slipped(ring, slip: slip, count: count, last: last, left: scratchLeft, right: scratchRight)
            }
            last[0] = scratchLeft[count - 1]
            last[1] = scratchRight[count - 1]
            meter(session, stem: stem, count: count)
            var start = envelope.0
            var rampStep = (envelope.1 - envelope.0) / Float(count)
            if start != 1 || rampStep != 0 {
                vDSP_vrampmul(scratchLeft, 1, &start, &rampStep, scratchLeft, 1, vDSP_Length(count))
                start = envelope.0
                vDSP_vrampmul(scratchRight, 1, &start, &rampStep, scratchRight, 1, vDSP_Length(count))
            }
            for side in 0 ..< 2 {
                let source = side == 0 ? scratchLeft : scratchRight
                let row = program.gains + (stem * 2 + side) * destinations
                let oldRow = from.map { $0.gains + (stem * 2 + side) * destinations }
                for destination in 0 ..< destinations {
                    var gain = row[destination]
                    let oldGain = oldRow?[destination] ?? gain
                    guard gain != 0 || oldGain != 0 else { continue }
                    let target: UnsafeMutablePointer<Float>
                    if destination < matrix.deviceChannels {
                        guard destination < deviceChannels else { continue }
                        target = outputs[destination] + offset
                    } else {
                        let feedSlot = destination - matrix.deviceChannels
                        guard writesFeeds, feedSlot < feeds * 2 else { continue }
                        target = feedFrames + feedSlot * count
                    }
                    if oldGain == gain {
                        vDSP_vsma(source, 1, &gain, target, 1, target, 1, vDSP_Length(count))
                    } else {
                        var start = oldGain
                        var step = (gain - oldGain) / Float(count)
                        vDSP_vrampmuladd(source, 1, &start, &step, target, 1, vDSP_Length(count))
                    }
                }
            }
        }
        position += Int64(count + slip)
        guard writesFeeds else { return }
        guard let share else { return }
        for feed in 0 ..< feeds {
            share.write(
                slot: program.matrix.feedSlots[feed],
                left: feedFrames + feed * 2 * count, right: feedFrames + (feed * 2 + 1) * count, count: count)
        }
    }

    private static func slipped(
        _ ring: StemRing, slip: Int, count: Int, last: UnsafeMutablePointer<Float>,
        left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>
    ) {
        if slip > 0 {
            ring.read(into: left, right, count: count + 1)
        } else {
            ring.read(into: left + 1, right + 1, count: count - 1)
            left[0] = last[0]
            right[0] = last[1]
        }
        blend(left, slip: slip, count: count)
        blend(right, slip: slip, count: count)
    }

    private static func blend(_ side: UnsafeMutablePointer<Float>, slip: Int, count: Int) {
        for j in 0 ..< count {
            let w = Float(j + 1) / Float(count)
            let old = slip > 0 ? side[j] : (j + 1 < count ? side[j + 1] : side[j])
            let new = slip > 0 ? side[j + 1] : side[j]
            side[j] = old + (new - old) * w
        }
    }

    private func meter(_ session: MultitrackSession, stem: Int, count: Int) {
        let slot = session.meters + stem * MultitrackSession.meterSlots
        meterSide(scratchLeft, peakSlot: slot, squaresSlot: slot + 2, count: count)
        meterSide(scratchRight, peakSlot: slot + 1, squaresSlot: slot + 3, count: count)
        mxu_store_i64(slot + 4, mxu_load_i64(slot + 4) + Int64(count))
    }

    private func meterSide(
        _ samples: UnsafeMutablePointer<Float>, peakSlot: UnsafeMutablePointer<mxu_atomic_i64>,
        squaresSlot: UnsafeMutablePointer<mxu_atomic_i64>, count: Int
    ) {
        var peak: Float = 0, squares: Float = 0
        vDSP_maxmgv(samples, 1, &peak, vDSP_Length(count))
        vDSP_svesq(samples, 1, &squares, vDSP_Length(count))
        let held = Float(bitPattern: UInt32(truncatingIfNeeded: mxu_load_i64(peakSlot)))
        mxu_store_i64(peakSlot, Int64(max(peak, held).bitPattern))
        let sum = Float(bitPattern: UInt32(truncatingIfNeeded: mxu_load_i64(squaresSlot))) + squares
        mxu_store_i64(squaresSlot, Int64(sum.bitPattern))
    }

    static func takeMeters(_ session: MultitrackSession) -> [(left: AudioLevel.Reading, right: AudioLevel.Reading)] {
        (0 ..< session.rings.count).map { stem in
            let slot = session.meters + stem * MultitrackSession.meterSlots
            let take = { (index: Int) in Float(bitPattern: UInt32(truncatingIfNeeded: mxu_exchange_i64(slot + index, 0))) }
            let peaks = (take(0), take(1))
            let squares = (take(2), take(3))
            let frames = Float(mxu_exchange_i64(slot + 4, 0))
            let rms = { (sum: Float) in frames > 0 ? sqrt(sum / frames) : 0 }
            return ((rms(squares.0), peaks.0), (rms(squares.1), peaks.1))
        }
    }
}
