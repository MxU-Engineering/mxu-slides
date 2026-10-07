import CNDI
import CoreVideo
import Foundation

public final class NDIInputSource: @unchecked Sendable {
    public enum State: Equatable, Sendable {
        case searching
        case receiving(sourceName: String)
        case offline
    }

    private let library: NDILibrary
    private let sourceFragment: String
    private let latest = Locked<CVPixelBuffer?>(nil)
    private let stateBox = Locked<State>(.searching)
    private let running = Locked(true)

    private let quietSecondsBeforeRehunt: Int

    public var state: State { stateBox.withLock { $0 } }

    public init(
        library: NDILibrary, sourceNameContaining fragment: String,
        quietSecondsBeforeRehunt: Int = 5
    ) {
        self.library = library
        self.sourceFragment = fragment
        self.quietSecondsBeforeRehunt = max(1, quietSecondsBeforeRehunt)
        let loopThread = Thread { [weak self] in
            self?.receiveLoop()
        }
        loopThread.name = "ndiKit.input.\(fragment)"
        loopThread.qualityOfService = .userInitiated
        loopThread.start()
    }

    deinit {
        running.withLock { $0 = false }
    }

    public func stop() {
        running.withLock { $0 = false }
    }

    public func latestFrame() -> CVPixelBuffer? {
        latest.withLock { $0 }
    }

    public func clearLatestFrameForTesting() {
        latest.withLock { $0 = nil }
    }

    private func receiveLoop() {

        while running.withLock({ $0 }) {
            guard let receiver = NDIReceiver(library: library) else {
                stateBox.withLock { $0 = .offline }
                return
            }

            var connected: String?
            var hunts = 0
            while running.withLock({ $0 }), connected == nil, hunts < 5 {
                connected = receiver.connect(toSourceContaining: sourceFragment, timeout: 3)
                hunts += 1
            }
            guard let name = connected else { continue }
            stateBox.withLock { $0 = .receiving(sourceName: name) }

            var quietSeconds = 0
            while running.withLock({ $0 }), quietSeconds < quietSecondsBeforeRehunt {
                guard let frame = receiver.captureVideoFrame(timeout: 1) else {

                    quietSeconds += 1
                    stateBox.withLock { state in
                        if case .receiving = state { state = .offline }
                    }
                    continue
                }
                quietSeconds = 0
                stateBox.withLock { $0 = .receiving(sourceName: name) }
                if let pixelBuffer = Self.pixelBuffer(from: frame) {
                    latest.withLock { $0 = pixelBuffer }
                }
            }
        }
    }

    private static func pixelBuffer(from frame: NDIVideoFrame) -> CVPixelBuffer? {
        var out: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        guard CVPixelBufferCreate(
            kCFAllocatorDefault, frame.width, frame.height,
            kCVPixelFormatType_32BGRA, attrs as CFDictionary, &out) == kCVReturnSuccess,
            let buffer = out
        else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let destinationRow = CVPixelBufferGetBytesPerRow(buffer)
        frame.data.withUnsafeBytes { source in
            guard let sourceBase = source.baseAddress else { return }
            for row in 0..<frame.height {
                memcpy(
                    base.advanced(by: row * destinationRow),
                    sourceBase.advanced(by: row * frame.bytesPerRow),
                    min(destinationRow, frame.bytesPerRow))
            }
        }
        return buffer
    }
}
