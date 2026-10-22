import Foundation
import Testing

@Suite struct ThumbnailDefaultsSweepTests {
    private var appSources: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources", isDirectory: true)
    }

    @Test func backgroundsOnlyOnDeclaringSlideIsOnByDefault() throws {
        for file in ["AppShell.swift", "PresentGridView.swift", "ServiceContinuousView.swift", "SettingsView.swift"] {
            let source = try String(contentsOf: appSources.appendingPathComponent(file), encoding: .utf8)
            #expect(source.contains(#"@AppStorage("slideGrid.hideScopedBackgrounds") private var hideScopedBackgrounds = true"#),
                    "\(file) must fall back to on")
        }
    }
}
