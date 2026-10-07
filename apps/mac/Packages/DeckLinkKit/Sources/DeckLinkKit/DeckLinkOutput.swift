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

    deinit {
        dlk_output_close(handle)
    }
}
