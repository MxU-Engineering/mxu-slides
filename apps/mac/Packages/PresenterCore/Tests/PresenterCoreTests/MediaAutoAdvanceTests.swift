import Foundation
import Testing
@testable import PresenterCore

private func playlist(
    delay: Double? = nil, autoAdvance: Bool? = nil
) -> Playlist {
    Playlist(
        id: "p", name: "Loop", playlistKind: .media, entries: [],
        playbackMode: .playAll, crossfadeSeconds: 0,
        autoAdvance: autoAdvance, autoAdvanceDelaySeconds: delay
    )
}

@Test func entryOverrideBeatsPlaylistDelay() {
    let entry = PlaylistEntry(id: "e", refKind: .media, refId: "m", autoAdvanceDelaySeconds: 2)
    #expect(MediaAutoAdvance.delay(for: entry, in: playlist(delay: 7)) == 2)
}

@Test func playlistDelayCoversUnmarkedEntries() {
    let entry = PlaylistEntry(id: "e", refKind: .media, refId: "m")
    #expect(MediaAutoAdvance.delay(for: entry, in: playlist(delay: 7)) == 7)
    #expect(MediaAutoAdvance.delay(for: entry, in: playlist()) == 0)
}

@Test func zeroOverrideIsARealChoice() {

    let entry = PlaylistEntry(id: "e", refKind: .media, refId: "m", autoAdvanceDelaySeconds: 0)
    #expect(MediaAutoAdvance.delay(for: entry, in: playlist(delay: 7)) == 0)
    #expect(
        MediaAutoAdvance.stillDwell(for: entry, in: playlist(delay: 7))
            == MediaAutoAdvance.minimumStillDwellSeconds
    )
}

@Test func autoAdvanceDefaultsOff() {
    #expect(!MediaAutoAdvance.isEnabled(playlist()))
    #expect(MediaAutoAdvance.isEnabled(playlist(autoAdvance: true)))
}

@Test func v39PlaylistDecodesWithAutoAdvanceAbsent() throws {
    let json = """
    {"id":"p","name":"Loop","entries":[{"id":"e","refKind":"media","refId":"m"}],\
    "playbackMode":"playAll","crossfadeSeconds":0}
    """
    let decoded = try JSONDecoder().decode(Playlist.self, from: Data(json.utf8))
    #expect(decoded.autoAdvance == nil)
    #expect(decoded.autoAdvanceDelaySeconds == nil)
    #expect(decoded.entries[0].autoAdvanceDelaySeconds == nil)
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
