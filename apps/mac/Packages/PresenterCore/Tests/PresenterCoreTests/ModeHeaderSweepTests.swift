import Foundation
import Testing

@Suite struct ModeHeaderSweepTests {
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

    @Test func editContextsSitInTheirOwnRowBelowTheModeChip() throws {
        let shell = try source("AppShell.swift")
        let chip = try #require(shell.range(of: "ModeSwitcher(modeRaw: $modeRaw)"))
        let tail = shell[chip.upperBound...]
        let contexts = try #require(tail.range(of: "EditContextSwitcher(model: model)"))
        let between = String(tail[..<contexts.lowerBound])
        #expect(between.contains(".frame(height: Self.headerHeight)"), "the mode chip owns the header band alone")
        #expect(shell[contexts.upperBound...].hasPrefix("\n                        .frame(height: Self.editContextRowHeight)"), "the edit contexts ride their own row below the mode chip")
    }

    @Test func editCardsReserveTheTallerHeader() throws {
        for file in ["SlideEditorView.swift", "MediaEditorView.swift"] {
            let text = try source(file)
            #expect(!text.contains("ShellView.headerHeight - CornerStandard.panelInset"), "\(file) reserves only the mode band — its top rows render under the edit context row")
            #expect(text.contains("ShellView.editorHeaderReserve"), "\(file) reserves the Edit header")
        }
    }
}
