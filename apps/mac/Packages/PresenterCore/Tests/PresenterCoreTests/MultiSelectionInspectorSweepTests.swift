import Foundation
import Testing

@Suite struct MultiSelectionInspectorSweepTests {
    private var appSources: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  
            .deletingLastPathComponent()  
            .deletingLastPathComponent()  
            .deletingLastPathComponent()  
            .deletingLastPathComponent()  
            .appendingPathComponent("Sources", isDirectory: true)
    }

    private func source(_ file: String) throws -> String {
        try String(contentsOf: appSources.appendingPathComponent(file), encoding: .utf8)
    }

    @Test func everyInspectorWriteFansOutOverTheSelection() throws {
        let inspector = try source("SlideObjectInspector.swift")
        let rows = try #require(inspector.range(of: "private struct ObjectGeometryRows: View {"))
        let form = inspector[..<rows.lowerBound]
        #expect(!form.contains("model.updateObject(id:"), "inspector writes go through commit(object), which targets the whole selection")
        #expect(form.contains("model.updateObjects(ids: editTargets(object), mutate)"), "commit(object) writes every selected object as one change")
        #expect(form.contains("if let object = model.inspectedObject {"), "a multi-selection edits through its primary object")
        #expect(!form.contains("Properties edit one object at a time"), "the multi-selection placeholder is gone")
        #expect(form.contains("model.resetObjectsToTheme(editTargets(object))"), "Reset to Theme resets the whole selection")
        for control in ["\\.fontName", "\\.fontSize", "\\.colorHex", "\\.horizontalAlignment", "\\.tracking", "\\.opacity"] {
            #expect(form.contains("mixedValue(styleMixed(\(control)") || form.contains("mixedValue(objectMixed(\(control)"), "\(control) carries the mixed dot")
        }
    }

    @Test func modelWritesTheSelectionAsOneUndoableChange() throws {
        let model = try source("SlideEditorModel.swift")
        let start = try #require(model.range(of: "func updateObjects(ids: Set<String>, _ rawMutate: (inout SlideObject) -> Void) {"))
        let tail = model[start.upperBound...]
        let end = try #require(tail.range(of: "\n    }\n"))
        let body = tail[..<end.lowerBound]
        #expect(body.contains("updateObject(id: id, rawMutate)"), "one id keeps the scoped subtree write and the build-state redirect")
        #expect(body.contains("updateDocument { presentation in"), "a set rides one whole-document write, like the multi-object nudge")
        #expect(body.contains("scrubPreviewOverrides[id] = object"), "mid-scrub every member previews live")
        #expect(model.contains("SelectionFormatting.primary(in: currentSlide?.objects ?? [], ids: selectedObjectIDs)"), "inspectedObject is the selection's primary")
    }
}
