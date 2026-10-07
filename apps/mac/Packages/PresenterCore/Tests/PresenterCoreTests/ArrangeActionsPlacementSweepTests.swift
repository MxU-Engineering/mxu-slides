import Foundation
import Testing

@Suite struct ArrangeActionsPlacementSweepTests {
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

    @Test func editorHeaderHasNoGroupAlignOrLayerTools() throws {
        let editor = try source("SlideEditorView.swift")
        let start = try #require(editor.range(of: "private func editorToolbar("))
        let end = try #require(editor.range(of: "private func addObjectTools(", range: start.upperBound..<editor.endIndex))
        let toolbar = editor[start.lowerBound..<end.lowerBound]
        for gone in ["alignMenu(", "layerTools(", "arrangeMenu(", "groupTools(", "bringForward", "alignSelection", "groupSelection"] {
            #expect(!toolbar.contains(gone), "the header places objects; \(gone) edits placed ones")
        }
    }

    @Test func groupShortcutsLiveInTheEditMenu() throws {
        let editor = try source("SlideEditorView.swift")
        #expect(editor.contains("CommandGroup(after: .pasteboard)"))
        #expect(editor.contains("Button(\"Group\") { editor?.perform(.group) }\n                .keyboardShortcut(\"g\", modifiers: .command)"))
        #expect(editor.contains("Button(\"Ungroup\") { editor?.perform(.ungroup) }\n                .keyboardShortcut(\"g\", modifiers: [.command, .shift])"))
    }

    @Test func inspectorObjectCardCarriesArrangeRows() throws {
        let inspector = try source("SlideObjectInspector.swift")
        #expect(inspector.contains("ObjectArrangeRows(model: model, multi: multi)"), "the Object card shows the rows")
        #expect(inspector.contains("strip(SlideEditorModel.ArrangeAction.horizontalAlign)"))
        #expect(inspector.contains("strip(SlideEditorModel.ArrangeAction.distribute)"))
        #expect(inspector.contains("strip(SlideEditorModel.ArrangeAction.layerOrder)"))
        #expect(inspector.contains("isEnabled: { model.canPerform($0) }"), "a verb that can't apply now is dimmed")
        #expect(inspector.contains("SelectionGroupButtons(model: model)"), "the multi-selection card groups")
        #expect(inspector.contains("ForEach(SlideEditorModel.ArrangeAction.grouping"))
    }

    @Test func bothRightClickMenusOfferAlignAndLayerOrder() throws {
        let canvas = try source("EditorInteractionView.swift")
        #expect(canvas.contains("NSMenuItem(title: \"Align\""), "the canvas menu's Align submenu")
        #expect(canvas.contains("SlideEditorModel.ArrangeAction.grouping.forEach"), "the canvas menu groups")
        #expect(canvas.contains("SlideEditorModel.ArrangeAction.layerOrder.forEach"))
        #expect(canvas.contains("model.perform(action)"))

        let panel = try source("SlideEditorView.swift")
        #expect(panel.contains("objectRowArrangeItems("), "the Objects panel row menu")
        #expect(panel.contains("Menu(\"Align\")"))
        #expect(panel.contains("Button(\"Group\") { arrangeFromRow(.group, id: id, model) }"), "the row menu groups the selection it belongs to")
        #expect(panel.contains("Button(\"Ungroup\") { arrangeFromRow(.ungroup, id: id, model) }"))
        #expect(panel.contains("canUngroup = isSelected ? selection.canUngroup : object.groupId?.isEmpty == false"), "a row outside the selection ungroups its own group")
        #expect(panel.contains("ForEach(SlideEditorModel.ArrangeAction.layerOrder"))
    }

    @Test func everyArrangeVerbRunsThroughOneCatalog() throws {
        let model = try source("SlideEditorModel.swift")
        let verbs = [
            ".group: groupSelection()", ".ungroup: ungroupSelection()",
            ".alignLeft: alignSelection(.left)", ".alignCenter: alignSelection(.centerX)",
            ".alignRight: alignSelection(.right)", ".alignTop: alignSelection(.top)",
            ".alignMiddle: alignSelection(.centerY)", ".alignBottom: alignSelection(.bottom)",
            ".distributeHorizontally: distributeSelection(horizontally: true)",
            ".distributeVertically: distributeSelection(horizontally: false)",
            ".bringToFront: bringToFront()", ".bringForward: bringForward()",
            ".sendBackward: sendBackward()", ".sendToBack: sendToBack()",
        ]
        for verb in verbs {
            #expect(model.contains("case \(verb)"), "perform maps \(verb)")
        }
    }
}
