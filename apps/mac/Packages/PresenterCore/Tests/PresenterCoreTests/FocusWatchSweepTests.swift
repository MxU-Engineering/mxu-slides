import Foundation
import Testing

@Suite struct FocusWatchSweepTests {
    private var appSources: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources", isDirectory: true)
    }

    private func source(_ name: String) throws -> String {
        try String(contentsOf: appSources.appendingPathComponent(name), encoding: .utf8)
    }

    @Test func theRecorderRunsFromLaunch() throws {
        #expect(try source("MxUSlidesApp.swift").contains("FocusWatchRecorder.shared.activate()"))
    }

    @Test func aClickFollowsTheFocusWatchRules() throws {
        let recorder = try source("FocusWatchRecorder.swift")
        let rescue = try #require(recorder.range(of: "if click.rescuesBeforeClick {"))
        #expect(recorder[rescue.upperBound...].prefix(250).contains("target.makeKey()"),
                "the window takes key before the press lands, so the press selects")
        #expect(recorder.contains("click.isStuck(hasKeyWindowAfter: NSApp.keyWindow != nil)"))
        #expect(recorder.contains("\"focus.lost\""), "the moment key goes nowhere is its own line")
    }

    @Test func sendFeedbacksNoteTakesTheCaret() throws {
        let feedback = try source("FeedbackView.swift")
        #expect(feedback.contains(".focused($noteFocused)"))
        #expect(feedback.contains("noteFocused = true"))
    }
}
