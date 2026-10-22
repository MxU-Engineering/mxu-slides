import AVFoundation
import Testing

@testable import AudioEngine

@Test func int32InterleavedBecomesDeinterleavedFloat() {
    let samples: [Int32] = [Int32.max, Int32.min, 0, 1 << 30]
    let buffer = samples.withUnsafeBytes {
        AudioInputHub.deviceBuffer(int32Interleaved: $0, frames: 2, channels: 2)
    }
    #expect(buffer?.frameLength == 2)
    #expect(buffer?.format.sampleRate == 48_000)
    let left = buffer!.floatChannelData![0]
    let right = buffer!.floatChannelData![1]
    #expect(abs(left[0] - 1) < 0.0001)
    #expect(left[1] == 0)
    #expect(right[0] == -1)
    #expect(right[1] == 0.5)
}

@Test func directUIDsRoundTripAndCoreAudioUIDsAreNotDirect() {
    let uid = DeckLinkAudioUID.uid(persistentID: -42)
    #expect(uid == "decklink:-42")
    #expect(DeckLinkAudioUID.persistentID(uid) == -42)
    #expect(DeckLinkAudioUID.persistentID("AppleUSBAudioEngine:Elgato:4K S") == nil)
    #expect(DeckLinkAudioUID.persistentID("decklink:not-a-number") == nil)
}

@Test func aShortPacketIsRefused() {
    let samples: [Int32] = [1, 2, 3]
    let buffer = samples.withUnsafeBytes {
        AudioInputHub.deviceBuffer(int32Interleaved: $0, frames: 2, channels: 2)
    }
    #expect(buffer == nil)
}

private final class FakeFeed: ExternalInputFeed, @unchecked Sendable {
    private let lock = NSLock()
    private var _hub: AudioInputHub?
    private var _stops = 0
    var hub: AudioInputHub? { lock.withLock { _hub } }
    var stops: Int { lock.withLock { _stops } }
    func start(into hub: AudioInputHub) throws { lock.withLock { _hub = hub } }
    func stop() { lock.withLock { _stops += 1 } }
}

@Test func externalUIDsRideTheirFeedThroughTheHub() throws {
    let pool = AudioInputHubPool()
    let feed = FakeFeed()
    pool.externalFeedProvider = { uid in uid == "decklink:7" ? feed : nil }
    pool.trimProvider = { _ in (0.5, false) }

    let hub = try pool.acquire(deviceUID: "decklink:7")
    #expect(feed.hub === hub, "the feed pushes into the hub it was started on")
    let heard = Box()
    _ = hub.addTap(channels: .stereoPair(offset: 2)) { buffer, _, host in
        heard.set(buffer.floatChannelData![0][0], host)
    }

    let samples: [Int32] = [0, 0, 1 << 30, 0]
    let buffer = samples.withUnsafeBytes {
        AudioInputHub.deviceBuffer(int32Interleaved: $0, frames: 1, channels: 4)
    }!
    hub.push(buffer, when: AVAudioTime(hostTime: 0), hostSeconds: 12)
    #expect(heard.value == 0.25)
    #expect(heard.host == 12)

    _ = try pool.acquire(deviceUID: "decklink:7")
    pool.release(deviceUID: "decklink:7")
    #expect(feed.stops == 0, "a holder remains")
    pool.release(deviceUID: "decklink:7")
    #expect(feed.stops == 1, "the last release stops the feed")
}

@Test func externalInputsListBesideCoreAudio() {
    let direct = AudioDeviceList.AudioInputDevice(
        id: 0, uid: "decklink:test-list", name: "DeckLink Duo (1) (Direct)", channelCount: 16)
    AudioDeviceList.setExternalInputDevices([direct])
    defer { AudioDeviceList.setExternalInputDevices([]) }
    #expect(AudioDeviceList.inputDevices().contains(direct))
    #expect(AudioDeviceList.inputDevice(uid: "decklink:test-list") == direct)
}

private final class Box: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Float?
    private var _host: Double?
    var value: Float? { lock.withLock { _value } }
    var host: Double? { lock.withLock { _host } }
    func set(_ value: Float, _ host: Double) {
        lock.withLock {
            _value = value
            _host = host
        }
    }
}
