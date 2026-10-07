import Foundation
import Testing
@testable import PresenterCore

private func layout(width: Int? = nil, height: Int? = nil) -> ConfidenceLayout {
    ConfidenceLayout(
        id: "layout-1", name: "Booth",
        objects: [SlideObject(id: "a", objectKind: .shape, name: "A", text: "")],
        canvasWidth: width, canvasHeight: height
    )
}

@Test func editorMirrorCarriesTheLayoutsCanvasAndComposition() {
    let mirror = layout(width: 1080, height: 1920).editorMirror

    #expect(mirror.canvasWidth == 1080)
    #expect(mirror.canvasHeight == 1920)
    #expect(mirror.slides.map(\.id) == ["layout-1"])
    #expect(mirror.slides.first?.objects.map(\.id) == ["a"])
}

@Test func adoptingAMirrorPersistsACanvasResize() {
    var edited = layout()
    var mirror = edited.editorMirror
    mirror.canvasWidth = 1080
    mirror.canvasHeight = 1920
    mirror.slides[0].objects.append(SlideObject(id: "b", objectKind: .text, name: "B", text: ""))
    mirror.slides[0].animationOrder = ["b", "a"]

    edited.adopt(editorMirror: mirror)

    #expect(edited.canvasWidth == 1080)
    #expect(edited.canvasHeight == 1920)
    #expect(edited.objects.map(\.id) == ["a", "b"])
    #expect(edited.animationOrder == ["b", "a"])
}

@Test func adoptingTheDefaultCanvasStoresAbsent() {
    var edited = layout(width: 1080, height: 1920)
    var mirror = edited.editorMirror
    mirror.canvasWidth = nil
    mirror.canvasHeight = nil

    edited.adopt(editorMirror: mirror)

    #expect(edited.canvasWidth == nil)
    #expect(edited.canvasHeight == nil)
}
