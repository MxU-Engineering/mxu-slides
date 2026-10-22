import Foundation
import Testing

@Suite struct SidebarToggleSweepTests {
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

    @Test func theContinuousWidthIsSavedAtQuitNotPerMeasure() throws {
        let grid = try source("PresentGridView.swift")
        let width = try block(after: "static var continuousWidth: CGFloat {", closedBy: "\n    }\n", in: grid)
        #expect(width.contains("liveContinuousWidth = newValue"))
        #expect(!width.contains("UserDefaults"), "a defaults write here re-ran the whole window per width step")
        let save = try block(after: "private static func savesContinuousWidthAtQuit()", closedBy: "\n    }\n", in: grid)
        #expect(save.contains("NSApplication.willTerminateNotification"))
        #expect(save.contains("UserDefaults.standard.set(Double(liveContinuousWidth), forKey: continuousWidthKey)"))
        #expect(grid.contains("private static var liveContinuousWidth = CGFloat(UserDefaults.standard.double(forKey: continuousWidthKey))"),
                "a launch still starts at the last session's width")
    }

    @Test func onlyTheSidebarAnimates() throws {
        let shell = try source("AppShell.swift")
        #expect(!shell.contains("value: sidebarVisible)"), "no shell-wide animation keyed on the sidebar")
        #expect(shell.contains(".transition(.move(edge: .leading).animation(.easeOut(duration: 0.15)))"))
    }

    @Test func theShellWidthIsReadOffGeometry() throws {
        let shell = try source("AppShell.swift")
        #expect(shell.contains(".onGeometryChange(for: CGFloat.self) { $0.size.width } action: { shellWidth = $0 }"))
        #expect(!shell.contains("ShellWidthKey"))
    }

    @Test func thePresentSurfaceSkipsEqualShellPasses() throws {
        let shell = try source("AppShell.swift")
        let call = try block(after: "ServiceContinuousView(", closedBy: "} else {", in: shell)
        #expect(call.contains(".equatable()"))
        let surface = try source("ServiceContinuousView.swift")
        let equal = try block(after: "extension ServiceContinuousView: @MainActor Equatable {", closedBy: "\n}\n", in: surface)
        for input in ["model", "render", "controls", "serviceID", "focusItemID", "focusScroll"] {
            #expect(equal.contains("lhs.\(input)"), "\(input) is compared")
        }
    }

    @Test func theCheckerboardIsOneFill() throws {
        let grid = try source("TransparencyGrid.swift")
        #expect(grid.components(separatedBy: "context.fill(").count == 2)
        #expect(grid.contains("context.fill(squares, with: .color(squareInk))"))
    }
}
