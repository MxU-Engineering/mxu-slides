import CoreVideo

public final class LiveFrameSlot: @unchecked Sendable {
    private let state = Locked<(frame: CVPixelBuffer?, generation: UInt64)>((nil, 0))

    public init() {}

    public var frame: CVPixelBuffer? { state.value.frame }

    public var generation: UInt64 { state.value.generation }

    public func set(_ frame: CVPixelBuffer) {
        state.withLock { current in
            guard current.frame !== frame else { return }
            current = (frame, Self.nextGeneration())
        }
    }

    private static let lastGeneration = Locked<UInt64>(0)

    public static func nextGeneration() -> UInt64 {
        lastGeneration.withLock { last -> UInt64 in
            last += 1
            return last
        }
    }
}
