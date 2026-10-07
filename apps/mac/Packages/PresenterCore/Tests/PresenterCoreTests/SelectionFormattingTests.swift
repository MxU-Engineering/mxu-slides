import Foundation
import Testing
@testable import PresenterCore

private func text(_ id: String, size: Double? = nil) -> SlideObject {
    var style = TextStyle()
    style.fontSize = size
    return SlideObject(id: id, objectKind: .text, name: id, text: id, textStyle: size == nil ? nil : style)
}

@Test func primaryIsTheSelectedObjectLowestInLayerOrder() {
    let objects = [text("bottom"), text("middle"), text("top")]
    #expect(SelectionFormatting.primary(in: objects, ids: ["top", "middle"])?.id == "middle")
    #expect(SelectionFormatting.primary(in: objects, ids: []) == nil)
    #expect(SelectionFormatting.selectedObjects(in: objects, ids: ["top", "bottom"]).map(\.id) == ["bottom", "top"])
}

@Test func selectedObjectsNormalizeLegacyKinds() {
    let media = SlideObject(id: "m", objectKind: .media, name: "Loop", text: "", mediaId: "media-1")
    let selected = SelectionFormatting.selectedObjects(in: [media, text("t")], ids: ["m"])
    #expect(selected.map(\.objectKind) == [.shape])
    #expect(selected.first?.fill?.mediaId == "media-1")
}

@Test func mixedKindsShareOnlyTheObjectCard() {
    let shape = SlideObject(id: "s", objectKind: .shape, name: "Box", text: "")
    #expect(SelectionFormatting.sharesKind([text("a"), text("b")]))
    #expect(SelectionFormatting.sharesKind([shape, shape]))
    #expect(!SelectionFormatting.sharesKind([text("a"), shape]))
}

@Test func mixedReadsThroughTheInheritedDefault() {
    let agree = [text("a"), text("b")]
    #expect(!SelectionFormatting.isMixed(agree) { $0.textStyle?.fontSize ?? 96 })
    let disagree = [text("a", size: 48), text("b")]
    #expect(SelectionFormatting.isMixed(disagree) { $0.textStyle?.fontSize ?? 96 })

    #expect(!SelectionFormatting.isMixed([text("a", size: 96), text("b")]) { $0.textStyle?.fontSize ?? 96 })
}
