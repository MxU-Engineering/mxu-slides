import Foundation

public enum RealtimeAudioCallback {
    private static let key = "AudioEngine.RealtimeAudioCallback.isActive"

    public static var isActive: Bool {
        Thread.current.threadDictionary[key] as? Bool == true
    }

    public static func scope<T>(_ body: () throws -> T) rethrows -> T {
        let dictionary = Thread.current.threadDictionary
        let previous = dictionary[key]
        dictionary[key] = true
        defer { dictionary[key] = previous }
        return try body()
    }
}

public final class EngineStateLock: @unchecked Sendable {
    private let inner = NSLock()

    public init() {}

    public func withLock<T>(_ body: () throws -> T) rethrows -> T {
        assert(
            !RealtimeAudioCallback.isActive,
            "Blocking EngineStateLock acquire inside an AVFAudio callback — "
                + "the sync-callback deadlock. Hop to another queue first, or "
                + "tryWithLock and drop (see RealtimeAudioCallback)."
        )
        inner.lock()
        defer { inner.unlock() }
        return try body()
    }

    public func tryWithLock<T>(_ body: () throws -> T) rethrows -> T? {
        guard inner.`try`() else { return nil }
        defer { inner.unlock() }
        return try body()
    }

    public func lock() { inner.lock() }
    public func unlock() { inner.unlock() }
}
