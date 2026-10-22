import Foundation
import Testing
@testable import PresenterCore

@Test func storedMediaPlaylistWithRetiredWalkFieldsStillDecodes() throws {
    let json = """
    {"id":"p","name":"Loop","playlistKind":"media","autoAdvance":true,"autoAdvanceDelaySeconds":7,\
    "entries":[{"id":"e","refKind":"media","refId":"m","autoAdvanceDelaySeconds":2}],\
    "playbackMode":"playAll","crossfadeSeconds":0}
    """
    let decoded = try JSONDecoder().decode(Playlist.self, from: Data(json.utf8))
    #expect(decoded.playlistKind == .media)
    #expect(decoded.entries.map(\.refId) == ["m"])
}

@Test func v39SlideDecodesWithAutoAdvanceAbsent() throws {
    let json = """
    {"id":"s","name":"Verse","objects":[]}
    """
    let decoded = try JSONDecoder().decode(Slide.self, from: Data(json.utf8))
    #expect(decoded.autoAdvance == nil)
}

@Test func slideAutoAdvanceRoundTrips() throws {
    let slide = Slide(
        id: "s", name: "Last", objects: [],
        autoAdvance: AutoAdvance(delaySeconds: 7, loopToStart: true)
    )
    let decoded = try JSONDecoder().decode(
        Slide.self, from: JSONEncoder().encode(slide)
    )
    #expect(decoded.autoAdvance == AutoAdvance(delaySeconds: 7, loopToStart: true))
}

@Test func negativeDelayLeadsTheEnding() {

    #expect(MediaAutoAdvance.leadSeconds(fromDelay: -0.7) == 0.7)
    #expect(MediaAutoAdvance.leadSeconds(fromDelay: 0) == 0)
    #expect(MediaAutoAdvance.leadSeconds(fromDelay: 5) == 0)
    #expect(MediaAutoAdvance.shouldPreFire(remainingWallClock: 0.6, delay: -0.7))
    #expect(!MediaAutoAdvance.shouldPreFire(remainingWallClock: 0.9, delay: -0.7))
    #expect(!MediaAutoAdvance.shouldPreFire(remainingWallClock: 0.1, delay: 0))
}
