import AVFoundation
import CoreVideo
import Metal
import RenderEngine

public struct PlaybackOptions: Sendable, Equatable {
    public var inPoint: Double?
    public var outPoint: Double?
    public var rate: Double?

    public init(inPoint: Double? = nil, outPoint: Double? = nil, rate: Double? = nil) {
        self.inPoint = inPoint
        self.outPoint = outPoint
        self.rate = rate
    }

    public static let rateRange: ClosedRange<Double> = 0.25 ... 4

    public func resolved(
        duration: Double, frameDuration: Double
    ) -> (start: Double, end: Double, rate: Double) {
        let rate = min(max(self.rate ?? 1, Self.rateRange.lowerBound), Self.rateRange.upperBound)
        var start = min(max(inPoint ?? 0, 0), max(0, duration))
        var end = min(max(outPoint ?? duration, 0), duration)

        if end - start < max(frameDuration, 0.05) {
            start = 0
            end = duration
        }
        return (start, end, rate)
    }

    public func effectiveWallClockDuration(duration: Double, frameDuration: Double) -> Double {
        let (start, end, rate) = resolved(duration: duration, frameDuration: frameDuration)
        return rate > 0 ? (end - start) / rate : end - start
    }
}

public struct PreparedMedia {
    public let url: URL
    public let duration: Double

    public let frameDuration: Double
    public let naturalSize: CGSize
    public let hasAlpha: Bool
    let asset: AVURLAsset

    var outputPixelBufferAttributes: [String: any Sendable] {
        var attributes: [String: any Sendable] = [
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]
        if hasAlpha {
            attributes[kCVPixelBufferPixelFormatTypeKey as String] = kCVPixelFormatType_32BGRA
        } else {
            attributes[kCVPixelBufferPixelFormatTypeKey as String] = [
                kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            ]
        }
        return attributes
    }
}

public final class MediaEngine: @unchecked Sendable {
    private let device: MTLDevice
    private let factory: SurfaceFactory
    private let players = Locked<[String: MediaPlayer]>([:])
    private let stills = Locked<[String: StillImage]>([:])

    private let captures = Locked<[String: CaptureSource]>([:])

    private struct LiveSource {
        let latestFrame: @Sendable () -> CVPixelBuffer?
        let onStop: @Sendable () -> Void
    }
    private let liveSources = Locked<[String: LiveSource]>([:])

    private let inputDelay = LiveInputDelay()
    private let audioDeviceUID = Locked<String?>(nil)
    private let audioVolume = Locked<Float>(1)

    private let videoAudioSink = Locked<VideoAudioTap.Sink?>(nil)

    private let videoAudioDelay = Locked<Double>(0)

    public func setVideoAudioConsumer(
        _ consumer: (@Sendable (AVAudioPCMBuffer) -> Void)?
    ) {
        videoAudioSink.value = consumer
    }

    public init(device: MTLDevice) throws {
        self.device = device
        factory = try SurfaceFactory(device: device)
    }

    public func prepare(url: URL) async throws -> PreparedMedia {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw MediaEngineError.noVideoTrack(url)
        }
        let duration = try await asset.load(.duration).seconds
        let (naturalSize, minFrameDuration, descriptions) = try await track.load(
            .naturalSize, .minFrameDuration, .formatDescriptions
        )
        let frameDuration = minFrameDuration.isNumeric && minFrameDuration.seconds > 0
            ? minFrameDuration.seconds
            : 1.0 / 30.0
        return PreparedMedia(
            url: url,
            duration: duration,
            frameDuration: frameDuration,
            naturalSize: naturalSize,
            hasAlpha: descriptions.contains(where: Self.carriesAlpha),
            asset: asset
        )
    }

    private static func carriesAlpha(_ description: CMFormatDescription) -> Bool {
        if let contains = CMFormatDescriptionGetExtension(
            description, extensionKey: kCMFormatDescriptionExtension_ContainsAlphaChannel
        ) as? Bool {
            return contains
        }

        let subType = CMFormatDescriptionGetMediaSubType(description)
        return subType == kCMVideoCodecType_AppleProRes4444 || subType == kCMVideoCodecType_AppleProRes4444XQ
    }

    public func play(
        _ media: PreparedMedia, id: String, loop: Bool,
        options: PlaybackOptions = PlaybackOptions()
    ) {
        let player = MediaPlayer(
            media: media, loop: loop, factory: factory, audioDeviceUID: audioDeviceUID.value,
            audioSink: videoAudioSink, audioDelay: videoAudioDelay, options: options
        )
        player.setAudioVolume(audioVolume.value)
        replacePlayer(player, for: id)
        stills.withLock { $0[id] = nil }
        player.play()
    }

    @discardableResult
    public func preroll(
        _ media: PreparedMedia, id: String, loop: Bool,
        options: PlaybackOptions = PlaybackOptions()
    ) async -> Bool {
        let player = MediaPlayer(
            media: media, loop: loop, factory: factory, audioDeviceUID: audioDeviceUID.value,
            audioSink: videoAudioSink, audioDelay: videoAudioDelay, options: options
        )
        player.setAudioVolume(audioVolume.value)
        replacePlayer(player, for: id)
        stills.withLock { $0[id] = nil }
        return await player.preroll()
    }

    public func start(id: String) {
        players.value[id]?.play()
    }

    public func stop(id: String) {
        replacePlayer(nil, for: id)
        stills.withLock { $0[id] = nil }
        stopCapture(id: id)
        removeLiveSource(id: id)
    }

    public func stopAll() {
        let stopped = players.withLock { table in
            let all = Array(table.values)
            table.removeAll()
            return all
        }
        for player in stopped { player.stop() }
        stills.withLock { $0.removeAll() }
    }

    public func stopAll(withPrefix prefix: String) {
        let stopped = players.withLock { table in
            let matching = table.filter { $0.key.hasPrefix(prefix) }
            for key in matching.keys { table[key] = nil }
            return Array(matching.values)
        }
        for player in stopped { player.stop() }
        stills.withLock { table in
            for key in table.keys where key.hasPrefix(prefix) { table[key] = nil }
        }
    }

    public func hasStill(id: String) -> Bool {
        stills.value[id] != nil
    }

    public var playingIDs: [String] { Array(players.value.keys) }

    public func pause(id: String) {
        players.value[id]?.pause()
    }

    public func resume(id: String) {
        players.value[id]?.resume()
    }

    public func seek(id: String, to seconds: Double, precise: Bool) {
        players.value[id]?.seek(to: seconds, precise: precise)
    }

    public func transport(id: String) -> MediaTransportState? {
        players.value[id]?.transport
    }

    public func transportStates() -> [String: MediaTransportState] {
        players.value.mapValues(\.transport)
    }

    public func setAudioOutputDevice(uid: String?) {
        audioDeviceUID.value = uid
        for player in players.value.values {
            player.setAudioOutputDevice(uid: uid)
        }
    }

    public func setAudioOutputDelay(milliseconds: Int) {
        videoAudioDelay.value = Double(max(0, min(milliseconds, 2000)))
    }

    public func setAudioVolume(_ volume: Float) {
        let clamped = min(max(volume, 0), 1)
        audioVolume.value = clamped
        for player in players.value.values {
            player.setAudioVolume(clamped)
        }
    }

    private func replacePlayer(_ player: MediaPlayer?, for id: String) {
        let previous = players.withLock { table -> MediaPlayer? in
            let existing = table[id]
            table[id] = player
            return existing
        }

        if let previous {
            DispatchQueue.global(qos: .utility).async {
                previous.stop()
            }
        }
    }

    @discardableResult
    public func showStill(url: URL, id: String) async throws -> CGSize {
        let size: CGSize
        if let existing = stills.value[id], existing.url == url {
            size = existing.size
        } else {
            let still = try StillImage.load(url: url, device: device)
            stills.withLock { $0[id] = still }
            size = still.size
        }
        replacePlayer(nil, for: id)
        return size
    }

    @discardableResult
    public func showStill(image: CGImage, cacheKey: String, id: String) async throws -> CGSize {
        let syntheticURL = URL(string: "still-image://\(cacheKey)")
            ?? URL(fileURLWithPath: "/still-image/\(cacheKey)")
        let size: CGSize
        if let existing = stills.value[id], existing.url == syntheticURL {
            size = existing.size
        } else {
            let still = try StillImage.make(image: image, url: syntheticURL, device: device)
            stills.withLock { $0[id] = still }
            size = still.size
        }
        replacePlayer(nil, for: id)
        return size
    }

    public func stats(for id: String) -> PlaybackStats? {
        players.value[id]?.stats
    }

    func playerForTesting(id: String) -> MediaPlayer? {
        players.value[id]
    }

    public var aggregateStats: PlaybackStats {
        players.value.values.reduce(PlaybackStats()) { $0 + $1.stats }
    }
}

extension MediaEngine {

    public static let captureNote = Locked<(@Sendable (String) -> Void)?>(nil)

    public static func captureFrameRates(for device: AVCaptureDevice) -> [Double] {
        let (candidates, active) = CaptureSource.candidates(of: device)
        return CaptureFormatChoice.rates(among: candidates, active: active)
    }

    public func startCapture(device: AVCaptureDevice, id: String, frameRate: Double? = nil) throws {
        let capture = try CaptureSource(device: device, frameRate: frameRate)
        let previous = captures.withLock { table -> CaptureSource? in
            let existing = table[id]
            table[id] = capture
            return existing
        }
        previous?.stop()
        inputDelay.clear(id: id)
        players.withLock { $0[id] = nil }
        stills.withLock { $0[id] = nil }
        capture.start()
    }

    public func stopCapture(id: String) {
        let previous = captures.withLock { table -> CaptureSource? in
            let existing = table[id]
            table[id] = nil
            return existing
        }
        previous?.stop()
        inputDelay.clear(id: id)
    }

    public func setInputDelay(id: String, frames: Int) {
        inputDelay.setDelay(id: id, frames: frames)
    }

    public var activeCaptureIDs: [String] {
        captures.withLock { Array($0.keys) }
    }

    public func captureFrameAge(id: String, at hostTime: CFTimeInterval) -> Double? {
        captures.value[id]?.frameAge(at: hostTime)
    }

    public func registerLiveSource(
        id: String,
        latestFrame: @escaping @Sendable () -> CVPixelBuffer?,
        onStop: @escaping @Sendable () -> Void
    ) {
        let previous = liveSources.withLock { table -> LiveSource? in
            let existing = table[id]
            table[id] = LiveSource(latestFrame: latestFrame, onStop: onStop)
            return existing
        }
        previous?.onStop()
        inputDelay.clear(id: id)
        players.withLock { $0[id] = nil }
        stills.withLock { $0[id] = nil }
    }

    private func removeLiveSource(id: String) {
        let previous = liveSources.withLock { table -> LiveSource? in
            let existing = table[id]
            table[id] = nil
            return existing
        }
        previous?.onStop()
        inputDelay.clear(id: id)
    }
}

extension MediaEngine: MediaTextureSource {
    public func surface(for mediaID: String, hostTime: CFTimeInterval) -> MediaSurface? {
        if let capture = captures.value[mediaID] {
            guard let frame = capture.latestFrame() else { return nil }
            return factory.makeSurface(from: inputDelay.delayed(frame, id: mediaID))
        }
        if let live = liveSources.value[mediaID] {
            guard let frame = live.latestFrame() else { return nil }
            return factory.makeSurface(from: inputDelay.delayed(frame, id: mediaID))
        }
        if let player = players.value[mediaID] {
            return player.surface(at: hostTime)
        }

        return stills.value[mediaID]?.surface
    }

    public func liveCadence(for mediaID: String) -> LiveCadence? {
        captures.value[mediaID]?.cadence
    }
}
