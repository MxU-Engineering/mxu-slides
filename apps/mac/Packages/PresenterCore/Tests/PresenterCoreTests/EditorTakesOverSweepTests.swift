import Foundation
import Testing

@Suite struct EditorTakesOverSweepTests {
    private var appSources: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  
            .deletingLastPathComponent()  
            .deletingLastPathComponent()  
            .deletingLastPathComponent()  
            .deletingLastPathComponent()  
            .appendingPathComponent("Sources", isDirectory: true)
    }

    @Test func everySlideEditorKindTakesOverTheShell() throws {
        let shell = try String(
            contentsOf: appSources.appendingPathComponent("AppShell.swift"), encoding: .utf8
        )
        let start = try #require(shell.range(of: "private var editorTakesOver: Bool {"))
        let tail = shell[start.upperBound...]
        let end = try #require(tail.range(of: "\n    }\n"))
        let body = String(tail[..<end.lowerBound])

        for kind in [".presentation", ".theme", ".overlay", ".confidenceLayout"] {
            #expect(body.contains("entry.kind == \(kind)"), "editorTakesOver must list \(kind): a SlideEditorView host outside it renders under the header spacer and clip and every click is a multi-second relayout")
        }
    }
}
