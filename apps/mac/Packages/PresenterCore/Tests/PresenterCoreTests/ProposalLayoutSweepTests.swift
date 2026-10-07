import Foundation
import Testing

@Suite struct ProposalLayoutSweepTests {

    private let proposalAllowed: [String: String] = [:]

    @Test func toolbarRowIsChosenAtTheMeasuredWidth() throws {
        let sweep = try SourceSweep.app()
        let file = try #require(sweep.file("SlideEditorView.swift"))
        let start = try #require(file.lines.firstIndex { $0.contains("private func editorToolbar(") })
        let body = file.block(from: start).map { file.lines[$0] }.joined(separator: "\n")
        #expect(body.contains("ViewThatFits(in: .horizontal)"))
        #expect(
            body.contains(".frame(width: toolbarWidth"),
            "ViewThatFits must see one fixed width in every pass, or the minimum-size probe and the real layout pick different rows forever"
        )
        #expect(
            body.contains(".onGeometryChange(for: CGFloat.self)") && body.contains("toolbarWidth = $0"),
            "toolbarWidth must come from the column's measured width"
        )
    }

    @Test func everyViewThatFitsChoosesAtAMeasuredWidth() throws {
        let sweep = try SourceSweep.app()
        var sites = 0
        var violations: [String] = []
        for file in sweep.files {
            for index in file.lines.indices where file.code(index).contains("ViewThatFits(") {
                sites += 1
                if proposalAllowed[file.name] != nil { continue }
                let closure = file.block(from: index)

                var chain: [String] = []
                var cursor = closure.upperBound + 1
                while cursor < file.lines.count {
                    let trimmed = file.lines[cursor].trimmingCharacters(in: .whitespaces)
                    guard trimmed.hasPrefix(".") || trimmed.hasPrefix("//") else { break }
                    chain.append(file.code(cursor))
                    cursor += 1
                }
                let width = chain.lazy.compactMap { $0.firstMatch(of: /\.frame\(width: ([A-Za-z_][A-Za-z0-9_]*)/) }.first
                let measured = width.map { name in
                    file.lines.contains { $0.contains(".onGeometryChange(") && $0.contains("\(name.1) = $0") }
                } ?? false
                if !measured {
                    violations.append("\(file.name):\(index + 1)")
                }
            }
        }
        #expect(sites >= 1, "the sweep should see the app's ViewThatFits sites (\(sites))")
        #expect(
            violations.isEmpty,
            "ViewThatFits must choose at a measured width: wrap it in .frame(width: w) with w written by .onGeometryChange { w = $0 } (see SlideEditorView.editorToolbar), or allow-list it here with the reason: \(violations)"
        )
    }

    @Test func geometryReaderBranchesNeverSwapControls() throws {
        let sweep = try SourceSweep.app()
        let controls = ["Button", "Menu(", "Picker(", "Toggle(", "TextField(", "Slider(", "Stepper(", "DatePicker("]
        var readers = 0
        var violations: [String] = []
        for file in sweep.files {
            for index in file.lines.indices where file.code(index).contains("GeometryReader") {
                guard let match = file.code(index).firstMatch(of: /GeometryReader\s*\{\s*([A-Za-z_][A-Za-z0-9_]*)\s+in/)
                else { continue }
                readers += 1
                let proxy = String(match.1)
                let closure = file.block(from: index)

                var derived: Set<String> = []
                var branches = false
                var hasControls = false
                for line in closure.map(file.code) {
                    let words = Set(line.split { !$0.isLetter && !$0.isNumber && $0 != "_" }.map(String.init))
                    let sized = line.contains("\(proxy).size") || !derived.isDisjoint(with: words)
                    if sized, let name = line.firstMatch(of: /let\s+([A-Za-z_][A-Za-z0-9_]*)\s*=/) {
                        derived.insert(String(name.1))
                    }
                    if sized, line.trimmingCharacters(in: .whitespaces).hasPrefix("if ") {
                        branches = true
                    }
                    if controls.contains(where: line.contains) { hasControls = true }
                }
                if branches, hasControls {
                    violations.append("\(file.name):\(index + 1)")
                }
            }
        }
        #expect(readers >= 30, "the sweep should see the app's GeometryReaders (\(readers))")
        #expect(
            violations.isEmpty,
            "a GeometryReader branch on the proposal swaps controls: measure into state (onGeometryChange) and branch on it: \(violations)"
        )
    }
}
