import Foundation
import Testing

@Suite struct SingleShellWindowSweepTests {
    private var appSources: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources", isDirectory: true)
    }

    @Test func theShellIsOneUntabbedWindow() throws {
        let app = try String(
            contentsOf: appSources.appendingPathComponent("MxUSlidesApp.swift"), encoding: .utf8
        )
        #expect(app.contains("Window(\"MxU Slides\", id: \"main\")"), "a WindowGroup shell can open more than one")
        #expect(!app.contains("WindowGroup(\"MxU Slides\", id: \"main\")"))

        let launch = try #require(app.range(of: "func applicationWillFinishLaunching"))
        #expect(app[launch.upperBound...].prefix(200).contains("NSWindow.allowsAutomaticWindowTabbing = false"),
                "tabbing must be off before the first window, or macOS shows tabs and a +")

        let reopen = try #require(app.range(of: "func applicationShouldHandleReopen"))
        let tail = app[reopen.upperBound...]
        let end = try #require(tail.range(of: "\n    }\n"))
        let body = tail[..<end.lowerBound]
        #expect(body.contains("return false"), "true lets SwiftUI's default reopen add another shell")
        #expect(!body.contains("return true"))
    }
}
