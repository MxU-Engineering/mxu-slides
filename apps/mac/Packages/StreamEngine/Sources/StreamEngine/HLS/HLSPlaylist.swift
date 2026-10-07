import Foundation

struct HLSPlaylist: Sendable, Equatable {

    static let window = 5

    private(set) var mediaSequence: Int
    private(set) var segments: [Segment] = []

    struct Segment: Sendable, Equatable {
        var name: String
        var duration: Double
    }

    init(mediaSequence: Int = 0) {
        self.mediaSequence = mediaSequence
    }

    var nextSequence: Int { mediaSequence + segments.count }

    mutating func add(name: String, duration: Double) {
        segments.append(Segment(name: name, duration: duration))
        while segments.count > Self.window {
            segments.removeFirst()
            mediaSequence += 1
        }
    }

    func render() -> String {
        let target = max(1, Int(segments.map(\.duration).max()?.rounded(.up) ?? 1))
        var lines = [
            "#EXTM3U",
            "#EXT-X-VERSION:3",
            "#EXT-X-TARGETDURATION:\(target)",
            "#EXT-X-MEDIA-SEQUENCE:\(mediaSequence)"
        ]
        for segment in segments {
            lines.append(String(format: "#EXTINF:%.3f,", segment.duration))
            lines.append(segment.name)
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

final class HLSContinuity: @unchecked Sendable {
    private let lock = NSLock()
    private var nextIndex = 0
    private var sequence = 0
    let epochMillis: Int

    init(epochMillis: Int = Int(Date().timeIntervalSince1970 * 1000)) {
        self.epochMillis = epochMillis
    }

    func claimSegmentName() -> String {
        lock.withLock {
            let name = "seg-\(epochMillis)-\(nextIndex).ts"
            nextIndex += 1
            return name
        }
    }

    var resumeSequence: Int {
        lock.withLock { sequence }
    }

    func recordSequence(_ value: Int) {
        lock.withLock { sequence = max(sequence, value) }
    }
}
