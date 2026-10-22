import Automerge
import Foundation
import Testing
@testable import PresenterCore

@Test func v138PresentationDecodesWithTransitionAbsent() throws {
    let json = """
    {"id":"p","name":"Song","presentationKind":"deck","themeId":"","slides":[]}
    """
    let decoded = try JSONDecoder().decode(Presentation.self, from: Data(json.utf8))
    #expect(decoded.transition == nil)
}

@Test func presentationTransitionRoundTrips() throws {
    var presentation = Presentation(id: "p", name: "Song", presentationKind: .deck, themeId: "", slides: [])
    presentation.transition = Transition(transitionKind: .dissolve, durationSeconds: 1)
    let document = Document()
    try AutomergeEncoder(doc: document).encode(presentation)
    let decoded = try AutomergeDecoder(doc: document).decode(Presentation.self)
    #expect(decoded.transition == Transition(transitionKind: .dissolve, durationSeconds: 1))
}
