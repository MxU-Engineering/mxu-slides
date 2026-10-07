import Foundation
import Testing

@Suite struct PresentFireKeysSweepTests {
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

    @Test func presentSurfacesFireOnlyThroughTheTypingAwareDoor() throws {
        for name in ["PresentGridView.swift", "ServiceContinuousView.swift"] {
            let view = try source(name)
            #expect(view.contains(".onPresentFireKeys {"), "\(name) takes the fire keys through the door")
            let raw = view.split(separator: "\n").filter { $0.contains(".onKeyPress(") && $0.contains("fireStep(") }
            #expect(raw.isEmpty, "\(name) fires from a raw onKeyPress: \(raw)")
        }
    }

    @Test func keyboardFiresBringTheLiveSlideIntoView() throws {
        for name in ["PresentGridView.swift", "ServiceContinuousView.swift"] {
            let view = try source(name)
            let door = try #require(view.range(of: ".onPresentFireKeys {"))
            #expect(view[door.upperBound...].prefix(160).contains("controls?.noteKeyboardFire()"), "\(name) notes its key fires")
            #expect(view.contains(".background(KeyboardFireFollow(controls: controls) { revealLive("), "\(name) follows them")

            #expect(view.components(separatedBy: "keyboardFires").count - 1 == (name == "PresentGridView.swift" ? 1 : 0))
        }
        let continuous = try source("ServiceContinuousView.swift")
        #expect(continuous.contains("PresentCardFrames.shared.reveal("))
        let keys = try source("KeyboardShortcuts.swift")
        #expect(keys.components(separatedBy: "controls.noteKeyboardFire()").count - 1 == 4,
                "custom next/previous chords, group hot keys and Go to Slide note theirs too")
        let controls = try source("ServiceControls.swift")
        #expect(controls.components(separatedBy: "keyboardFires += 1").count - 1 == 1, "one writer: noteKeyboardFire")
    }

    @Test func theDoorStandsAsideWhileSomeoneTypes() throws {
        let grid = try source("PresentGridView.swift")
        let start = try #require(grid.range(of: "func onPresentFireKeys("))
        let body = grid[start.upperBound...].prefix(600)
        let typing = try #require(body.range(of: "firstResponder is NSText {"))
        let ignored = try #require(body.range(of: "return .ignored"))
        let step = try #require(body.range(of: "step(direction)"))
        #expect(typing.lowerBound < ignored.lowerBound && ignored.lowerBound < step.lowerBound)
    }
}
