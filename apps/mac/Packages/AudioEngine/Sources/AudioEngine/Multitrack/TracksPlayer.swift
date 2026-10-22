import Darwin
import Foundation
import os

public enum TracksPlayerMessage: Codable, Equatable, Sendable {

    case hello(version: Int)
    case attach(deviceUID: String?)
    case cue(song: MultitrackSong, at: Double)
    case routing(MultitrackRouting)
    case play(hostTime: UInt64)
    case stop
    case seek(seconds: Double)

    case quit

    case status(TracksPlayerStatus)
}

public struct TracksPlayerStatus: Codable, Equatable, Sendable {
    public var songID: String?
    public var playing: Bool

    public var frame: Int64
    public var hostTime: UInt64
    public var sampleRate: Double
    public var deviceUID: String?
    public var deviceChannels: Int
    public var starvedFrames: Int64

    public var meters: [String: [Float]]
    public var error: String?

    public var channels: [String]?

    public func position(atHostTime now: UInt64 = mach_absolute_time()) -> Double {
        var seconds = sampleRate > 0 ? Double(frame) / sampleRate : 0
        guard playing, hostTime > 0, now > hostTime else { return seconds }
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        seconds += Double(now - hostTime) * Double(timebase.numer) / Double(timebase.denom) / 1e9
        return seconds
    }
}

public enum TracksPlayerWire {

    public static let version = 1

    public static func socketPath(appIdentity: String) -> String {
        var hash: UInt32 = 2_166_136_261
        for byte in appIdentity.utf8 { hash = (hash ^ UInt32(byte)) &* 16_777_619 }
        return (NSTemporaryDirectory() as NSString).appendingPathComponent(String(format: "mxu-tracks-%08x.sock", hash))
    }
}

final class TracksPlayerConnection: @unchecked Sendable {
    private let fd: Int32
    private let queue: DispatchQueue
    private var source: DispatchSourceRead?
    private var pending = Data()
    private let onMessage: (TracksPlayerMessage) -> Void
    private let onClose: (TracksPlayerConnection) -> Void
    private var closed = false

    init(
        fd: Int32, queue: DispatchQueue, onMessage: @escaping (TracksPlayerMessage) -> Void,
        onClose: @escaping (TracksPlayerConnection) -> Void
    ) {
        self.fd = fd
        self.queue = queue
        self.onMessage = onMessage
        self.onClose = onClose

        closed = !noSigPipe(fd)
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.readAvailable() }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
        if closed { queue.async { [self] in closed = false; shut() } }
    }

    func send(_ message: TracksPlayerMessage) {
        queue.async { [self] in
            guard !closed, var data = try? JSONEncoder().encode(message) else { return }
            data.append(0x0A)
            let ok = data.withUnsafeBytes { bytes -> Bool in
                var offset = 0
                while offset < bytes.count {
                    let wrote = write(fd, bytes.baseAddress! + offset, bytes.count - offset)
                    if wrote > 0 {
                        offset += wrote
                    } else if wrote < 0, errno == EAGAIN {
                        usleep(1000)
                    } else {
                        return false
                    }
                }
                return true
            }
            if !ok { shut() }
        }
    }

    func cancel() { queue.async { [self] in shut() } }

    private func readAvailable() {
        var buffer = [UInt8](repeating: 0, count: 65_536)
        let count = read(fd, &buffer, buffer.count)
        guard count > 0 else {
            if count == 0 || errno != EAGAIN { shut() }
            return
        }
        pending.append(contentsOf: buffer[0 ..< count])
        while let newline = pending.firstIndex(of: 0x0A) {
            let line = pending[pending.startIndex ..< newline]
            pending.removeSubrange(pending.startIndex ... newline)
            if let message = try? JSONDecoder().decode(TracksPlayerMessage.self, from: line) {
                onMessage(message)
            }
        }
    }

    private func shut() {
        guard !closed else { return }
        closed = true
        source?.cancel()
        onClose(self)
    }
}

private func unixAddress(_ path: String) -> sockaddr_un {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &address.sun_path) { raw in
        let bytes = Array(path.utf8.prefix(raw.count - 1))
        raw.copyBytes(from: bytes)
        raw[bytes.count] = 0
    }
    return address
}

@discardableResult
private func noSigPipe(_ fd: Int32) -> Bool {
    var on: Int32 = 1
    return setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size)) == 0
}

private func connectSocket(_ path: String) -> Int32? {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    noSigPipe(fd)
    var address = unixAddress(path)
    let result = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard result == 0 else { close(fd); return nil }
    return fd
}

public final class TracksPlayerServer: @unchecked Sendable {
    private let path: String
    private let engine: MultitrackEngine
    private let queue = DispatchQueue(label: "io.prodcontrol.tracksplayer.server")
    private var listenSource: DispatchSourceRead?
    private var client: TracksPlayerConnection?
    private var statusTimer: DispatchSourceTimer?
    private var alone: CFAbsoluteTime? = CFAbsoluteTimeGetCurrent()
    private var lastError: String?
    private let exit: @Sendable (Int32) -> Void
    private let log = Logger(subsystem: "io.prodcontrol.tracksplayer", category: "server")
    let orphanLimit: Double

    public init(
        socketPath: String, engine: MultitrackEngine, orphanLimit: Double = 600,
        exit: @escaping @Sendable (Int32) -> Void = { Darwin.exit($0) }
    ) {
        path = socketPath
        self.engine = engine
        self.orphanLimit = orphanLimit
        self.exit = exit
    }

    public func start() throws -> Bool {
        if let fd = connectSocket(path) {
            close(fd)
            return false
        }
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw MultitrackError.status(OSStatus(errno)) }

        noSigPipe(fd)
        var address = unixAddress(path)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, listen(fd, 4) == 0 else {
            close(fd)
            throw MultitrackError.status(OSStatus(errno))
        }
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.accept(fd) }
        source.setCancelHandler { close(fd) }
        source.resume()
        listenSource = source
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(66))
        timer.setEventHandler { [weak self] in self?.beat() }
        timer.resume()
        statusTimer = timer
        log.info("listening at \(self.path, privacy: .public)")
        return true
    }

    public func shutDown() {
        queue.sync {
            statusTimer?.cancel()
            listenSource?.cancel()
            client?.cancel()
            client = nil
            unlink(path)
        }
    }

    private func accept(_ listener: Int32) {
        let fd = Darwin.accept(listener, nil, nil)
        guard fd >= 0 else { return }

        client?.cancel()
        let connection = TracksPlayerConnection(fd: fd, queue: queue, onMessage: { [weak self] in
            self?.handle($0)
        }, onClose: { [weak self] connection in
            guard let self, self.client === connection else { return }
            self.client = nil
            self.alone = CFAbsoluteTimeGetCurrent()
            self.log.info("Slides went away; playing on alone")
        })
        client = connection
        alone = nil
        sendStatus()
    }

    private func handle(_ message: TracksPlayerMessage) {
        switch message {
        case .hello(let version):
            if version != TracksPlayerWire.version, !engine.isPlaying {
                log.info("version \(version) != \(TracksPlayerWire.version); exiting for the new player")
                finish(code: 0)
            }
        case .attach(let uid):
            let device = uid.flatMap { uid in AudioDeviceList.outputDevices().first { $0.uid == uid } }
            do {
                try engine.attach(device: device)
                lastError = nil
            } catch {
                lastError = "Couldn't open the tracks device: \(error)"
            }
        case .cue(let song, let at):
            engine.cue(song, at: at)
        case .routing(let routing):
            engine.setRouting(routing)
        case .play(let hostTime):
            engine.play(atHostTime: hostTime)
        case .stop:
            engine.stop()
        case .seek(let seconds):
            engine.seek(to: seconds)
        case .quit:
            engine.stop()
            queue.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.finish(code: 0) }
        case .status:
            break
        }
    }

    private func finish(code: Int32) {
        engine.detach()
        statusTimer?.cancel()
        listenSource?.cancel()
        unlink(path)
        exit(code)
    }

    private func beat() {
        if let alone {

            if engine.isPlaying, let length = engine.songLength, engine.position() >= length {
                engine.stop()
            }
            if !engine.isPlaying, CFAbsoluteTimeGetCurrent() - alone > orphanLimit {
                log.info("alone for \(Int(self.orphanLimit)) s; exiting")
                finish(code: 0)
            }
            return
        }
        sendStatus()
    }

    private func sendStatus() {
        guard let client else { return }
        client.send(.status(status()))
    }

    func status() -> TracksPlayerStatus {
        let published = engine.renderer.published
        return TracksPlayerStatus(
            songID: engine.songID, playing: published.playing,
            frame: published.playing ? published.frame : Int64((engine.position() * engine.sampleRate).rounded()),
            hostTime: published.hostTime, sampleRate: engine.sampleRate, deviceUID: engine.deviceUID,
            deviceChannels: engine.deviceChannels, starvedFrames: engine.starvedFrames,
            meters: engine.takeMeters().mapValues { [$0.left.rms, $0.left.peak, $0.right.rms, $0.right.peak] },
            error: lastError,
            channels: engine.songChannelIDs)
    }
}

public final class TracksPlayerClient: @unchecked Sendable {
    private let path: String
    private let launch: @Sendable () -> Void
    private let queue = DispatchQueue(label: "io.prodcontrol.tracksplayer.client")
    private var connection: TracksPlayerConnection?
    private var connecting = false
    private var backlog: [TracksPlayerMessage] = []
    public var onStatus: (@Sendable (TracksPlayerStatus) -> Void)?
    public var onConnect: (@Sendable () -> Void)?
    public var onDisconnect: (@Sendable () -> Void)?

    public init(socketPath: String, launch: @escaping @Sendable () -> Void) {
        path = socketPath
        self.launch = launch
    }

    public var isConnected: Bool { queue.sync { connection != nil } }

    public func send(_ message: TracksPlayerMessage) {
        queue.async { [self] in
            if let connection {
                connection.send(message)
            } else {
                backlog.append(message)
                connect()
            }
        }
    }

    public func reattach() {
        queue.async { [self] in
            guard connection == nil, let fd = connectSocket(path) else { return }
            adopt(fd)
        }
    }

    public func disconnect() {
        queue.sync {
            connection?.cancel()
            connection = nil
        }
    }

    private func connect() {
        guard !connecting else { return }
        if let fd = connectSocket(path) {
            adopt(fd)
            return
        }
        connecting = true
        launch()
        retry(attempt: 0)
    }

    private func retry(attempt: Int) {
        queue.asyncAfter(deadline: .now() + 0.1) { [self] in
            if let fd = connectSocket(path) {
                connecting = false
                adopt(fd)
            } else if attempt < 30 {
                retry(attempt: attempt + 1)
            } else {
                connecting = false
                backlog.removeAll()
            }
        }
    }

    private func adopt(_ fd: Int32) {
        let made = TracksPlayerConnection(fd: fd, queue: queue, onMessage: { [weak self] message in
            if case .status(let status) = message { self?.onStatus?(status) }
        }, onClose: { [weak self] connection in
            guard let self, self.connection === connection else { return }
            self.connection = nil
            self.onDisconnect?()
        })
        connection = made
        made.send(.hello(version: TracksPlayerWire.version))
        onConnect?()
        for message in backlog { made.send(message) }
        backlog.removeAll()
    }
}
