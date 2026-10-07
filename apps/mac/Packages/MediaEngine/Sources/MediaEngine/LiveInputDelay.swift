import CoreVideo
import Foundation
import RenderEngine

public final class LiveInputDelay: @unchecked Sendable {

    public static let maxFrames = 30

    private struct State {
        var pending: [CVPixelBuffer] = []
        var lastSeen: CVPixelBuffer?
        var pool: CVPixelBufferPool?
        var poolKey = ""
    }

    private let delays = Locked<[String: Int]>([:])
    private let states = Locked<[String: State]>([:])

    public init() {}

    public func setDelay(id: String, frames: Int) {
        let clamped = max(0, min(frames, Self.maxFrames))
        delays.withLock { $0[id] = clamped > 0 ? clamped : nil }
        if clamped == 0 { states.withLock { $0[id] = nil } }
    }

    public func delay(id: String) -> Int {
        delays.value[id] ?? 0
    }

    public func clear(id: String) {
        states.withLock { $0[id] = nil }
    }

    public func delayed(_ frame: CVPixelBuffer, id: String) -> CVPixelBuffer {
        guard let target = delays.value[id], target > 0 else { return frame }
        return states.withLock { table in
            var state = table[id] ?? State()
            if state.lastSeen !== frame {
                state.lastSeen = frame
                if let copy = Self.copy(frame, reusing: &state) {
                    state.pending.append(copy)
                }
                let capacity = target + 1
                if state.pending.count > capacity {
                    state.pending.removeFirst(state.pending.count - capacity)
                }
            }
            table[id] = state
            return state.pending.first ?? frame
        }
    }

    private static func copy(
        _ frame: CVPixelBuffer, reusing state: inout State
    ) -> CVPixelBuffer? {
        let width = CVPixelBufferGetWidth(frame)
        let height = CVPixelBufferGetHeight(frame)
        let format = CVPixelBufferGetPixelFormatType(frame)
        let key = "\(width)x\(height):\(format)"
        if state.pool == nil || state.poolKey != key {
            let attributes: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: format,
                kCVPixelBufferWidthKey: width,
                kCVPixelBufferHeightKey: height,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
                kCVPixelBufferMetalCompatibilityKey: true,
            ]
            var pool: CVPixelBufferPool?
            guard CVPixelBufferPoolCreate(
                kCFAllocatorDefault, nil, attributes as CFDictionary, &pool
            ) == kCVReturnSuccess, let pool else { return nil }
            state.pool = pool
            state.poolKey = key
        }
        guard let pool = state.pool else { return nil }

        let auxiliary: [CFString: Any] = [
            kCVPixelBufferPoolAllocationThresholdKey: maxFrames + 2
        ]
        var out: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
            kCFAllocatorDefault, pool, auxiliary as CFDictionary, &out
        ) == kCVReturnSuccess, let out else { return nil }
        CVPixelBufferLockBaseAddress(frame, .readOnly)
        CVPixelBufferLockBaseAddress(out, [])
        defer {
            CVPixelBufferUnlockBaseAddress(out, [])
            CVPixelBufferUnlockBaseAddress(frame, .readOnly)
        }
        if CVPixelBufferIsPlanar(frame) {
            for plane in 0 ..< CVPixelBufferGetPlaneCount(frame) {
                guard let source = CVPixelBufferGetBaseAddressOfPlane(frame, plane),
                      let destination = CVPixelBufferGetBaseAddressOfPlane(out, plane)
                else { return nil }
                let sourceRow = CVPixelBufferGetBytesPerRowOfPlane(frame, plane)
                let destinationRow = CVPixelBufferGetBytesPerRowOfPlane(out, plane)
                let rows = CVPixelBufferGetHeightOfPlane(frame, plane)
                for row in 0 ..< rows {
                    memcpy(
                        destination.advanced(by: row * destinationRow),
                        source.advanced(by: row * sourceRow),
                        min(sourceRow, destinationRow))
                }
            }
        } else {
            guard let source = CVPixelBufferGetBaseAddress(frame),
                  let destination = CVPixelBufferGetBaseAddress(out)
            else { return nil }
            let sourceRow = CVPixelBufferGetBytesPerRow(frame)
            let destinationRow = CVPixelBufferGetBytesPerRow(out)
            for row in 0 ..< height {
                memcpy(
                    destination.advanced(by: row * destinationRow),
                    source.advanced(by: row * sourceRow),
                    min(sourceRow, destinationRow))
            }
        }
        return out
    }
}
