import Foundation
import Testing

@Suite struct NotePanelAttachmentSweepTests {
    private var appSources: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources", isDirectory: true)
    }

    @Test func aPanelHostedCardAttachmentCarriesABlankImage() throws {
        let file = appSources.appendingPathComponent("NoteDocumentView.swift")
        let lines = try String(contentsOf: file, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let start = lines.firstIndex(where: { $0.contains("func hostedCard(") }) else {
            Issue.record("hostedCard not found")
            return
        }
        var body: [String] = []
        for line in lines[(start + 1)...] {
            if line.hasPrefix("    }") { break }
            body.append(line)
        }
        let text = body.joined(separator: "\n")
        #expect(text.contains("attachment.panelHosted = true"))
        #expect(text.contains("attachment.image = NSImage("), "a hosted card's attachment draws nothing of its own, never the generic file icon")
        #expect(!text.contains("attachment.bounds = .zero"), "zero bounds fall back to the icon's own size")
    }
}
