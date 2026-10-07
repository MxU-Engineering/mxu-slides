import Foundation
import Testing

@testable import PresenterCore

@Suite struct MenuCommandLogicTests {
    @Test func menuActionsCompareByIdentityNotClosure() {
        var runs = 0
        let first = MenuAction("find") { runs += 1 }
        let again = MenuAction("find") { runs += 10 }
        let other = MenuAction("import") { runs += 100 }
        #expect(first == again)
        #expect(first != other)
        first()
        #expect(runs == 1)
    }

    @Test func undoRoutesToTheOpenEditorFirst() {
        #expect(UndoMenuLogic.target(editorOpen: true, fieldEditorCan: true, journalCan: true) == .editor)
        #expect(UndoMenuLogic.target(editorOpen: true, fieldEditorCan: false, journalCan: false) == .editor)
    }

    @Test func undoOutsideTheEditorLetsTextFieldsKeepFirstClaim() {
        #expect(UndoMenuLogic.target(editorOpen: false, fieldEditorCan: true, journalCan: true) == .responderChain)
        #expect(UndoMenuLogic.target(editorOpen: false, fieldEditorCan: false, journalCan: true) == .journal)
    }

    @Test func undoWithNothingToUndoSwallowsTheKeystroke() {
        #expect(UndoMenuLogic.target(editorOpen: false, fieldEditorCan: false, journalCan: false) == .nothing)
    }

    @Test func undoItemGreysOnlyWithTheEditorsTrail() {
        #expect(UndoMenuLogic.disabled(editorOpen: true, editorCan: false))
        #expect(!UndoMenuLogic.disabled(editorOpen: true, editorCan: true))
        #expect(!UndoMenuLogic.disabled(editorOpen: false, editorCan: false))
    }

    private var appSources: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  
            .deletingLastPathComponent()  
            .deletingLastPathComponent()  
            .deletingLastPathComponent()  
            .deletingLastPathComponent()  
            .appendingPathComponent("Sources", isDirectory: true)
    }

    @Test func focusedValuesNeverCarryBareClosures() throws {
        let files = FileManager.default.enumerator(at: appSources, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        try #require(!files.isEmpty, "app sources not found at \(appSources.path)")
        var violations: [String] = []
        for file in files {
            let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false)
            for (index, line) in lines.enumerated() where line.contains("@Entry var") && line.contains("->") {
                violations.append("\(file.lastPathComponent):\(index + 1): \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
        #expect(violations.isEmpty, "closure-typed focused values: \(violations)")
    }
}
