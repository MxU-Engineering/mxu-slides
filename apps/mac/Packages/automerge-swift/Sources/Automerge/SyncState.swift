import class AutomergeUniffi.SyncState
import Foundation

typealias FfiSyncState = AutomergeUniffi.SyncState

public struct SyncState: @unchecked Sendable {
    #if !os(WASI)
    fileprivate let queue = DispatchQueue(label: "automerge-syncstate-queue", qos: .userInteractive)
    fileprivate func sync<T>(execute work: () throws -> T) rethrows -> T {
        try queue.sync(execute: work)
    }
    #else
    fileprivate func sync<T>(execute work: () throws -> T) rethrows -> T {
        try work()
    }
    #endif

    var ffi_state: FfiSyncState

    public var theirHeads: Set<ChangeHash>? {
        sync {
            ffi_state.theirHeads().map { Set($0.map { ChangeHash(bytes: $0) }) }
        }
    }

    public init() {
        ffi_state = FfiSyncState()
    }

    public init(bytes: Data) throws {
        ffi_state = try wrappedErrors { try FfiSyncState.decode(bytes: Array(bytes)) }
    }

    public func reset() {
        sync {
            ffi_state.reset()
        }
    }

    public func encode() -> Data {
        sync {
            Data(ffi_state.encode())
        }
    }
}
