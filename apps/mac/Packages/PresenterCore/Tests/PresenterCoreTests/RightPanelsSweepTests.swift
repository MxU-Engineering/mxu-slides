import Foundation
import Testing

@Suite struct RightPanelsSweepTests {
    private func source(_ name: String) throws -> String {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  
            .deletingLastPathComponent()  
            .deletingLastPathComponent()  
            .deletingLastPathComponent()  
            .deletingLastPathComponent()  
            .appendingPathComponent("Sources", isDirectory: true)
        return try String(contentsOf: sources.appendingPathComponent(name), encoding: .utf8)
    }

    @Test func layoutsSavedBeforeTheBoothStillDecode() throws {
        let layout = try source("PresentLayout.swift")
        for field in [
            "var rightRailHidden: Bool?",
            "var serviceControlsWindowOpen: Bool?",
            "var serviceControlsWindowFrame: String?",
        ] {
            #expect(layout.contains(field), "\(field) must stay OPTIONAL: synthesized Codable fails a whole saved-layouts array on one missing key")
        }
    }

    @Test func closingTheOnlyServiceControlsBringsTheRailBack() throws {
        let controller = try source("PresentLayoutController.swift")
        let start = try #require(controller.range(of: "func serviceControlsWindowClosed()"))
        let body = controller[start.upperBound...].prefix(400)
        #expect(body.contains("set(false, forKey: Self.rightRailHiddenKey)"), "a user close with the rail hidden would leave the operator with no clears or timers")
    }

    @Test func theRailHidesOnOneSharedKey() throws {
        let shell = try source("AppShell.swift")
        #expect(shell.contains("&& !rightRailHidden"), "railVisible honors the hidden flag")
        #expect(!shell.contains("\"shell.rightRailHidden\""), "the key lives on PresentLayoutController so the menu, the shell and saved layouts can't drift")
    }
}
