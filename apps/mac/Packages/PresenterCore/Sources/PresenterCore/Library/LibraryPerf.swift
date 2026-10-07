import Foundation
import os

let perfSignposter = OSSignposter(
    subsystem: "com.example.mxuslides", category: "library"
)
let perfLog = Logger(subsystem: "com.example.mxuslides", category: "library")

public struct MainPassOpens: Sendable, Equatable {
    public private(set) var count = 0
    public private(set) var total: Duration = .zero
    public private(set) var kinds: [String: Int] = [:]

    public init() {}

    public mutating func record(_ elapsed: Duration, kind: String) {
        count += 1
        total += elapsed
        kinds[kind, default: 0] += 1
    }

    public var breakdown: String {
        kinds.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .map { "\($0.key)×\($0.value)" }.joined(separator: " ")
    }
}

public enum MainThreadOpenTrap {

    public static let environmentKey = "MXU_ALLOW_MAIN_OPENS"

    static let environmentValue = ProcessInfo.processInfo.environment[environmentKey]

    #if DEBUG
    static let isDebugBuild = true
    #else
    static let isDebugBuild = false
    #endif

    @MainActor public private(set) static var isArmed = false

    public static func armsAtLaunch(isDebug: Bool, envValue: String?) -> Bool {
        isDebug && envValue != "1"
    }

    @MainActor public static func armAtLaunch() {
        isArmed = armsAtLaunch(isDebug: isDebugBuild, envValue: environmentValue)
    }

    public static func shouldTrap(isMain: Bool, armed: Bool) -> Bool {
        isMain && armed
    }

    public final class Record: Sendable {
        private let opens = OSAllocatedUnfairLock(initialState: [String]())

        init() {}

        public var trapped: [String] { opens.withLock { $0 } }

        func note(_ open: String) {
            opens.withLock { $0.append(open) }
        }
    }

    @TaskLocal static var record: Record?

    public static func recordingOpens(
        isolation: isolated (any Actor)? = #isolation, _ body: () async throws -> Void
    ) async rethrows -> [String] {
        let record = Record()
        try await $record.withValue(record, operation: body, isolation: isolation)
        return record.trapped
    }

    static func check(kind: DocumentKind, id: String) {
        #if DEBUG
        let isMain = Thread.isMainThread
        let armed = isMain ? MainActor.assumeIsolated { isArmed } : false
        if isMain {
            record?.note("\(kind.directoryName)/\(id)")
        }
        if shouldTrap(isMain: isMain, armed: armed) {
            preconditionFailure(
                "main-thread open of \(kind.directoryName)/\(id) (the DEBUG trap; \(environmentKey)=1 opts out): "
                    + "decode it off main (the reader's loadValue / loadValues, the editor's checkout, or the resident tables)"
            )
        }
        #endif
    }
}

@MainActor private var mainPassOpens = MainPassOpens()

private let perfNoticeLimiter = OSAllocatedUnfairLock(initialState: PerfLineLimiter(perMinute: 30))

private func perfNotice(_ event: String, _ detail: String) {
    if let sink = Library.perfSink {
        let now = ProcessInfo.processInfo.systemUptime
        if let dropped = perfNoticeLimiter.withLock({ $0.admit(event, now: now) }) {
            sink(event, PerfLineLimiter.annotate(detail, dropped: dropped))
        }
    }
}

private func milliseconds(_ duration: Duration) -> String {
    let ms = Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    return String(format: "%.1f ms", ms)
}

extension Library {

    nonisolated(unsafe) public static var perfSink: (@Sendable (_ event: String, _ detail: String) -> Void)?

    @MainActor public static func takeMainPassOpens() -> MainPassOpens {
        let pass = mainPassOpens
        mainPassOpens = MainPassOpens()
        return pass
    }

    nonisolated static func measuringOpen<Value>(
        kind: DocumentKind, id: String, _ decode: () throws -> Value
    ) rethrows -> Value {
        let start = ContinuousClock.now
        defer {
            if Thread.isMainThread {
                let elapsed = start.duration(to: .now)
                MainActor.assumeIsolated {
                    mainPassOpens.record(elapsed, kind: kind.directoryName)
                }
                if elapsed > .milliseconds(8) {

                    perfLog.notice(
                        "slow open on MAIN THREAD \(kind.directoryName, privacy: .public)/\(id, privacy: .public): \(elapsed.description, privacy: .public)"
                    )
                    perfNotice("library.slowOpen", "\(kind.directoryName)/\(id) \(milliseconds(elapsed))")
                }
            }
        }
        return try decode()
    }
}

nonisolated(unsafe) private var mainThreadStatements = 0

extension LibraryIndex {

    @MainActor public static func takeMainThreadStatementCount() -> Int {
        let count = mainThreadStatements
        mainThreadStatements = 0
        return count
    }

    nonisolated static func countStatement() {
        if pthread_main_np() != 0 {
            mainThreadStatements += 1
        }
    }
}
