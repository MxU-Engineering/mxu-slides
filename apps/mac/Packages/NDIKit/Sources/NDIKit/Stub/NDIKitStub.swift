import CoreVideo
import Foundation

let ndiUnavailable = "NDI isn't available in this build — install the NDI SDK for Apple and rebuild."

public enum NDIError: Error, Equatable {
    case runtimeNotFound([String])
    case loadFailed(String)

    case tableMismatch([String])
    case initializeFailed
}

public final class NDILibrary: Sendable {
    public static func reinitialize(timeout: TimeInterval = 8) -> Bool { true }

    public static func load() throws -> NDILibrary {
        throw NDIError.loadFailed(ndiUnavailable)
    }
}

public final class NDIFinder: Sendable {
    public init?(library: NDILibrary) { return nil }

    public func currentSourceNames(wait milliseconds: UInt32 = 1500) -> [String] { [] }
}

public final class NDIInputSource: Sendable {
    public enum State: Equatable, Sendable {
        case searching
        case receiving(sourceName: String)
        case offline
    }

    public var state: State { .offline }

    public init(
        library: NDILibrary, sourceNameContaining fragment: String,
        quietSecondsBeforeRehunt: Int = 5
    ) {}

    public func stop() {}

    public func latestFrame() -> CVPixelBuffer? { nil }
}

public final class NDISender: Sendable {
    public init?(library: NDILibrary, name: String) { return nil }

    public func send(
        pixelBuffer: CVPixelBuffer,
        frameRateNumerator: Int32 = 30_000,
        frameRateDenominator: Int32 = 1_000
    ) {}
}
