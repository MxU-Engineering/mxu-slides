import Foundation
import Testing
@testable import PresenterCore

@Test func fontRecentsMoveToFrontDedupeAndCap() {
    var recents: [String] = []
    for family in ["Arial", "Helvetica", "Futura", "Georgia", "Verdana", "Menlo"] {
        recents = FontMenuLogic.recents(adding: family, to: recents)
    }

    #expect(recents == ["Menlo", "Verdana", "Georgia", "Futura", "Helvetica"])

    recents = FontMenuLogic.recents(adding: "Georgia", to: recents)
    #expect(recents == ["Georgia", "Menlo", "Verdana", "Futura", "Helvetica"])
}

@Test func fontRecentsDropUninstalledFamilies() {
    let shown = FontMenuLogic.installedRecents(
        ["Gotham", "Helvetica", "Ghost"], installed: ["Arial", "Helvetica"])
    #expect(shown == ["Helvetica"])
}

@Test func fontFilterRanksPrefixBeforeContainsCaseInsensitively() {
    let families = ["Arial", "Chalkboard", "Helvetica", "Helvetica Neue", "Marker Felt"]
    #expect(FontMenuLogic.filter(families, query: "  ") == families)

    #expect(FontMenuLogic.filter(families, query: "HE") == ["Helvetica", "Helvetica Neue"])

    #expect(FontMenuLogic.filter(families, query: "ar") == ["Arial", "Chalkboard", "Marker Felt"])
    #expect(FontMenuLogic.filter(families, query: "zzz").isEmpty)
}
