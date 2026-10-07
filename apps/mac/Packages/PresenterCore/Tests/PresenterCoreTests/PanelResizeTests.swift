import Foundation
import Testing
@testable import PresenterCore

@Test func aTrailingEdgeGrowsWithThePointerAndHoldsItsRange() {
    #expect(PanelResize.width(start: 272, moved: 60, leadingEdge: false, range: 272 ... 420) == 332)
    #expect(PanelResize.width(start: 272, moved: -40, leadingEdge: false, range: 272 ... 420) == 272, "no narrower than the floor")
    #expect(PanelResize.width(start: 400, moved: 90, leadingEdge: false, range: 272 ... 420) == 420)
}

@Test func aLeadingEdgeGrowsAsThePointerMovesLeft() {
    #expect(PanelResize.width(start: 340, moved: -50, leadingEdge: true, range: 240 ... 480) == 390)
    #expect(PanelResize.width(start: 340, moved: 200, leadingEdge: true, range: 240 ... 480) == 240)
}

@Suite struct PanelResizeSweepTests {
    private var appSources: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  
            .deletingLastPathComponent()  
            .deletingLastPathComponent()  
            .deletingLastPathComponent()  
            .deletingLastPathComponent()  
            .appendingPathComponent("Sources", isDirectory: true)
    }

    @Test func theWidthGripsAreAppKitHandles() throws {
        let shell = try String(contentsOf: appSources.appendingPathComponent("AppShell.swift"), encoding: .utf8)
        for grip in ["private var widthGrip: some View {", "private var rightRailWidthGrip: some View {"] {
            let start = try #require(shell.range(of: grip))
            let body = shell[start.upperBound...].prefix(1400)
            let end = body.range(of: "\n    }\n").map { body[..<$0.lowerBound] } ?? body
            #expect(end.contains("ResizeGripArea("), "\(grip) uses the AppKit handle")
            #expect(!end.contains("DragGesture("), "\(grip) has no SwiftUI drag left")
        }
        let grip = try String(contentsOf: appSources.appendingPathComponent("ResizeGrip.swift"), encoding: .utf8)
        let up = try #require(grip.range(of: "override func mouseUp(with event: NSEvent) {"))
        #expect(grip[up.upperBound...].prefix(500).contains("changed(event.locationInWindow.x - pressX)"),
                "the release position is applied, not only the last drag event")
        let marquee = try String(contentsOf: appSources.appendingPathComponent("ListMarquee.swift"), encoding: .utf8)
        #expect(marquee.contains("!ResizeGripView.covers(event.locationInWindow, in: window)"),
                "the run order's marquee lets a press on a handle through")
        #expect(!marquee.contains("contentView?.hitTest(event.locationInWindow) is"),
                "no hosting-view hit test from the monitor: it broke the run order's row clicks")
    }
}
