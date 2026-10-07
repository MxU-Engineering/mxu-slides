import Foundation
import Testing

@Suite struct EditorSelectionSweepTests {
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

    @Test func sceneAndInteractionSpanThePasteboard() throws {
        let editor = try source("SlideEditorView.swift")
        let scene = try #require(editor.range(of: "SceneCanvas(render: render, transparentBackground: true, inset: EditorGeometry.pasteboardInset)\n"))
        let next = editor[scene.upperBound...].prefix(120)
        #expect(next.contains("EditorInteractionView(model: model)\n"), "the interaction view sits right over the scene")
        #expect(!next.contains(".aspectRatio("), "neither is cut to the slide's aspect")
        #expect(editor.contains("TransparencyGrid(square: 12)\n                        .aspectRatio(model.canvasSize, contentMode: .fit)\n                        .padding(EditorGeometry.pasteboardInset)"),
                "the checkerboard stays the slide's size")

        let canvas = try source("EditorInteractionView.swift")
        #expect(canvas.contains("drawPasteboardVeil(in: context)\n        drawGuides("), "the veil draws under all chrome")
        #expect(canvas.contains("canvas: model.canvasSize, in: bounds.size, inset: EditorGeometry.pasteboardInset)"))
        #expect(try source("GutterDropDelegate.swift").contains(
            "fromView: location, viewSize: viewSize(), canvas: canvasSize, inset: EditorGeometry.pasteboardInset)"),
            "drops map through the same letterbox")
        #expect(editor.contains("SceneCanvas(render: render, transparentBackground: true, inset: EditorGeometry.pasteboardInset)"),
                "the scene keeps the same band clear")
        #expect(editor.components(separatedBy: ".padding(EditorGeometry.pasteboardInset)").count == 4,
                "the checkerboard, Animate overlay and drop outline sit in the same letterbox")
    }

    @Test func aPressKeepsTheSelectedObjectUnderAnother() throws {
        let canvas = try source("EditorInteractionView.swift")
        #expect(canvas.contains("EditorGeometry.pressTarget(\n                at: point, in: objects, selected: model.selectedObjectIDs"))
        #expect(canvas.contains("if event.clickCount == 2, let hit = pressed, model.canEditPath(hit)"), "double-click edits the pressed object")
        #expect(canvas.contains("if event.clickCount == 2, let hit = pressed,\n"))
        #expect(canvas.contains(": pressed\n"), "a plain press moves the pressed object")
    }

    @Test func objectsPanelTakesModifierClicksAndBothListsSweep() throws {
        let editor = try source("SlideEditorView.swift")
        #expect(!editor.contains("select: { model.setSelection([entry.object.id]) }"),
                "a select-on-down with ⌘/⇧ held undid the List's own extend")
        let objectSelect = try #require(editor.range(of: "if NSEvent.modifierFlags.isDisjoint(with: [.command, .shift]) {\n"
            + "                                                model.setSelection([entry.object.id])"))
        #expect(!objectSelect.isEmpty, "only a plain press selects on the way down")
        #expect(editor.contains(".reportingGlobalFrame(id: slide.id, into: $slideRowFrames)"))
        #expect(editor.contains(".reportingGlobalFrame(id: entry.object.id, into: $objectRowFrames)"))
        #expect(editor.contains("rowFrames: Array(slideRowFrames.values)"))
        #expect(editor.contains("rowFrames: Array(objectRowFrames.values)"))
        #expect(editor.contains("RunOrderSelection.swept(frames: slideRowFrames, band: band, keeping: slideMarqueeBase)"))
        #expect(editor.contains("RunOrderSelection.swept(frames: objectRowFrames, band: band, keeping: objectMarqueeBase)"))
        #expect(editor.contains(".overlay { ListMarqueeBand(rect: slideMarquee) }"))
        #expect(editor.contains(".overlay { ListMarqueeBand(rect: objectMarquee) }"))
    }
}
