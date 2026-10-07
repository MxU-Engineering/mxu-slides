import CNDI
import Foundation

public enum NDIError: Error, Equatable {
    case runtimeNotFound([String])
    case loadFailed(String)

    case tableMismatch([String])
    case initializeFailed
}

public final class NDILibrary: @unchecked Sendable {
    public let table: NDIlib_v5

    let handle: UnsafeMutableRawPointer

    public static let searchPaths: [String] = candidatePaths(
        bundlePath: Bundle.main.bundlePath,
        privateFrameworksPath: Bundle.main.privateFrameworksPath)

    static func candidatePaths(
        bundlePath: String, privateFrameworksPath: String?
    ) -> [String] {
        [
            privateFrameworksPath.map { $0 + "/libndi.dylib" },
            bundlePath + "/Contents/XPCServices/NDIHelper.xpc/Contents/Frameworks/libndi.dylib",
            "/usr/local/lib/libndi.dylib",
            "/Library/NDI SDK for Apple/lib/macOS/libndi.dylib",
        ].compactMap { $0 }
    }

    private static let shared = Locked<Result<NDILibrary, NDIError>?>(nil)

    private static let gate = InstanceGate()

    static func retainInstance() { gate.enter() }
    static func releaseInstance() { gate.leave() }

    public static func reinitialize(timeout: TimeInterval = 8) -> Bool {
        let cached = shared.withLock { $0 }
        guard case .success(let library)? = cached else { return true }
        return gate.withExclusive(timeout: timeout) {
            library.table.destroy?()
            return library.table.initialize?() == true
        } ?? false
    }

    public static func load() throws -> NDILibrary {
        let result: Result<NDILibrary, NDIError> = shared.withLock { cached in
            if let cached { return cached }
            let fresh = Self.loadFresh()
            cached = fresh
            return fresh
        }
        return try result.get()
    }

    private static func loadFresh() -> Result<NDILibrary, NDIError> {
        var handle: UnsafeMutableRawPointer?
        for path in searchPaths where FileManager.default.fileExists(atPath: path) {
            handle = dlopen(path, RTLD_NOW | RTLD_LOCAL)
            if handle != nil { break }
        }
        guard let handle else {
            return .failure(.runtimeNotFound(searchPaths))
        }
        guard let symbol = dlsym(handle, "NDIlib_v5_load") else {
            return .failure(.loadFailed("NDIlib_v5_load missing"))
        }
        typealias LoadFunction = @convention(c) () -> UnsafePointer<NDIlib_v5>?
        let load = unsafeBitCast(symbol, to: LoadFunction.self)
        guard let tablePointer = load() else {
            return .failure(.loadFailed("NDIlib_v5_load returned NULL"))
        }
        return activate(table: tablePointer.pointee, handle: handle)
    }

    static func activate(
        table: NDIlib_v5, handle: UnsafeMutableRawPointer
    ) -> Result<NDILibrary, NDIError> {
        let mismatches = tableMismatches(table) { name in
            dlsym(handle, name).map { UnsafeRawPointer($0) }
        }
        if mismatches.isEmpty {
            if table.initialize?() == true {
                return .success(NDILibrary(table: table, handle: handle))
            } else {
                return .failure(.initializeFailed)
            }
        } else {
            return .failure(.tableMismatch(mismatches))
        }
    }

    static func tableMismatches(
        _ table: NDIlib_v5, resolve: (String) -> UnsafeRawPointer?
    ) -> [String] {
        let slots: [(name: String, entry: UnsafeRawPointer?)] = [
            ("NDIlib_initialize", address(table.initialize)),
            ("NDIlib_destroy", address(table.destroy)),
            ("NDIlib_find_create_v2", address(table.find_create_v2)),
            ("NDIlib_find_destroy", address(table.find_destroy)),
            ("NDIlib_find_wait_for_sources", address(table.find_wait_for_sources)),
            ("NDIlib_find_get_current_sources", address(table.find_get_current_sources)),
            ("NDIlib_recv_create_v3", address(table.recv_create_v3)),
            ("NDIlib_recv_destroy", address(table.recv_destroy)),
            ("NDIlib_recv_capture_v3", address(table.recv_capture_v3)),
            ("NDIlib_recv_free_video_v2", address(table.recv_free_video_v2)),
            ("NDIlib_send_create", address(table.send_create)),
            ("NDIlib_send_destroy", address(table.send_destroy)),
            ("NDIlib_send_send_video_v2", address(table.send_send_video_v2)),
        ]
        return slots.compactMap { slot in
            resolve(slot.name) == slot.entry ? nil : slot.name
        }
    }

    func export(named name: String) -> UnsafeRawPointer? {
        dlsym(handle, name).map { UnsafeRawPointer($0) }
    }

    private static func address<Function>(_ slot: Function?) -> UnsafeRawPointer? {
        unsafeBitCast(slot, to: UnsafeRawPointer?.self)
    }

    private init(table: NDIlib_v5, handle: UnsafeMutableRawPointer) {
        self.table = table
        self.handle = handle
    }
}

final class InstanceGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var active = 0
    private var exclusive = false

    func enter() {
        condition.lock()
        while exclusive { condition.wait() }
        active += 1
        condition.unlock()
    }

    func leave() {
        condition.lock()
        active -= 1
        condition.broadcast()
        condition.unlock()
    }

    func withExclusive<T>(timeout: TimeInterval, _ body: () -> T) -> T? {
        let deadline = Date(timeIntervalSinceNow: timeout)
        condition.lock()
        while active > 0 || exclusive {
            guard condition.wait(until: deadline) else {
                condition.unlock()
                return nil
            }
        }
        exclusive = true
        condition.unlock()
        let result = body()
        condition.lock()
        exclusive = false
        condition.broadcast()
        condition.unlock()
        return result
    }
}

final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) { storage = value }

    func withLock<T>(_ body: (inout Value) throws -> T) rethrows -> T {
        try lock.withLock { try body(&storage) }
    }
}
