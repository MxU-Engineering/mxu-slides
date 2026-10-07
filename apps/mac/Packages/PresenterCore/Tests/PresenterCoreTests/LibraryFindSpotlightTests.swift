import Foundation
import Testing
@testable import PresenterCore

@Test func findSpotlightIsOffUntilTheShortcut() {
    var spotlight = LibraryFindSpotlight()
    #expect(!spotlight.active)

    spotlight.clicked(insideLibrary: true)
    #expect(!spotlight.active)
    spotlight.invoke()
    #expect(spotlight.active)
}

@Test func findSpotlightSurvivesClicksInsideTheCard() {
    var spotlight = LibraryFindSpotlight()
    spotlight.invoke()

    spotlight.clicked(insideLibrary: true)
    #expect(spotlight.active)
}

@Test func findSpotlightEndsOnAClickOffTheCard() {
    var spotlight = LibraryFindSpotlight()
    spotlight.invoke()
    spotlight.clicked(insideLibrary: false)
    #expect(!spotlight.active)

    spotlight.invoke()
    #expect(spotlight.active)
}
