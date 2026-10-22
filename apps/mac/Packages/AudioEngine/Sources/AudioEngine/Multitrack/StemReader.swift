import AVFoundation

public struct MultitrackStem: Codable, Equatable, Sendable {
    public var path: String
    public var channelId: String

    public var at: Double

    public var inPoint: Double?

    public var duration: Double?

    public init(path: String, channelId: String, at: Double = 0, inPoint: Double? = nil, duration: Double? = nil) {
        self.path = path; self.channelId = channelId; self.at = at; self.inPoint = inPoint; self.duration = duration
    }
}

public struct MultitrackSong: Codable, Equatable, Sendable {
    public var id: String
    public var stems: [MultitrackStem]

    public init(id: String, stems: [MultitrackStem]) {
        self.id = id; self.stems = stems
    }
}

final class StemReader {
    let ring: StemRing
    private let file: AVAudioFile?
    private let converter: AVAudioConverter?
    private let target: AVAudioFormat

    private var songFrame: Int64
    private let audioStart: Int64

    let audioEnd: Int64
    private let fileEndFrame: AVAudioFramePosition
    private var decoded: AVAudioPCMBuffer
    private var decodedOffset = 0
    private var flushed = false
    private let source: AVAudioPCMBuffer?
    private let zeros: UnsafeMutablePointer<Float>
    private static let chunk = 4096

    private(set) var failure: String?

    init(stem: MultitrackStem, sampleRate: Double, startFrame: Int64, capacity: Int) {
        ring = StemRing(capacity: capacity)
        target = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        songFrame = startFrame
        audioStart = Int64((stem.at * sampleRate).rounded())
        zeros = .allocate(capacity: Self.chunk)
        zeros.initialize(repeating: 0, count: Self.chunk)
        decoded = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 1)!
        decoded.frameLength = 0
        var opened: AVAudioFile?
        do {
            opened = try AVAudioFile(forReading: URL(fileURLWithPath: stem.path))
        } catch {
            failure = "\(stem.path): \(error.localizedDescription)"
        }
        file = opened
        guard let opened else {
            converter = nil; source = nil; fileEndFrame = 0; audioEnd = audioStart
            return
        }
        let fileRate = opened.processingFormat.sampleRate
        let inFrames = AVAudioFramePosition(((stem.inPoint ?? 0) * fileRate).rounded())
        let playable = stem.duration.map { AVAudioFramePosition(($0 * fileRate).rounded()) }
            ?? (opened.length - inFrames)
        fileEndFrame = min(opened.length, inFrames + max(0, playable))
        audioEnd = audioStart + Int64((Double(fileEndFrame - inFrames) / fileRate * sampleRate).rounded())

        let into = max(0, startFrame - audioStart)
        opened.framePosition = min(fileEndFrame, inFrames + AVAudioFramePosition((Double(into) / sampleRate * fileRate).rounded()))
        converter = opened.processingFormat == target ? nil : AVAudioConverter(from: opened.processingFormat, to: target)
        converter?.downmix = true
        source = AVAudioPCMBuffer(pcmFormat: opened.processingFormat, frameCapacity: AVAudioFrameCount(Self.chunk))
    }

    deinit { zeros.deallocate() }

    @discardableResult
    func fill(upTo limit: Int = .max) -> Int {
        var produced = 0
        while true {
            let drop = ring.framesToDrop
            let wanted = drop > 0 ? drop : min(ring.space, limit - ring.buffered)
            guard wanted >= (drop > 0 ? 1 : 1024) else { break }
            let count = min(Self.chunk, wanted)
            produce(count, dropping: drop > 0)
            produced += count
        }
        return produced
    }

    private func produce(_ count: Int, dropping: Bool) {
        var done = 0
        while done < count {
            let frame = songFrame + Int64(done)
            let left: UnsafePointer<Float>, right: UnsafePointer<Float>
            var run: Int
            if frame < audioStart || frame >= audioEnd {
                let edge = frame < audioStart ? audioStart : Int64.max
                run = Int(min(Int64(count - done), edge - frame))
                left = UnsafePointer(zeros); right = UnsafePointer(zeros)
            } else {
                if decodedOffset >= Int(decoded.frameLength), !decodeMore() {
                    run = min(count - done, Int(audioEnd - frame))
                    left = UnsafePointer(zeros); right = UnsafePointer(zeros)
                    run = min(run, Self.chunk)
                    if dropping { ring.drop(run) } else { ring.write(left: left, right: right, count: run) }
                    done += run
                    continue
                }
                run = min(count - done, Int(decoded.frameLength) - decodedOffset, Int(audioEnd - frame))
                left = UnsafePointer(decoded.floatChannelData![0] + decodedOffset)
                right = UnsafePointer(decoded.floatChannelData![1] + decodedOffset)
                decodedOffset += run
            }
            run = min(run, Self.chunk)
            if dropping { ring.drop(run) } else { ring.write(left: left, right: right, count: run) }
            done += run
        }
        songFrame += Int64(count)
    }

    private func decodeMore() -> Bool {
        guard let file, let source else { return false }
        decodedOffset = 0
        while true {
            let atEnd = file.framePosition >= fileEndFrame
            if atEnd, converter == nil || flushed { return false }
            if !atEnd {
                let frames = AVAudioFrameCount(min(Int64(Self.chunk), fileEndFrame - file.framePosition))
                do {
                    try file.read(into: source, frameCount: frames)
                } catch {
                    return false
                }
                guard source.frameLength > 0 else { return false }
            }
            guard let converter else {
                decoded = source.copy() as! AVAudioPCMBuffer
                return true
            }
            let ratio = target.sampleRate / file.processingFormat.sampleRate
            let capacity = AVAudioFrameCount((Double(Self.chunk) * ratio).rounded(.up)) + 64
            if decoded.frameCapacity < capacity {
                decoded = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity)!
            }
            decoded.frameLength = 0
            var fed = false
            var error: NSError?
            let status = converter.convert(to: decoded, error: &error) { _, outStatus in
                if atEnd {
                    outStatus.pointee = .endOfStream
                    return nil
                }
                if fed {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                fed = true
                outStatus.pointee = .haveData
                return source
            }
            if atEnd { flushed = true }
            guard status != .error else { return false }
            if decoded.frameLength > 0 { return true }
        }
    }
}
