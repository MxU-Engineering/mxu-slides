import PresenterCore
import Testing
@testable import SlideScene

private func text(_ id: String, _ text: String, kind: SlideObjectKind = .text) -> SlideObject {
    SlideObject(id: id, objectKind: kind, name: id, text: text)
}

@Test func emptyTextBoxGetsDimmedHint() {
    let out = EmptyTextPlaceholder.applied(to: [text("a", "")])
    #expect(out[0].text == EmptyTextPlaceholder.text)
    #expect(out[0].opacity == EmptyTextPlaceholder.opacityScale)
}

@Test func placeholderScalesExistingOpacity() {
    var object = text("a", "")
    object.opacity = 0.5
    let out = EmptyTextPlaceholder.applied(to: [object])
    #expect(out[0].opacity == 0.5 * EmptyTextPlaceholder.opacityScale)
}

@Test func placeholderSkipsTypedEditedLinkedAndShapes() {
    var linked = text("linked", "")
    linked.textLink = TextLink(source: .currentSlide)
    let objects = [text("typed", "Hi"), text("editing", ""), linked, text("shape", "", kind: .shape)]
    let out = EmptyTextPlaceholder.applied(to: objects, editingID: "editing")
    #expect(out.map(\.text) == ["Hi", "", "", ""])
    #expect(out.allSatisfy { $0.opacity == nil })
}
