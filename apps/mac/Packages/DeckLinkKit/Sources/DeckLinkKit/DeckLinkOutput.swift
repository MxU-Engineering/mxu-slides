import CDeckLink
import CoreVideo
import Foundation

public enum DeckLinkKeying: Int32, Sendable, CaseIterable {
    case off = 0
    case internalKey = 1
    case externalKey = 2
}

public enum DeckLinkError: Error, Equatable {
    case openFailed(String)
}

public final class DeckLinkOutput: @unchecked Sendable {
    private let handle: OpaquePointer

    public init(
        persistentID: Int64, modeID: UInt32, keying: DeckLinkKeying
    ) throws {
        var error = [CChar](repeating: 0, count: 256)
        guard let opened = dlk_output_open(
            persistentID, modeID,
            DLKKeying(rawValue: UInt32(keying.rawValue)),
            &error, error.count)
        else {
            throw DeckLinkError.openFailed(String(cString: error))
        }
        handle = opened
    }

    @discardableResult
    public func display(pixelBuffer: CVPixelBuffer) -> Bool {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            return false
        }
        return dlk_output_display(
            handle,
            base.assumingMemoryBound(to: UInt8.self),
            CVPixelBufferGetBytesPerRow(pixelBuffer))
    }

    public var timing: DeckLinkOutputTiming {
        DeckLinkOutputTiming(dlk_output_timing(handle))
    }

    deinit {
        dlk_output_close(handle)
    }
}

public struct DeckLinkOutputTiming: Equatable, Sendable {
    public enum Completion: Sendable {
        case onTime, late, dropped, flushed
    }

    public var completions: UInt64 = 0
    public var lastCompletionHostTime: Double = 0
    public var latched: UInt64 = 0

    public var waiting: [Int32] = []
    public var shownSlot: Int32 = 0
    public var repeats: UInt64 = 0
    public var skips: UInt64 = 0
    public var late: UInt64 = 0
    public var dropped: UInt64 = 0
    public var jumps: UInt64 = 0

    public init() {}

    init(_ raw: DLKOutputTiming) {
        completions = raw.completions
        lastCompletionHostTime = raw.lastCompletionHostTime
        latched = raw.latched
        waiting = Array([raw.waiting.0, raw.waiting.1].prefix(Int(raw.waitingCount)))
        shownSlot = raw.shownSlot
        repeats = raw.repeats
        skips = raw.skips
        late = raw.late
        dropped = raw.dropped
        jumps = raw.jumps
    }

    private var raw: DLKOutputTiming {
        DLKOutputTiming(
            completions: completions, lastCompletionHostTime: lastCompletionHostTime,
            latched: latched,
            waiting: (waiting.first ?? 0, waiting.dropFirst().first ?? 0),
            waitingCount: Int32(waiting.count), shownSlot: shownSlot,
            repeats: repeats, skips: skips,
            late: late, dropped: dropped, jumps: jumps)
    }

    @discardableResult
    public mutating func latch() -> Int32 {
        var updated = raw
        let slot = dlk_latch_slot(&updated)
        self = DeckLinkOutputTiming(updated)
        return slot
    }

    @discardableResult
    public mutating func tallyCompletion(
        at hostTime: Double, result: Completion = .onTime, jumped: Bool = false
    ) -> Int32 {
        var updated = raw
        let tallied: DLKCompletionResult =
            switch result {
            case .onTime: DLKCompletionOnTime
            case .late: DLKCompletionLate
            case .dropped: DLKCompletionDropped
            case .flushed: DLKCompletionFlushed
            }
        let slot = dlk_tally_completion(&updated, hostTime, tallied, jumped)
        self = DeckLinkOutputTiming(updated)
        return slot
    }
}
