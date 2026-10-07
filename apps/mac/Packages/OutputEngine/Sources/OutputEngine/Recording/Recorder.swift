import AVFoundation
import CoreVideo
import RenderEngine

public final class Recorder: @unchecked Sendable {
    public enum State: Equatable, Sendable {
        case recording
        case finishing
        case finished(RecordingConfiguration.StopReason)
        case failed(String)
    }

    public struct Status: Sendable, Equatable {
        public var state: State
        public var elapsedSeconds: Double
        public var appendedFrames: Int
        public var droppedFrames: Int
        public var droppedAudioBuffers: Int
        public var freeDiskBytes: Int64
        public var url: URL
    }

    private struct MutableState {
        var state: State = .recording
        var sessionOrigin: Double?
        var lastVideoSeconds: Double = 0
        var appendedFrames = 0
        var droppedFrames = 0
        var droppedAudioBuffers = 0
        var freeDiskBytes: Int64 = .max
        var audioFormat: CMFormatDescription?
    }

    public let configuration: RecordingConfiguration
    public let url: URL

    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let audioInput: AVAssetWriterInput?
    private let box: Locked<MutableState>
    private let diskTimer: DispatchSourceTimer
    private static let timescale: CMTimeScale = 60_000

    public init(url: URL, configuration: RecordingConfiguration) throws {
        self.configuration = configuration
        self.url = url
        self.box = Locked(MutableState())

        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        writer.movieFragmentInterval = CMTime(
            seconds: configuration.fragmentInterval, preferredTimescale: Self.timescale)
        writer.shouldOptimizeForNetworkUse = false

        videoInput = AVAssetWriterInput(
            mediaType: .video, outputSettings: configuration.videoSettings())
        videoInput.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: configuration.width,
                kCVPixelBufferHeightKey as String: configuration.height,
            ])
        writer.add(videoInput)

        if configuration.includesAudio {
            let input = AVAssetWriterInput(
                mediaType: .audio, outputSettings: configuration.audioSettings())
            input.expectsMediaDataInRealTime = true
            writer.add(input)
            audioInput = input
        } else {
            audioInput = nil
        }

        guard writer.startWriting() else {
            throw writer.error ?? CocoaError(.fileWriteUnknown)
        }

        diskTimer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        diskTimer.schedule(deadline: .now() + 1, repeating: 1)
        diskTimer.setEventHandler { [weak self] in self?.checkDiskHeadroom() }
        diskTimer.resume()

        checkDiskHeadroom(autoStop: false)
    }

    deinit {
        diskTimer.cancel()
    }

    @discardableResult
    public func append(_ pixelBuffer: CVPixelBuffer, atHostSeconds seconds: Double) -> Bool {
        let pts: CMTime? = box.withLock { state in
            guard case .recording = state.state else { return nil }
            let origin: Double
            if let existing = state.sessionOrigin {
                origin = existing
            } else {
                origin = seconds
                state.sessionOrigin = seconds
            }
            let relative = max(0, seconds - origin)

            let floor = state.lastVideoSeconds + Double(1) / Double(Self.timescale)
            let stamped = state.appendedFrames == 0 ? relative : max(relative, floor)
            state.lastVideoSeconds = stamped
            return CMTime(seconds: stamped, preferredTimescale: Self.timescale)
        }
        guard let pts else { return false }

        if box.withLock({ $0.appendedFrames == 0 }) {
            writer.startSession(atSourceTime: .zero)
        }
        guard videoInput.isReadyForMoreMediaData, adaptor.append(pixelBuffer, withPresentationTime: pts) else {
            box.withLock { $0.droppedFrames += 1 }
            noteWriterFailureIfAny()
            return false
        }
        box.withLock { $0.appendedFrames += 1 }
        return true
    }

    public func appendAudio(_ buffer: AVAudioPCMBuffer, atHostSeconds seconds: Double) {
        guard let audioInput else { return }
        let pts: CMTime? = box.withLock { state in
            guard case .recording = state.state,
                  let origin = state.sessionOrigin,
                  seconds >= origin
            else { return nil }
            return CMTime(seconds: seconds - origin, preferredTimescale: Self.timescale)
        }
        guard let pts, audioInput.isReadyForMoreMediaData,
              let sample = Self.sampleBuffer(from: buffer, presentationTime: pts)
        else {
            box.withLock { $0.droppedAudioBuffers += 1 }
            return
        }
        if !audioInput.append(sample) {
            box.withLock { $0.droppedAudioBuffers += 1 }
            noteWriterFailureIfAny()
        }
    }

    public func finish(reason: RecordingConfiguration.StopReason = .requested) async {
        let shouldFinish: Bool = box.withLock { state in
            guard case .recording = state.state else { return false }
            state.state = .finishing
            return true
        }
        guard shouldFinish else { return }
        diskTimer.cancel()

        videoInput.markAsFinished()
        audioInput?.markAsFinished()
        if writer.status == .writing {
            await writer.finishWriting()
        }
        box.withLock { state in
            if writer.status == .completed {
                state.state = .finished(reason)
            } else {
                state.state = .failed(writer.error?.localizedDescription ?? "writer \(writer.status.rawValue)")
            }
        }
    }

    public var status: Status {
        box.withLock { state in
            Status(
                state: state.state,
                elapsedSeconds: state.lastVideoSeconds,
                appendedFrames: state.appendedFrames,
                droppedFrames: state.droppedFrames,
                droppedAudioBuffers: state.droppedAudioBuffers,
                freeDiskBytes: state.freeDiskBytes,
                url: url)
        }
    }

    private func noteWriterFailureIfAny() {
        guard writer.status == .failed else { return }
        let message = writer.error?.localizedDescription ?? "writer failed"
        box.withLock { state in
            if case .recording = state.state { state.state = .failed(message) }
        }
    }

    private func checkDiskHeadroom(autoStop: Bool = true) {
        let free: Int64
        do {
            let values = try url.deletingLastPathComponent()
                .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            free = Int64(values.volumeAvailableCapacityForImportantUsage ?? .max)
        } catch {
            return
        }
        box.withLock { $0.freeDiskBytes = free }
        if autoStop, free < configuration.minimumFreeDiskBytes {
            Task { await finish(reason: .diskFull) }
        }
    }

    public static func sampleBuffer(
        from buffer: AVAudioPCMBuffer, presentationTime: CMTime
    ) -> CMSampleBuffer? {
        let format = buffer.format
        var sampleBuffer: CMSampleBuffer?
        let frames = CMItemCount(buffer.frameLength)
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(format.sampleRate)),
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: .invalid)
        guard CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: nil,
            dataReady: false,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: format.formatDescription,
            sampleCount: frames,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer) == noErr,
            let sampleBuffer
        else { return nil }
        guard CMSampleBufferSetDataBufferFromAudioBufferList(
            sampleBuffer,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0,
            bufferList: buffer.audioBufferList) == noErr
        else { return nil }
        return sampleBuffer
    }
}
