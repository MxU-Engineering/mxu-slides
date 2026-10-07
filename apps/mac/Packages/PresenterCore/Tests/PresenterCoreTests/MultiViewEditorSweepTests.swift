import Foundation
import Testing

@Suite struct MultiViewEditorSweepTests {
    private func source(_ name: String) throws -> String {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  
            .deletingLastPathComponent()  
            .deletingLastPathComponent()  
            .deletingLastPathComponent()  
            .deletingLastPathComponent()  
            .appendingPathComponent("Sources", isDirectory: true)
        return try String(contentsOf: sources.appendingPathComponent(name), encoding: .utf8)
    }

    @Test func aCanvasPressOnAMultiViewNeverReachesTheObjectDragPath() throws {
        let view = try source("EditorInteractionView.swift")
        let down = try #require(view.range(of: "override func mouseDown(with event: NSEvent) {"))
        let tiles = try #require(view.range(of: "if let layout = model.multiViewLayout {", range: down.upperBound..<view.endIndex))
        let objectHit = try #require(view.range(of: "model.handleClick(objectID:", range: down.upperBound..<view.endIndex))
        #expect(tiles.lowerBound < objectHit.lowerBound, "the tile branch returns before any object hit-testing")
    }

    @Test func selectingAnObjectInAMultiViewSelectsItsTile() throws {
        let model = try source("SlideEditorModel.swift")
        let start = try #require(model.range(of: "func setSelection(_ ids: Set<String>) {"))
        let body = model[start.upperBound...].prefix(900)
        #expect(body.contains("if isMultiView {") && body.contains("selectedObjectIDs = []"))
    }

    @Test func everyTreeEditRegeneratesTheObjectsInTheSameWrite() throws {
        let model = try source("SlideEditorModel.swift")
        let start = try #require(model.range(of: "func updateMultiView("))
        let body = model[start.upperBound...].prefix(700)
        #expect(body.contains("let next = transform(tree)") && body.contains("layout.multiView = next"))
        #expect(body.contains("layout.regenerateMultiViewObjects(context: context)"), "tree and objects land as ONE undoable change, never apart")
    }

    @Test func theMultiViewToolbarReplacesTheObjectTools() throws {
        let editor = try source("SlideEditorView.swift")
        let start = try #require(editor.range(of: "private func editorToolbar("))
        let body = editor[start.upperBound...].prefix(900)
        #expect(body.contains("if model.isMultiView {") && body.contains("MultiViewToolbar(model: model)"))
    }
}

extension MultiViewEditorSweepTests {
    @Test func noDoorAddsAnObjectToAMultiView() throws {
        let model = try source("SlideEditorModel.swift")
        for door in ["private func add(_ object: SlideObject) {", "func pasteObjects() {", "func beginPathDrawing() {"] {
            let start = try #require(model.range(of: door))
            #expect(model[start.upperBound...].prefix(260).contains("guard !isMultiView"), "\(door) must refuse a MultiView")
        }
    }

    @Test func theLibraryBadgeNeverDecodesInABody() throws {
        let app = try source("AppModel.swift")
        let start = try #require(app.range(of: "func isMultiView(_ layoutID: String) -> Bool {"))
        let body = app[start.upperBound...].prefix(1200)
        #expect(body.contains("ThumbnailStore.shared.faceValue(") && !body.contains("library.open("), "the badge reads a set filled off-main (the noteLinks pattern)")
    }
}

extension MultiViewEditorSweepTests {

    @Test func newMultiViewsAreFiledLikeAnyNewItem() throws {
        let app = try source("AppModel.swift")
        let start = try #require(app.range(of: "func createMultiView("))
        let body = app[start.upperBound...].prefix(700)
        #expect(body.contains("createInDrive(layout)") && !body.contains("layout.folder ="))
    }
}

@Suite struct AutomaticTimerCopySweepTests {
    @Test func noPickerStillSaysPrimaryTimer() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources", isDirectory: true)
        var offered = 0
        for file in ["SlideObjectInspector.swift", "MultiViewEditorViews.swift"] {
            let text = try String(contentsOf: sources.appendingPathComponent(file), encoding: .utf8)
            #expect(!text.contains("\"Primary Timer\""))
            offered += text.components(separatedBy: "Text(AutomaticTimer.title)").count - 1
            #expect(
                text.components(separatedBy: "Text(AutomaticTimer.title)").count
                    == text.components(separatedBy: ".help(AutomaticTimer.help)").count,
                "\(file): every picker that offers it explains it")
        }
        #expect(offered == 3)
    }
}


extension MultiViewEditorSweepTests {

    @Test func theTileContextIsBuiltOncePerTreeNotPerBodyPass() throws {
        let model = try source("SlideEditorModel.swift")
        #expect(model.components(separatedBy: "makeMultiViewContext(for:").count - 1 == 2, "the snapshot and updateMultiView — nowhere else")
        for file in ["MultiViewEditorViews.swift", "EditorInteractionView.swift"] {
            #expect(!(try source(file)).contains("makeMultiViewContext"))
        }
    }
}
