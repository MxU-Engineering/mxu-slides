import Foundation

public struct StreamEndpoint: Sendable, Equatable, Identifiable, Codable {
    public enum Kind: String, Sendable, Codable, CaseIterable {
        case rtmp
        case rtmps
        case srt

        case hls
    }

    public var id: String
    public var name: String
    public var kind: Kind

    public var url: String

    public var streamKey: String

    public var backupUrl: String?

    public init(
        id: String = UUID().uuidString,
        name: String,
        kind: Kind,
        url: String,
        streamKey: String = "",
        backupUrl: String? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.url = url
        self.streamKey = streamKey
        self.backupUrl = backupUrl
    }
}

public struct StreamVideoConfiguration: Sendable, Equatable {
    public enum Codec: String, Sendable, Equatable {
        case h264
        case hevc
    }

    public var width: Int
    public var height: Int
    public var frameRate: Int
    public var bitrateKbps: Int
    public var codec: Codec

    public var hdr: Bool

    public init(width: Int, height: Int, frameRate: Int = 30, bitrateKbps: Int = 4500, codec: Codec = .h264, hdr: Bool = false) {
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.bitrateKbps = bitrateKbps
        self.codec = codec
        self.hdr = hdr
    }
}
