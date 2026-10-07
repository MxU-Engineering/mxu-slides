import AVFoundation
import VideoToolbox

public struct RecordingConfiguration: Sendable, Equatable {
    public enum Codec: String, Sendable, Codable, CaseIterable {
        case h264
        case hevc

        case hevc10
        case proRes422
        case proRes4444

        var avCodec: AVVideoCodecType {
            switch self {
            case .h264: .h264
            case .hevc, .hevc10: .hevc
            case .proRes422: .proRes422
            case .proRes4444: .proRes4444
            }
        }

        public var preservesAlpha: Bool { self == .proRes4444 }

        public var wantsHDRSource: Bool { self == .hevc10 }

        var usesPCMAudio: Bool {
            switch self {
            case .proRes422, .proRes4444: true
            case .h264, .hevc, .hevc10: false
            }
        }
    }

    public enum StopReason: String, Sendable, Equatable {
        case requested
        case diskFull
        case writerFailed
    }

    public var codec: Codec
    public var width: Int
    public var height: Int

    public var frameRate: Int

    public var averageBitrate: Int?
    public var includesAudio: Bool
    public var audioSampleRate: Double
    public var audioChannels: Int

    public var minimumFreeDiskBytes: Int64

    public var fragmentInterval: TimeInterval

    public init(
        codec: Codec,
        width: Int,
        height: Int,
        frameRate: Int = 60,
        averageBitrate: Int? = nil,
        includesAudio: Bool = false,
        audioSampleRate: Double = 48_000,
        audioChannels: Int = 2,
        minimumFreeDiskBytes: Int64 = 2 << 30,
        fragmentInterval: TimeInterval = 2
    ) {
        self.codec = codec
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.averageBitrate = averageBitrate
        self.includesAudio = includesAudio
        self.audioSampleRate = audioSampleRate
        self.audioChannels = audioChannels
        self.minimumFreeDiskBytes = minimumFreeDiskBytes
        self.fragmentInterval = fragmentInterval
    }

    func videoSettings() -> [String: Any] {
        var settings: [String: Any] = [
            AVVideoCodecKey: codec.avCodec,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ]
        var compression: [String: Any] = [
            AVVideoExpectedSourceFrameRateKey: frameRate
        ]
        switch codec {
        case .h264, .hevc, .hevc10:
            if let averageBitrate {
                compression[AVVideoAverageBitRateKey] = averageBitrate
            }
            compression[AVVideoAllowFrameReorderingKey] = false
            if codec == .hevc10 {
                compression[AVVideoProfileLevelKey] =
                    kVTProfileLevel_HEVC_Main10_AutoLevel as String
            }
        case .proRes422, .proRes4444:

            compression = [:]
        }
        if !compression.isEmpty {
            settings[AVVideoCompressionPropertiesKey] = compression
        }
        if codec == .hevc10 {

            settings[AVVideoColorPropertiesKey] = [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_2100_HLG,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020,
            ]
        }
        return settings
    }

    func audioSettings() -> [String: Any] {
        if codec.usesPCMAudio {
            [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: audioSampleRate,
                AVNumberOfChannelsKey: audioChannels,
                AVLinearPCMBitDepthKey: 24,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ]
        } else {
            [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: audioSampleRate,
                AVNumberOfChannelsKey: audioChannels,
                AVEncoderBitRateKey: 256_000,
            ]
        }
    }
}
