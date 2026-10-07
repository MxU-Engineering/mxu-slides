import Foundation
@testable import PresenterCore

enum DeckFixtures {
    static func deck(_ id: String = "deck") -> Presentation {
        Presentation(id: id, name: "Deck \(id)", presentationKind: .deck, themeId: "", slides: [
            Slide(id: "\(id)-s1", name: "One", objects: []),
            Slide(id: "\(id)-s2", name: "Two", objects: []),
            Slide(id: "\(id)-s3", name: "Three", objects: []),
        ])
    }
}
