import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import HaishinKit
import os
import RTMPHaishinKit
import SRTHaishinKit
import VideoToolbox

private let log = Logger(subsystem: "com.example.mxuslides", category: "stream")

public final class StreamSession: @unchecked Sendable {
    public enum State: Equatable, Sendable {
        case idle
        case connecting
        case publishing
        case reconnecting(attempt: Int)
        case failed(String)
        case stopped
    }

    public struct Status: Sendable, Equatable {
        public var state: State
        public var framesSubmitted: Int
        public var framesDropped: Int
    }

    public let destination: StreamEndpoint
    public let video: StreamVideoConfiguration

    private struct Mutable {
        var state: State = .idle
        var framesSubmitted = 0
        var framesDropped = 0

        var audioFormat: AVAudioFormat?
        var audioFormatMismatchLogged = false
    }

    private struct Pipes {
        var frames: AsyncStream<CMSampleBuffer>.Continuation?
        var audio: AsyncStream<(AVAudioPCMBuffer, AVAudioTime)>.Continuation?
    }

    private let mutable = NSLock()
    private var storage = Mutable()

    private var pipes = Pipes()
    private var supervisorTask: Task<Void, Never>?
    private var formatDescription: CMVideoFormatDescription?
    private let scaler = PixelScaler()

    private let hlsContinuity = HLSContinuity()

    public init(destination: StreamEndpoint, video: StreamVideoConfiguration) {
        self.destination = destination
        self.video = video
    }

    public var status: Status {
        mutable.withLock {
            Status(
                state: storage.state,
                framesSubmitted: storage.framesSubmitted,
                framesDropped: storage.framesDropped)
        }
    }

    private func setState(_ state: State) {
        mutable.withLock { storage.state = state }
    }

    public func start() {
        guard mutable.withLock({
            guard storage.state == .idle || storage.state == .stopped else { return false }
            storage.state = .connecting
            return true
        }) else { return }

        supervisorTask = Task { [weak self] in
            await self?.superviseConnection()
        }
    }

    public func stop() {
        setState(.stopped)
        let taken = mutable.withLock {
            let taken = pipes
            pipes = Pipes()
            return taken
        }
        taken.frames?.finish()
        taken.audio?.finish()
        let supervisor = supervisorTask
        supervisorTask = nil
        if destination.kind == .hls {

            Task {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                supervisor?.cancel()
            }
        } else {
            supervisor?.cancel()
        }
    }

    public func append(_ pixelBuffer: CVPixelBuffer, atHostSeconds seconds: Double) {
        let continuation = mutable.withLock {
            storage.state == .publishing ? pipes.frames : nil
        }
        guard let continuation else { return }
        guard let sample = makeSampleBuffer(pixelBuffer, seconds: seconds) else {
            mutable.withLock { storage.framesDropped += 1 }
            return
        }
        switch continuation.yield(sample) {
        case .enqueued:
            mutable.withLock { storage.framesSubmitted += 1 }
        default:
            mutable.withLock { storage.framesDropped += 1 }
        }
    }

    public func appendAudio(_ buffer: AVAudioPCMBuffer, when: AVAudioTime) {
        guard buffer.frameLength > 0 else { return }
        var mismatch: AVAudioFormat?
        let continuation = mutable.withLock { () -> AsyncStream<(AVAudioPCMBuffer, AVAudioTime)>.Continuation? in
            guard storage.state == .publishing else { return nil }
            if let pinned = storage.audioFormat {
                guard buffer.format == pinned else {
                    if !storage.audioFormatMismatchLogged {
                        storage.audioFormatMismatchLogged = true
                        mismatch = pinned
                    }
                    return nil
                }
            } else {
                storage.audioFormat = buffer.format
            }
            return pipes.audio
        }
        if let mismatch {
            log.warning("audio format changed mid-stream: \(self.destination.name, privacy: .public) pinned=\(mismatch, privacy: .public) got=\(buffer.format, privacy: .public) — dropping until reconnect")
        }
        guard let continuation, let copy = Self.copiedAudioBuffer(buffer) else { return }
        continuation.yield((copy, when))
    }

    static func copiedAudioBuffer(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(
            pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return nil }
        copy.frameLength = buffer.frameLength
        let source = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: buffer.audioBufferList))
        let target = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for (from, to) in zip(source, target) {
            guard let fromData = from.mData, let toData = to.mData else { return nil }
            memcpy(toData, fromData, Int(min(from.mDataByteSize, to.mDataByteSize)))
        }
        return copy
    }

    private func superviseConnection() async {
        var attempt = 0
        while !Task.isCancelled {

            let (frames, frameContinuation) = AsyncStream<CMSampleBuffer>.makeStream(
                bufferingPolicy: .bufferingNewest(2))

            let (audio, audioContinuation) = AsyncStream<(AVAudioPCMBuffer, AVAudioTime)>
                .makeStream(bufferingPolicy: .bufferingNewest(16))
            let proceed = mutable.withLock {
                guard storage.state != .stopped else { return false }
                pipes = Pipes(frames: frameContinuation, audio: audioContinuation)

                storage.audioFormat = nil
                storage.audioFormatMismatchLogged = false
                return true
            }
            guard proceed else { return }

            do {
                try await runOnce(frames: frames, audio: audio)

                return
            } catch let error as StreamSessionError where error.isFatal {

                log.error("transport failed permanently: \(self.destination.name, privacy: .public) — \(String(describing: error), privacy: .public)")
                setState(.failed(error.failureDescription))
                return
            } catch {

                let wasPublishing = mutable.withLock { storage.state == .publishing }
                guard mutable.withLock({ storage.state != .stopped }) else { return }
                attempt = wasPublishing ? 1 : attempt + 1
                log.warning("transport lost: \(self.destination.name, privacy: .public) attempt \(attempt) — \(String(describing: error), privacy: .public)")
                setState(.reconnecting(attempt: attempt))

                let delay = min(15.0, pow(2.0, Double(attempt - 1)))
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }

    private func runOnce(
        frames: AsyncStream<CMSampleBuffer>,
        audio: AsyncStream<(AVAudioPCMBuffer, AVAudioTime)>
    ) async throws {
        switch destination.kind {
        case .rtmp, .rtmps:
            let connection = RTMPConnection()
            let stream = RTMPStream(connection: connection)
            try await configure(stream: stream)
            _ = try await connection.connect(destination.url)
            _ = try await stream.publish(destination.streamKey)
            setState(.publishing)
            log.info("publishing: \(self.destination.name, privacy: .public) -> \(self.destination.url, privacy: .public)")
            defer {
                Task {
                    _ = try? await stream.close()
                    try? await connection.close()
                }
            }

            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { [weak self] in
                    await self?.pump(frames: frames, audio: audio, into: stream)
                }
                group.addTask {
                    for await event in await connection.status where Self.endsTransport(event) {
                        throw StreamSessionError.transportClosed(event.code)
                    }

                    if !Task.isCancelled {
                        throw StreamSessionError.transportClosed("status stream ended")
                    }
                }
                group.addTask {

                    while true {
                        try await Task.sleep(nanoseconds: 2_000_000_000)
                        guard await connection.connected else {
                            throw StreamSessionError.transportClosed("connected flag dropped")
                        }
                    }
                }

                try await group.next()
                group.cancelAll()
            }
        case .hls:

            let transport = HLSTransport(
                destination: destination, video: video, continuity: hlsContinuity)
            setState(.publishing)
            log.info("publishing: \(self.destination.name, privacy: .public) -> hls ingest")
            try await transport.run(frames: frames, audio: audio)
        case .srt:
            let connection = SRTConnection()
            let stream = SRTStream(connection: connection)
            try await configure(stream: stream)
            guard let url = URL(string: destination.url) else {
                throw StreamSessionError.badURL(destination.url)
            }
            try await connection.connect(url)
            await stream.publish()
            setState(.publishing)
            defer {
                Task {
                    await stream.close()
                    try? await connection.close()
                }
            }

            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { [weak self] in
                    await self?.pump(frames: frames, audio: audio, into: stream)
                }
                group.addTask {
                    while true {
                        try await Task.sleep(nanoseconds: 2_000_000_000)
                        guard await connection.connected else {
                            throw StreamSessionError.transportClosed("srt disconnected")
                        }
                    }
                }
                try await group.next()
                group.cancelAll()
            }
        }
    }

    private static func endsTransport(_ event: RTMPStatus) -> Bool {
        if event.level == "error" { return true }
        switch RTMPConnection.Code(rawValue: event.code) {
        case .connectClosed, .connectIdleTimeOut, .connectAppshutdown:
            return true
        default:
            return false
        }
    }

    private func configure(stream: some StreamConvertible) async throws {
        var settings = VideoCodecSettings()
        settings.videoSize = CGSize(width: video.width, height: video.height)
        settings.bitRate = video.bitrateKbps * 1000

        settings.profileLevel = kVTProfileLevel_H264_High_AutoLevel as String
        try await stream.setVideoSettings(settings)
        var audioSettings = AudioCodecSettings()
        audioSettings.bitRate = 128_000
        try await stream.setAudioSettings(audioSettings)
    }

    private func pump(
        frames: AsyncStream<CMSampleBuffer>,
        audio: AsyncStream<(AVAudioPCMBuffer, AVAudioTime)>,
        into stream: some StreamConvertible
    ) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for await sample in frames {
                    await stream.append(sample)
                    if self.mutable.withLock({ self.storage.state != .publishing }) {
                        break
                    }
                }
            }
            group.addTask {
                for await (buffer, when) in audio {
                    await stream.append(buffer, when: when)

                    if self.mutable.withLock({ self.storage.state != .publishing }) {
                        break
                    }
                }
            }

            await group.next()
            group.cancelAll()
        }
    }

    private func makeSampleBuffer(_ pixelBuffer: CVPixelBuffer, seconds: Double) -> CMSampleBuffer? {

        var pixelBuffer = pixelBuffer
        let incomingHDR = CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_ARGB2101010LEPacked
        if CVPixelBufferGetWidth(pixelBuffer) != video.width
            || CVPixelBufferGetHeight(pixelBuffer) != video.height
            || incomingHDR != video.hdr {
            guard let transferred = scaler.transfer(
                pixelBuffer, width: video.width, height: video.height, hdr: video.hdr) else {
                return nil
            }
            pixelBuffer = transferred
        }
        if formatDescription == nil
            || CMVideoFormatDescriptionMatchesImageBuffer(formatDescription!, imageBuffer: pixelBuffer) == false {
            var fresh: CMVideoFormatDescription?
            CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer,
                formatDescriptionOut: &fresh)
            formatDescription = fresh
        }
        guard let formatDescription else { return nil }
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(video.frameRate)),
            presentationTimeStamp: CMTime(seconds: seconds, preferredTimescale: 60_000),
            decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: formatDescription,
            sampleTiming: &timing,
            sampleBufferOut: &sample)
        return sample
    }
}

public enum StreamSessionError: Error {
    case badURL(String)

    case transportClosed(String)

    case fatal(String)

    var isFatal: Bool {
        if case .fatal = self { return true }
        return false
    }

    var failureDescription: String {
        switch self {
        case .badURL(let url): "bad URL: \(url)"
        case .transportClosed(let reason): reason
        case .fatal(let reason): reason
        }
    }
}
