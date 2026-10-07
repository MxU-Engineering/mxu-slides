import Foundation
import Testing

@Suite struct ScopedGridEditSweepTests {
    private var appSources: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  
            .deletingLastPathComponent()  
            .deletingLastPathComponent()  
            .deletingLastPathComponent()  
            .deletingLastPathComponent()  
            .appendingPathComponent("Sources", isDirectory: true)
    }

    private func lines(of fileName: String) throws -> [String] {
        try String(contentsOf: appSources.appendingPathComponent(fileName), encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    private func braceBlock(from start: Int, in lines: [String]) -> String {
        var depth = 0
        var started = false
        var cursor = start
        var block: [String] = []
        while cursor < lines.count, !(started && depth <= 0) {
            for character in lines[cursor] {
                if character == "{" { depth += 1; started = true }
                if character == "}" { depth -= 1 }
            }
            block.append(lines[cursor])
            cursor += 1
        }
        return block.joined(separator: "\n")
    }

    private func arguments(of token: String, at start: Int, in lines: [String]) -> String {
        let text = lines[start...].joined(separator: "\n")
        var depth = 0
        var end = text.endIndex
        if let open = text.range(of: token) {
            var index = open.lowerBound
            while index < text.endIndex, end == text.endIndex {
                if text[index] == "(" { depth += 1 }
                if text[index] == ")" {
                    depth -= 1
                    if depth == 0 { end = text.index(after: index) }
                }
                index = text.index(after: index)
            }
        }
        return String(text[..<end])
    }

    private let structural: [(file: String, token: String)] = [

    ]

    @Test func gridFieldEditsWriteThroughTheScopedPaths() throws {
        var matched = Set<String>()
        var violations: [String] = []
        var scoped = 0
        for fileName in ["PresentGridView.swift", "ChordEditorSheet.swift"] {
            let lines = try lines(of: fileName)
            for (index, line) in lines.enumerated() {
                if line.contains("updatePresentation(") {
                    let block = braceBlock(from: index, in: lines)
                    if let entry = structural.first(where: { $0.file == fileName && block.contains($0.token) }) {
                        matched.insert(entry.token)
                    } else if block.contains(".updateSlideList(") || block.contains(".updateSlideList {") {

                        scoped += 1
                    } else {
                        violations.append("\(fileName):\(index + 1)")
                    }
                }
                for api in [".updateSlide(", ".updateSlides(", ".updatePresentationField("]
                where line.contains(api) {
                    scoped += 1
                }
            }
        }
        #expect(violations.isEmpty, "a field edit re-encodes the whole deck — use updateSlide / updateSlides / updatePresentationField: \(violations)")
        let stale = structural.map(\.token).filter { !matched.contains($0) }
        #expect(stale.isEmpty, "no longer a whole-value site, shrink the allowlist: \(stale)")
        #expect(scoped >= 17, "the migrated grid, chord and plan-sync edits (\(scoped))")
    }

    @Test func presentSurfaceWritesAndTheirUndoStayScoped() throws {
        let lines = try lines(of: "AppModel.swift")
        let start = try #require(lines.firstIndex { $0.contains("func updatePresentation(") })
        let end = try #require(lines[start...].firstIndex { $0.contains("func addArrangement(_ presentationID: String, then select:") })
        var calls = 0
        var violations: [String] = []
        for index in start..<end where lines[index].contains("updatePresentation(")
            && !lines[index].contains("func updatePresentation(") {
            calls += 1
            let block = braceBlock(from: index, in: lines)
            if !block.contains("try ") {
                violations.append("AppModel.swift:\(index + 1)")
            }
        }
        #expect(calls >= 10, "the section's writes (\(calls))")
        #expect(violations.isEmpty, "whole-value write in the present-surface section: \(violations)")
        let section = lines[start..<end].joined(separator: "\n")

        #expect(section.contains("updatePresentation(id, scope: \"whole\", value: mutate) { try $0.update(mutate) }"), "the whole-value path names itself in presentation.write")
        #expect(section.components(separatedBy: "updateSlideList").count - 1 >= 2, "restore and apply land through updateSlideList")
    }

    @Test func mediaEditorWritesOncePerDragAndPerPause() throws {
        let lines = try lines(of: "MediaEditorView.swift")
        var sliders = 0
        for (index, line) in lines.enumerated() {
            if line.contains("BoundedSliderRow(") {
                sliders += 1
                #expect(
                    arguments(of: "BoundedSliderRow(", at: index, in: lines).contains("onScrubPhase:"),
                    "MediaEditorView.swift:\(index + 1) writes the document per drag tick")
            }
            if line.contains(" TextField(") {
                let call = arguments(of: "TextField(", at: index, in: lines)
                #expect(
                    !call.contains("updateMedia(") && !call.contains("updateAudio("),
                    "MediaEditorView.swift:\(index + 1) writes the document per keystroke")
            }
        }
        #expect(sliders >= 2)
    }
}
