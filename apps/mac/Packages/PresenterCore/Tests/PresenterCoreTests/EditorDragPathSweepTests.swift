import Foundation
import Testing

@Suite struct EditorDragPathSweepTests {
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

    private func body(of function: String, in source: String) throws -> String {
        let start = try #require(source.range(of: function))
        let tail = source[start.upperBound...]
        let end = try #require(tail.range(of: "\n    }\n"))
        return String(tail[..<end.lowerBound])
    }

    @Test func onlyTheGeometryRowsReadTheLiveDragFrame() throws {
        let inspector = try source("SlideObjectInspector.swift")
        let rows = try #require(inspector.range(of: "private struct ObjectGeometryRows: View {"))
        let before = inspector[..<rows.lowerBound]
        #expect(!before.contains("displayFrame("), "the inspector's Form body must not read displayFrame: it reads previewFrames, which every mouse move writes — ObjectGeometryRows is the one reader")
        let rowsBody = inspector[rows.lowerBound...]
        #expect(rowsBody.contains("model.displayFrame(for: object)"), "ObjectGeometryRows reads the live frame")
        #expect(rowsBody.contains("model.isDraggingObjects") && rowsBody.contains("documentFrame(for: object)"), "mid-drag the rows hold the document frame: any SwiftUI update per mouse move is a full inspector layout pass (~45 ms)")
        let model = try source("SlideEditorModel.swift")
        #expect(model.contains("private(set) var isDraggingObjects = false"), "isDraggingObjects is stored and flips twice per drag; computed from previewFrames every reader would update per move")
    }

    @Test func canvasOverlayObservesTheModelItself() throws {
        let overlay = try source("EditorInteractionView.swift")
        let update = try body(of: "func updateNSView(_ nsView: EditorInteractionNSView", in: overlay)
        #expect(!update.contains("= model."), "updateNSView must not read observable model state: SwiftUI charges a representable's reads to the enclosing body, and the drag state read there re-laid out the whole editor per mouse move (2026-09-16)")
        #expect(overlay.contains("withObservationTracking"), "the overlay NSView observes the model itself (armObservation)")
    }

    @Test func canvasMarqueeLandsItsSelectionOnMouseUp() throws {
        let overlay = try source("EditorInteractionView.swift")
        let dragged = try body(of: "override func mouseDragged(with event: NSEvent)", in: overlay)
        let sweep = try #require(dragged.range(of: "case .marquee(let origin, let base):"))
        #expect(dragged[sweep.lowerBound...].contains("marqueeSelection = model.sweptSelection("), "the band's sweep stays on the canvas while it moves")
        #expect(!dragged.contains("setSelection("), "a selection write per move re-evaluated the whole editor, Objects panel and inspector each time the band reached an object")
        let up = try body(of: "override func mouseUp(with event: NSEvent)", in: overlay)
        #expect(up.contains("model.setSelection(marqueeSelection)"), "mouse-up lands the sweep as one selection change")
    }

    @Test func inspectorFieldFocusKeepsTheCanvasTextEditOpen() throws {
        let overlay = try source("EditorInteractionView.swift")
        let ended = try body(of: "func textDidEndEditing(_ notification: Notification)", in: overlay)
        #expect(ended.contains("settleCanvasEditFocus()") && !ended.contains("endCanvasEditing()"), "closing the edit as the overlay resigns removed the Selection section mid-click, and AppKit's click loop spun on the orphaned Size field (2026-10-08 beachball)")
        let settle = try body(of: "private func keepOrEndCanvasEditing()", in: overlay)
        #expect(settle.contains("field.isFieldEditor") && settle.contains("NSText.didEndEditingNotification"), "a one-line field keeps the edit open until that field's editing ends")
        #expect(!settle.contains("endCanvasEditing()"), "the deferred close leaves focus where the click put it")
        let teardown = try body(of: "private func tearDownOverlay()", in: overlay)
        #expect(teardown.contains("stopWatchingInspectorField()"), "every close drops the field watch")
    }

    @Test func toolbarStateNeverReadsTheLiveDragFrame() throws {
        let model = try source("SlideEditorModel.swift")
        let start = try #require(model.range(of: "var canDistribute: Bool {"))
        let line = model[start.upperBound...].prefix { $0 != "\n" }
        #expect(!line.contains("selectionUnits()") && !line.contains("displayFrame("), "canDistribute is read by the editor toolbar on every body pass; counting through display frames (previewFrames) re-evaluated the whole editor per mouse move (2026-09-16)")
    }

    @Test func liveDragSharesTheEditorScenePipeline() throws {
        let model = try source("SlideEditorModel.swift")
        let drag = try body(of: "func previewDrag(frames:", in: model)
        #expect(drag.contains("editorScene(for:"), "previewDrag builds its scene through editorScene, never its own SlideSceneBuilder call")
        #expect(!drag.contains("SlideSceneBuilder.scene("), "a second scene path drops the linked-text sample data (2026-09-16)")
        let refresh = try body(of: "func refreshScene()", in: model)
        #expect(refresh.contains("editorScene(for:"), "refreshScene rides the same pipeline")
        let pipeline = try body(of: "private func editorScene(for slide: Slide", in: model)
        #expect(pipeline.contains("LinkedText.previewObjects("), "the pipeline resolves linked text (resolvedObjects over sample data)")
        #expect(pipeline.contains("EmptyTextPlaceholder.applied("), "the pipeline applies the empty-text hint")
    }
}
