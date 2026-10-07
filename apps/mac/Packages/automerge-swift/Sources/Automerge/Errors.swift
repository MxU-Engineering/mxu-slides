import enum AutomergeUniffi.DecodeSyncStateError
import enum AutomergeUniffi.DocError
import enum AutomergeUniffi.LoadError
import enum AutomergeUniffi.ReceiveSyncError
import Foundation

typealias FfiDocError = AutomergeUniffi.DocError
typealias FfiDecodeSyncStateError = AutomergeUniffi.DecodeSyncStateError
typealias FfiLoadError = AutomergeUniffi.LoadError
typealias FfiReceiveSyncError = AutomergeUniffi.ReceiveSyncError

public struct DocError: LocalizedError {
    let inner: FfiDocError

    init(_ inner: FfiDocError) {
        self.inner = inner
    }

    public var errorDescription: String? {
        inner.errorDescription
    }
}

public struct DecodeSyncStateError: LocalizedError {
    let inner: FfiDecodeSyncStateError

    init(_ inner: FfiDecodeSyncStateError) {
        self.inner = inner
    }

    public var errorDescription: String? {
        switch inner {
        case let .Internal(message: msg):
            return "Error decoding sync state: \(msg)"
        }
    }
}

public struct LoadError: LocalizedError {
    let inner: FfiLoadError

    init(_ inner: FfiLoadError) {
        self.inner = inner
    }

    public var errorDescription: String? {
        switch inner {
        case let .Internal(message: msg):
            return "Error loading a document: \(msg)"
        }
    }
}

public struct ReceiveSyncError: LocalizedError {
    let inner: FfiReceiveSyncError

    init(_ inner: FfiReceiveSyncError) {
        self.inner = inner
    }

    public var errorDescription: String? {
        switch inner {
        case let .Internal(message: msg):
            return "ReceiveSyncError: \(msg)"
        case let .InvalidMessage(message: message):
            return "Invalid message: \(message)"
        }
    }
}

func wrappedErrors<T>(_ f: () throws -> T) throws -> T {
    do {
        return try f()
    } catch let error as FfiDocError {
        throw DocError(error)
    } catch let error as FfiLoadError {
        throw LoadError(error)
    } catch let error as FfiReceiveSyncError {
        throw ReceiveSyncError(error)
    } catch let error as FfiDecodeSyncStateError {
        throw DecodeSyncStateError(error)
    }
}
