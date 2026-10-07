import Accelerate
import AVFoundation
import CoreGraphics
import CoreVideo
import VideoToolbox

public enum MediaAuthoring {
    public enum Codec: String, CaseIterable, Sendable {
        case h264
        case hevc
        case proRes4444Alpha
        case hevcAlpha

        public var carriesAlpha: Bool {
            switch self {
            case .h264, .hevc: false
            case .proRes4444Alpha, .hevcAlpha: true
            }
        }

        var avCodec: AVVideoCodecType {
            switch self {
            case .h264: .h264
            case .hevc: .hevc
            case .proRes4444Alpha: .proRes4444
            case .hevcAlpha: .hevcWithAlpha
            }
        }

        var storesStraightAlpha: Bool { self == .proRes4444Alpha }
    }

    public static func writeMovie(
        to url: URL,
        codec: Codec,
        size: CGSize,
        frameCount: Int,
        framesPerSecond: Int32 = 30,
        monoAudio: [Float]? = nil,
        draw: @Sendable (CGContext, _ frameIndex: Int) -> Void
    ) async throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)

        var settings: [String: Any] = [
            AVVideoCodecKey: codec.avCodec,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ]
        if codec == .hevcAlpha {
            settings[AVVideoCompressionPropertiesKey] = [
                kVTCompressionPropertyKey_TargetQualityForAlpha as String: 0.75
            ]
        }

        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(size.width),
                kCVPixelBufferHeightKey as String: Int(size.height),
                kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            ]
        )

        guard writer.canAdd(input) else {
            throw MediaEngineError.authoringFailed("writer rejected \(codec.rawValue) input")
        }
        writer.add(input)

        let audioInput = monoAudio.map { _ in
            AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: audioSampleRate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ])
        }
        if let audioInput {
            audioInput.expectsMediaDataInRealTime = false
            guard writer.canAdd(audioInput) else {
                throw MediaEngineError.authoringFailed("writer rejected the audio input")
            }
            writer.add(audioInput)
        }
        guard writer.startWriting() else {
            throw MediaEngineError.authoringFailed(
                "startWriting (\(codec.rawValue)): \(writer.error?.localizedDescription ?? "unknown")"
            )
        }
        writer.startSession(atSourceTime: .zero)

        var audioWritten = 0
        for frame in 0..<frameCount {

            try await waitUntilReady(input, writer: writer, codec: codec)
            guard let pool = adaptor.pixelBufferPool else {
                throw MediaEngineError.authoringFailed("no pixel buffer pool (\(codec.rawValue))")
            }
            var pixelBuffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer)
            guard let pixelBuffer else {
                throw MediaEngineError.authoringFailed("pixel buffer allocation failed")
            }

            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            if let context = CGContext(
                data: CVPixelBufferGetBaseAddress(pixelBuffer),
                width: Int(size.width),
                height: Int(size.height),
                bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue
            ) {
                context.clear(CGRect(origin: .zero, size: size))
                draw(context, frame)
            }
            if codec.storesStraightAlpha {

                var buffer = vImage_Buffer(
                    data: CVPixelBufferGetBaseAddress(pixelBuffer),
                    height: vImagePixelCount(size.height),
                    width: vImagePixelCount(size.width),
                    rowBytes: CVPixelBufferGetBytesPerRow(pixelBuffer)
                )

                vImageUnpremultiplyData_RGBA8888(&buffer, &buffer, vImage_Flags(kvImageNoFlags))
            }
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

            let time = CMTime(value: CMTimeValue(frame), timescale: framesPerSecond)
            guard adaptor.append(pixelBuffer, withPresentationTime: time) else {
                throw MediaEngineError.authoringFailed(
                    "append failed (\(codec.rawValue)): \(writer.error?.localizedDescription ?? "unknown")"
                )
            }

            if let audioInput, let monoAudio {
                let upTo = frame == frameCount - 1
                    ? monoAudio.count
                    : min(monoAudio.count, (frame + 1) * Int(audioSampleRate) / Int(framesPerSecond))
                try await append(
                    monoAudio, from: audioWritten, upTo: upTo, to: audioInput, writer: writer)
                audioWritten = max(audioWritten, upTo)
            }
        }

        input.markAsFinished()
        audioInput?.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw MediaEngineError.authoringFailed(
                "finishWriting (\(codec.rawValue)): \(writer.error?.localizedDescription ?? "unknown")"
            )
        }
    }

    static let audioSampleRate = 48_000.0

    private static func waitUntilReady(
        _ input: AVAssetWriterInput, writer: AVAssetWriter, codec: Codec?
    ) async throws {
        let deadline = Date().addingTimeInterval(stallSeconds)
        while !input.isReadyForMoreMediaData, writer.status == .writing, Date() < deadline {
            try await Task.sleep(for: .milliseconds(2))
        }
        if writer.status != .writing {
            throw MediaEngineError.authoringFailed(
                "writer failed mid-stream (\(codec?.rawValue ?? "audio")): \(writer.error?.localizedDescription ?? "unknown")"
            )
        } else if !input.isReadyForMoreMediaData {
            writer.cancelWriting()
            throw MediaEngineError.authoringFailed(
                "writer stalled (\(codec?.rawValue ?? "audio")): not ready for \(Int(stallSeconds)) s")
        }
    }

    static let stallSeconds = 10.0

    private static func append(
        _ samples: [Float], from start: Int, upTo end: Int,
        to input: AVAssetWriterInput, writer: AVAssetWriter
    ) async throws {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16, sampleRate: audioSampleRate, channels: 1, interleaved: true)
        else { throw MediaEngineError.authoringFailed("no audio format") }
        let chunk = Int(audioSampleRate)
        var offset = start
        while offset < end {
            let count = min(chunk, end - offset)
            guard let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
                  let data = pcm.int16ChannelData
            else { throw MediaEngineError.authoringFailed("audio buffer allocation failed") }
            pcm.frameLength = AVAudioFrameCount(count)
            for index in 0..<count {
                data[0][index] = Int16(max(-1, min(1, samples[offset + index])) * Float(Int16.max))
            }
            var timing = CMSampleTimingInfo(
                duration: CMTime(value: 1, timescale: CMTimeScale(audioSampleRate)),
                presentationTimeStamp: CMTime(value: CMTimeValue(offset), timescale: CMTimeScale(audioSampleRate)),
                decodeTimeStamp: .invalid)
            var sample: CMSampleBuffer?
            CMSampleBufferCreate(
                allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false,
                makeDataReadyCallback: nil, refcon: nil,
                formatDescription: format.formatDescription, sampleCount: count,
                sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample)
            guard let sample,
                  CMSampleBufferSetDataBufferFromAudioBufferList(
                      sample, blockBufferAllocator: kCFAllocatorDefault,
                      blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0,
                      bufferList: pcm.audioBufferList) == noErr
            else { throw MediaEngineError.authoringFailed("audio sample buffer failed") }
            try await waitUntilReady(input, writer: writer, codec: nil)
            guard input.append(sample) else {
                throw MediaEngineError.authoringFailed(
                    "audio append failed: \(writer.error?.localizedDescription ?? "unknown")")
            }
            offset += count
        }
    }
}
