import Foundation
import Testing

@Suite struct ConfidenceEditorCrashSweepTests {

    @Test func toolTipOwnersAreRetained() throws {
        let sweep = try SourceSweep.app()
        var sites = 0
        var violations: [String] = []
        for file in sweep.files {
            for index in file.lines.indices where file.code(index).contains("addToolTip(") {
                sites += 1

                let call = (index..<min(index + 6, file.lines.count)).map { file.code($0) }.joined(separator: " ")
                let owner = call.firstMatch(of: /owner:\s*([^,)]+)/).map { String($0.1).trimmingCharacters(in: .whitespaces) }
                let retained = owner.map { $0 == "self" || $0.hasPrefix("Self.") } ?? false
                if !retained {
                    violations.append("\(file.name):\(index + 1)")
                }
            }
        }
        #expect(sites >= 1, "the sweep should see the editor's clipped-text tooltip")
        #expect(
            violations.isEmpty,
            "AppKit keeps a tooltip owner unretained: pass self or a static (Self.name), never a value made in the call: \(violations)"
        )
    }

    @Test func layoutAssignmentsPruneOnlyOnceTheLibraryIsOpen() throws {
        let sweep = try SourceSweep.app()
        let file = try #require(sweep.file("ConfidenceMonitorController.swift"))
        let start = try #require(file.lines.firstIndex { $0.contains("func refresh() {") })
        let body = file.block(from: start).map { file.code($0) }
        let prunes = body.filter { $0.contains("indexEntry(") && $0.contains("== nil") }
        #expect(!prunes.isEmpty)
        #expect(
            prunes.allSatisfy { $0.contains("client.isReady") },
            "refresh() must not prune an assignment before the library opens (the index is empty at launch)"
        )
    }
}
