import AVFoundation
import CoreMedia
import Foundation
import QuartzCore
import RenderEngine

public final class MediaFileSource: @unchecked Sendable {
    public let url: URL

    private let frameSink: @Sendable (CVPixelBuffer, Double) -> Void
    private let audioSink: @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void

    private let onEnded: @Sendable (String?) -> Void
    private let inPoint: Double?
    private let outPoint: Double?

    private let running = Locked(false)
    private let endedOnce = Locked(false)
    private let reader = Locked<AVAssetReader?>(nil)

    private let videoOut = Locked<AVAssetReaderTrackOutput?>(nil)
    private let audioOut = Locked<AVAssetReaderAudioMixOutput?>(nil)
    private let counters = Locked((delivered: 0, dropped: 0))

    public var framesDelivered: Int { counters.withLock { $0.delivered } }
    public var framesDropped: Int { counters.withLock { $0.dropped } }

    private static let lateFrameThreshold = 0.25

    private static let audioLeadSeconds = 0.05

    public init(
        url: URL,
        inPoint: Double? = nil,
        outPoint: Double? = nil,
        frameSink: @escaping @Sendable (CVPixelBuffer, Double) -> Void,
        audioSink: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void,
        onEnded: @escaping @Sendable (String?) -> Void
    ) {
        self.url = url
        self.inPoint = inPoint
        self.outPoint = outPoint
        self.frameSink = frameSink
        self.audioSink = audioSink
        self.onEnded = onEnded
    }

    public func start() {
        let wasRunning = running.withLock { value -> Bool in
            defer { value = true }
            return value
        }
        guard !wasRunning else { return }
        Task.detached(priority: .userInitiated) { [self] in
            await pump()
        }
    }

    public func stop() {
        running.value = false
        endedOnce.value = true  
        reader.withLock { $0?.cancelReading() }
    }

    private func end(_ reason: String?) {
        let alreadyEnded = endedOnce.withLock { value -> Bool in
            defer { value = true }
            return value
        }
        guard !alreadyEnded else { return }
        running.value = false
        onEnded(reason)
    }

    private func pump() async {
        let asset = AVURLAsset(url: url)
        let videoTracks: [AVAssetTrack]
        let audioTracks: [AVAssetTrack]
        do {
            videoTracks = try await asset.loadTracks(withMediaType: .video)
            audioTracks = try await asset.loadTracks(withMediaType: .audio)
        } catch {
            end("unreadable file: \(error.localizedDescription)")
            return
        }
        guard let videoTrack = videoTracks.first else {
            end("no video track")
            return
        }
        let assetReader: AVAssetReader
        do {
            assetReader = try AVAssetReader(asset: asset)
        } catch {
            end("decoder unavailable: \(error.localizedDescription)")
            return
        }

        let rangeStart = inPoint ?? 0
        let rangeEnd = outPoint
        assetReader.timeRange = CMTimeRange(
            start: CMTime(seconds: rangeStart, preferredTimescale: 600),
            end: rangeEnd.map { CMTime(seconds: $0, preferredTimescale: 600) }
                ?? .positiveInfinity)

        let videoOutput = AVAssetReaderTrackOutput(
            track: videoTrack,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ])
        videoOutput.alwaysCopiesSampleData = false
        guard assetReader.canAdd(videoOutput) else {
            end("video track not decodable")
            return
        }
        assetReader.add(videoOutput)

        var audioOutput: AVAssetReaderAudioMixOutput?
        if !audioTracks.isEmpty {
            let output = AVAssetReaderAudioMixOutput(
                audioTracks: audioTracks,
                audioSettings: [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: 48_000,
                    AVNumberOfChannelsKey: 2,
                    AVLinearPCMBitDepthKey: 32,
                    AVLinearPCMIsFloatKey: true,
                    AVLinearPCMIsNonInterleaved: true,
                ])
            if assetReader.canAdd(output) {
                assetReader.add(output)
                audioOutput = output
            }
        }

        guard assetReader.startReading() else {
            end("decode failed to start: \(assetReader.error?.localizedDescription ?? "unknown")")
            return
        }
        reader.value = assetReader
        videoOut.value = videoOutput
        audioOut.value = audioOutput
        guard running.value else { return }

        let anchor = CACurrentMediaTime()

        if audioOutput != nil {
            Task.detached(priority: .userInitiated) { [self] in
                await pumpAudio(anchor: anchor, base: rangeStart)
            }
        }
        await pumpVideo(anchor: anchor, base: rangeStart)
    }

    private func pumpVideo(anchor: Double, base: Double) async {
        guard let output = videoOut.value, let reader = reader.value else { return }
        while running.value, let sample = output.copyNextSampleBuffer() {
            guard let imageBuffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            let target = anchor + max(0, pts - base)
            let now = CACurrentMediaTime()
            if target > now {
                try? await Task.sleep(nanoseconds: UInt64((target - now) * 1_000_000_000))
            } else if now - target > Self.lateFrameThreshold {

                counters.withLock { $0.dropped += 1 }
                continue
            }
            guard running.value else { return }
            frameSink(imageBuffer, CACurrentMediaTime())
            counters.withLock { $0.delivered += 1 }
        }
        guard running.value else { return }
        switch reader.status {
        case .completed:
            end(nil)
        default:
            end("decode stopped: \(reader.error?.localizedDescription ?? "unknown")")
        }
    }

    private func pumpAudio(anchor: Double, base: Double) async {
        guard let output = audioOut.value,
              let format = AVAudioFormat(
                  standardFormatWithSampleRate: 48_000, channels: 2) else { return }
        while running.value, let sample = output.copyNextSampleBuffer() {
            let frames = CMSampleBufferGetNumSamples(sample)
            guard frames > 0,
                  let pcm = AVAudioPCMBuffer(
                      pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))
            else { continue }
            pcm.frameLength = AVAudioFrameCount(frames)
            guard CMSampleBufferCopyPCMDataIntoAudioBufferList(
                sample, at: 0, frameCount: Int32(frames),
                into: pcm.mutableAudioBufferList) == noErr else { continue }
            let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            let target = anchor + max(0, pts - base)
            let now = CACurrentMediaTime()
            if target - Self.audioLeadSeconds > now {
                try? await Task.sleep(
                    nanoseconds: UInt64((target - Self.audioLeadSeconds - now) * 1_000_000_000))
            }
            guard running.value else { return }
            audioSink(pcm, AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: target)))
        }
    }
}
