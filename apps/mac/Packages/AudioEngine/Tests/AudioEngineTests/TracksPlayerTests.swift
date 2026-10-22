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

private func rawConnect(_ path: String) -> Int32 {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &address.sun_path) { raw in
        let bytes = Array(path.utf8)
        raw.copyBytes(from: bytes)
        raw[bytes.count] = 0
    }
    _ = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    return fd
}

@Test func aConnectionThatNeverSaysHelloCantTakeSlidesPlace() throws {
    let path = socketPath()
    let server = TracksPlayerServer(socketPath: path, engine: MultitrackEngine(), exit: { _ in })
    #expect(try server.start())
    let client = TracksPlayerClient(socketPath: path) { Issue.record("no launch") }
    let statuses = Box(0)
    let reasons = Box<[String]>([])
    client.onStatus = { _ in statuses.value += 1 }
    client.onDisconnect = { reasons.value.append($0) }
    client.reattach()
    #expect(waitFor { statuses.value > 0 })

    #expect(try TracksPlayerServer(socketPath: path, engine: MultitrackEngine(), exit: { _ in }).start() == false)
    let probe = rawConnect(path)
    Thread.sleep(forTimeInterval: 0.2)
    close(probe)
    let before = statuses.value
    #expect(waitFor { statuses.value > before + 2 })
    #expect(reasons.value.isEmpty)
    #expect(client.isConnected)
    client.disconnect()
    server.shutDown()
}

@Test func aLostConnectionReattachesButAReplacedSlidesStaysOff() throws {
    let path = socketPath()
    let server = TracksPlayerServer(socketPath: path, engine: MultitrackEngine(), exit: { _ in })
    #expect(try server.start())
    let first = TracksPlayerClient(socketPath: path) { Issue.record("no launch") }
    let firstReasons = Box<[String]>([])
    let firstConnects = Box(0)
    first.onConnect = { firstConnects.value += 1 }
    first.onDisconnect = { firstReasons.value.append($0) }
    let heardPid = Box<Int32?>(nil)
    first.onStatus = { heardPid.value = $0.pid }
    first.reattach()
    #expect(waitFor { heardPid.value == getpid() })

    server.shutDown()
    let again = TracksPlayerServer(socketPath: path, engine: MultitrackEngine(), exit: { _ in })
    #expect(try again.start())
    #expect(waitFor { firstConnects.value == 2 })
    #expect(firstReasons.value == ["end of file"])
    let second = TracksPlayerClient(socketPath: path) { Issue.record("no launch") }
    second.reattach()
    #expect(waitFor { firstReasons.value.last == "another Slides took over" })
    Thread.sleep(forTimeInterval: 1.2)
    #expect(firstConnects.value == 2, "a replaced Slides doesn't fight back")
    #expect(!first.isConnected && second.isConnected)
    second.disconnect()
    again.shutDown()
}

@Test func thePlayersShareIsMappedByName() throws {
    let path = socketPath()
    let engine = MultitrackEngine()
    let server = TracksPlayerServer(socketPath: path, engine: engine, exit: { _ in })
    #expect(try server.start())
    let name = TracksPlayerWire.shareName(socketPath: path)
    #expect(name.utf8.count <= 31)
    let mapped = try #require(TracksShare.open(name: name))
    #expect(mapped.sampleRate == 48_000)
    let ones = [Float](repeating: 1, count: 64)
    ones.withUnsafeBufferPointer { engine.share?.write(slot: 9, left: $0.baseAddress, right: $0.baseAddress, count: 64) }
    #expect(mapped.writtenFrames(slot: 9) == 64)
    server.shutDown()
    #expect(TracksShare.open(name: name) == nil)
}

@Test func thePlayerPreloadsWhatSlidesNames() throws {
    let path = socketPath()
    let engine = MultitrackEngine()
    let server = TracksPlayerServer(socketPath: path, engine: engine, exit: { _ in })
    #expect(try server.start())
    let client = TracksPlayerClient(socketPath: path) {}
    client.send(.preload(songs: [MultitrackSong(id: "next", stems: [.init(path: try silentStem(), channelId: "c")])]))
    #expect(waitFor { engine.preloadedSongIDs == ["next"] })
    client.disconnect()
    server.shutDown()
}
