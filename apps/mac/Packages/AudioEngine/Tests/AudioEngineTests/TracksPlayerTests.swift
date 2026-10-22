import AVFoundation
import Foundation
import Testing
@testable import AudioEngine

private final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

private func waitFor(_ seconds: Double = 3, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if condition() { return true }
        Thread.sleep(forTimeInterval: 0.02)
    }
    return condition()
}

private func silentStem() throws -> String {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("tracks-\(UUID().uuidString).wav")
    let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000)!
    buffer.frameLength = 48_000
    try file.write(from: buffer)
    return url.path
}

private func socketPath() -> String { TracksPlayerWire.socketPath(appIdentity: UUID().uuidString) }

@Test func theClientStartsThePlayerAndHearsItsStatus() throws {
    let path = socketPath()
    let servers = Box<[TracksPlayerServer]>([])
    let launches = Box(0)
    let client = TracksPlayerClient(socketPath: path) {
        launches.value += 1
        let server = TracksPlayerServer(socketPath: path, engine: MultitrackEngine(), exit: { _ in })
        _ = try? server.start()
        servers.value.append(server)
    }
    let latest = Box<TracksPlayerStatus?>(nil)
    client.onStatus = { latest.value = $0 }
    client.send(.routing(MultitrackRouting(channels: [.init(id: "click")])))
    client.send(.cue(song: MultitrackSong(id: "way-maker", stems: [.init(path: try silentStem(), channelId: "click")]), at: 0))
    #expect(waitFor { latest.value?.songID == "way-maker" })
    #expect(launches.value == 1)
    #expect(latest.value?.sampleRate == 48_000)
    client.disconnect()
    servers.value.forEach { $0.shutDown() }
}

@Test func aRelaunchedSlidesFindsTheSongStillCued() throws {
    let path = socketPath()
    let server = TracksPlayerServer(socketPath: path, engine: MultitrackEngine(), exit: { _ in })
    #expect(try server.start())

    #expect(try TracksPlayerServer(socketPath: path, engine: MultitrackEngine(), exit: { _ in }).start() == false)
    let first = TracksPlayerClient(socketPath: path) {}
    first.send(.cue(song: MultitrackSong(id: "song", stems: [.init(path: try silentStem(), channelId: "c")]), at: 0.5))
    let firstHeard = Box(false)
    first.onStatus = { if $0.songID == "song" { firstHeard.value = true } }
    #expect(waitFor { firstHeard.value })
    first.disconnect()
    let second = TracksPlayerClient(socketPath: path) { Issue.record("must not launch a second player") }
    let heard = Box<TracksPlayerStatus?>(nil)
    second.onStatus = { heard.value = $0 }
    second.reattach()
    #expect(waitFor { heard.value?.songID == "song" })
    #expect(heard.value.map { abs($0.position() - 0.5) < 0.01 } == true)
    second.disconnect()
    server.shutDown()
}

@Test func anIdlePlayerLeftAloneQuits() throws {
    let path = socketPath()
    let exited = Box<Int32?>(nil)
    let server = TracksPlayerServer(socketPath: path, engine: MultitrackEngine(), orphanLimit: 0.3, exit: { exited.value = $0 })
    #expect(try server.start())
    let client = TracksPlayerClient(socketPath: path) {}
    let connected = Box(false)
    client.onStatus = { _ in connected.value = true }
    client.reattach()
    #expect(waitFor { connected.value })

    Thread.sleep(forTimeInterval: 0.5)
    #expect(exited.value == nil)
    client.disconnect()
    #expect(waitFor { exited.value == 0 })
}

@Test func anIdlePlayerOfAnotherVersionMakesWay() throws {
    let path = socketPath()
    let exited = Box<Int32?>(nil)
    let server = TracksPlayerServer(socketPath: path, engine: MultitrackEngine(), exit: { exited.value = $0 })
    #expect(try server.start())
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &address.sun_path) { raw in
        let bytes = Array(path.utf8)
        raw.copyBytes(from: bytes)
        raw[bytes.count] = 0
    }
    let connected = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    #expect(connected == 0)
    var line = try JSONEncoder().encode(TracksPlayerMessage.hello(version: TracksPlayerWire.version + 1))
    line.append(0x0A)
    _ = line.withUnsafeBytes { write(fd, $0.baseAddress!, $0.count) }
    #expect(waitFor { exited.value == 0 })
    close(fd)
}
