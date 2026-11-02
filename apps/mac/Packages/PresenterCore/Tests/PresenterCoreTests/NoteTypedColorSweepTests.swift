import AppKit
import Foundation
import Testing

@Suite struct NoteTypedColorSweepTests {
    private var appSources: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources", isDirectory: true)
    }

    @MainActor @Test func theDefaultTypingColorIsNeverSavedAsTheRunsColor() throws {
        let typing = NSTextView().typingAttributes[.foregroundColor] as? NSColor
        #expect(typing == NSColor.textColor)
        let resolved = try #require(NSColor.textColor.usingColorSpace(.sRGB))
        #expect(resolved.redComponent + resolved.greenComponent + resolved.blueComponent == 0, "why it saved as #000000")

        let editing = try String(contentsOf: appSources.appendingPathComponent("NoteDocumentEditing.swift"), encoding: .utf8)
        let rule = try #require(editing.range(of: "static func isLabelColor(_ color: NSColor) -> Bool {"))
        let body = editing[rule.upperBound...].prefix(200)
        #expect(body.contains(".textColor]"), "textColor is one of the editor's own colors, so typed text keeps no color")

        #expect(editing.contains("let shown = attributes[NoteBlockMarker.greyKey] ?? attributes[.foregroundColor]"))
        #expect(editing.contains("if let color = shown as? NSColor, !NoteRunText.isLabelColor(color) {"))
    }
}
