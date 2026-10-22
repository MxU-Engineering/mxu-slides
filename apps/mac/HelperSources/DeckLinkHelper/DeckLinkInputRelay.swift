import CoreVideo
import DeckLinkKit
import Foundation
import IOSurface

final class DeckLinkInputRelay: @unchecked Sendable {

    static let maxInFlight = 2

    private let sink: DeckLinkInputSinkProtocol
    private let converter = DeckLinkFrameConverter()
    private let lock = NSLock()

    private var inFlight: [UUID: CVPixelBuffer] = [:]
    private var pendingSlots = 0
    private var pool: CVPixelBufferPool?
    private var poolDimensions = (width: 0, height: 0)
    private var lastSignal: Bool?
    private var input: DeckLinkInput?

    init(persistentID: Int64, audioChannels: Int, sink: DeckLinkInputSinkProtocol) throws {
        self.sink = sink
        input = try DeckLinkInput(
            persistentID: persistentID, audioChannels: audioChannels,
            onFrame: { [weak self] arrival in self?.arrived(arrival) },
            onFormat: { [weak self] format in
                self?.sink.inputFormat(format.name, interlaced: format.interlaced)
            })
    }

    private func arrived(_ arrival: DeckLinkInputArrival) {
        if arrival.hasSignal != lastSignal {
            lastSignal = arrival.hasSignal
            sink.inputSignal(arrival.hasSignal)
        }
        if let audio = arrival.audio, arrival.audioFrames > 0, arrival.audioChannels > 0 {
            let byteCount = arrival.audioFrames * arrival.audioChannels * MemoryLayout<Int32>.size
            sink.inputAudio(
                Data(bytes: audio, count: byteCount),
                frames: Int32(arrival.audioFrames), channels: Int32(arrival.audioChannels),
                hostTime: arrival.hostTime)
        }
        if let video = arrival.video, arrival.hasSignal, reserveSlot() {
            if let buffer = nextBuffer(width: arrival.width, height: arrival.height),
                converter.convert(
                    video, rowBytes: arrival.rowBytes, width: arrival.width,
                    height: arrival.height, interlaced: arrival.interlaced, into: buffer),
                let surface = CVPixelBufferGetIOSurface(buffer)?.takeUnretainedValue() {
                let token = UUID()
                lock.withLock { inFlight[token] = buffer }
                sink.inputFrame(unsafeBitCast(surface, to: IOSurface.self), hostTime: arrival.hostTime) {
                    [weak self] in self?.releaseSlot(token)
                }
            } else {
                releaseSlot(nil)
            }
        }
    }

    private func reserveSlot() -> Bool {
        lock.withLock {
            if pendingSlots < Self.maxInFlight {
                pendingSlots += 1
                return true
            } else {
                return false
            }
        }
    }

    private func releaseSlot(_ token: UUID?) {
        lock.withLock {
            pendingSlots = max(0, pendingSlots - 1)
            if let token { inFlight[token] = nil }
        }
    }

    private func nextBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        if poolDimensions != (width, height) {
            pool = Self.surfacePool(width: width, height: height)
            poolDimensions = (width, height)
        }
        var buffer: CVPixelBuffer?
        if let pool {
            CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
        }
        return buffer
    }

    private static func surfacePool(width: Int, height: Int) -> CVPixelBufferPool? {
        var pool: CVPixelBufferPool?
        let attributes: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
        ]
        CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &pool)
        return pool
    }
}
