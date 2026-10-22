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

    let varispeed: MultitrackVarispeed?

    let entryFrames: Int64?

    init(
        rings: [StemRing], stemChannels: [String], startFrame: Int64, anchor: (frame: Int64, hostTime: UInt64)? = nil,
        varispeed: MultitrackVarispeed? = nil, entryFrames: Int64? = nil
    ) {
        self.rings = rings
        self.stemChannels = stemChannels
        self.startFrame = startFrame
        self.anchor = anchor
        self.varispeed = varispeed
        self.entryFrames = entryFrames
        meters = .allocate(capacity: max(1, rings.count * Self.meterSlots))
        for index in 0 ..< max(1, rings.count * Self.meterSlots) { mxu_store_i64(meters + index, 0) }
    }

    deinit { meters.deallocate() }
}

final class MultitrackProgram: @unchecked Sendable {
    let session: MultitrackSession
    let matrix: MultitrackMatrix
    let gains: UnsafeMutablePointer<Float>

    let delays: MultitrackDelays?

    let handover: MultitrackHandover?

    let companions: [MultitrackProgram]

    init(
        session: MultitrackSession, matrix: MultitrackMatrix, delays: MultitrackDelays? = nil,
        handover: MultitrackHandover? = nil, companions: [MultitrackProgram] = []
    ) {
        self.session = session
        self.matrix = matrix
        self.delays = delays
        self.handover = handover
        self.companions = companions
        let table = UnsafeMutablePointer<Float>.allocate(capacity: max(1, matrix.gains.count))
        table.initialize(repeating: 0, count: max(1, matrix.gains.count))
        matrix.gains.withUnsafeBufferPointer { if let base = $0.baseAddress { table.update(from: base, count: $0.count) } }
        gains = table
    }

    deinit { gains.deallocate() }
}

struct MultitrackShape: Equatable, Sendable {
    enum Curve: Equatable, Sendable {

        case linear

        case equalPower

        case cosine
    }

    var inFrom: Int64 = 0
    var inFrames: Int64 = 0
    var inCurve: Curve = .linear
    var fadeFrom: Int64 = .max
    var fadeFrames: Int64 = 1
    var fadeCurve: Curve = .linear
    var end: Int64 = .max

    var endRamp: Int64 = 480

    static let flat = MultitrackShape()

    func gain(at frame: Int64) -> Float {
        var gain: Float = 1
        if inFrames > 0, frame < inFrom + inFrames {
            let t = Float(max(frame - inFrom, 0)) / Float(inFrames)
            gain *= Self.rise(t, inCurve)
        }
        if frame >= fadeFrom {
            let t = min(Float(frame - fadeFrom) / Float(max(fadeFrames, 1)), 1)
            gain *= Self.rise(1 - t, fadeCurve)
        }
        if frame >= end {
            gain = 0
        } else if end != .max, end - frame < endRamp {
            gain *= Float(end - frame) / Float(endRamp)
        }
        return gain
    }

    func isDone(at frame: Int64) -> Bool {
        frame >= end || (fadeFrom != .max && frame >= fadeFrom + fadeFrames)
    }

    func framesToBreak(from frame: Int64) -> Int64 {
        var nearest = Int64.max
        for point in [inFrom + inFrames, fadeFrom, fadeFrom &+ fadeFrames, end &- endRamp, end] where point > frame {
            nearest = min(nearest, point - frame)
        }
        return nearest
    }

    func shapes(_ frame: Int64, count: Int) -> Bool {
        (inFrames > 0 && frame < inFrom + inFrames) || frame + Int64(count) > fadeFrom
            || (end != .max && frame + Int64(count) > end - endRamp)
    }

    private static func rise(_ t: Float, _ curve: Curve) -> Float {
        switch curve {
        case .linear: t
        case .equalPower: sin(t * .pi / 2)
        case .cosine: 0.5 * (1 - cos(t * .pi))
        }
    }
}

final class MultitrackHandover: @unchecked Sendable {
    let next: MultitrackProgram?
    let at: Int64
    let outgoing: MultitrackShape
    let incoming: MultitrackShape

    init(next: MultitrackProgram?, at: Int64, outgoing: MultitrackShape, incoming: MultitrackShape) {
        self.next = next
        self.at = at
        self.outgoing = outgoing
        self.incoming = incoming
    }
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

    private let speedBits = UnsafeMutablePointer<mxu_atomic_i64>.allocate(capacity: 1)

    private let usingCurrent = UnsafeMutablePointer<mxu_atomic_ptr>.allocate(capacity: 1)

    private let usingOutgoing = UnsafeMutablePointer<mxu_atomic_ptr>.allocate(capacity: MultitrackRenderer.outgoingSlots)
    private let publishedFrame = UnsafeMutablePointer<mxu_atomic_i64>.allocate(capacity: 1)
    private let publishedHostTime = UnsafeMutablePointer<mxu_atomic_i64>.allocate(capacity: 1)
    private let publishedPlaying = UnsafeMutablePointer<mxu_atomic_i64>.allocate(capacity: 1)

    private let handoversMade = UnsafeMutablePointer<mxu_atomic_i64>.allocate(capacity: 1)

    private var current: Unmanaged<MultitrackProgram>?
    private var currentShape = MultitrackShape.flat

    private var rampFrom: Unmanaged<MultitrackProgram>?
    private struct Voice {
        var program: Unmanaged<MultitrackProgram>
        var frame: Int64
        var shape: MultitrackShape

        var rampFrom: Unmanaged<MultitrackProgram>?
    }
    private var outgoing: [Voice?]

    private var handedOverFrom: UnsafeMutableRawPointer?
    private var frame: Int64 = 0
    private var playing = false
    private var envelope: Float = 0
    private var envelopeTarget: Float = 0
    private var seenPlay: Int64 = 0
    private var seenStop: Int64 = 0
    private let scratchLeft: UnsafeMutablePointer<Float>
    private let scratchRight: UnsafeMutablePointer<Float>

    private let feedScratch: UnsafeMutablePointer<Float>
    private static let maxFeeds = TracksShare.slots
    private static let outgoingSlots = 2

    private static let shapedSlice = 256
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
        scratchLeft = .allocate(capacity: maxFrames)
        scratchRight = .allocate(capacity: maxFrames)
        feedScratch = .allocate(capacity: maxFrames * 2 * Self.maxFeeds)
        outgoing = Array(repeating: nil, count: Self.outgoingSlots)
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        nanosPerTick = Double(timebase.numer) / Double(timebase.denom)
        mxu_store_ptr(wanted, nil)
        mxu_store_ptr(usingCurrent, nil)
        for slot in 0 ..< Self.outgoingSlots { mxu_store_ptr(usingOutgoing + slot, nil) }
        for counter in [playRequest, playHostTime, stopRequest, publishedFrame, publishedHostTime, publishedPlaying, handoversMade] {
            mxu_store_i64(counter, 0)
        }
        mxu_store_i64(speedBits, Int64(bitPattern: (1.0).bitPattern))
    }

    deinit {
        scratchLeft.deallocate(); scratchRight.deallocate(); feedScratch.deallocate()
        wanted.deallocate(); playRequest.deallocate(); playHostTime.deallocate(); stopRequest.deallocate()
        speedBits.deallocate(); handoversMade.deallocate()
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

    var speed: Double {
        get { Double(bitPattern: UInt64(bitPattern: mxu_load_i64(speedBits))) }
        set { mxu_store_i64(speedBits, Int64(bitPattern: newValue.bitPattern)) }
    }

    func isHolding(_ program: MultitrackProgram) -> Bool {
        let pointer = Unmanaged.passUnretained(program).toOpaque()
        return mxu_load_ptr(usingCurrent) == pointer || mxu_load_ptr(wanted) == pointer
            || (0 ..< Self.outgoingSlots).contains { mxu_load_ptr(usingOutgoing + $0) == pointer }
    }

    func isCurrent(_ program: MultitrackProgram) -> Bool {
        mxu_load_ptr(usingCurrent) == Unmanaged.passUnretained(program).toOpaque()
    }

    var handovers: Int64 { mxu_load_i64(handoversMade) }

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
        guard let first = current?.takeUnretainedValue() else { return }
        if playing {

            if offset > 0 {
                for slot in first.matrix.feedSlots.prefix(Self.maxFeeds) {
                    share?.write(slot: slot, left: nil, right: nil, count: offset)
                }
            }
            var done = offset
            while done < total, playing, let program = current?.takeUnretainedValue() {
                var count = min(maxFrames, total - done)
                if let handover = program.handover, handedOverFrom == nil {
                    if frame >= handover.at {
                        handOver(handover)
                        continue
                    }

                    count = min(count, Int(handover.at - frame))
                }
                if shaping(count) { count = min(count, Self.shapedSlice) }
                count = min(count, breakFrames())
                renderSlice(count: count, at: done, outputs: outputs)
                done += count
            }
        }

        (current?.takeUnretainedValue() ?? first).delays?.process(outputs, channels: deviceChannels, count: total)
    }

    private func shaping(_ count: Int) -> Bool {
        envelope != envelopeTarget || currentShape.shapes(frame, count: count)
            || outgoing.contains { $0.map { $0.shape.shapes($0.frame, count: count) } ?? false }
    }

    private func breakFrames() -> Int {
        var nearest = currentShape.framesToBreak(from: frame)
        for voice in outgoing { if let voice { nearest = min(nearest, voice.shape.framesToBreak(from: voice.frame)) } }
        return Int(min(nearest, Int64(maxFrames)))
    }

    private func handOver(_ handover: MultitrackHandover) {
        guard let leaving = current else { return }
        handedOverFrom = leaving.toOpaque()
        mxu_store_i64(handoversMade, mxu_load_i64(handoversMade) + 1)
        guard let next = handover.next else {

            envelopeTarget = 0
            envelope = 0
            playing = false
            clearOutgoing()
            return
        }
        addOutgoing(Voice(program: leaving, frame: frame, shape: currentShape))
        current = Unmanaged.passUnretained(next)
        mxu_store_ptr(usingCurrent, Unmanaged.passUnretained(next).toOpaque())
        frame = next.session.startFrame
        currentShape = handover.incoming
    }

    private func addOutgoing(_ voice: Voice) {

        let slot = outgoing.firstIndex { $0 == nil } ?? {
            outgoing[0] = outgoing[1]
            mxu_store_ptr(usingOutgoing, outgoing[0].map { $0.program.toOpaque() })
            return 1
        }()
        outgoing[slot] = voice
        mxu_store_ptr(usingOutgoing + slot, voice.program.toOpaque())
    }

    private func clearOutgoing() {
        for slot in 0 ..< Self.outgoingSlots {
            outgoing[slot] = nil
            mxu_store_ptr(usingOutgoing + slot, nil)
        }
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
            clearOutgoing()
            return
        }
        if let handedOverFrom {

            if pointer == handedOverFrom { return }
            if let incoming = program.handover?.next, let previous, incoming.session === previous.session {
                self.handedOverFrom = pointer
                for slot in 0 ..< Self.outgoingSlots where outgoing[slot]?.program.takeUnretainedValue().session === program.session {
                    outgoing[slot]?.program = Unmanaged.passUnretained(program)
                    mxu_store_ptr(usingOutgoing + slot, pointer)
                }
                rampFrom = Unmanaged.passUnretained(previous)
                current = Unmanaged.passUnretained(incoming)
                mxu_store_ptr(usingCurrent, Unmanaged.passUnretained(incoming).toOpaque())
                return
            }
            self.handedOverFrom = nil
        }
        if previous?.session !== program.session {
            let crossfading = playing && envelopeTarget > 0 && previous != nil
            let entry = program.session.entryFrames
            if crossfading, let previous {

                var shape = currentShape
                shape.fadeFrom = min(shape.fadeFrom, frame)
                shape.fadeFrames = entry ?? Int64(fadeFrames)
                shape.fadeCurve = entry == nil ? .linear : .equalPower
                addOutgoing(Voice(program: Unmanaged.passUnretained(previous), frame: frame, shape: shape))
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
            currentShape = crossfading
                ? MultitrackShape(
                    inFrom: frame, inFrames: entry ?? Int64(fadeFrames), inCurve: entry == nil ? .linear : .equalPower)
                : .flat

            if !crossfading { envelope = frame <= 0 ? 1 : 0 }
        } else if let previous {
            rampFrom = Unmanaged.passUnretained(previous)
        }
        adoptCompanions(program)

        let leaving = program.handover?.outgoing ?? .flat
        currentShape.fadeFrom = leaving.fadeFrom
        currentShape.fadeFrames = leaving.fadeFrames
        currentShape.fadeCurve = leaving.fadeCurve
        currentShape.end = leaving.end
        current = next
        mxu_store_ptr(usingCurrent, pointer)
    }

    private func adoptCompanions(_ program: MultitrackProgram) {
        for companion in program.companions {
            for slot in 0 ..< Self.outgoingSlots where outgoing[slot]?.program.takeUnretainedValue().session === companion.session {
                guard var voice = outgoing[slot] else { continue }
                voice.rampFrom = voice.program
                voice.program = Unmanaged.passUnretained(companion)
                outgoing[slot] = voice
                mxu_store_ptr(usingOutgoing + slot, Unmanaged.passUnretained(companion).toOpaque())
            }
        }
    }

    private func renderSlice(count: Int, at offset: Int, outputs: UnsafeMutablePointer<UnsafeMutablePointer<Float>>) {
        guard let program = current?.takeUnretainedValue() else { return }

        for slot in feedSlots(program) { (feedScratch + slot * 2 * count).update(repeating: 0, count: 2 * count) }

        let startGain = envelope
        let step = 1 / Float(fadeFrames)
        let endGain = envelopeTarget > envelope
            ? min(envelopeTarget, envelope + step * Float(count))
            : max(envelopeTarget, envelope - step * Float(count))
        for slot in 0 ..< Self.outgoingSlots {
            guard var voice = outgoing[slot] else { continue }
            let from = voice.shape.gain(at: voice.frame)
            let to = voice.shape.gain(at: voice.frame + Int64(count))
            mix(voice.program.takeUnretainedValue(), count: count, offset: offset,
                envelope: (startGain * from, endGain * to), outputs: outputs, readFrom: &voice.frame,
                rampFrom: voice.rampFrom?.takeUnretainedValue())
            voice.rampFrom = nil
            if voice.shape.isDone(at: voice.frame) {
                outgoing[slot] = nil
                mxu_store_ptr(usingOutgoing + slot, nil)
            } else {
                outgoing[slot] = voice
            }
        }
        let from = currentShape.gain(at: frame)
        let to = currentShape.gain(at: frame + Int64(count))
        mix(program, count: count, offset: offset, envelope: (startGain * from, endGain * to),
            outputs: outputs, readFrom: &frame, rampFrom: rampFrom?.takeUnretainedValue())
        rampFrom = nil
        envelope = endGain
        if let share {
            for slot in feedSlots(program) {
                share.write(slot: slot, left: feedScratch + slot * 2 * count, right: feedScratch + (slot * 2 + 1) * count, count: count)
            }
        }
        if envelopeTarget == 0, envelope == 0 {
            playing = false
            clearOutgoing()
        }
    }

    private func feedSlots(_ program: MultitrackProgram) -> FeedSlots {
        FeedSlots(current: program.matrix.feedSlots, outgoing: outgoing)
    }

    private struct FeedSlots: Sequence, IteratorProtocol {
        let current: [Int]
        let outgoing: [Voice?]
        var voice = -1
        var index = 0

        init(current: [Int], outgoing: [Voice?]) {
            self.current = current
            self.outgoing = outgoing
        }

        mutating func next() -> Int? {
            while true {
                let slots = voice < 0 ? current : outgoing[voice]?.program.takeUnretainedValue().matrix.feedSlots ?? []
                if index < slots.count {
                    let slot = slots[index]
                    index += 1
                    guard slot < MultitrackRenderer.maxFeeds else { continue }
                    if voice >= 0, current.contains(slot) { continue }
                    if voice >= 1, (0 ..< voice).contains(where: { outgoing[$0]?.program.takeUnretainedValue().matrix.feedSlots.contains(slot) ?? false }) { continue }
                    return slot
                }
                voice += 1
                index = 0
                if voice >= outgoing.count { return nil }
            }
        }
    }

    private func mix(
        _ program: MultitrackProgram, count: Int, offset: Int, envelope: (Float, Float),
        outputs: UnsafeMutablePointer<UnsafeMutablePointer<Float>>, readFrom position: inout Int64,
        rampFrom: MultitrackProgram? = nil
    ) {

        let from = rampFrom.flatMap { $0.matrix.destinations == program.matrix.destinations
            && $0.matrix.stems == program.matrix.stems ? $0 : nil }
        let session = program.session
        let matrix = program.matrix
        let destinations = matrix.destinations
        let speed = self.speed
        let advance = session.varispeed?.plan(count: count, speed: speed) ?? count
        for (stem, ring) in session.rings.enumerated() {
            if let varispeed = session.varispeed {
                varispeed.render(stem: stem, ring: ring, count: count, advance: advance, left: scratchLeft, right: scratchRight)
            } else {
                ring.read(into: scratchLeft, scratchRight, count: count)
            }
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

                        let feed = (destination - matrix.deviceChannels) / 2
                        guard feed < matrix.feedSlots.count, matrix.feedSlots[feed] < Self.maxFeeds else { continue }
                        target = feedScratch + (matrix.feedSlots[feed] * 2 + (destination - matrix.deviceChannels) % 2) * count
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
        session.varispeed?.finish(count: count, speed: speed, advance: advance)
        position += Int64(advance)
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
