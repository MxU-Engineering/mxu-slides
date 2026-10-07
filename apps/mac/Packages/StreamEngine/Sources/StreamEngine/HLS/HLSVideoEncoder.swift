import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

final class HLSVideoEncoder: @unchecked Sendable {
    let output: AsyncStream<CMSampleBuffer>
    private let continuation: AsyncStream<CMSampleBuffer>.Continuation
    private let session: VTCompressionSession
    private let frameDuration: CMTime
    private let segmentDuration: Double
    private var lastKeyframePTS: CMTime = .invalid

    init(video: StreamVideoConfiguration, segmentDuration: Double) throws {
        var session: VTCompressionSession?
        let codecType: CMVideoCodecType = video.codec == .hevc
            ? kCMVideoCodecType_HEVC
            : kCMVideoCodecType_H264
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(video.width),
            height: Int32(video.height),
            codecType: codecType,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &session)
        guard status == noErr, let session else {
            throw StreamSessionError.transportClosed("VTCompressionSession create failed (\(status))")
        }
        self.session = session
        self.frameDuration = CMTime(value: 1, timescale: CMTimeScale(video.frameRate))
        self.segmentDuration = segmentDuration
        (output, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(240))

        func set(_ key: CFString, _ value: CFTypeRef) {
            VTSessionSetProperty(session, key: key, value: value)
        }
        set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
        let hevcProfile = video.hdr
            ? kVTProfileLevel_HEVC_Main10_AutoLevel
            : kVTProfileLevel_HEVC_Main_AutoLevel
        set(kVTCompressionPropertyKey_ProfileLevel, video.codec == .hevc
            ? hevcProfile
            : kVTProfileLevel_H264_High_AutoLevel)
        if video.hdr {

            set(kVTCompressionPropertyKey_ColorPrimaries, kCVImageBufferColorPrimaries_ITU_R_2020)
            set(kVTCompressionPropertyKey_TransferFunction, kCVImageBufferTransferFunction_ITU_R_2100_HLG)
            set(kVTCompressionPropertyKey_YCbCrMatrix, kCVImageBufferYCbCrMatrix_ITU_R_2020)
        }
        set(kVTCompressionPropertyKey_AverageBitRate, NSNumber(value: video.bitrateKbps * 1000))

        set(kVTCompressionPropertyKey_DataRateLimits,
            [NSNumber(value: video.bitrateKbps * 1000 * 3 / 2 / 8), NSNumber(value: 1.0)] as CFArray)
        set(kVTCompressionPropertyKey_ExpectedFrameRate, NSNumber(value: video.frameRate))

        set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, NSNumber(value: segmentDuration))
        set(kVTCompressionPropertyKey_MaxKeyFrameInterval, NSNumber(value: Int(segmentDuration * Double(video.frameRate))))
        set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
        set(kVTCompressionPropertyKey_AllowOpenGOP, kCFBooleanFalse)
        VTCompressionSessionPrepareToEncodeFrames(session)
    }

    func encode(_ sample: CMSampleBuffer) {
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sample) else { return }

        let pts = sample.presentationTimeStamp
        var frameProperties: CFDictionary?
        if lastKeyframePTS == .invalid
            || (pts - lastKeyframePTS).seconds >= segmentDuration {
            frameProperties = [
                kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue as Any
            ] as CFDictionary
            lastKeyframePTS = pts
        }
        VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: imageBuffer,
            presentationTimeStamp: pts,
            duration: frameDuration,
            frameProperties: frameProperties,
            infoFlagsOut: nil
        ) { [continuation] status, _, encoded in
            guard status == noErr, let encoded else { return }
            continuation.yield(encoded)
        }
    }

    func finish() {
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        continuation.finish()
        VTCompressionSessionInvalidate(session)
    }
}
