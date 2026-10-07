import Foundation
import Testing

@Suite struct MainThreadChurnSweepTests {
    private var appSources: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  
            .deletingLastPathComponent()  
            .deletingLastPathComponent()  
            .deletingLastPathComponent()  
            .deletingLastPathComponent()  
            .appendingPathComponent("Sources", isDirectory: true)
    }

    private func source(_ file: String) throws -> String {
        try String(contentsOf: appSources.appendingPathComponent(file), encoding: .utf8)
    }

    private func block(after marker: String, closedBy end: String, in source: String) throws -> String {
        let start = try #require(source.range(of: marker), "\(marker) expected")
        let tail = source[start.upperBound...]
        return String(tail[..<(try #require(tail.range(of: end))).lowerBound])
    }

    @Test func theTransportPollWritesOnlyOnChange() throws {
        let transport = try source("MediaTransportController.swift")
        let refresh = try block(after: "func refresh(seeds", closedBy: "\n    }\n", in: transport)
        #expect(refresh.contains("if moved { rows = next }"))
        #expect(refresh.contains("rowsVersion += 1"))
        #expect(!refresh.contains("library.index"), "names come from the epoch-cached entry")
        #expect(transport.components(separatedBy: "rows = ").count == 2, "refresh is the one writer")

        let tracking = try source("ServiceTimingController.swift")
        let arm = try block(after: "private func arm()", closedBy: "\n    }\n", in: tracking)
        #expect(arm.contains("media.rowsVersion"))
        #expect(!arm.contains("media.rows.") && !arm.contains("media.rows\n"), "never the rows themselves")

        let timers = try source("TimersController.swift")
        let system = try block(after: "func setSystemTimers(", closedBy: "\n    }\n", in: timers)
        #expect(system.contains("ServiceTrackingTimers.merge("))
        #expect(system.contains("if merged.timersChanged"))
        #expect(system.contains("if merged.boardChanged"))
        #expect(!system.contains("push()"), "the permanent set never re-saves the user's timers")
    }
}
