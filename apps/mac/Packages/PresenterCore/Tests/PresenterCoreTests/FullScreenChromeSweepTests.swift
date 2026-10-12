import Foundation
import Testing

@Suite struct FullScreenChromeSweepTests {
    private var appSources: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources", isDirectory: true)
    }

    @Test func fullScreenHidesTheShellToolbar() throws {
        let shell = try String(
            contentsOf: appSources.appendingPathComponent("AppShell.swift"), encoding: .utf8
        )
        let start = try #require(shell.range(of: "private struct WindowChromeConfigurator"))
        let tail = shell[start.upperBound...]
        let end = try #require(tail.range(of: "\n}\n"))
        let body = String(tail[..<end.lowerBound])
        #expect(body.contains("willEnterFullScreenNotification"), "entering full screen must hide the empty toolbar, or it covers the header")
        #expect(body.contains("willExitFullScreenNotification"), "leaving full screen must bring the toolbar back: it sets the windowed titlebar height")
        #expect(body.contains("toolbar.isVisible = !fullScreen"))

        #expect(shell.contains("Color.clear.frame(width: Self.trafficLightSlot(fullScreen: isFullScreen))"))
    }
}
