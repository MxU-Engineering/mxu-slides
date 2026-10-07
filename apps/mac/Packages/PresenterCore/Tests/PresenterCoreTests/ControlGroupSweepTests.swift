import Foundation
import Testing

@Suite struct ControlGroupSweepTests {
    private var appSources: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  
            .deletingLastPathComponent()  
            .deletingLastPathComponent()  
            .deletingLastPathComponent()  
            .deletingLastPathComponent()  
            .appendingPathComponent("Sources", isDirectory: true)
    }

    @Test func noControlGroupInAppSources() throws {
        let all = FileManager.default.enumerator(
            at: appSources, includingPropertiesForKeys: nil
        )?.compactMap { $0 as? URL } ?? []
        let files = all.filter { $0.pathExtension == "swift" }
        try #require(!files.isEmpty, "app sources not found at \(appSources.path)")
        var violations: [String] = []
        var clusters = 0
        for file in files {
            let lines = try String(contentsOf: file, encoding: .utf8)
                .split(separator: "\n", omittingEmptySubsequences: false)
            for (index, line) in lines.enumerated() {
                if line.contains("ControlGroup {") || line.contains("ControlGroup(") {
                    violations.append("\(file.lastPathComponent):\(index + 1)")
                }
                if line.contains("ToolbarCluster {") { clusters += 1 }
            }
        }
        #expect(violations.isEmpty, "ControlGroup is an NSSegmentedControl measured per layout proposal; use ToolbarCluster: \(violations)")
        #expect(clusters >= 4, "the editor toolbar's four runs use ToolbarCluster (\(clusters))")
    }

    @Test func toolbarTogglesUseButtonStyle() throws {
        let editor = try String(contentsOf: appSources.appendingPathComponent("SlideEditorView.swift"), encoding: .utf8)
        let start = try #require(editor.range(of: "private func addObjectTools("))
        let end = try #require(editor.range(of: "private func presentationTools(", range: start.upperBound..<editor.endIndex))
        let tools = editor[start.lowerBound..<end.lowerBound]
        let toggles = tools.components(separatedBy: "Toggle(").count - 1
        #expect(toggles >= 1, "Draw Path is a Toggle")
        #expect(tools.components(separatedBy: ".toggleStyle(.button)").count - 1 == toggles)
    }
}
