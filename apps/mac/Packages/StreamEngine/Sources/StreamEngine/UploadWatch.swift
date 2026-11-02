import Foundation
import HaishinKit

public struct UploadStall: Sendable, Equatable {
    public static let silentSeconds = 10
    public static let backlogSeconds = 20

    public private(set) var bytesOutPerSecond = 0
    public private(set) var queuedBytes = 0
    private var silent = 0

    public init() {}

    public mutating func record(bytesOutPerSecond: Int, queuedBytes: Int) {
        self.bytesOutPerSecond = bytesOutPerSecond
        self.queuedBytes = queuedBytes
        silent = bytesOutPerSecond > 0 ? 0 : silent + 1
    }

    public func stalled(targetKbps: Int) -> String? {
        if silent >= Self.silentSeconds { return "nothing sent for \(silent)s" }
        if queuedBytes > targetKbps * 125 * Self.backlogSeconds {
            return "upload \(queuedBytes / 1_000_000) MB behind"
        }
        return nil
    }
}

final actor UploadWatch: StreamBitRateStrategy {
    nonisolated let mamimumVideoBitRate: Int
    nonisolated let mamimumAudioBitRate = 0
    private let adaptive: StreamVideoAdaptiveBitRateStrategy?
    private let floor: Int
    private(set) var stall = UploadStall()
    private(set) var videoKbps: Int

    init(videoBitRate: Int, floorBitRate: Int?) {
        mamimumVideoBitRate = videoBitRate
        videoKbps = videoBitRate / 1000
        floor = min(floorBitRate ?? videoBitRate, videoBitRate)
        adaptive = floorBitRate.map { _ in StreamVideoAdaptiveBitRateStrategy(mamimumVideoBitrate: videoBitRate) }
    }

    func adjustBitrate(_ event: NetworkMonitorEvent, stream: some StreamConvertible) async {
        if let adaptive {
            await adaptive.adjustBitrate(event, stream: stream)
            var settings = await stream.videoSettings
            if settings.bitRate < floor {
                settings.bitRate = floor
                try? await stream.setVideoSettings(settings)
            }
        }
        switch event {
        case .status(let report), .publishInsufficientBWOccured(let report):
            stall.record(bytesOutPerSecond: report.currentBytesOutPerSecond, queuedBytes: report.currentQueueBytesOut)
        case .reset:
            break
        }
        videoKbps = await stream.videoSettings.bitRate / 1000
    }
}
