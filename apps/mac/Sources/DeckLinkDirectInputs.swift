import AVFoundation
import AudioEngine
import CoreVideo
import Foundation
import IOSurface
import QuartzCore

enum DeckLinkDirect {

    static func audioUID(persistentID: Int64) -> String {
        DeckLinkAudioUID.uid(persistentID: persistentID)
    }

    static func isDirect(audioUID: String) -> Bool {
        DeckLinkAudioUID.persistentID(audioUID) != nil
    }

    static func displayName(_ cardName: String) -> String {
        "\(cardName) (Direct)"
    }

    static func feed(forAudioUID uid: String) -> (any ExternalInputFeed)? {
        DeckLinkAudioUID.persistentID(uid).map { DeckLinkDirectAudioFeed(persistentID: $0, uid: uid) }
    }
}

final class DeckLinkDirectInputs: @unchecked Sendable {
    static let shared = DeckLinkDirectInputs()

    private let lock = NSLock()
    private var captures: [Int64: (capture: DeckLinkDirectCapture, users: Int)] = [:]

    func acquire(persistentID: Int64, name: String) -> DeckLinkDirectCapture {
        var started: DeckLinkDirectCapture?
        let capture = lock.withLock { () -> DeckLinkDirectCapture in
            if let existing = captures[persistentID] {
                captures[persistentID] = (existing.capture, existing.users + 1)
                return existing.capture
            } else {
                let capture = DeckLinkDirectCapture(persistentID: persistentID, name: name)
                captures[persistentID] = (capture, 1)
                started = capture
                return capture
            }
        }
        started?.start()
        return capture
    }

    func release(persistentID: Int64) {
        var stopped: DeckLinkDirectCapture?
        lock.withLock {
            if let entry = captures[persistentID] {
                if entry.users <= 1 {
                    captures[persistentID] = nil
                    stopped = entry.capture
                } else {
                    captures[persistentID] = (entry.capture, entry.users - 1)
                }
            }
        }
        stopped?.stop()
    }

    func capture(persistentID: Int64) -> DeckLinkDirectCapture? {
        lock.withLock { captures[persistentID]?.capture }
    }

    func checkLiveness(at now: Double) {
        let running = lock.withLock { captures.values.map(\.capture) }
        for capture in running { capture.checkLiveness(at: now) }
    }
}

final class DeckLinkDirectCapture: @unchecked Sendable {
    typealias AudioSink = @Sendable (AVAudioPCMBuffer, AVAudioTime, Double) -> Void

    static let retrySeconds: Double = 2

    let persistentID: Int64
    let name: String
    private let lock = NSLock()
    private var latest: CVPixelBuffer?
    private var lastFrameAt: Double = -.infinity
    private var audioSinks: [UUID: AudioSink] = [:]
    private var connection: NSXPCConnection?
    private var generation = 0

    private var liveness = DirectInputLiveness()

    init(persistentID: Int64, name: String) {
        self.persistentID = persistentID
        self.name = name
    }

    func latestFrame() -> CVPixelBuffer? {
        lock.withLock { latest }
    }

    func isReceiving(at now: Double) -> Bool {
        lock.withLock { now - lastFrameAt < 2 }
    }

    func addAudioSink(_ sink: @escaping AudioSink) -> UUID {
        let token = UUID()
        lock.withLock { audioSinks[token] = sink }
        return token
    }

    func removeAudioSink(_ token: UUID) {
        lock.withLock { audioSinks[token] = nil }
    }

    func start() {
        lock.withLock { liveness.running = true }
        open()
    }

    func stop() {
        let closing = lock.withLock { () -> NSXPCConnection? in
            liveness.stopped()
            generation += 1
            latest = nil
            let closing = connection
            connection = nil
            return closing
        }
        (closing?.remoteObjectProxy as? DeckLinkHelperProtocol)?.stopInput()
        closing?.invalidate()
    }

    func checkLiveness(at now: Double) {
        if lock.withLock({ liveness.shouldReopen(at: now) }) {
            DiagnosticsStore.shared.note(
                "input.decklink",
                detail: "\(name): nothing from the card for \(Int(DirectInputLiveness.silentSeconds)) s — reopening")
            open()
        }
    }

    private func open() {
        let opened = lock.withLock { () -> (generation: Int, connection: NSXPCConnection)? in
            if liveness.running {
                connection?.invalidate()
                generation += 1
                liveness.opening()
                let connection = NSXPCConnection(serviceName: DeckLinkHelperIdentity.serviceName)
                connection.remoteObjectInterface = NSXPCInterface(with: DeckLinkHelperProtocol.self)
                connection.exportedInterface = NSXPCInterface(with: DeckLinkInputSinkProtocol.self)
                connection.exportedObject = DeckLinkDirectSink(owner: self, generation: generation)
                self.connection = connection
                return (generation, connection)
            } else {
                return nil
            }
        }
        if let (generation, connection) = opened {

            connection.interruptionHandler = { @Sendable [weak self] in

                self?.failed("helper interrupted", generation: generation, retryAfter: 0.5)
            }
            connection.invalidationHandler = { @Sendable [weak self] in
                self?.failed("helper unreachable", generation: generation, retryAfter: Self.retrySeconds)
            }
            connection.resume()
            let remote = connection.remoteObjectProxyWithErrorHandler { @Sendable [weak self] error in
                self?.failed(
                    "proxy error: \(error.localizedDescription)", generation: generation,
                    retryAfter: Self.retrySeconds)
            }
            (remote as? DeckLinkHelperProtocol)?.startInput(devicePersistentID: persistentID) {
                @Sendable [weak self] error in
                if let error {
                    self?.failed(error, generation: generation, retryAfter: Self.retrySeconds)
                } else {
                    self?.opened(generation: generation)
                }
            }
        }
    }

    private func opened(generation: Int) {
        let current = lock.withLock { () -> Bool in
            if generation == self.generation {
                liveness.opened(at: CACurrentMediaTime())
                return true
            } else {
                return false
            }
        }
        if current {
            DiagnosticsStore.shared.note("input.decklink", detail: "\(name): open")
        }
    }

    private func failed(_ message: String, generation: Int, retryAfter delay: Double) {
        let action = lock.withLock {
            liveness.failed(message, current: generation == self.generation)
        }
        if case .retry(let note) = action {
            if note {
                DiagnosticsStore.shared.note("input.decklink", detail: "\(name): \(message) — retrying")
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) { [weak self] in
                if let self {
                    self.lock.withLock { self.liveness.retrying() }
                    self.open()
                }
            }
        }
    }

    fileprivate func frameArrived(_ surface: IOSurface, generation: Int) {
        var unmanaged: Unmanaged<CVPixelBuffer>?
        CVPixelBufferCreateWithIOSurface(
            kCFAllocatorDefault, unsafeBitCast(surface, to: IOSurfaceRef.self), nil, &unmanaged)
        let now = CACurrentMediaTime()
        if let buffer = unmanaged?.takeRetainedValue() {
            lock.withLock {
                if generation == self.generation {
                    latest = buffer
                    lastFrameAt = now
                    liveness.arrived(at: now)
                }
            }
        }
    }

    fileprivate func audioArrived(_ samples: Data, frames: Int, channels: Int, hostTime: Double, generation: Int) {
        let sinks = lock.withLock { () -> [AudioSink] in
            if generation == self.generation {
                liveness.arrived(at: CACurrentMediaTime())
                return Array(audioSinks.values)
            } else {
                return []
            }
        }
        if !sinks.isEmpty,
            let buffer = samples.withUnsafeBytes({
                AudioInputHub.deviceBuffer(int32Interleaved: $0, frames: frames, channels: channels)
            }) {
            let when = AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: hostTime))

            RealtimeAudioCallback.scope {
                for sink in sinks { sink(buffer, when, hostTime) }
            }
        }
    }

    fileprivate func formatChanged(_ format: String, interlaced: Bool, generation: Int) {
        if lock.withLock({ generation == self.generation }) {
            DiagnosticsStore.shared.note(
                "input.decklink",
                detail: "\(name): \(format)" + (interlaced ? " (interlaced — deinterlacing)" : ""))
        }
    }

    fileprivate func signalChanged(_ present: Bool, generation: Int) {
        if lock.withLock({ generation == self.generation }) {
            DiagnosticsStore.shared.note(
                "input.decklink", detail: "\(name): " + (present ? "signal" : "no signal"))
        }
    }
}

private final class DeckLinkDirectSink: NSObject, DeckLinkInputSinkProtocol, @unchecked Sendable {
    private weak var owner: DeckLinkDirectCapture?
    private let generation: Int

    init(owner: DeckLinkDirectCapture, generation: Int) {
        self.owner = owner
        self.generation = generation
    }

    func inputFrame(_ surface: IOSurface, hostTime: Double, reply: @escaping () -> Void) {
        owner?.frameArrived(surface, generation: generation)

        reply()
    }

    func inputAudio(_ samples: Data, frames: Int32, channels: Int32, hostTime: Double) {
        owner?.audioArrived(
            samples, frames: Int(frames), channels: Int(channels), hostTime: hostTime,
            generation: generation)
    }

    func inputFormat(_ name: String, interlaced: Bool) {
        owner?.formatChanged(name, interlaced: interlaced, generation: generation)
    }

    func inputSignal(_ present: Bool) {
        owner?.signalChanged(present, generation: generation)
    }
}

final class DeckLinkDirectAudioFeed: ExternalInputFeed, @unchecked Sendable {
    let persistentID: Int64
    let uid: String
    private let lock = NSLock()
    private var token: UUID?

    init(persistentID: Int64, uid: String) {
        self.persistentID = persistentID
        self.uid = uid
    }

    func start(into hub: AudioInputHub) throws {
        let name = AudioDeviceList.inputDevice(uid: uid)?.name ?? "DeckLink \(persistentID)"
        let capture = DeckLinkDirectInputs.shared.acquire(persistentID: persistentID, name: name)
        let token = capture.addAudioSink { [weak hub] buffer, when, hostSeconds in
            hub?.push(buffer, when: when, hostSeconds: hostSeconds)
        }
        lock.withLock { self.token = token }
    }

    func stop() {
        if let token = lock.withLock({ self.token }) {
            DeckLinkDirectInputs.shared.capture(persistentID: persistentID)?.removeAudioSink(token)
        }
        DeckLinkDirectInputs.shared.release(persistentID: persistentID)
    }
}
